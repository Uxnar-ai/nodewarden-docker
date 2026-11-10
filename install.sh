#!/usr/bin/env bash
# NodeWarden 一键部署脚本（离线镜像版）
#
# 用法：
#   ./install.sh 你的域名                              # 用同目录镜像包导入
#   NW_IMAGE=ghcr.io/uxnar-ai/nodewarden-docker:latest ./install.sh 你的域名   # 直接拉 GHCR
#   ./install.sh                                       # 不填域名，仅内网 IP 访问（passkey 不可用）
#   NW_HOST_PORT=19000 ./install.sh 你的域名
#
# 做的事：
#   1. 检查 docker / compose
#   2. 准备镜像（本地已有则跳过；否则导入同目录镜像包）
#   3. 生成 .env（域名、端口、密钥留空由容器自动生成）
#   4. 起容器并等到 healthy
set -euo pipefail

cd "$(dirname "$0")"

DOMAIN="${1:-}"
PORT="${NW_HOST_PORT:-18787}"
CONTAINER="${NW_CONTAINER_NAME:-nodewarden}"
IMAGE_TAR="nodewarden-image-amd64.tar.gz"
IMAGE="${NW_IMAGE:-nodewarden:local}"

say() { printf '\033[1;36m[nw]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[nw] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 1. 环境检查 ----------
command -v docker >/dev/null 2>&1 || die "没装 docker。先装：curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || die "docker compose 不可用（需要 compose v2）"
docker info >/dev/null 2>&1 || die "连不上 docker daemon，确认服务已启动、当前用户有权限"

# ---------- 2. 镜像 ----------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  say "镜像 $IMAGE 已存在，直接使用"
elif [ "$IMAGE" != "nodewarden:local" ]; then
  say "拉取镜像 $IMAGE ..."
  docker pull "$IMAGE"
elif [ -f "$IMAGE_TAR" ]; then
  say "导入镜像包（约 360MB）..."
  gunzip -c "$IMAGE_TAR" | docker load
else
  die "既没有本地镜像 $IMAGE，也没找到 $IMAGE_TAR。想从源码构建：docker build -t nodewarden:local ."
fi

# ---------- 3. 配置 ----------
if [ -f .env ]; then
  say ".env 已存在，保留原配置"
else
  RP_ID=""
  ORIGINS=""
  if [ -n "$DOMAIN" ]; then
    RP_ID="$DOMAIN"
    ORIGINS="https://$DOMAIN"
  fi
  cat > .env <<EOF
# 留空由容器首次启动自动生成并保存到 ./data/jwt_secret
JWT_SECRET=
# Passkey 用；必须与实际访问域名一致。改了要重启容器。
WEBAUTHN_RP_ID=$RP_ID
WEBAUTHN_RP_NAME=NodeWarden
WEBAUTHN_ALLOWED_ORIGINS=$ORIGINS
# 1 = 关闭自带网页版，只留客户端 API
HIDE_WEB_VAULT=
# 只监听回环，由 Nginx / Cloudflare Tunnel 反代进来
NW_BIND_ADDR=127.0.0.1
NW_HOST_PORT=$PORT
# 每 5 分钟触发一次定时任务（云端自动备份依赖它）
NW_ENABLE_CRON=1
# compose 项目名 / 容器名 / 镜像（同机多实例或换镜像源时改掉）
NW_PROJECT=${NW_PROJECT:-nodewarden}
NW_CONTAINER_NAME=$CONTAINER
NW_IMAGE=$IMAGE
EOF
  chmod 600 .env
  say "已生成 .env"
fi

mkdir -p data

# ---------- 4. 启动 ----------
say "启动容器..."
docker compose up -d

say "等待健康检查（最多 90 秒）..."
for i in $(seq 1 45); do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo starting)"
  if [ "$STATUS" = "healthy" ]; then
    say "就绪。"
    break
  fi
  if [ "$i" = "45" ]; then
    echo
    die "启动超时，看日志：docker logs $CONTAINER"
  fi
  sleep 2
done

echo
say "完成。"
echo "  本机地址 : http://127.0.0.1:${PORT}"
if [ -n "$DOMAIN" ]; then
  echo "  对外地址 : https://${DOMAIN}（先把反向代理指到 127.0.0.1:${PORT}）"
fi
echo
echo "  下一步：浏览器打开，第一个注册的账号自动是管理员，之后注册需要邀请码。"
echo "  数据目录：$(pwd)/data —— 备份它就等于备份整个密码库。"
echo "  日志    ：docker logs -f $CONTAINER"
