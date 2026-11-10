#!/bin/sh
# NodeWarden 容器启动脚本
#
# 职责：
#   1. 准备 /data 持久化目录（D1 SQLite / Durable Objects / R2 对象全在里面）
#   2. 解析 JWT_SECRET：环境变量 > /data/jwt_secret > 自动生成并落盘
#      （密钥一旦变化，所有登录会话失效、备份凭据解不开，所以必须持久化）
#   3. 生成 wrangler 需要的 .dev.vars（权限 600）
#   4. 降权到 node 用户启动 wrangler dev（本地 workerd），并按 5 分钟触发 cron
set -eu

PORT="${NW_PORT:-8787}"
DATA_DIR="${NW_DATA_DIR:-/data}"
PERSIST_DIR="${DATA_DIR}/persist"
SECRET_FILE="${DATA_DIR}/jwt_secret"

IS_ROOT=0
if [ "$(id -u)" = "0" ]; then
  IS_ROOT=1
  mkdir -p "${PERSIST_DIR}"
  # 只修顶层属主：容器内 node 新建的文件本来就是 node 所有。
  # 从别处拷回来的数据（属主是 root）设 NW_FIX_OWNER=1 递归修一次。
  chown node:node "${DATA_DIR}" "${PERSIST_DIR}" 2>/dev/null || true
  if [ "${NW_FIX_OWNER:-0}" = "1" ]; then
    echo "[init] 递归修正 ${DATA_DIR} 属主（可能较慢）"
    chown -R node:node "${DATA_DIR}" 2>/dev/null || true
  fi
  chmod 700 "${DATA_DIR}" 2>/dev/null || true
fi

# ---------- JWT_SECRET ----------
if [ -n "${JWT_SECRET:-}" ]; then
  SECRET="${JWT_SECRET}"
  # 环境变量提供的密钥同步落盘，避免以后漏传 .env 时换成新密钥
  if [ ! -s "${SECRET_FILE}" ]; then
    umask 077
    printf '%s' "${SECRET}" > "${SECRET_FILE}"
  fi
elif [ -s "${SECRET_FILE}" ]; then
  SECRET="$(cat "${SECRET_FILE}")"
else
  SECRET="$(node -e 'process.stdout.write(require("crypto").randomBytes(48).toString("base64url"))')"
  umask 077
  printf '%s' "${SECRET}" > "${SECRET_FILE}"
  echo "[init] 已生成新的 JWT_SECRET 并保存到 ${SECRET_FILE}"
  echo "[init] 迁移时务必把整个 ${DATA_DIR} 一起备份，否则所有用户会掉线。"
fi

if [ "${#SECRET}" -lt 32 ]; then
  echo "[fatal] JWT_SECRET 少于 32 字符，拒绝启动。" >&2
  exit 1
fi

# ---------- .dev.vars ----------
umask 077
{
  printf 'JWT_SECRET=%s\n' "${SECRET}"
  if [ -n "${WEBAUTHN_RP_ID:-}" ]; then
    printf 'WEBAUTHN_RP_ID=%s\n' "${WEBAUTHN_RP_ID}"
  fi
  if [ -n "${WEBAUTHN_RP_NAME:-}" ]; then
    printf 'WEBAUTHN_RP_NAME=%s\n' "${WEBAUTHN_RP_NAME}"
  fi
  if [ -n "${WEBAUTHN_ALLOWED_ORIGINS:-}" ]; then
    printf 'WEBAUTHN_ALLOWED_ORIGINS=%s\n' "${WEBAUTHN_ALLOWED_ORIGINS}"
  fi
  if [ -n "${HIDE_WEB_VAULT:-}" ]; then
    printf 'HIDE_WEB_VAULT=%s\n' "${HIDE_WEB_VAULT}"
  fi
} > /app/.dev.vars
chmod 600 /app/.dev.vars

if [ "${IS_ROOT}" = "1" ]; then
  chown node:node "${SECRET_FILE}" /app/.dev.vars 2>/dev/null || true
  chown -R node:node /app/node_modules/.cache 2>/dev/null || true
fi

# ---------- cron ----------
# wrangler dev 不会自己跑 cron trigger，只能通过 /__scheduled 手动触发
# （wrangler.toml 里定义的是 */5 * * * *）。这里用后台循环模拟。
if [ "${NW_ENABLE_CRON:-1}" = "1" ]; then
  (
    while sleep 300; do
      curl -fsS "http://127.0.0.1:${PORT}/__scheduled?cron=*/5+*+*+*+*" >/dev/null 2>&1 || true
    done
  ) &
fi

echo "[init] 数据目录: ${DATA_DIR}（备份这个目录即可迁移）"
echo "[init] 监听: 0.0.0.0:${PORT}"

START_CMD="exec npx wrangler dev -c wrangler.toml --ip 0.0.0.0 --port ${PORT} --persist-to ${PERSIST_DIR} --test-scheduled"

if [ "${IS_ROOT}" = "1" ]; then
  # HOME 必须换掉，否则 wrangler 会去访问 /root/.wrangler 而失败
  exec setpriv --reuid=node --regid=node --init-groups \
    env HOME=/home/node \
    sh -c "${START_CMD}"
fi

exec sh -c "${START_CMD}"
