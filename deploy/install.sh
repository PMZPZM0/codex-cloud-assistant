#!/usr/bin/env bash
# ── codex-cloud-assistant 一键部署（Ubuntu / Debian，需 root）─────────────────
#   sudo bash deploy/install.sh                  # 默认装到 /opt/codex-cloud-admin
#   sudo INSTALL_DIR=/srv/cca bash deploy/install.sh
#   sudo bash deploy/install.sh --uninstall
#
# 做的事：检查 Node → 建目录 → 拷代码 → 生成 config.env（若不存在）→ 建 systemd 单元
#        → 提示创建管理员 → 起服务。⛔ 不会动你的 nginx/caddy 配置（反代示例见 README）。
set -euo pipefail

DIR="${INSTALL_DIR:-/opt/codex-cloud-admin}"
SVC="codex-cloud-admin"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install] %s\033[0m\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
  say "停止并移除 $SVC（数据目录保留：$DIR/data）"
  systemctl disable --now "$SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SVC.service"
  systemctl daemon-reload
  say "服务已移除。代码目录 $DIR 与数据未删（如需彻底删除：rm -rf $DIR）"
  exit 0
fi

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo bash deploy/install.sh）"

# ① Node（>= 18，只需 fetch/AbortSignal.timeout）
if ! command -v node >/dev/null 2>&1; then
  die "未找到 node。请先装 Node.js 18+（建议 20/22）：
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs"
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node 版本过低（当前 $(node -v)），需要 >= 18"
say "Node $(node -v) ✓"

# ② 目录与代码
mkdir -p "$DIR/data"
if [ "$SRC" != "$DIR" ]; then
  cp -r "$SRC/server-account" "$SRC/web" "$DIR/"
  [ -f "$SRC/VERSION" ] && cp "$SRC/VERSION" "$DIR/"
  say "代码已复制到 $DIR"
else
  say "已在目标目录，跳过复制"
fi

# ③ 配置文件
if [ ! -f "$DIR/config.env" ]; then
  cp "$SRC/config.example.env" "$DIR/config.env"
  chmod 600 "$DIR/config.env"
  say "已生成 $DIR/config.env —— ⛔ 先把 HARNESS_ACCOUNTS_ORIGINS 改成你的面板域名"
else
  say "已存在 $DIR/config.env（不覆盖）"
fi

# ④ systemd 单元
cat > "/etc/systemd/system/$SVC.service" <<UNIT
[Unit]
Description=Codex Cloud Assistant (account / credits / model pool)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR
EnvironmentFile=$DIR/config.env
ExecStart=$(command -v node) $DIR/server-account/server.js
Restart=always
RestartSec=3
# 数据目录可写；其余只读
ReadWritePaths=$DIR/data
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
say "systemd 单元已写入 /etc/systemd/system/$SVC.service"

# ⑤ 首次创建管理员（❗必须在服务启动前，否则会与内存里的库互相覆盖）
if [ ! -f "$DIR/data/data.json" ]; then
  say "初始化数据文件与管理员的两种方式："
  say "  A) 交互式（推荐）：cd $DIR && set -a && . ./config.env && set +a && node server-account/server.js --init-admin <用户名> <密码>"
  say "  B) 启动后在面板注册首个账号，再手工把 data.json 里该账号 role 改成 admin"
fi

systemctl enable --now "$SVC"
sleep 1
systemctl is-active --quiet "$SVC" && say "服务已启动 ✓（$SVC）" || say "⚠️ 服务未启动，看日志：journalctl -u $SVC -n 50 --no-pager"

cat <<TIP

下一步：
  1. 改 $DIR/config.env 里的 HARNESS_ACCOUNTS_ORIGINS（你的面板域名）→ systemctl restart $SVC
  2. 配反代（README 第 3 节），把 /cloud-api/* 反代到 127.0.0.1:$(grep -E '^HARNESS_ACCOUNTS_PORT=' "$DIR/config.env" | cut -d= -f2 || echo 8091)
  3. 打开 https://<你的域名>/account.html#/admin 登录
  4. 面板「上游 API」「知识库 · 记忆空间」「模型管理」按需配置

更新：cd $DIR && git pull && systemctl restart $SVC     （或重跑本脚本覆盖代码）
状态：systemctl status $SVC        日志：journalctl -u $SVC -f
TIP
