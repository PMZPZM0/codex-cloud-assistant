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
网关要不要自己装、怎么装，见 **[`deploy/model-gateway.md`](deploy/model-gateway.md)**：

- **方案 A 全栈单机**：记忆代理 + 上游中继 + Caddy 全放一台服务器（一个 compose，带验证清单）；
- **方案 B 仅模型通道**：不部署记忆，只把 `/claude-code/<instance>` 前缀剥掉直连中继
  （⚠️ 先决条件：客户端发的是记忆代理签发的 `sk-mem-*`，中继只认自己的 key，不做换 key 映射会 401）；
- 另附 **frp 隧道形态**（NAS 在家）的风险说明与一页 6 条命令的排障手册；
- 还有 **第 7 章「把三件套 + 云管理合并到一台服务器」**：目标拓扑、资源预算（8C/16G 起就够，
  磁盘不是瓶颈）、分三步迁移（先网关、再记忆空间/知识库、最后切流撤隧道）、验收清单与回滚表。

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
