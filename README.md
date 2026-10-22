# codex-cloud-assistant · 云助手云端管理

把「账号 / 积分 / 模型池 / 闲时倍率 / 知识库与记忆授权」做成**可自部署**的一套服务：
一个人也能在自己服务器上跑起来，管理自己的用户与模型额度。

> 供 Codex Harness 系列客户端（桌面版 / 云助手）对接；也可独立当"账号 + 计费 + 模型目录"后台用。

## 1. 目录结构

```
server-account/server.js   # 服务端（Node 18+，零第三方依赖）
web/                       # 管理面板与登录门（纯静态）
  account.html             #   管理面板（用户/积分/模型池/上游/知识库记忆）
  index.html               #   登录门
  fnos-guide.html          #   知识库/记忆对接教程（可整段交给 AI）
deploy/install.sh          # 一键部署（systemd）
deploy/model-gateway.md    # 模型 / 记忆网关的单机部署（两套方案，与本仓可同机）
config.example.env         # 配置模板（含全部可配项说明）
VERSION                    # 当前版本（面板「检查更新」用）
```

## 2. 三种部署方式

### 方式 A：一键脚本（Ubuntu / Debian，推荐）

```bash
git clone https://github.com/PMZPZM0/codex-cloud-assistant.git
cd codex-cloud-assistant
sudo bash deploy/install.sh
```

脚本会：检查 Node ≥18 → 建 `/opt/codex-cloud-admin` → 拷代码 → 生成 `config.env` →
写 systemd 单元 `codex-cloud-admin` → 启动。

装完**必须**先改一项，否则面板登录会 403：

```bash
sudo nano /opt/codex-cloud-admin/config.env
#   HARNESS_ACCOUNTS_ORIGINS=https://admin.example.com
sudo systemctl restart codex-cloud-admin
```

### 方式 B：手工（任意 Linux）

```bash
sudo mkdir -p /opt/codex-cloud-admin && cd /opt/codex-cloud-admin
sudo cp -r <repo>/server-account <repo>/web <repo>/VERSION .
sudo cp <repo>/config.example.env config.env && sudo chmod 600 config.env
sudo nano config.env          # 至少填 HARNESS_ACCOUNTS_ORIGINS
set -a && . ./config.env && set +a
node server-account/server.js &          # 前台试跑，确认能起
```

### 方式 C：Docker

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY server-account web VERSION ./
ENV HARNESS_ACCOUNTS_FILE=/app/data/data.json
VOLUME /app/data
EXPOSE 8091
CMD ["node", "server-account/server.js"]
```

```bash
docker build -t codex-cloud-admin .
docker run -d --name cca -p 8091:8091 \
  -v $PWD/data:/app/data \
  -e HARNESS_ACCOUNTS_ORIGINS=https://admin.example.com \
  codex-cloud-admin
```

### 方式 D：模型网关（另一套服务，按需）

本仓只管「账号 / 积分 / 模型目录」；客户端真正发推理请求打的是**模型网关**（可带记忆注入）。
网关要不要自己装、怎么装，见 **[`deploy/model-gateway.md`](deploy/model-gateway.md)**，配套两个文件：

- **[`deploy/Caddyfile.example`](deploy/Caddyfile.example)** —— 四条反代路由（云管理 / 网关 / 面板 / 知识库），
  含「剥前缀」和 SSE 关缓冲这两个必做项；
- **[`deploy/verify-all.sh`](deploy/verify-all.sh)** —— 验收脚本，`bash deploy/verify-all.sh <域名>`，
  全绿才算部署完成（判据含「模型目录返回鉴权错误而不是 502」）。

文档要点：

- **组件与开源地址**：记忆空间/记忆中枢 = [TencentCloud/TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)（MIT，
  镜像 `agentmemory/memory-core|hub|proxy`）、知识库 = [Tencent/WeKnora](https://github.com/Tencent/WeKnora)；
- **两条链路衔接**：模型+记忆走网关（注入 L2/L3 后转发上游），知识库走 WeKnora 的 `/mcp/<endpointId>`，
  两套鉴权互不相通；
- **方案 A 一站式**：记忆三件套一条 `./start-all.sh`（交互填两组 LLM + 通路预检）→ WeKnora →
  云管理 → 反代 → 验收，每步都给了「预期输出」；
- **方案 B 仅模型通道**：先决条件（`sk-mem-*` 与中继 key 的换发）写死，不做会 401；
- **方案 C frp 隧道**：家里机器的形态与风险；
- **§6 飞牛 OS（fnOS）部署**：面板步骤 + 四个实证坑（卷路径 / UID 999 / Docker 自启 / 防火墙）；
- **§7 迁移**：资源预算（8C16G 起够）、三步走、回滚表。

⛔ 若仍用 frp 隧道：客户端容器**必须** `restart: always`。真实事故：隧道客户端 13:00 退出、
直到 16:43 机器重开才恢复，期间所有子域 502 而主站正常 —— 极难第一眼看出。

## 3. 反向代理（必须）

服务只绑 `127.0.0.1:8091`，对外由反代提供 HTTPS。**两条规则缺一不可**：

| 路径 | 指向 | 含义 |
|---|---|---|
| `/cloud-api/*` | `127.0.0.1:8091`（**去掉前缀**） | 账号 API |
| 其他静态路径 | 本仓 `web/` 目录 | 面板与登录门 |

### Caddy

```caddy
admin.example.com {
    handle_path /cloud-api/* {
        reverse_proxy 127.0.0.1:8091
    }
    @html path *.html
    header @html Cache-Control "no-cache"
    root * /opt/codex-cloud-admin/web
    file_server
}
```

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name admin.example.com;
    root /opt/codex-cloud-admin/web;

    location /cloud-api/ {
        proxy_pass http://127.0.0.1:8091/;      # 末尾斜杠 = 去掉 /cloud-api 前缀
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    location ~* \.html$ {
        add_header Cache-Control "no-cache";
        try_files $uri =404;
    }
    location / { try_files $uri $uri/ =404; }
}
```

⛔ `/cloud-api` 的 `proxy_pass` **必须**带末尾斜杠，否则后端收到带前缀的路径，全部 404。

## 4. 首次登录

1. 打开 `https://admin.example.com/account.html`
2. 注册首个账号（或按 `install.sh` 提示用 `--init-admin` 预建）
3. 把该账号 `role` 改成 `admin`（`data.json` 里改，或预建时直接是管理员）
4. 以管理员登录 → 进 `#/admin`

## 5. 面板能配什么

| 卡 | 能力 |
|---|---|
| 上游 API | 地址（https/http/裸主机/内网/端口/路径前缀）+ 网关密钥 + **连通性测试** + 目录同步地址 |
| 知识库 · 记忆空间 | 两个上游的地址/密钥/模型 id/检索代理 + 单服务**连通性测试** + 热生效 |
| 模型管理 | 每模型高峰倍率、**闲时倍率**（直接替换，不是折扣）、钉住/恢复上游、**导出模型池**、同步目录 |
| 闲时时段 | 定义"哪些时间算闲时"（倍率在模型表里逐个填） |
| 用户 · 权益 · 积分 | 开通知识库/记忆（按时长+额度）、发/扣积分、云存储配额 |

### 5.1 「上游 API」到底填哪个地址（部署最常踩的坑）

⛔ **控制台地址 ≠ API 地址**。填成控制台时，面板能连上但读不到模型（返回的是登录页 HTML）：

```
https://你的域名                  → 302 到 /login（控制台）        ❌ 不是 API
https://你的域名/v1               → GET /v1/models 返回 JSON       ✅ 常见网关
https://你的域名/claude-code/default → 本产品记忆网关的默认实例     ✅ 自带记忆注入
```

自查一条命令即可（**返回 JSON 才对**，返回 HTML 就是填错了）：

```bash
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://你的域名/v1/models -H "Authorization: Bearer <密钥>"
# 期望：200 application/json（或 401 application/json —— 说明端点对、只是密钥不对）
# 若出现 text/html 或 302，说明这是控制台页面，不是 API
```

从 **1.0.8 起**面板会把「实际使用的上游地址」直接显示在「模型管理」页，并在同步失败时带上地址；
测试连通性也会区分三档：✓ 解析出模型列表 / ⚠ 能连通但返回网页（控制台）/ ✗ 不通。
候选端点表（管理目录 → `/v1/models` → `/models` → `/claude-code/default/v1/models`）
会依次尝试，**填了 API 地址 + 密钥就能自动识别**，不需要手工指定路径。

### 5.2 倍率（积分倍率）从哪来

同步目录时会顺带读上游倍率，**逐模型优先、账号级兜底**，都读不到就留空（面板显示「未设倍率 / 当前免费」）：

| 上游类型 | 端点 | 字段 | 粒度 |
|---|---|---|---|
| WBM / 内置供应商 | `/api/model-catalog` | `credits`（兼容 `credit/rate/ratio`） | 逐模型 |
| New API / one-api | `GET /api/pricing` | `model_ratio`（`quota_type=0` 才取） | 逐模型 |
| **sub2api** | `GET /v1/sub2api/billing` | `effective_rate_multiplier` → `resolved` → `group` | 账号级（兜底） |
| OpenAI 兼容 | `/v1/models` | 无倍率字段 | — |

⛔ 绝不猜默认倍率（猜错就是多扣钱）。模型管理页顶部会显示「倍率来源」，一眼看出这次是 pricing 还是 billing。

**Claude 协议**：同一个 `/v1/models` 换 `x-api-key + anthropic-version` 头再取一次，按 id 合并去重 ——
很多网关按请求头切分组，只用 Bearer 会漏掉 Claude 模型。

## 6. 更新

```bash
cd /opt/codex-cloud-admin
sudo git pull                 # 或重新解压新版覆盖
sudo systemctl restart codex-cloud-admin
```

面板里能看到当前版本：`GET /cloud-api/api/version` 返回 `{ version, repo, uptimeSec }`。
「检查更新」对比本仓最新 tag —— ⛔ 升级动作本身要在服务器上执行（面板不替你重启进程）。

## 7. 安全清单

- `config.env` 权限 `600`，**不要**提交进 git
- `HARNESS_ACCOUNTS_ORIGINS` 必须是你自己的域名（留空 = 浏览器请求全拒）
- 服务只监听 `127.0.0.1`，对外一律走反代 + HTTPS
- 密钥（网关/知识库/记忆）可放 `config.env`，也可在面板里配（面板值优先，存 `data.json` 0600）
- 定期备份 `data/`（`data.json` 是唯一真相源）

## 8. 与其他仓的关系

| 仓 | 作用 |
|---|---|
| 本仓 `codex-cloud-assistant` | **本套云端管理**（可自部署，你正在看的） |
| `codex-harness-desktop` | 桌面版客户端（本地构建，无需部署） |
| `codex-harness-cloud-src` | 云助手的"本地壳 + 云端界面"源码（界面资产部署到作者服务器） |

⛔ 本仓是**独立可跑**的：不依赖上面任何仓也能完成账号/积分/模型管理。
