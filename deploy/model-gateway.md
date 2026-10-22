# 单服务器部署：云端模型 + 记忆 + 知识库（一站式 / 飞牛两种形态）

> **与本仓的关系**：本仓（`server-account` + `web`）是**云管理** —— 只管「账号 / 积分 / 模型目录 /
> 授权发号」，不转发推理。客户端真正发推理请求打的是**记忆网关**，知识库检索打的是 **WeKnora 的 MCP 端点**。
>
> 本文目标：**照着做，部署完客户端就能用**。每步都有「预期输出」，不一致就停在那步排查，别往下走。
> 所有 `<...>` 是唯一需要替换的地方；密钥一律不写进仓库。

---

## 目录

- [0. 5 分钟速览（命令序列）](#0-5-分钟速览命令序列)
- [1. 组件与开源地址](#1-组件与开源地址)
- [2. 两条链路怎么衔接](#2-两条链路怎么衔接)
- [3. 方案 A：一台服务器一站式](#3-方案-a一台服务器一站式)
- [4. 方案 B：只搬模型通道](#4-方案-b只搬模型通道)
- [5. 方案 C：frp 隧道（家里机器，对照）](#5-方案-cfrp-隧道家里机器对照)
- [6. 飞牛 OS（fnOS）部署](#6-飞牛-osfnos部署)
- [7. 从 C 迁到 A](#7-从-c-迁到-a)
- [8. 运维加固与排障](#8-运维加固与排障)
- [9. 常见问题](#9-常见问题)

---

## 0. 5 分钟速览（命令序列）

```bash
# ① 记忆中枢（记忆空间面板 + 记忆网关）：一条命令，交互式填两组 LLM，先预检通路再拉起
git clone https://github.com/TencentCloud/TencentDB-Agent-Memory.git
cd TencentDB-Agent-Memory/deploy/global-images && ./start-all.sh

# ② 知识库（WeKnora）：clone → 填 .env → compose 起
git clone https://github.com/Tencent/WeKnora.git && cd WeKnora
cp .env.example .env && $EDITOR .env
docker compose pull && docker compose up -d

# ③ 云管理（本仓）：发号服务
git clone https://github.com/PMZPZM0/codex-cloud-assistant.git && cd codex-cloud-assistant
sudo bash deploy/install.sh
sudo nano /opt/codex-cloud-admin/config.env      # 见 §3.4 必填表

# ④ 反代 + 验收（模板与脚本都在本仓 deploy/ 下）
sudo cp deploy/Caddyfile.example /etc/caddy/sites.caddy && sudo nano /etc/caddy/sites.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
bash deploy/verify-all.sh <你的域名>              # 全绿才算部署完成
```

---

## 1. 组件与开源地址

| 组件 | 作用 | 开源地址 | 镜像 / 产物 | 默认端口 |
|---|---|---|---|---|
| **记忆空间（面板）+ 记忆中枢** | L0–L3 分层记忆、技能、知识 Wiki、代码图谱 | <https://github.com/TencentCloud/TencentDB-Agent-Memory>（MIT） | Docker Hub `agentmemory/memory-core`、`agentmemory/memory-hub` | `8420`（core）/ `8125`（Panel）/ `8424`（Knowledge） |
| **记忆网关 proxy** | 挡在模型前面：注入 L2/L3 记忆与技能后转发上游 LLM | 同上仓 | `agentmemory/memory-proxy` | `8096` |
| **知识库** | 文档 → RAG / Agent / 自维护 Wiki；对外暴露 MCP 端点 | <https://github.com/Tencent/WeKnora>（见仓库 LICENSE） | `docker compose`（前端 + API + PG + Redis） | `80`（前端）/ `8080`（API） |
| **云管理（本仓）** | 账号 / 积分 / 模型目录 / 知识库与记忆授权；给客户端**发号** | <https://github.com/PMZPZM0/codex-cloud-assistant> | `server-account/server.js`（Node ≥18，零依赖） | `8091` |
| **上游中继（可选）** | 自建模型转发与计费；直连商用 API 可不装 | 自建 | — | 自定（示例 `18081`） |

三个 `agentmemory/*` 镜像都在 Docker Hub 公开命名空间、多架构（amd64/arm64），**无需登录**。
固定版本把 tag 从 `:latest` 换成具体版本（如 `:1.0.0-beta.1`）即可。

---

## 2. 两条链路怎么衔接

### 链路 1 · 模型 + 记忆（同步，发生在每次推理之前）

```
客户端 ──POST /<client>/<instance>/v1/messages──> 反代 ──> 记忆网关 proxy :8096
   proxy ──(1) 读 L2/L3 记忆 / 技能──> memory-core :8420
         ──(2) 拼进 system 与上下文──> 上游 LLM（PROXY_UPSTREAM_URL）
         ──(3) SSE 原样回传──> 客户端
```

客户端只填三样：**Base URL**、**API Key**、**模型 id**。记忆读写全在 proxy/core 侧完成，客户端零改造。
⇒ 所以它是「挡在调用链路上的一层」，proxy/core 挂了模型就用不了（今天 502 事故的本质）。

### 链路 2 · 知识库（按需，与推理解耦）

```
客户端 MCP 连接器 ──Streamable HTTP──> <WEKNORA_BASE>/mcp/<endpointId> ──> 该账号的私有知识库
```

云管理用 **WeKnora 管理员 Key** 调：`POST /api/v1/knowledge-bases` → `POST /api/v1/mcp-endpoints`
（限定工具与速率）→ 得到 `token` 与 `mcpUrl = <WEKNORA_BASE>/mcp/<endpointId>`，
再由 `/cloud-api` 下发给客户端，自动配成 `cloud-kb` 连接器。

⛔ **两套鉴权互不相通**：模型链路是记忆网关的 key，知识库链路是 WeKnora 的 endpoint token。

---

## 3. 方案 A：一台服务器一站式

### 3.1 前置自查

```bash
docker --version && docker compose version     # Docker 24+ / compose v2
node -v                                         # v18 以上（云管理要求）
caddy version                                   # 反代（也可用 Nginx，本文以 Caddy 为例）
```

资源：**8 核 / 16 GB / 100 GB 起**（详见 §7.2 预算表）。磁盘不是瓶颈，内存才是。

域名（全文用 `<域名>` 代替）：`a.<域名>`（云管理）、`memapi.<域名>`（记忆网关）、
`mem.<域名>`（记忆空间面板）、`kb.<域名>`（知识库）。四条 A 记录都指向这台服务器。

### 3.2 记忆中枢 + 记忆空间 + 记忆网关

```bash
git clone https://github.com/TencentCloud/TencentDB-Agent-Memory.git
cd TencentDB-Agent-Memory/deploy/global-images
./start-all.sh
```

`start-all.sh` 是**交互式**的，依次做四件事：

1. `.env` 不存在就从 `.env.example` 复制（不用手动 cp）；
2. 填**两组 LLM**（回车 = 保留默认）：

   | 组 | 变量 | 用途 |
   |---|---|---|
   | memory 组 | `MEMORY_LLM_BASE_URL` / `_API_KEY` / `_MODEL` / `_PROTOCOL`（`openai`/`anthropic`） | 记忆提炼、embedding、wiki ingest |
   | proxy 组 | `PROXY_UPSTREAM_URL` / `_API_KEY` / `_MODEL` | 客户端请求最终转发目标 |

   两组可相同，也可「便宜的做记忆、强的做主对话」；
3. **立刻预检两组 LLM 通路**（OpenAI 兼容走 `GET /models`，不耗 token；Anthropic 走 `max_tokens=1`，
   消耗 ≤10 token），不通会让你重填 —— 这步能挡掉九成「起来但用不了」；
4. 通过后拉起三个容器：

| 容器 | 端口 | 用途 | 验证 |
|---|---|---|---|
| `tdai-memory-core` | 8420 | 记忆读写 / 鉴权 / skill·RAG 数据面 | `curl -s localhost:8420/` |
| `tdai-memory-hub` | 8125 / 8424 | Panel 面板 + Knowledge 服务 | 浏览器开 `http://<服务器IP>:8125/` |
| `tdai-proxy` | 8096 | 客户端 API 入口 | `curl -s localhost:8096/health` → `{"status":"ok"}` |

**⛔ 生产必改三项**（在 `.env` 取消注释后覆盖；默认值只适合本机试跑）：

| 变量 | 默认 | 风险 |
|---|---|---|
| `MEMORY_CORE_GATEWAY_API_KEY` | `local` | hub/proxy 调 core 的 Bearer，拿到端口就能冒充 |
| `MEMORY_CORE_ADMIN_USERNAME` / `_USER_KEY` | `admin` / `admin` | system_admin 登录凭据 |
| `KNOWLEDGE_SERVICE_KEY` | 脚本自动生成 `ks-svc-*` | 保持自动生成即可（要外部编排才手填） |

改完 `./stop-all.sh && ./start-all.sh` 重启；数据在命名卷 `tdai-memory-core-data` / `tdai-panel-data`，不丢。

端口冲突就在 `.env` 改 `PANEL_PORT` / `MEMORY_CORE_PORT` / `KNOWLEDGE_PORT` / `PROXY_PORT`，
并同步 `KNOWLEDGE_PUBLIC_BASE_URL`（⛔ 必须以 `/v3` 结尾，否则面板报错）。

### 3.3 知识库（WeKnora）

```bash
git clone https://github.com/Tencent/WeKnora.git && cd WeKnora
cp .env.example .env
$EDITOR .env            # 至少确认：模型配置、WEKNORA_VERSION（固定版本比 latest 稳）
docker compose pull
docker compose up -d
```

起来后浏览器开 `http://<服务器IP>/` 走**首次初始化向导**（建管理员）。
API 在 `:8080`，前端在 `:80`；需要图谱/对象存储加 profile：
`docker compose --profile neo4j --profile minio up -d`。

**建「知识库 + MCP 端点」**（云管理会调这两个 API，手动建一次便于验证）：

```bash
KEY=<WeKnora 管理员 API Key>
BASE=http://127.0.0.1:8080

# 1) 建库
curl -s -X POST $BASE/api/v1/knowledge-bases -H "X-API-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"name":"demo","description":"联调库","type":"document"}'

# 2) 建 MCP 端点（只读检索工具 + 限速）
curl -s -X POST $BASE/api/v1/mcp-endpoints -H "X-API-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"name":"demo-mcp","description":"只读检索","enabled":true,
       "knowledge_base_ids":["<上一步返回的 id>"],
       "tools":["list_knowledge_bases","search_knowledge","grep_chunks","list_documents","read_document","ask"],
       "rate_limit_per_minute":120}'
```

第 2 步返回里的 `token` 就是客户端要用的凭据，端点地址是 `http://<host>:8080/mcp/<endpointId>`。

### 3.4 云管理（本仓）

```bash
git clone https://github.com/PMZPZM0/codex-cloud-assistant.git && cd codex-cloud-assistant
sudo bash deploy/install.sh
sudo nano /opt/codex-cloud-admin/config.env
```

`config.env` 必填：

| 变量 | 填什么 |
|---|---|
| `HARNESS_ACCOUNTS_ORIGINS` | `https://a.<域名>`（不填登录会 403） |
| `WEKNORA_BASE` | `http://127.0.0.1:8080`（或你的 `https://kb.<域名>`） |
| `WEKNORA_ADMIN_KEY` | §3.3 的管理员 API Key |
| 记忆相关（若面板要显示记忆状态） | 按 `config.example.env` 注释填网关地址与实例名 |

```bash
sudo systemctl restart codex-cloud-admin
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8091/    # 期望 200
```

### 3.5 反代（四条路由）

模板在 **`deploy/Caddyfile.example`**，替换域名即可：

```caddyfile
a.<域名> {
	handle_path /cloud-api/* { reverse_proxy 127.0.0.1:8091 }
	root * /opt/codex-cloud-admin/web
	file_server
}

memapi.<域名> {
	# ⛔ handle_path 会剥掉前缀：/<client>/<instance>/v1/messages → /v1/messages
	handle_path /*/* { reverse_proxy 127.0.0.1:8096 }
}

mem.<域名> { reverse_proxy 127.0.0.1:8125 }
kb.<域名>  { reverse_proxy 127.0.0.1:80 }
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

### 3.6 客户端配置

| 项 | 值 | 说明 |
|---|---|---|
| Base URL | `https://memapi.<域名>/claude-code/default` | 中间是 client 名，`default` 是实例名 |
| API Key | `sk-mem-…`（面板里该实例的 key）或云管理下发的代理令牌 | 不是上游 LLM 的 key |
| 模型 | 面板里为该实例启用的模型 id | ⛔ 必须与 `PROXY_UPSTREAM_MODEL` 认得的一致 |
| 上游协议 | 自动 | 网关侧翻译；Claude 客户端走 Anthropic，OpenAI 客户端走 `/v1` |

### 3.7 验收（跑脚本，全绿才算完）

```bash
bash deploy/verify-all.sh <域名>
```

逐项检查：网关 `/health`、core/hub 端口、知识库 API、云管理 API、四条反代域名，以及
「模型目录接口返回**鉴权错误而不是 502**」这条关键判据。FAIL 项会打印对应排查命令（见 §8.2）。

---

## 4. 方案 B：只搬模型通道

### 4.1 先决条件（⛔ 不看会 401）

客户端发 `Authorization: Bearer sk-mem-*`（记忆网关签发），上游中继只认自己的 key。
换 key 原本发生在网关里。二选一：

1. 中继侧加 `sk-mem-* → 上游 key` 的映射（推荐）；
2. 客户端直接填中继 key，Base URL 改成中继地址（不再走 `/<client>/<instance>`）。

不做任一条而直接改反代 ⇒ 客户端拿 **401 invalid api key**，这是**预期**，别误判成网关挂了。

### 4.2 反代改写

```caddyfile
memapi.<域名> {
	handle_path /*/* { reverse_proxy 127.0.0.1:18081 }   # 18081 = 你的上游中继
	respond /health 200
}
```

代价：**没有记忆注入，也没有知识库自动检索**，只剩模型出话。

---

## 5. 方案 C：frp 隧道（家里机器，对照）

```
反代 ──> 127.0.0.1:18080 ──frps(服务器)──> frpc(家里机器) ──> 家里 NPM ──> 各服务
```

服务器 `/etc/frp/frps.toml`：

```toml
bindAddr = "0.0.0.0"
bindPort = 7000
proxyBindAddr = "127.0.0.1"
auth.token = "<48 位随机串>"                 # ⛔ 客户端必须完全一致
allowPorts = [{ start = 18000, end = 18099 }]
webServer.addr = "127.0.0.1"
webServer.port = 7500
```

家里机器 `frpc.toml`：

```toml
serverAddr = "<服务器公网 IP>"
serverPort = 7000
auth.token = "<与服务器完全一致>"
[[proxies]]
name = "nas-npm-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 18080
remotePort = 18080
```

**风险**：家里那台重启/更新后，容器没设 `restart: always` 就不会自己回来，表现是
**所有子域 502、主站正常**（2026-10-22 真实事故：13:00 断，16:43 开机才恢复）。

---

## 6. 飞牛 OS（fnOS）部署

### 6.1 步骤（面板操作即可）

1. **装 Docker**：fnOS 应用中心 → Docker；
2. **建目录**（⛔ 绝对路径，相对路径会落到 `/root`）：`/vol1/docker/tdai/`、`/vol1/docker/weknora/`；
3. **记忆三件套**：`cd /vol1/docker/tdai/deploy/global-images && ./start-all.sh`
   （或面板 → Docker → 项目 → 选目录启动）；
4. **知识库**：`cd /vol1/docker/weknora && cp .env.example .env && docker compose up -d`；
5. **局域网先验**：
   ```bash
   curl -s http://<NAS的IP>:8096/health     # {"status":"ok"}
   curl -sI http://<NAS的IP>:8125/          # 记忆空间面板
   curl -sI http://<NAS的IP>/               # 知识库前端
   ```
6. **公网暴露**：有公网 IP 就映射 `8096`（面板只内网）；没有就走 frp（§5）。

### 6.2 fnOS 特有的四个坑

1. **卷路径**：共享目录 `/vol1/...`，Docker 默认工作目录 `/root`，写相对路径会静默落系统盘；
2. **属主**：面板建目录属主是 `admin`，容器内 PG 要 UID `999` ⇒ `sudo chown -R 999:999 <目录>`；
3. **系统更新会重启 Docker** ⇒ 所有容器 `restart: always`（今天事故同源）；
4. **防火墙**：入站默认只放行面板端口，`ports:` 写了还要在系统防火墙放行。

### 6.3 选型对照

| | 一台服务器（§3） | 飞牛 OS（本节） |
|---|---|---|
| 公网稳定性 | ✅ 直连 | ⚠️ 依赖家里网络 + 隧道 |
| 延迟 | 少一跳 | 多一跳 |
| 成本 | 云服务器月付 | 已有 NAS，边际≈0 |
| 数据 | 云端，需自备份 | ✅ 在自己手里，可快照 |
| 建议 | **对外服务** | 自用/内网，或先在这里验证 |

> 折中：**数据留飞牛，只把记忆网关放服务器**，模型通道就不再依赖家里网络。

---

## 7. 从 C 迁到 A

### 7.1 目标拓扑

```
反代(443) ─┬ /cloud-api/*  → 127.0.0.1:8091  云管理
           ├ /<client>/*   → 127.0.0.1:8096  记忆网关
           ├ mem.<域名>    → 127.0.0.1:8125  记忆空间面板
           └ kb.<域名>     → 127.0.0.1:80    知识库
```

### 7.2 资源预算

| 组件 | CPU | 内存 | 磁盘 |
|---|---|---|---|
| 记忆三件套（core+hub+proxy） | 2–3 核 | 2–4 GB | 20–200 GB |
| 知识库（前端+API+PG+Redis） | 2–4 核 | 4–8 GB（本地 embedding 再 +2–4 GB） | 100 GB–1 TB+ |
| 云管理 | 0.2 核 | ~200 MB | 几 MB |
| 反代 | 0.1 核 | ~100 MB | 忽略 |
| **合计** | **6–8 核** | **8–14 GB** | **0.2–1.5 TB** |

**8C16G 起就够**；磁盘不是瓶颈，内存才是（PG 与向量检索）。10T 级磁盘余量非常充足。

### 7.3 顺序（⛔ 不能反）

1. **先起新的**：按 §3.2/§3.3 在目标机装一遍（端口不变，先只监听回环）；
2. **数据搬家**：`tdai-memory-core-data` / `tdai-panel-data` 两个命名卷 + WeKnora 的 PG 卷。
   停写窗口 10–30 分钟：
   ```bash
   docker compose stop
   for v in tdai-memory-core-data tdai-panel-data; do
     docker run --rm -v $v:/v -v /tmp:/b alpine tar czf /b/$v.tgz -C /v .
   done
   scp /tmp/*.tgz <user>@<服务器>:/tmp/
   docker compose start          # 源机先恢复，别长停
   ```
   目标机 `docker volume create <同名>` 后把 tgz 解到卷里（PG 卷记得 `chown -R 999:999`）；
3. **逐个切反代**（改一个验一个）：
   ```bash
   sudo cp /etc/caddy/sites.caddy /etc/caddy/sites.caddy.bak-$(date +%Y%m%d-%H%M)
   sudo sed -i 's|127.0.0.1:18080|127.0.0.1:8096|' /etc/caddy/sites.caddy
   sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
   ```
4. **验完再撤隧道**：`sudo systemctl disable --now frps`，家里停掉 frpc（容器保留，方便回滚）。

### 7.4 回滚（任一步失败，5 分钟回原状）

| 失败点 | 回滚 |
|---|---|
| 新服务起不来 | `docker compose down`，反代恢复 `.bak` 并 reload（隧道仍在，立刻恢复） |
| 数据不对 | 目标机 down，反代恢复 `18080`；源机数据卷未动 |
| 全线异常 | `sudo systemctl enable --now frps` + 家里启 frpc |

---

## 8. 运维加固与排障

### 8.1 三条硬性要求

1. **所有容器 `restart: always`**；
2. **断线看门狗**（隧道形态必装）：

```bash
cat >/usr/local/bin/ppz-nas-watch.sh <<'EOF'
#!/bin/bash
if ! ss -lntH | grep -q ":18080 "; then logger -t ppz-tunnel "18080 无监听（隧道断开）"; fi
EOF
chmod +x /usr/local/bin/ppz-nas-watch.sh
(sudo crontab -l; echo "* * * * * /usr/local/bin/ppz-nas-watch.sh") | sudo crontab -
```

3. **改反代前备份**；改指向之前先确认端口身份：

```bash
sudo ss -lptnp | grep -E ':8096|:8091|:8080|:18080'
sudo ps -o pid,cmd -p <pid>     # ⛔ 必看命令行：只看 /health 会被 SPA 的 catch-all 骗
```

### 8.2 排障顺序（6 步到底）

```bash
curl -I https://memapi.<域名>/health           # ① 200 ⇒ 边缘正常；502 ⇒ 上游没起来
sudo grep -n reverse_proxy /etc/caddy/*.caddy  # ② 反代目标是谁
sudo ss -lntp | grep <port>                    # ③ 端口有人在听吗
sudo docker ps -a                               # ④ 容器状态 / 端口映射
sudo ps -o pid,cmd -p <pid>                     # ⑤ 端口身份确认
journalctl -t ppz-tunnel --since today          # ⑥ 隧道断线起点（装了看门狗才有）
```

**判据**：根路径 502 ⇒ 服务端；只有特定路径 4xx ⇒ 客户端协议/参数/密钥。
frp 的 `token in login doesn't match` **多半是公网扫描器**（无 hostname、云 IP、版本对不上），
认 **同一个 client id + hostname** 才算用户侧证据。

---

## 9. 常见问题

**Q1：`./start-all.sh` 卡在 wait_healthy？**
镜像还在拉。先 `docker pull agentmemory/memory-core`（三个都拉）再跑。

**Q2：Panel 打不开或报错？**
先查 `.env` 的 `KNOWLEDGE_PUBLIC_BASE_URL` 是否**带 `/v3`**。

**Q3：Proxy 转发 401？**
`PROXY_UPSTREAM_API_KEY` / `PROXY_UPSTREAM_URL` 不匹配；`docker logs tdai-proxy` 看原文。

**Q4：L1 一直没产出记忆？**
`MEMORY_PROMPT_MODE` 默认 `code`（工程向）；纯闲聊改成 `chat`。

**Q5：容器里怎么访问宿主机 Ollama？**
脚本已加 `host.docker.internal:host-gateway`，容器内用 `http://host.docker.internal:<port>`。

**Q6：客户端 Base URL 到底填哪个？**
`https://memapi.<域名>/<client>/<instance>`，`client` ∈ `claude-code` / `codebuddy` / `hermes` / `openclaw`，
`instance` 默认 `default`。client 名写错是 **404**（不是 502）。

**Q7：能不能只装知识库、不装记忆？**
可以，两条链路独立：只装 WeKnora + 云管理，客户端不配「云端模型」即可。
