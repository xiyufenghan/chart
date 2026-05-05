# 市场活动全链路 · 协作版

> 多人协作的市场活动节点盘点工具，基于 FastAPI + SQLite + 原生 JS 构建。  
> 用于团队讨论市场活动各环节流程、痛点识别、任务跟踪。

🌐 **在线访问**：https://chart.dacongming.chat

---

## 📋 项目概览

这是一个 **泳道图 / 看板** 形态的协作工具，把市场活动的全链路按 **泳道（参与角色）× 阶段（时间线）** 展开，每个交叉单元格内放置该阶段、该角色要做的「节点」。每个节点可以：

- 标记为 **痛点**（红色边）并附上痛点描述
- 设置 **状态**（待开发 / 开发中 / 已完成 / 受阻）
- 设置 **优先级**（P0 / P1 / P2 / P3）
- 指定 **负责人**

所有改动实时同步到服务器，多人协作时刷新即可看到他人改动。

---

## 🏗️ 技术栈

| 层 | 选型 | 说明 |
|----|------|------|
| 后端 | FastAPI 0.115 + Uvicorn | 单文件 ~430 行 |
| 数据库 | SQLite（WAL 模式） | 单文件 `swimlane.db` |
| 前端 | 原生 HTML/CSS/JS | 单文件 `static/index.html`，零构建 |
| 部署 | systemd + Nginx + Let's Encrypt | 北京 Lighthouse 服务器 |

无前端构建、无 ORM、无 Redis、无 Docker，**最少依赖、最易维护**。

---

## 📐 数据模型

### activities 表（活动元配置）
| 字段 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK | 活动 ID |
| name | TEXT | 活动名称 |
| stages | TEXT (JSON) | 阶段列表，如 `["S1 筹备期", "S2 报名期", ...]` |
| lanes | TEXT (JSON) | 泳道列表，如 `["客户视角", "业务方", ...]` |
| lane_desc | TEXT (JSON) | 泳道说明 `{lane: desc}` |
| stage_desc | TEXT (JSON) | 阶段说明 `{stage: desc}` |
| created_at / updated_at | TEXT | 时间戳 |

### nodes 表（节点）
| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| id | INTEGER PK | - | 节点 ID |
| activity_id | INTEGER | 1 | 所属活动 |
| lane | TEXT | - | 泳道 |
| stage | TEXT | - | 阶段 |
| node_name | TEXT | - | 节点名称 |
| pain | TEXT | `''` | 痛点描述 |
| has_pain | INTEGER | 0 | 是否痛点（1/0） |
| view_raw | TEXT | `''` | 原始角色视角（市场PM / 活动PM 等）|
| sort_order | INTEGER | 0 | 排序 |
| **status** | TEXT | `'todo'` | **状态：todo/doing/done/blocked** |
| **priority** | TEXT | `'P2'` | **优先级：P0/P1/P2/P3** |
| **owner** | TEXT | `''` | **负责人** |
| created_at / updated_at | TEXT | - | 时间戳 |

⚠️ `status` / `priority` / `owner` 三个字段在 v1.1 增加，旧库会自动迁移补字段。

---

## 🔌 API

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/` | 返回前端页面 |
| GET | `/api/activity?activity_id=1` | 一次性返回完整活动配置 + 全部节点 |
| POST | `/api/nodes` | 创建节点 |
| PUT | `/api/nodes/{id}` | 更新节点（任意字段） |
| DELETE | `/api/nodes/{id}` | 删除节点 |
| POST | `/api/nodes/bulk` | 批量插入/更新 |
| DELETE | `/api/nodes/activity/{aid}` | 清空某活动所有节点 |
| POST | `/api/init-data` | 从 `init_data.sql` 重新导入初始数据 |
| PUT | `/api/activity/{aid}` | 更新活动配置（泳道/阶段/说明等）|

---

## 🚀 本地运行

```bash
pip install -r requirements.txt
python3 -m uvicorn main:app --host 0.0.0.0 --port 8100
# 浏览器访问 http://localhost:8100
```

首次启动时若 `init_data.sql` 存在，会自动加载 52 个初始节点。

---

## 🌐 服务器部署

服务器：腾讯云 Lighthouse `lhins-1kh87y02`（北京，82.156.82.50）

```bash
# 一键部署
bash deploy.sh
# 它会：
# 1. 创建 /opt/swimlane-app/
# 2. 写入 main.py + requirements.txt
# 3. 安装依赖
# 4. 初始化数据库 + 导入 init_data.sql
# 5. 配置 systemd（开机自启）
# 6. 开放防火墙 8100 端口
```

### Nginx 反向代理（HTTPS）

```nginx
# /etc/nginx/conf.d/chart.conf
server {
    listen 443 ssl;
    server_name chart.dacongming.chat;
    ssl_certificate /etc/letsencrypt/live/chart.dacongming.chat/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/chart.dacongming.chat/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:8100;
        proxy_set_header Host $host;
    }
}
```

证书通过 Certbot 申请：
```bash
certbot --nginx -d chart.dacongming.chat
```

---

## 🎨 UI 说明

### 状态徽章（左上角）
| 状态 | 颜色 | 视觉效果 |
|------|------|---------|
| 🔴 待开发 (todo) | 红 | 默认状态 |
| 🟡 开发中 (doing) | 黄 | 卡片有浅黄高亮 |
| 🟢 已完成 (done) | 绿 | 文字加删除线 + 整卡半透明 |
| ⚫ 受阻 (blocked) | 灰 | 卡片灰底 |

### 优先级（节点左边竖条）
- **P0** — 深红色粗条（紧急高优）
- **P1** — 橙色（重要）
- **P2** — 蓝色（常规，默认）
- **P3** — 灰色（低优）

### 筛选器
顶部有 3 组筛选 chip：状态 / 优先级 / 痛点，点击即时过滤（不匹配的卡片变灰 25% 透明度）。

### 进度条
横向分段彩色进度条，实时显示完成 / 进行中 / 受阻 / 待开发 的占比。

---

## 📝 开发记录

### v1.0 · 2026-05-05 初始版本
- ✅ FastAPI + SQLite 后端，提供完整 CRUD
- ✅ 4 泳道 × 7 阶段网格视图
- ✅ 节点拖拽（编辑模式下跨格移动）
- ✅ 痛点标记（红边 + 描述）
- ✅ 实时同步：每次操作即时落库，30s 自动刷新拉取他人改动
- ✅ 部署到腾讯云 Lighthouse（北京），HTTPS 通过 Let's Encrypt

### v1.1 · 2026-05-05 增强：状态 + 优先级
- ✅ 数据模型扩展：`nodes` 表新增 `status` / `priority` / `owner` 字段，含自动迁移
- ✅ 状态系统：4 档循环（todo → doing → done → blocked）
- ✅ 优先级系统：4 档（P0 / P1 / P2 / P3）
- ✅ 负责人字段：每个节点可指定 `owner`
- ✅ 工具栏新增筛选器：按状态 / 优先级 / 仅看痛点 过滤
- ✅ 进度概览：分段彩色进度条 + P0 剩余计数
- ✅ 视觉重构：状态徽章 + 优先级粗条 + 负责人标签
- ✅ 编辑交互：点徽章一键循环切换状态/优先级，无需弹窗

### 部署里程碑
- 🌐 域名 `chart.dacongming.chat` 接入（DNSPod 泛域名解析）
- 🔒 HTTPS 证书申请 + Nginx 反向代理（80→443 自动跳转）

---

## 🤝 协作规约

1. **不要在生产环境直接修改数据库**，所有改动通过界面操作
2. **大改前先 `重置` 备份当前数据**（导出 `swimlane.db`）
3. **痛点描述尽量具体**：包含「现状 + 期望 + 影响」三段式
4. **P0 节点必须有 owner**，P1 建议有 owner

---

## 🧰 项目结构

```
.
├── main.py              # FastAPI 后端（CRUD + 静态文件托管）
├── requirements.txt     # fastapi + uvicorn
├── init_data.sql        # 52 个初始节点（含 38 个痛点）
├── deploy.sh            # 一键部署脚本
├── static/
│   └── index.html       # 单文件前端（HTML + CSS + JS 一体）
├── README.md            # 本文档
└── .gitignore
```

---

## 📜 License

内部使用，未授权
