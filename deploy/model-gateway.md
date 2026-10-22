# 单服务器部署：云端模型 + 记忆网关（两套方案）

> **与本仓的关系**：本仓（`server-account` + `web`）负责**账号 / 积分 / 模型目录**；
> 客户端真正发推理请求打的是**另一个服务** —— 模型网关（可选带记忆注入）。
> 本文就是那套网关的单机部署说明，可以和本仓跑在同一台服务器上，也可以分开。
>
> 客户端把 `baseUrl` 指向 `https://<你的域名>/claude-code/<instance>`，网关负责「记忆注入 + 转发上游 LLM」。
> 本文只写**已经踩过的坑**与**可验证的步骤**，不含任何密钥；所有 `<...>` 都要换成你自己的值。

---

## 目录

- **组件一览（含开源地址）** · **两条链路怎么衔接** ← 先看这两节
- **§0–§1** 为什么会有两套方案、前置
- **§2 方案 A** 全栈单机（记忆 + 模型都放服务器）
- **§3 方案 B** 只搬模型通道（不部署记忆，⚠️ 先看先决条件）
- **§4 方案 C** frp 隧道（现状/对照）
- **§5 运维加固** · **§6 排障手册**
- **§7 三件套 + 云管理合并到一台服务器**（迁移：拓扑 / 资源预算 / 三步走 / 验收 / 回滚）
- **§8 飞牛 OS（fnOS）部署方案**（含 fnOS 特有的四个坑与选型对照）

## 组件一览（含开源地址）

| 组件 | 作用 | 开源地址 | 许可 |
|---|---|---|---|
| **记忆空间 / 记忆中枢** | L0–L3 分层记忆 + 技能 / 知识 Wiki / 代码图谱；提供 Memory Panel 面板与 Core / Knowledge 服务 | https://github.com/TencentCloud/TencentDB-Agent-Memory | MIT |
| **知识库** | 文档 → RAG 检索 / Agent / 自维护 Wiki；对外暴露 MCP 检索端点 | https://github.com/Tencent/WeKnora | 见仓库 LICENSE |
| **记忆网关 proxy** | 挡在模型前面：注入 L2/L3 记忆与技能后转发上游 LLM（"零代码接入"就靠它） | 上面那个仓的 `MemoryProxy/` | MIT |
| **云管理（本仓）** | 账号 / 积分 / 模型目录 / 知识库与记忆授权；给客户端**发号** | https://github.com/PMZPZM0/codex-cloud-assistant | 见本仓 |
| **上游中继（可选）** | 自建模型转发与计费；直接接商用 API 时可以不装 | 自建 | — |

> 端口以各自 `INSTALL.md` / `docker-compose.yml` 为准。本文用的是某套现网部署的实测值，便于对照：
> 记忆网关 `8096`、Memory Core `8420`、知识服务 `8424`、Memory Panel `8125`、WeKnora API `8083` / 前端 `8082`。

## 两条链路怎么衔接（⛔ 最容易被问到的部分）

**链路 1 · 模型 + 记忆（同步，发生在每次推理之前）**

```
客户端 ──POST /claude-code/<instance>/v1/messages──> Caddy ──> 记忆网关 8096
   记忆网关 ──(1) 读 L2/L3 记忆与技能──> Memory Core 8420
            ──(2) 拼进 system / 上下文──> 上游 LLM（自建中继 18081 或商用 API）
            ──(3) SSE 原样回传──> 客户端
```

- 客户端只配三样：`baseUrl`、`Authorization: Bearer sk-mem-<user_key>`、模型 id；
- 记忆的读写**全在网关侧**完成，客户端零改造 —— 这就是"记忆很深的牵扯"的真实原因：
  它不是旁挂的一个库，而是**挡在模型调用链路上的一层**。

**链路 2 · 知识库检索（按需，与推理解耦）**

```
客户端 MCP 连接器 ──https──> <WEKNORA_BASE>/mcp/<endpointId> ──> 该账号的私有知识库
```

- 云管理用 **管理员 key** 调 WeKnora：建知识库 → 建 **MCP 端点**（限定工具与速率）→ 得到 `token` 与 `mcpUrl`；
- 客户端从 `/cloud-api` 取回 `mcpUrl` + `token`，配成 MCP 连接器，会话里就能 `knowledge_search`；
- 相关配置项（云管理 `config.env`）：`WEKNORA_BASE`、`WEKNORA_ADMIN_KEY`。

⛔ **两套鉴权互不相通**：模型链路是记忆网关签发的 `sk-mem-*`，知识库链路是 WeKnora 的 endpoint token。
排查时别把两者的 401 混为一谈。

**云管理的角色**：只负责"发号"（模型目录、`sk-mem-*`、`mcpUrl` + token），**不参与推理转发**。
所以它挂了，已登录的客户端仍能推理；它活着，也不代表网关通（今天的事故就是这种组合）。

---

## 0. 为什么会有两套方案

很多自建部署最初是「服务器 Caddy → frp 隧道 → 家里那台机器的 NPM → 记忆代理」，
省事，但**单点在家里**。真实案例（2026-10-22，某自建部署）：

```
13:00:02  家里机器上的 frpc 正常退出（client exit success）⇒ 18080 不再监听
13:00 起  所有子域 502（mem / kb / api / memapi），而主站仍 200
16:43:53  那台机器重新开机，frpc 重新登录、注册 nas-npm-web，18080 恢复，全部服务自动回来
```

结论：**功能没问题，单点在家里那台机器上**。所以给出两套「全部放服务器」的方案：

| | 方案 A 全栈单机 | 方案 B 仅模型通道 | 方案 C 现状（frp 隧道） |
|---|---|---|---|
| 记忆注入（L2/L3 自动进上下文） | ✅ | ❌ | ✅ |
| 模型可用 | ✅ | ✅ | ✅ |
| 依赖家里的 NAS | 否 | 否 | **是（单点）** |
| 密钥体系 | 记忆代理签发 `sk-mem-*` | 需要中继自己的 key | 记忆代理签发 |
| 部署量 | 2 个容器 + Caddy | 只有 Caddy 改写 | 0（但会挂） |

---

## 1. 前置（两套方案通用）

- 一台有公网 IP 的 Linux 服务器，域名 A 记录指向它（如 `memapi.example.com`）。
- Caddy（或 Nginx）已能签 TLS；本文用 Caddy。
- Docker + compose 插件。
- 一个**上游 LLM**：`base_url` + `api_key` + `model`（OpenAI 兼容即可）。

目录约定（下文都用它）：

```
/etc/caddy/Caddyfile              # 主站
/etc/caddy/<domain>-sites.caddy   # 子域转发（被 Caddyfile import）
/opt/memory-proxy/docker-compose.yml
/var/log/caddy/                   # 访问日志
```

---

## 2. 方案 A：全栈单机（记忆 + 模型都在服务器）

### 2.1 拓扑

```
桌面端 ──https──> Caddy ──/claude-code/*──> 记忆代理 127.0.0.1:8096 ──> 上游 LLM
                     └──/health──> 同一实例
```

记忆代理负责：校验 `sk-mem-*` → 按用户注入 L2/L3 记忆与技能 → 转发上游 → 回传（SSE 透传）。

### 2.2 docker-compose

```yaml
# /opt/memory-proxy/docker-compose.yml
services:
  memory-proxy:
    image: <记忆代理镜像>            # 例如团队自建仓库中的 proxy 镜像
    restart: always                  # ⛔ 必须：本次事故就是因为客户端没自启
    ports:
      - "127.0.0.1:8096:8096"        # ⛔ 只绑回环，公网只经 Caddy
    environment:
      LLM_BASE_URL: "<上游 LLM base_url>"      # 例：https://api.example.com/v1
      LLM_API_KEY: "<上游 key>"
      LLM_MODEL: "<默认模型 id>"
      INSTANCE_ID: "default"                    # 对应 URL 里的 /claude-code/<instance>
      ADMIN_KEY_FILE: "/data/.admin-key"        # 首次启动写入，用于面板建 Team/业务用户
    volumes:
      - ./data:/data
```

```bash
cd /opt/memory-proxy && docker compose up -d
docker compose logs --tail=50        # 等到出现 listening / admin key
curl -s http://127.0.0.1:8096/health # 期望：{"status":"ok", ...}
```

### 2.3 Caddy

```caddyfile
# /etc/caddy/memapi-sites.caddy（由 Caddyfile 里 import）
memapi.example.com {
	# ⛔ handle_path 会**剥掉**前缀：/claude-code/default/v1/messages → /v1/messages
	handle_path /claude-code/* {
		reverse_proxy 127.0.0.1:8096
	}
	reverse_proxy 127.0.0.1:8096
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

### 2.4 客户端（桌面端「模型」页）

| 字段 | 值 |
|---|---|
| Base URL | `https://memapi.example.com/claude-code/default` |
| API Key | `sk-mem-<该用户在面板里签发的 user_key>` |
| 模型 | 面板里为该 Team/Agent 启用的模型 id |
| 上游协议 | `自动`（网关侧负责翻译；若只支持 Responses 也可显式选 `responses`） |

### 2.5 验证清单

```bash
curl -s https://memapi.example.com/health
curl -s https://memapi.example.com/claude-code/default/v1/models            # 无 key 应 401/鉴权错误，⛔ 不该是 502
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://memapi.example.com/claude-code/default/v1/messages \
  -H 'content-type: application/json' -H 'authorization: Bearer sk-mem-xxx' \
  -d '{"model":"<模型>","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
```

判据：**/health 200 + 鉴权错误（而不是 502）** ⇒ 网关活着；带上真 key 能出 token ⇒ 全链路通。

---

## 3. 方案 B：只搬模型通道（不带记忆）

适用：不想部署记忆代理，只需要「云端模型能用」。

### 3.1 关键前提（⛔ 先读）

桌面端发出去的是 `Authorization: Bearer sk-mem-*`（记忆代理签发的用户 key），
而**上游中继认的是它自己的 key**（自行管理的密钥库）。两者的换 key 动作原本发生在记忆代理里。

⇒ 方案 B 必须解决「谁把 `sk-mem-*` 换成中继 key」，两条路：

1. **中继侧认 `sk-mem-*`**：在转发层加一条 `sk-mem-* → 中继 key` 的映射（推荐，一次性）；
2. **客户端直填中继 key**：把用户中心的模型档案改成「中继 baseUrl + 中继 key」，
   即不再经过 `/claude-code/<instance>` 这层。

⚠️ 直接改写 Caddy 而不做上面任一条 ⇒ 客户端会拿到 `401 invalid api key`（不是 502），
这是**预期**的，别误判成网关挂了。

### 3.2 Caddy（前缀剥离 + 直连中继）

```caddyfile
memapi.example.com {
	# 只保留模型通道：/claude-code/default/v1/* → 中继 /v1/*
	handle_path /claude-code/* {
		reverse_proxy 127.0.0.1:18081
	}
	respond /health 200
	reverse_proxy 127.0.0.1:18081
}
```

`18081` = 供应商中继（本仓之外的独立服务，只认自己的 key）。它认识模型 id 映射
（如 `space-bunny` → 上游真名），并对 `/v1/chat/completions`、`/v1/messages` 双向服务。

### 3.3 能力差异（必须让用户知道）

| 能力 | 方案 A | 方案 B |
|---|---|---|
| 云端记忆自动注入 | ✅ | ❌（每轮不再带 L2/L3） |
| 云端知识库自动检索 | ✅ | ❌ |
| 模型出话 | ✅ | ✅ |
| 计费口径 | 代理侧 | 中继侧 |

---

## 4. 方案 C（现状）：frp 隧道，仅作对照

```
Caddy ──> 127.0.0.1:18080 ──frps──> frpc(家里 NAS) ──> NAS 上的 NPM ──> 各服务
```

`/etc/frp/frps.toml`（服务器）：

```toml
bindAddr = "0.0.0.0"
bindPort = 7000
proxyBindAddr = "127.0.0.1"
auth.token = "<48 位随机串>"                       # ⛔ 客户端必须一致，否则 login 被拒
allowPorts = [{ start = 18000, end = 18099 }]
webServer.addr = "127.0.0.1"
webServer.port = 7500
```

NAS 侧 `frpc.toml`：

```toml
serverAddr = "<服务器公网 IP>"
serverPort = 7000
auth.token = "<与服务器完全一致>"
[[proxies]]
name = "nas-npm-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 18080          # NAS 上 NPM 的端口
remotePort = 18080         # 服务器上 Caddy 转发的目标
```

**已知风险**：NAS 重启/系统更新后，若容器没设 `restart: always`，隧道不会自己回来，
表现就是**所有子域 502、主站正常**。要长期稳定，请迁移到方案 A。

---

## 5. 运维加固（本次事故的补丁）

1. **容器一律 `restart: always`**，并确认开机自启（fnOS / Docker 面板里都有开关）。
2. **断线看门狗**（服务器，每分钟记录一次，便于回溯断线起点）：

```bash
cat >/usr/local/bin/ppz-nas-watch.sh <<'EOF'
#!/bin/bash
# 18080 = NAS 隧道端口；没有监听 = 所有子域 502
if ! ss -lntH | grep -q ":18080 "; then logger -t ppz-tunnel "18080 无监听（NAS 隧道断开）"; fi
EOF
chmod +x /usr/local/bin/ppz-nas-watch.sh
(sudo crontab -l; echo "* * * * * /usr/local/bin/ppz-nas-watch.sh") | sudo crontab -
# 查询：journalctl -t ppz-tunnel --since today
```

3. **改反代前先备份**：`cp /etc/caddy/<file>.caddy /etc/caddy/<file>.caddy.bak-$(date +%Y%m%d)`
4. **⛔ 改反代指向之前先确认端口身份**：

```bash
sudo ss -lptnp | grep -E ':8096|:18080|:18081'
sudo ps -o pid,cmd -p <pid>
```

> 只看 `/health` 返回 200 会被 SPA 的 catch-all 骗（它会把未知路径也回首页 HTML）。
> 2026-10-22 就曾把 8097（WorkBuddy 重试代理）误当成记忆网关，结果公网返回 200 HTML。

---

## 6. 排障手册（按顺序，6 条命令定位到底）

```bash
# 1) 客户端还是服务端？—— 先打根路径
curl -I https://memapi.example.com/            # 200 ⇒ 边缘正常；502 ⇒ 上游没起来

# 2) 反代目标是谁？
sudo grep -n reverse_proxy /etc/caddy/*.caddy

# 3) 那个端口有人在听吗？
sudo ss -lntp | grep <port>                    # 没有 ⇒ 后端没起（或隧道断了）

# 4) 是容器还是进程？
sudo docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo ps -o pid,cmd -p <pid>                    # ⛔ 一定要看命令行，别信端口号看着像

# 5) 隧道（方案 C）
sudo systemctl status frps --no-pager
sudo journalctl -u frps --since '-3h' | grep -E 'client login|new proxy|client exit|token'

# 6) 应用侧日志
journalctl -t ppz-tunnel --since today         # 看门狗记录的断线起点
```

**判据记忆法**：根路径 502 ⇒ 服务端；只有特定路径 4xx ⇒ 客户端协议/参数/密钥。
`token in login doesn't match` 这类登录失败**多半是公网扫描器**（无 hostname、云 IP、版本对不上），
不要当成用户侧证据 —— 认 **同一个 client id + hostname** 才算。

---

## 7. 把「三件套 + 云管理」合并到一台服务器（迁移方案）

> 现状常是四件东西分两处：**服务器**跑「云管理 + 上游中继」，**家里那台**跑「记忆空间 + 知识库 + 记忆网关」，
> 中间一条 frp 隧道。本节就是把后三个搬到服务器、最终撤掉隧道的完整动作。

### 7.1 目标拓扑（全部落在同一台机：只暴露 443）

```
                    ┌──────────────── 一台服务器 ────────────────┐
 客户端 ──https──>  │ Caddy (443)                                │
                    │  ├ /cloud-api/*        → 127.0.0.1:8091  云管理 API
                    │  ├ ppz→ 静态面板        → web/             云管理面板
                    │  ├ /claude-code/*      → 127.0.0.1:8096  记忆网关（注入 L2/L3）
                    │  ├ mem.<域名>          → 127.0.0.1:8125  记忆空间面板
                    │  └ kb.<域名>           → 127.0.0.1:8082  知识库前端
                    │       记忆网关 ──> 127.0.0.1:18081 上游中继 ──> LLM
                    └────────────────────────────────────────────┘
```

### 7.2 端口 / 数据对照（以你实际部署为准，先 `docker ps` 核对）
| 组件 | 典型端口 | 关键数据（必须迁） |
|---|---|---|
| 记忆网关 proxy | 8096 | 配置（LLM_BASE_URL/KEY）、账号与 Team 元数据、`.admin-key` |
| 记忆空间 Memory Hub | 8125（面板）/ 8420（core） | 记忆库数据卷（Postgres / 向量索引） |
| 知识库 WeKnora | 8083（API）/ 8082（前端） | 租户与知识库数据卷（PG + 向量库 + 上传件） |
| 云管理（本仓） | 8091 | `data/data.json`（用户/积分/模型目录） |
| 上游中继 | 18081 | 自有密钥库（`manager.db` 等） |

#### 资源预算（合并到一台够不够）

| 组件 | CPU | 内存 | 磁盘 | 说明 |
|---|---|---|---|---|
| Caddy | 0.1 核 | ~100 MB | 证书 + 日志，忽略 | — |
| 云管理 `server-account` | 0.2 核 | ~200 MB | 几 MB（`data.json`） | 纯 Node，零依赖 |
| 记忆网关 proxy | 0.5 核 | 0.5–1 GB | < 5 GB | 只做转发 + 注入，不吃盘 |
| 记忆空间 Memory Hub | 2 核 | 2–4 GB | 50–200 GB | PG + 向量索引，随记忆条目增长 |
| 知识库 WeKnora | 2–4 核 | 4–8 GB（本地跑 embedding 再加 2–4 GB） | 100 GB–1 TB+ | 上传件是大头，按用户量线性涨 |
| 上游中继 | 0.5 核 | ~0.5 GB | 忽略 | 只做转发与计费记账 |
| **合计** | **约 6–8 核** | **约 8–14 GB** | **约 0.2–1.5 TB** | — |

结论：**一台 8C / 16G / 1T 起的机器就能全放下**；磁盘是「10T 级」的话余量非常充足
（真正会先顶到的是**内存**——WeKnora 的嵌入与向量检索、以及 PG 的 shared_buffers，
不是磁盘）。若知识库要本地跑 embedding 模型，按上面括号再加 2–4 GB 内存。

⛔ 单机部署的边界：**所有服务共用一个 Docker daemon 与一条公网入口**，
所以务必备份数据卷（7.8 的回滚只保服务，不保数据），并给每个容器设 `restart: always`。

### 7.3 第 0 步：准备（只读，不影响线上）

```bash
# 在「家里那台」上：把要迁的东西盘点清楚
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'
docker inspect <容器> --format '{{json .Mounts}}' | jq -r '.[] | "\(.Type)\t\(.Name // .Source)\t\(.Destination)"'
docker inspect <容器> --format '{{json .Config.Env}}' | jq -r '.[]' > /tmp/<容器>.env.txt   # ⛔ 含密钥，别提交
```

把上面三条的输出存成一份迁移清单（镜像 tag、数据卷名、env 键名），后面按清单逐项搬。

### 7.4 第 1 步：先迁记忆网关（影响面最小，单独可回退）

```bash
# 源机：导出（镜像 + 配置）
docker save <proxy 镜像> | gzip > proxy.tgz
tar czf proxy-data.tgz -C <数据卷父目录> <数据卷名>

scp proxy.tgz proxy-data.tgz <user>@<服务器>:/tmp/

# 目标机：导入并起服务（只绑回环，公网仍由 Caddy 进）
docker load < /tmp/proxy.tgz
docker volume create proxy-data && tar xzf /tmp/proxy-data.tgz -C /var/lib/docker/volumes/proxy-data/_data

cat >/opt/memory-proxy/docker-compose.yml <<'YAML'
services:
  memory-proxy:
    image: <proxy 镜像>
    restart: always
    ports: ["127.0.0.1:8096:8096"]
    env_file: /opt/memory-proxy/proxy.env        # LLM_BASE_URL/LLM_API_KEY/INSTANCE_ID 等
    volumes: ["proxy-data:/data"]
volumes: { proxy-data: {} }
YAML
cd /opt/memory-proxy && docker compose up -d
curl -s http://127.0.0.1:8096/health             # 期望 {"status":"ok",...}
```

**切换**（只改一个站点的上游，秒级回退）：

```bash
sudo cp /etc/caddy/<sites>.caddy /etc/caddy/<sites>.caddy.bak-$(date +%Y%m%d-%H%M)
sudo sed -i '/memapi\.<域名>/,/^}/ s|127\.0\.0\.1:18080|127.0.0.1:8096|' /etc/caddy/<sites>.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
curl -s https://memapi.<域名>/health             # 期望 ok
curl -s https://memapi.<域名>/claude-code/default/v1/models   # 期望鉴权错误，⛔ 不是 502
```

到这里**模型通道已脱离家里那台机器**；记忆空间/知识库仍可暂时走隧道，互不影响。

### 7.5 第 2 步：迁记忆空间 + 知识库（带数据，需要停写窗口）

这两个是「有状态」的，⛔ 不能只搬镜像，必须连数据卷一起搬，且**先停写再导**：

```bash
# 源机（建议 10–30 分钟窗口，期间面板/检索不可用）
docker stop <hub容器> <kb容器> <kb-pg容器>
docker save <hub镜像> <kb镜像> <pg镜像> | gzip > stacks.tgz
for v in <hub卷> <kb卷> <pg卷>; do docker run --rm -v $v:/v -v /tmp:/b alpine tar czf /b/$v.tgz -C /v .; done
scp stacks.tgz *.tgz <user>@<服务器>:/tmp/
docker start <hub容器> <kb容器> <kb-pg容器>     # 源机先恢复服务，别长停
```

目标机按清单 `docker load` + 重建同名卷 + 用**同一份 compose**（改端口为回环）起容器，然后：

```bash
curl -sI http://127.0.0.1:8125/    # 记忆空间面板
curl -sI http://127.0.0.1:8082/    # 知识库前端
```

⚠️ 三个高频坑：
1. **卷权限**：`tar` 解出来属主常常不对（尤其 PG，UID 必须保持容器内的），解压后 `chown -R 999:999`（PG）或按镜像文档；
2. **端口占用**：目标机若已有同名端口进程，先 `ss -lntp` 核对，别盲目 `docker compose up`；
3. **HTTPS/域名**：面板里如果存了绝对地址（回调、Webhook），迁完要一并改，否则登录会跳回旧域名。

### 7.6 第 3 步：Caddy 切流 + 撤隧道

```bash
# 三个站点全部改为本机端口
sudo sed -i 's|127.0.0.1:18080|127.0.0.1:8096|'  # memapi
sudo sed -i '/mem\.<域名>/,/^}/ s|127.0.0.1:18080|127.0.0.1:8125|' <sites>.caddy
sudo sed -i '/kb\.<域名>/,/^}/ s|127.0.0.1:18080|127.0.0.1:8082|' <sites>.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

全部验证通过后，再撤隧道（**顺序不能反**）：

```bash
sudo systemctl stop frps && sudo systemctl disable frps     # 服务器侧
# 家里那台：停掉 frpc 容器（保留，别删，方便回滚）
```

### 7.7 验收清单（逐条打勾再撤隧道）

```bash
for u in https://memapi.<域名>/health https://mem.<域名>/ https://kb.<域名>/ \
         https://<主域>/account.html https://<主域>/cloud-api/<任一只读接口>; do
  printf '%s -> ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "$u"
done
# 再确认没有任何响应再经过旧 NPM：应当只剩一层 Server: Caddy
curl -sI https://mem.<域名>/ | grep -ci openresty      # 期望 0
```

⚠️ 迁移窗口内**别同时重启云管理**：客户端登录态在 `8091`，一并抖动会让人误判成迁移失败。

### 7.8 回滚（任一步失败，5 分钟内恢复）

| 失败点 | 回滚动作 |
|---|---|
| 网关起不来 | `docker compose down`，Caddy 恢复备份文件 `reload`，隧道仍在 ⇒ 立刻恢复原状 |
| 面板/知识库数据不对 | 目标机 `docker compose down`，Caddy 的 mem/kb 两站点恢复 `127.0.0.1:18080` |
| 全线异常 | `sudo systemctl enable --now frps` + 家里那台启 frpc ⇒ 回到方案 C（隧道形态） |

⛔ 全程保留：Caddy 配置备份、源机容器与数据卷（迁完一周再清理）。

### 7.9 迁移后的收益

- 少一个跨公网单点：家里那台机器重启/换网/运营商掉线，**不再影响线上**；
- 延迟少一跳（少了 frp 中转），面板与检索的首屏明显更快；
- 一处备份：数据卷、配置、证书都在同一台，恢复演练变简单。

---

## 8. 飞牛 OS（fnOS）部署方案

适合「家里已经有台 fnOS NAS」：Docker 面板、快照、磁盘都现成，装三件套很快。
代价是**公网访问**要么做端口映射、要么走 frp 隧道（风险见 §4 与今天的 502 事故）。

### 8.1 步骤（面板操作，不用命令也能完成）

1. **装 Docker**：fnOS 应用中心 → Docker（已装跳过）；
2. **建目录**（一律绝对路径，⛔ 别用相对路径）：
   ```
   /vol1/docker/memory-core/     # 记忆空间（含 PG/向量数据）
   /vol1/docker/weknora/         # 知识库
   /vol1/docker/memory-proxy/    # 记忆网关
   ```
3. **放 compose**：把 §2.2（网关）、§7.4（网关迁移版）、记忆空间与知识库各自的 compose 分别放进对应目录，
   端口保持默认（`8096 / 8125 / 8420 / 8424 / 8083 / 8082`）；
4. **起容器**：fnOS Docker 面板 → 项目/Compose → 选目录 → 启动；或 `cd <目录> && docker compose up -d`；
5. **本机验证**（局域网内先跑通再看公网）：
   ```bash
   curl -s http://<NAS的局域网IP>:8096/health        # 期望 {"status":"ok",...}
   curl -sI http://<NAS的局域网IP>:8125/             # 记忆空间面板
   curl -sI http://<NAS的局域网IP>:8082/             # 知识库前端
   ```
6. **公网暴露**，二选一：
   - 有公网 IP + 会做端口映射 ⇒ 直接映射 `8096`（其余面板建议只在内网）；
   - 没有公网 IP（大多数家庭宽带）⇒ 用 frp（§4），服务器侧 Caddy 反代 `127.0.0.1:18080`。

### 8.2 fnOS 特有的四个坑（都实际踩过）

1. **卷路径**：fnOS 的共享目录是 `/vol1/...`，而 Docker 默认工作目录在 `/root` ⇒ compose 里写相对路径
   会静默落到系统盘；**全部写绝对路径**。
2. **属主/权限**：fnOS 面板新建目录默认属主是 `admin`，而容器里的 Postgres 要求 UID `999`
   ⇒ 启动前 `sudo chown -R 999:999 /vol1/docker/memory-core/pgdata`（或 compose 里用 `user:` 指定）。
3. **系统更新会重启 Docker daemon**：所有容器**必须** `restart: always`。
   今天的 502 事故就是 `frpc` 容器没设自启：13:00 退出，直到 16:43 机器重开才回来。
4. **防火墙**：fnOS 入站默认只放行面板端口；即便 compose 写了 `ports:`，还要在系统防火墙里放行，
   否则局域网能通、公网不通。

### 8.3 两种部署形态怎么选

| | 一台服务器全放（§2 + §7） | 飞牛 OS（本节） |
|---|---|---|
| 公网稳定性 | ✅ 直连，无跨网单点 | ⚠️ 依赖家里网络 + 隧道 |
| 延迟 | 少一跳 | 多一跳 frp |
| 成本 | 云服务器月付 | 已有 NAS，边际成本≈0 |
| 数据安全 | 云端（要自己做备份） | ✅ 数据在自己手里，可快照 |
| 运维 | 一处备份/监控 | 需盯 Docker 自启与宿主机重启 |
| 建议 | **对外服务用这个** | 自用/内网为主，或先在这台验证 |

> 折中方案：**记忆/知识库留飞牛（数据在家、有快照），记忆网关放服务器**（§7.4 单独迁网关），
> 这样模型通道不再依赖家里网络，面板与检索仍走内网/隧道。
