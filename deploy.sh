#!/bin/bash
# ============================================================
#  市场活动泳道图 · 一键部署脚本
#  用法: bash deploy.sh
#  前提: 已 SSH 登录到腾讯云服务器（root 权限）
# ============================================================
set -e

APP_DIR="/opt/swimlane-app"
DOMAIN="82.156.82.50"
PORT=8100
SERVICE_NAME="swimlane"

echo "╔══════════════════════════════════════════════════╗"
echo "║   市场活动泳道图 · 协作版 部署脚本 v1.0          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Step 1: 系统环境检查 ──────────────────────────────
echo "[1/7] 检查系统环境..."
if command -v python3 &>/dev/null; then
    echo "  ✓ Python3: $(python3 --version)"
else
    echo "  ✗ 未检测到 Python3，正在安装..."
    if command -v yum &>/dev/null; then
        yum install -y python3 python3-pip
    elif command -v apt &>/dev/null; then
        apt update && apt install -y python3 python3-pip
    else
        echo "  ✗ 无法自动安装 Python3，请手动安装后重试"
        exit 1
    fi
fi

# ── Step 2: 创建项目目录 ──────────────────────────────
echo ""
echo "[2/7] 创建项目目录: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/static"
cd "$APP_DIR"
echo "  ✓ 目录已创建"

# ── Step 3: 写入应用文件 ───────────────────────────────
echo ""
echo "[3/7] 写入应用文件..."

cat > "$APP_DIR/requirements.txt" << 'REQUIREMENTS_EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
REQUIREMENTS_EOF
echo "  ✓ requirements.txt"

cat > "$APP_DIR/main.py" << 'MAINEOF'
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
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (activity_id) REFERENCES activities(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_nodes_activity ON nodes(activity_id);
    CREATE INDEX IF NOT EXISTS idx_nodes_lane_stage ON nodes(lane, stage);
    """)
    conn.commit()
    row = conn.execute("SELECT id FROM activities WHERE id=1").fetchone()
    if not row:
        now = datetime.now().isoformat()
        default_stages = json.dumps(["S1 筹备期","S2 报名期","S3 审核期","S4 会前","S5 现场签到","S6 活动进行","S7 活动后"], ensure_ascii=False)
        default_lanes = json.dumps(["客户视角","业务方","运营 / 平台","数据"], ensure_ascii=False)
        default_lane_desc = json.dumps({"客户视角":"参会人体验","业务方":"市场 PM + 活动 PM","运营 / 平台":"后台执行","数据":"数据沉淀 / 复盘"}, ensure_ascii=False)
        default_stage_desc = json.dumps({"S1 筹备期":"活动信息搭建","S2 报名期":"TA 邀约 / 客户报名","S3 审核期":"名单审核","S4 会前":"通知 / 行前指引","S5 现场签到":"到场签到","S6 活动进行":"议程 / 体验","S7 活动后":"数据 / 复盘"}, ensure_ascii=False)
        conn.execute("""INSERT INTO activities (name,description,stages,lanes,lane_desc,stage_desc,created_at,updated_at)
            VALUES ('市场活动全链路',?,?,?,?,?,?,?)""",
            (default_stages,default_lanes,default_lane_desc,default_stage_desc,now,now))
        conn.commit()
    conn.close()


class NodeCreate(BaseModel):
    activity_id: int = 1
    lane: str
    stage: str
    node_name: str
    pain: str = ""
    has_pain: bool = False
    view_raw: str = ""

class NodeUpdate(BaseModel):
    lane: Optional[str] = None
    stage: Optional[str] = None
    node_name: Optional[str] = None
    pain: Optional[str] = None
    has_pain: Optional[bool] = None
    view_raw: Optional[str] = None

class ActivityUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    stages: Optional[List[str]] = None
    lanes: Optional[List[str]] = None
    lane_desc: Optional[Dict[str, str]] = None
    stage_desc: Optional[Dict[str, str]] = None

class BulkNodesPayload(BaseModel):
    nodes: List[Dict[str, Any]]


@app.get("/api/activity", response_class=JSONResponse)
def get_activity(activity_id: int = 1):
    conn = get_db()
    act = conn.execute("SELECT * FROM activities WHERE id=?", (activity_id,)).fetchone()
    if not act:
        conn.close()
        raise HTTPException(404, "活动不存在")
    rows = conn.execute("SELECT * FROM nodes WHERE activity_id=? ORDER BY sort_order, id", (activity_id,)).fetchall()
    conn.close()
    nodes = []
    for r in rows:
        nodes.append({"id":r["id"],"lane":r["lane"],"stage":r["stage"],"node":r["node_name"],"pain":r["pain"] or "","has_pain":bool(r["has_pain"]),"view_raw":r["view_raw"] or ""})
    return {"activity":{"id":act["id"],"name":act["name"],"description":act["description"]},"stages":json.loads(act["stages"]),"lanes":json.loads(act["lanes"]),"lane_desc":json.loads(act["lane_desc"]),"stage_desc":json.loads(act["stage_desc"]),"nodes":nodes}


@app.post("/api/nodes", response_class=JSONResponse)
def create_node(node: NodeCreate):
    now = datetime.now().isoformat()
    conn = get_db()
    cur = conn.execute("""INSERT INTO nodes (activity_id,lane,stage,node_name,pain,has_pain,view_raw,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
        (node.activity_id,node.lane,node.stage,node.node_name,node.pain,int(node.has_pain),node.view_raw,0,now,now))
    conn.commit()
    nid = cur.lastrowid
    conn.close()
    return {"id": nid, "status": "created"}


@app.put("/api/nodes/{node_id}", response_class=JSONResponse)
def update_node(node_id: int, node: NodeUpdate):
    now = datetime.now().isoformat()
    conn = get_db()
    existing = conn.execute("SELECT id FROM nodes WHERE id=?", (node_id,)).fetchone()
    if not existing:
        conn.close()
        raise HTTPException(404, f"节点 {node_id} 不存在")
    updates, values = [], []
    for f in ["lane","stage","node_name","pain","has_pain","view_raw"]:
        val = getattr(node, f, None)
        if val is not None:
            updates.append(f"{f}=?")
            values.append(val if not isinstance(val, bool) else int(val))
    if not updates:
        conn.close(); return {"id": node_id, "status": "no_change"}
    values.extend([now, node_id])
    conn.execute(f"UPDATE nodes SET {', '.join(updates)}, updated_at=? WHERE id=?", values)
    conn.commit(); conn.close()
    return {"id": node_id, "status": "updated"}


@app.delete("/api/nodes/{node_id}", response_class=JSONResponse)
def delete_node(node_id: int):
    conn = get_db()
    existing = conn.execute("SELECT id FROM nodes WHERE id=?", (node_id,)).fetchone()
    if not existing: conn.close(); raise HTTPException(404, f"节点 {node_id} 不存在")
    conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
    conn.commit(); conn.close()
    return {"id": node_id, "status": "deleted"}


@app.post("/api/nodes/bulk", response_class=JSONResponse)
def bulk_upsert(payload: BulkNodesPayload):
    now = datetime.now().isoformat()
    conn = get_db()
    result = {"created": 0, "updated": 0}
    for n in payload.nodes:
        nid = n.get("id")
        if nid:
            conn.execute("""UPDATE nodes SET lane=?,stage=?,node_name=?,pain=?,has_pain=?,view_raw=?,updated_at=? WHERE id=?""",
                (n.get("lane",""),n.get("stage",""),n.get("node",""),n.get("pain",""),int(n.get("has_pain",False)),n.get("view_raw",""),now,nid))
            result["updated"] += 1
        else:
            cur = conn.execute("""INSERT INTO nodes (activity_id,lanes,stage,node_name,pain,has_pain,view_raw,sort_order,created_at,updated_at) VALUES (1,?,?,?,?,?,?,?,0,?,?)""",
                (n.get("lane",""),n.get("stage",""),n.get("node",""),n.get("pain",""),int(n.get("has_pain",False)),n.get("view_raw",""),now,now))
            result["created"] += cur.lastrowid or 0
    conn.commit(); conn.close()
    return result


@app.delete("/api/nodes/activity/{activity_id}", response_class=JSONResponse)
def clear_activity_nodes(activity_id: int = 1):
    conn = get_db()
    conn.execute("DELETE FROM nodes WHERE activity_id=?", (activity_id,))
    conn.commit()
    cnt = conn.total_changes; conn.close()
    return {"deleted_count": cnt}


@app.post("/api/init-data", response_class=JSONResponse)
def reimport_initial_data():
    sql_path = Path(__file__).parent / "init_data.sql"
    if not sql_path.exists():
        raise HTTPException(500, f"初始化数据文件不存在: {sql_path}")
    conn = get_db()
    conn.execute("DELETE FROM nodes WHERE activity_id=1")
    conn.executescript(sql_path.read_text(encoding="utf-8"))
    conn.commit()
    total = conn.execute("SELECT COUNT(*) FROM nodes WHERE activity_id=1").fetchone()[0]
    conn.close()
    return {"status": "ok", "imported": total, "total": total}


@app.put("/api/activity/{activity_id}", response_class=JSONResponse)
def update_activity(activity_id: int, act: ActivityUpdate):
    now = datetime.now().isoformat()
    conn = get_db()
    existing = conn.execute("SELECT id FROM activities WHERE id=?", (activity_id,)).fetchone()
    if not existing: conn.close(); raise HTTPException(404, "活动不存在")
    updates, values = [], []
    for field in ["name","description"]:
        val = getattr(act, field, None)
        if val is not None: updates.append(f"{field}=?"); values.append(val)
    for field in ["stages","lanes","lane_desc","stage_desc"]:
        val = getattr(act, field, None)
        if val is not None: updates.append(f"{field}=?"); values.append(json.dumps(val, ensure_ascii=False))
    if updates:
        values.extend([now, activity_id])
        conn.execute(f"UPDATE activities SET {', '.join(updates)}, updated_at=? WHERE id=?", values)
        conn.commit()
    conn.close()
    return {"id": activity_id, "status": "updated"}


@app.get("/", response_class=HTMLResponse)
def index():
    html_path = STATIC_DIR / "index.html"
    if html_path.exists(): return html_path.read_text(encoding="utf-8")
    return "<h1>前端文件未找到</h1>"


@app.on_event("startup")
def startup():
    init_db()
    print("✅ 数据库初始化完成")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8100)
MAINEOF
echo "  ✓ main.py"


# ── Step 4: 安装 Python 依赖 ───────────────────────────
echo ""
echo "[4/7] 安装 Python 依赖..."
pip3 install -r requirements.txt -q --break-system-packages 2>/dev/null || pip3 install -r requirements.txt -q
echo "  ✓ 依赖安装完成"

# ── Step 5: 初始化数据库 + 导入数据 ───────────────────
echo ""
echo "[5/7] 初始化数据库并导入节点数据..."
python3 -c "
import sys; sys.path.insert(0, '$APP_DIR')
from main import app, init_db
init_db()
print('✅ 数据库已初始化')

# 导入初始数据
import sqlite3, pathlib
conn = sqlite3.connect(str(pathlib.Path('$APP_DIR') / 'swimlane.db'))
sql_file = pathlib.Path('$APP_DIR') / 'init_data.sql'
if sql_file.exists():
    conn.executescript(sql_file.read_text('utf-8'))
    conn.commit()
    cnt = conn.execute('SELECT COUNT(*) FROM nodes').fetchone()[0]
    pain_cnt = conn.execute(\"SELECT COUNT(*) FROM nodes WHERE has_pain=1\").fetchone()[0]
    print(f'✅ 节点数据已导入: {cnt} 个节点 ({pain_cnt} 个痛点)')
else:
    print('⚠️ 未找到 init_data.sql，请手动上传')
conn.close()
"
echo ""

# ── Step 6: 配置 systemd 服务（开机自启） ──────────────
echo "[6/7] 配置系统服务（开机自启）..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICEEOF
[Unit]
Description=Swimlane Chart Collaborative Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}
sleep 2

if systemctl is-active ${SERVICE_NAME} >/dev/null 2>&1; then
    echo "  ✓ 服务已启动 (端口 $PORT)"
else
    echo "  ⚠️ 服务启动失败，查看日志: journalctl -u ${SERVICE_NAME} -f"
fi

# ── Step 7: 配置防火墙 ────────────────────────────────
echo ""
echo "[7/7] 配置防火墙..."

# 尝试开放端口
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo "  ✓ firewalld 端口 ${PORT} 已开放"
elif command -v ufw &>/dev/null; then
    ufw allow ${PORT}/tcp 2>/dev/null || true
    echo "  ✓ ufw 端口 ${PORT} 已开放"
else
    echo "  ℹ️ 未检测到防火墙工具，请手动在腾讯云安全组开放 TCP ${PORT}"
fi

# ── 完成 ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║              🎉 部署完成！                        ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  访问地址: http://${DOMAIN}:${PORT}              ║"
echo "║  服务状态: systemctl status ${SERVICE_NAME}       ║"
echo "║  查看日志: journalctl -u ${SERVICE_NAME} -f      ║"
echo "║  重启服务: systemctl restart ${SERVICE_NAME}     ║"
echo "║                                                  ║"
echo "║  ⚠️ 别忘了在腾讯云控制台 → 安全组 开放 ${PORT}   ║"
echo "╚══════════════════════════════════════════════════╝"
