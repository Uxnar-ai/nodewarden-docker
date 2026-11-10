# NodeWarden 自托管镜像
#
# 上游只提供 Cloudflare Workers 部署方式。本镜像用 Cloudflare 官方本地运行时
# （workerd，通过 wrangler dev 启动）把同一个 Worker 跑在容器里，不依赖
# Cloudflare 账号、D1、R2、KV 等云资源：
#   - D1      -> 本地 SQLite 文件
#   - R2      -> 本地对象存储目录
#   - KV      -> 本地命名空间
#   - Durable Objects -> 本地 SQLite 存储
#   - Cron    -> 容器内每 5 分钟调用 /__scheduled
# 全部状态落在 /data，迁移时只拷这个目录。

FROM node:22-bookworm-slim AS builder
WORKDIR /app

ENV NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false

COPY package.json package-lock.json ./
RUN npm ci --registry=https://registry.npmjs.org/

COPY tsconfig.json wrangler.toml wrangler.kv.toml ./
COPY shared ./shared
COPY webapp ./webapp
COPY src ./src
COPY scripts ./scripts
COPY migrations ./migrations
COPY patches ./patches

# 自托管补丁：config 响应里的服务器地址改用反代传来的协议/域名（幂等）
RUN node patches/forwarded-origin.mjs

RUN npm run build


FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    CI=1 \
    WRANGLER_SEND_METRICS=false \
    NW_DATA_DIR=/data \
    NW_PORT=8787

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/src ./src
COPY --from=builder /app/shared ./shared
COPY --from=builder /app/webapp ./webapp
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/migrations ./migrations
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/tsconfig.json ./tsconfig.json
COPY --from=builder /app/wrangler.toml ./wrangler.toml
COPY --from=builder /app/wrangler.kv.toml ./wrangler.kv.toml

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && mkdir -p /data/persist \
 && chown -R node:node /data /app

# 以 root 进入 entrypoint，修好挂载目录属主后立刻 setpriv 降权到 node 运行，
# 这样宿主机上 ./data 是 root 建的也不会启动失败。
EXPOSE 8787

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
