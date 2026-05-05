"""
市场活动泳道图 · 协作版后端
FastAPI + SQLite
支持多人实时编辑、多活动模板扩展
"""
import sqlite3
import json
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

DB_PATH = Path(__file__).parent / "swimlane.db"
STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="市场活动泳道图协作版", version="1.0.0")

# ── 数据库 ──────────────────────────────────────────────


def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db():
    conn = get_db()
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS activities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL DEFAULT '默认活动',
        description TEXT DEFAULT '',
        stages TEXT NOT NULL DEFAULT '[]',
        lanes TEXT NOT NULL DEFAULT '[]',
        lane_desc TEXT NOT NULL DEFAULT '{}',
        stage_desc TEXT NOT NULL DEFAULT '{}',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        activity_id INTEGER NOT NULL DEFAULT 1,
        lane TEXT NOT NULL,
        stage TEXT NOT NULL,
        node_name TEXT NOT NULL,
        pain TEXT DEFAULT '',
        has_pain INTEGER NOT NULL DEFAULT 0,
        view_raw TEXT DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'todo',
        priority TEXT NOT NULL DEFAULT 'P2',
        owner TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (activity_id) REFERENCES activities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_nodes_activity ON nodes(activity_id);
    CREATE INDEX IF NOT EXISTS idx_nodes_lane_stage ON nodes(lane, stage);
    CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status);
    CREATE INDEX IF NOT EXISTS idx_nodes_priority ON nodes(priority);
    """)
    conn.commit()

    # 自动迁移：为已有数据库补充字段（幂等）
    existing_cols = [r[1] for r in conn.execute("PRAGMA table_info(nodes)").fetchall()]
    for col, ddl in [
        ("status", "ALTER TABLE nodes ADD COLUMN status TEXT NOT NULL DEFAULT 'todo'"),
        ("priority", "ALTER TABLE nodes ADD COLUMN priority TEXT NOT NULL DEFAULT 'P2'"),
        ("owner", "ALTER TABLE nodes ADD COLUMN owner TEXT DEFAULT ''"),
    ]:
        if col not in existing_cols:
            conn.execute(ddl)
    conn.commit()

    # 如果没有活动记录，创建默认的
    row = conn.execute("SELECT id FROM activities WHERE id=1").fetchone()
    if not row:
        now = datetime.now().isoformat()
        default_stages = json.dumps([
            "S1 筹备期", "S2 报名期", "S3 审核期",
            "S4 会前", "S5 现场签到", "S6 活动进行", "S7 活动后"
        ], ensure_ascii=False)
        default_lanes = json.dumps([
            "客户视角", "业务方", "运营 / 平台", "数据"
        ], ensure_ascii=False)
        default_lane_desc = json.dumps({
            "客户视角": "参会人体验",
            "业务方": "市场 PM + 活动 PM",
            "运营 / 平台": "后台执行",
            "数据": "数据沉淀 / 复盘",
        }, ensure_ascii=False)
        default_stage_desc = json.dumps({
            "S1 筹备期": "活动信息搭建",
            "S2 报名期": "TA 邀约 / 客户报名",
            "S3 审核期": "名单审核",
            "S4 会前": "通知 / 行前指引",
            "S5 现场签到": "到场签到",
            "S6 活动进行": "议程 / 体验",
            "S7 活动后": "数据 / 复盘",
        }, ensure_ascii=False)
        conn.execute(
            """INSERT INTO activities (name, description, stages, lanes, lane_desc, stage_desc, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            ("市场活动全链路", "", default_stages, default_lanes,
             default_lane_desc, default_stage_desc, now, now)
        )
        conn.commit()
    conn.close()


# ── Pydantic 模型 ──────────────────────────────────────


class NodeCreate(BaseModel):
    activity_id: int = 1
    lane: str
    stage: str
    node_name: str
    pain: str = ""
    has_pain: bool = False
    view_raw: str = ""
    status: str = "todo"
    priority: str = "P2"
    owner: str = ""


class NodeUpdate(BaseModel):
    lane: Optional[str] = None
    stage: Optional[str] = None
    node_name: Optional[str] = None
    pain: Optional[str] = None
    has_pain: Optional[bool] = None
    view_raw: Optional[str] = None
    status: Optional[str] = None
    priority: Optional[str] = None
    owner: Optional[str] = None


class ActivityUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    stages: Optional[List[str]] = None
    lanes: Optional[List[str]] = None
    lane_desc: Optional[Dict[str, str]] = None
    stage_desc: Optional[Dict[str, str]] = None


class BulkNodesPayload(BaseModel):
    nodes: List[Dict[str, Any]]


# ── API：获取完整泳道数据（前端一次加载） ───────────


@app.get("/api/activity", response_class=JSONResponse)
def get_activity(activity_id: int = 1):
    """获取活动配置 + 所有节点，前端一次请求拿完全部数据"""
    conn = get_db()
    act = conn.execute(
        "SELECT * FROM activities WHERE id=?", (activity_id,)
    ).fetchone()
    if not act:
        conn.close()
        raise HTTPException(404, "活动不存在")

    rows = conn.execute(
        "SELECT * FROM nodes WHERE activity_id=? ORDER BY sort_order, id",
        (activity_id,)
    ).fetchall()
    conn.close()

    nodes = []
    for r in rows:
        nodes.append({
            "id": r["id"],
            "lane": r["lane"],
            "stage": r["stage"],
            "node": r["node_name"],
            "pain": r["pain"] or "",
            "has_pain": bool(r["has_pain"]),
            "view_raw": r["view_raw"] or "",
            "status": r["status"] if "status" in r.keys() else "todo",
            "priority": r["priority"] if "priority" in r.keys() else "P2",
            "owner": (r["owner"] if "owner" in r.keys() else "") or "",
        })

    return {
        "activity": {
            "id": act["id"],
            "name": act["name"],
            "description": act["description"],
        },
        "stages": json.loads(act["stages"]),
        "lanes": json.loads(act["lanes"]),
        "lane_desc": json.loads(act["lane_desc"]),
        "stage_desc": json.loads(act["stage_desc"]),
        "nodes": nodes,
    }


# ── API：节点 CRUD ─────────────────────────────────────


@app.post("/api/nodes", response_class=JSONResponse)
def create_node(node: NodeCreate):
    now = datetime.now().isoformat()
    conn = get_db()
    cur = conn.execute(
        """INSERT INTO nodes (activity_id, lane, stage, node_name, pain, has_pain, view_raw, sort_order, status, priority, owner, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)""",
        (node.activity_id, node.lane, node.stage, node.node_name,
         node.pain, int(node.has_pain), node.view_raw,
         node.status, node.priority, node.owner, now, now),
    )
    conn.commit()
    node_id = cur.lastrowid
    conn.close()
    return {"id": node_id, "status": "created"}


@app.put("/api/nodes/{node_id}", response_class=JSONResponse)
def update_node(node_id: int, node: NodeUpdate):
    now = datetime.now().isoformat()
    conn = get_db()
    # 先查是否存在
    existing = conn.execute("SELECT id FROM nodes WHERE id=?", (node_id,)).fetchone()
    if not existing:
        conn.close()
        raise HTTPException(404, f"节点 {node_id} 不存在")

    updates = []
    values = []
    fields = ["lane", "stage", "node_name", "pain", "has_pain", "view_raw", "status", "priority", "owner"]
    db_fields = {"node_name": "node_name"}
    for f in fields:
        val = getattr(node, f, None)
        if val is not None:
            col = f
            updates.append(f"{col}=?")
            values.append(val if not isinstance(val, bool) else int(val))

    if not updates:
        conn.close()
        return {"id": node_id, "status": "no_change"}

    values.extend([now, node_id])
    conn.execute(
        f"UPDATE nodes SET {', '.join(updates)}, updated_at=? WHERE id=?",
        values,
    )
    conn.commit()
    conn.close()
    return {"id": node_id, "status": "updated"}


@app.delete("/api/nodes/{node_id}", response_class=JSONResponse)
def delete_node(node_id: int):
    conn = get_db()
    existing = conn.execute("SELECT id FROM nodes WHERE id=?", (node_id,)).fetchone()
    if not existing:
        conn.close()
        raise HTTPException(404, f"节点 {node_id} 不存在")
    conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
    conn.commit()
    conn.close()
    return {"id": node_id, "status": "deleted"}


# ── API：批量操作 ──────────────────────────────────────


@app.post("/api/nodes/bulk", response_class=JSONResponse)
def bulk_upsert(payload: BulkNodesPayload):
    """批量写入节点（用于导入/同步）"""
    now = datetime.now().isoformat()
    conn = get_db()
    result = {"created": 0, "updated": 0}
    for n in payload.nodes:
        nid = n.get("id")
        if nid:
            # 更新已有节点
            conn.execute(
                """UPDATE nodes SET lane=?, stage=?, node_name=?, pain=?, has_pain=?, view_raw=?, updated_at=?
                WHERE id=?""",
                (n.get("lane", ""), n.get("stage", ""), n.get("node", ""),
                 n.get("pain", ""), int(n.get("has_pain", False)),
                 n.get("view_raw", ""), now, nid),
            )
            result["updated"] += 1
        else:
            cur = conn.execute(
                """INSERT INTO nodes (activity_id, lane, stage, node_name, pain, has_pain, view_raw, sort_order, created_at, updated_at)
                VALUES (1, ?, ?, ?, ?, ?, ?, 0, ?, ?)""",
                (n.get("lane", ""), n.get("stage", ""), n.get("node", ""),
                 n.get("pain", ""), int(n.get("has_pain", False)),
                 n.get("view_raw", ""), now, now),
            )
            result["created"] += cur.lastrowid or 0
    conn.commit()
    conn.close()
    return result


@app.delete("/api/nodes/activity/{activity_id}", response_class=JSONResponse)
def clear_activity_nodes(activity_id: int = 1):
    """清空某活动的所有节点"""
    conn = get_db()
    conn.execute("DELETE FROM nodes WHERE activity_id=?", (activity_id,))
    conn.commit()
    cnt = conn.total_changes
    conn.close()
    return {"deleted_count": cnt}


# ── API：重新导入初始数据 ─────────────────────────────


@app.post("/api/init-data", response_class=JSONResponse)
def reimport_initial_data():
    """从 SQL 文件重新导入初始 52 个节点数据（重置用）"""
    sql_path = Path(__file__).parent / "init_data.sql"
    if not sql_path.exists():
        raise HTTPException(500, f"初始化数据文件不存在: {sql_path}")

    conn = get_db()

    # 清空
    conn.execute("DELETE FROM nodes WHERE activity_id=1")

    # 执行 SQL
    sql_content = sql_path.read_text(encoding="utf-8")
    conn.executescript(sql_content)
    conn.commit()

    total = conn.execute("SELECT COUNT(*) FROM nodes WHERE activity_id=1").fetchone()[0]
    conn.close()

    return {"status": "ok", "imported": imported, "total": total}


# ── API：活动配置 CRUD ────────────────────────────────


@app.put("/api/activity/{activity_id}", response_class=JSONResponse)
def update_activity(activity_id: int, act: ActivityUpdate):
    now = datetime.now().isoformat()
    conn = get_db()
    existing = conn.execute("SELECT id FROM activities WHERE id=?", (activity_id,)).fetchone()
    if not existing:
        conn.close()
        raise HTTPException(404, "活动不存在")

    updates = []
    values = []
    for field in ["name", "description"]:
        val = getattr(act, field, None)
        if val is not None:
            updates.append(f"{field}=?")
            values.append(val)
    for field in ["stages", "lanes", "lane_desc", "stage_desc"]:
        val = getattr(act, field, None)
        if val is not None:
            updates.append(f"{field}=?")
            values.append(json.dumps(val, ensure_ascii=False))

    if updates:
        values.extend([now, activity_id])
        conn.execute(
            f"UPDATE activities SET {', '.join(updates)}, updated_at=? WHERE id=?",
            values,
        )
        conn.commit()
    conn.close()
    return {"id": activity_id, "status": "updated"}


# ── 前端页面 ───────────────────────────────────────────


@app.get("/", response_class=HTMLResponse)
def index():
    """返回前端 HTML 页面"""
    html_path = STATIC_DIR / "index.html"
    if html_path.exists():
        return html_path.read_text(encoding="utf-8")
    return "<h1>请将前端文件放到 static/index.html</h1>"


# ── 启动初始化 ─────────────────────────────────────────


@app.on_event("startup")
def startup():
    init_db()
    print("✅ 数据库初始化完成")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8100)
