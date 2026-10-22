#!/usr/bin/env bash
# 部署验收脚本 —— 「部署完就能用」的唯一判据。
#
#   bash deploy/verify-all.sh example.com
#   bash deploy/verify-all.sh example.com --local     # 在服务器上跑：额外检查本机端口
#
# 判据（每条都对应文档 §8.2 的一步排查）：
#   1. 记忆网关 /health 必须是 200
#   2. 模型目录接口必须返回「鉴权错误」（401/403）而不是 502/404  ← 链路通了才可能这样
#   3. 记忆面板、知识库前端必须 200
#   4. 云管理 API 必须返回 401（接口在、缺凭据）而不是 5xx
#   5. 反代不应再有 openresty 层（仍然有 = 还在走 frp 隧道，不是本机服务）
#
# ⛔ 不需要任何密钥：本脚本只验「服务在不在、链路通不通」，不消费 token。

set -u

DOMAIN="${1:-}"
LOCAL=0
[ "${2:-}" = "--local" ] && LOCAL=1

if [ -z "$DOMAIN" ]; then
  echo "用法: bash deploy/verify-all.sh <域名> [--local]" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_NAMES=""

# check <名称> <期望> <实际> <排查提示>
check() {
  local name="$1" expect="$2" actual="$3" hint="${4:-}"
  if [ "$expect" = "$actual" ]; then
    printf '  \033[32m✓\033[0m %-34s %s\n' "$name" "$actual"
    PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %-34s 期望 %s，实得 %s\n' "$name" "$expect" "$actual"
    [ -n "$hint" ] && printf '      ↳ %s\n' "$hint"
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
  fi
}

code() {  # code <url> [extra curl args...]
  local url="$1"; shift
  local out
  out="$(curl -s -o /dev/null -m 12 -w '%{http_code}' "$@" "$url" 2>/dev/null)"
  printf '%s' "${out:-000}"
}

echo "== 反代域名（https） =="
check "记忆网关 /health"            "200" "$(code "https://memapi.$DOMAIN/health")" \
      "网关没起或反代指错端口：sudo ss -lntp | grep 8096"

MODELS=$(code "https://memapi.$DOMAIN/claude-code/default/v1/models")
case "$MODELS" in
  401|403) check "模型目录（鉴权错误=链路通）" "$MODELS" "$MODELS" ;;
  *)       check "模型目录（鉴权错误=链路通）" "401/403" "$MODELS" \
                 "502=上游没起；404=client 名写错或缺前缀剥离（见 Caddyfile.example）" ;;
esac

check "记忆空间面板"                "200" "$(code "https://mem.$DOMAIN/")" \
      "8424/8125 未监听或反代错：docker ps | grep tdai"
check "知识库前端"                  "200" "$(code "https://kb.$DOMAIN/")" \
      "WeKnora 未起：cd WeKnora && docker compose ps"

# 云管理有两种布局：独立子域 a.<域名>，或直接挂在主域 /cloud-api/*
CLOUD_HOST="${CLOUD_HOST:-a.$DOMAIN}"
CADM="$(code "https://$CLOUD_HOST/cloud-api/models")"
if [ "$CADM" = "000" ] && [ "$CLOUD_HOST" != "$DOMAIN" ]; then
  CLOUD_HOST="$DOMAIN"
  CADM="$(code "https://$CLOUD_HOST/cloud-api/models")"
fi
check "云管理 API（$CLOUD_HOST）"   "401" "$CADM" \
      "云管理没起：systemctl status codex-cloud-admin（缺凭据返回 401 才算对）"

echo
echo "== 链路健康（不该再有隧道层） =="
for host in "mem.$DOMAIN" "kb.$DOMAIN"; do
  layers=$(curl -sI -m 10 "https://$host/" 2>/dev/null | grep -ci '^server:')
  if [ "$layers" -ge 2 ]; then
    printf '  \033[33m!\033[0m %-34s 有 %s 层 Server 头（疑似仍经 frp → 家里 NPM）\n' "$host" "$layers"
  else
    printf '  \033[32m✓\033[0m %-34s 单层 Server（本机直连）\n' "$host"
    PASS=$((PASS + 1))
  fi
done

if [ "$LOCAL" = "1" ]; then
  echo
  echo "== 本机端口 =="
  for p in 8096 8420 8125 8424 8091 80; do
    if ss -lntH 2>/dev/null | grep -q ":$p "; then
      printf '  \033[32m✓\033[0m %-34s LISTEN\n' "127.0.0.1:$p"; PASS=$((PASS + 1))
    else
      printf '  \033[31m✗\033[0m %-34s 无监听\n' "127.0.0.1:$p"; FAIL=$((FAIL + 1))
      FAILED_NAMES="$FAILED_NAMES port:$p"
    fi
  done
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m全部通过（%s 项）\033[0m —— 可以在客户端点「连接测试」了。\n' "$PASS"
  exit 0
fi
printf '\033[31m%s 项失败\033[0m：%s\n' "$FAIL" "$FAILED_NAMES"
echo "按文档 §8.2 的顺序排查：根路径 502 ⇒ 服务端；特定路径 4xx ⇒ 客户端协议/参数。"
exit 1
