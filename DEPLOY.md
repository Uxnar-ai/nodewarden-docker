# NodeWarden 部署与运维

Bitwarden 兼容的密码库服务端。上游只支持 Cloudflare Workers，本分发包把它跑在容器里：
用 Cloudflare 官方本地运行时（workerd）承载，D1→本地 SQLite、R2→本地目录、KV/DO→本地存储，
**不需要任何 Cloudflare 账号或云资源**。

```
Cloudflare / Nginx / Caddy (HTTPS)  →  127.0.0.1:18787 (容器)  →  workerd
```

## 包里有什么

| 文件 | 用途 |
|---|---|
| `nodewarden-image-amd64.tar.gz` | 预构建镜像（x86_64），免联网免构建，**推荐** |
| `nodewarden-src.tar.gz` | 完整源码 + 构建文件，想自己构建或改代码时用 |
| `install.sh` | 一键：导入镜像 → 生成 .env → 起容器 → 等 healthy |
| `docker-compose.yml` | 运行时定义（端口、数据卷、安全限制） |
| `.env.example` | 配置模板 |

---

## 快速开始（镜像版，3 条命令）

```bash
tar xzf nodewarden-kit-*.tar.gz && cd nodewarden-kit
chmod +x install.sh
./install.sh vault.example.com        # 换成你的域名；不填则只能内网 IP 访问
```

装完访问 `http://127.0.0.1:18787` 验活，再配反向代理对外。

**第一个注册的账号自动成为管理员**，之后所有注册都必须填邀请码（管理员在「用户管理」生成）。

> 预构建镜像是 **x86_64（amd64）** 的。ARM 机器（Apple Silicon、甲骨文 ARM 实例等）用不了，
> 改用下面的源码构建：`docker build --platform linux/amd64 -t nodewarden:local .`

### 没有 docker 的机器

```bash
curl -fsSL https://get.docker.com | sh
# 国内网络慢可换镜像源，装完把 docker 服务设为开机自启
systemctl enable --now docker
```

### 端口被占用 / 想换端口

```bash
NW_HOST_PORT=19000 ./install.sh vault.example.com
```

### 同一台机器跑第二个实例

容器名和 compose 项目名都要换，否则会接管已有容器：

```bash
NW_PROJECT=nw2 NW_CONTAINER_NAME=nodewarden2 NW_HOST_PORT=19001 ./install.sh test.example.com
```

---

## 从源码构建（可选）

```bash
tar xzf nodewarden-src.tar.gz && cd nodewarden
docker build -t nodewarden:local .
cp ../nodewarden-kit/{install.sh,docker-compose.yml} .   # compose 里去掉 build 段也行
./install.sh vault.example.com
```

构建需要访问 `registry.npmjs.org`（约 1.1k 个包），首次 3~8 分钟。

---

## 反向代理要求（必须照做，否则会出怪问题）

后端只监听回环，反代必须把真实信息传进去：

| 头 | 不传的后果 |
|---|---|
| `Host` | 客户端拿到的服务器地址变成 `127.0.0.1` |
| `X-Forwarded-Proto` | 地址变成 `http://`，https 页面里图标/接口被当混合内容拦掉 |
| `X-Real-IP` 或 `CF-Connecting-IP` | 所有访客共用一份限流配额，几个人一起用就 429 |
| `Upgrade` / `Connection` | 通知推送（WebSocket）连不上，改动不实时同步 |

还必须**封掉 `/__scheduled`**：那是容器内跑定时任务的内部端点，暴露出去任何人都能反复触发你的备份任务。

### CDN 回源（Cloudflare / EdgeOne / 其他）

源站前面套了 CDN 时，链路是：

```
浏览器 https://vault.example.com
   ↓ CDN 终止 TLS、做 WAF 和限速
   ↓ 回源 http://origin.example.com:80，Host 头 = vault.example.com
nginx：server_name vault.example.com → 127.0.0.1:18787
```

**两个概念别混**，它们在 CDN 控制台是两个独立配置：

| | 是什么 | 填什么 |
|---|---|---|
| 回源地址 | CDN 去哪儿取内容 | `origin.example.com` 或源站 IP，端口 80，协议 HTTP |
| 回源 Host 头 | 到源站后 `Host` 是什么 | **必须是用户访问的域名** `vault.example.com` |

回源 Host 如果填成 `origin.example.com`，应用会把它当成服务器地址返回给客户端，后果是：

- 客户端之后直连源站域名，**绕过 CDN**，WAF 和限速全失效
- Passkey 的 RP ID 对不上，**指纹 / 设备登录失效**

**nginx 里必检三项**

```nginx
# 1. 固定成对外域名，别用 $host
#    回源 Host 是回源域名时，$host 会把错误地址写进 config 响应
proxy_set_header X-Forwarded-Host vault.example.com;

# 2. 协议写死 https
#    CDN 回源走的是 http，$scheme 就是 http，config 会返回 http:// 地址，
#    浏览器把图标和接口当混合内容拦掉
proxy_set_header X-Forwarded-Proto https;

# 3. 不要设 X-Real-IP
#    回源时它是 CDN 节点 IP，应用按它做限流 = 全站共用一份配额
#    只传 X-Forwarded-For，让应用取第一段（真实客户端）
```

**防绕过**：回源域名通常公开可解析，别人拿它直连就绕过了 CDN。两种做法：

- CDN 配自定义回源请求头（如 `X-Origin-Token: <随机串>`），nginx 校验：

  ```nginx
  if ($http_x_origin_token != "<同一串随机值>") { return 444; }
  ```

  头名用**连字符**。带下划线的请求头 nginx 默认丢弃（`underscores_in_headers off`），
  填成 `X_Origin_Token` 会永远匹配不上，表现为全站 403。

- 或把回源域名的 A 记录只开放给 CDN 回源节点，用 IP 白名单。

**两个 CDN 侧常见限制**

- 免费版常限制单文件上传（Cloudflare 免费 100MB），要和 nginx 的 `client_max_body_size` 对齐。
- **WebSocket 必须在 CDN 侧显式开启**，否则通知推送不通，改动不会实时同步到其他设备。

### Nginx

```nginx
server {
    listen 80;
    server_name vault.example.com;
    client_max_body_size 100m;

    set $nw_proto $http_x_forwarded_proto;
    if ($nw_proto = "") { set $nw_proto $scheme; }

    location ^~ /__scheduled { return 404; }

    location / {
        proxy_pass http://127.0.0.1:18787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # 直连反代（前面没有 CDN）才加这行；有 CDN 时必须注释掉，见上一节
        # proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $nw_proto;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
```

### Caddy

```caddyfile
vault.example.com {
    @sched path /__scheduled
    respond @sched 404

    reverse_proxy 127.0.0.1:18787 {
        request_body { max_size 100MB }
    }
}
```

Caddy 自动配 HTTPS 并默认带齐 `X-Forwarded-*`。

### Cloudflare Tunnel

`config.yml` 的 ingress 里加：

```yaml
  - hostname: vault.example.com
    service: http://localhost:80      # 前面有 Nginx 就指 80，没有就指 http://localhost:18787
```

```bash
cloudflared tunnel route dns <隧道名或ID> vault.example.com
systemctl restart cloudflared
```

走 Tunnel 时 cloudflared 会自动带上 `X-Forwarded-Proto: https`。

---

## 客户端怎么填

Bitwarden 浏览器扩展 / 手机 App / 桌面端 → 登录界面选「自托管」→ 服务器地址填
`https://vault.example.com`（不要带 `/api`，不要用 http）。

---

## 备份与迁移

**要备的只有一个目录：`data/`**

```bash
tar czf nw-backup-$(date +%F).tgz data
```

| 文件 | 说明 |
|---|---|
| `data/jwt_secret` | 会话签名 + 备份凭据加密。**丢了所有人掉线、云备份凭据解不开** |
| `data/persist/v3/` | D1 数据库、Durable Objects、附件 |

迁移：新机器上解包 → 把 `data/` 覆盖回去 → `docker compose up -d`。
从别处拷回数据若属主不对，启动时加 `NW_FIX_OWNER=1` 让它递归修一次：

```bash
NW_FIX_OWNER=1 docker compose up -d
```

---

## 更新

```bash
tar czf nw-backup-$(date +%F).tgz data          # 先备份
curl -sL https://ghfast.top/https://github.com/shuaiplus/nodewarden/archive/refs/heads/main.tar.gz -o /tmp/nw.tgz
tar xzf /tmp/nw.tgz --strip-components=1         # 只覆盖源码，不动 data/ .env Dockerfile
docker build -t nodewarden:local .
docker compose up -d --force-recreate
```

> 构建时会跑 `patches/forwarded-origin.mjs`（让服务端知道你反代的真实协议和域名）。
> 若上游改了那行锚点，补丁会报 `anchor not found` 并让构建失败——这是有意的，
> 说明需要人工看一眼，而不是默默生成一堆 `http://127.0.0.1` 的地址。

---

## 小内存机器（1–2G）

`wrangler dev` 承载生产，空载就要 450–500MB。1G 上限的机器在同步时容易卡死，典型现象：

```
网页显示「暂时无法验证会话，登录状态已保留，稍后会自动重试」
公网请求 30 秒超时，容器 health 仍显示 healthy
docker stats 显示 1022MiB / 1GiB
```

根因：客户端同步时会给每个条目的网址抓 favicon，默认全由容器内的 Worker 完成，
单张 1–4 秒，请求一积压就把内存吃满。**不是死机，是内存耗尽后所有请求排队超时。**

**两步解决**

1. 图标交给官方服务（`.env`）：

```ini
ICON_SERVICE_URL=https://icons.bitwarden.net
```

改完客户端直接用官方地址取图，容器一个字节不花，条目里的域名也不会写进你的访问日志。
留空则维持原行为（本站抓图）。

2. 抬高上限 + 配好 swap：

```yaml
# docker-compose.yml
mem_limit: 1536m
memswap_limit: 3g
```

```bash
swapon --show                  # 确认 swap 真的挂上了
sysctl vm.swappiness           # 0 = 几乎不用 swap，等于白配
sysctl -w vm.swappiness=60
echo 'vm.swappiness=60' >> /etc/sysctl.conf
```

`vm.swappiness=0` 的机器宁可 OOM 杀进程也不换页，很多镜像/面板默认就是 0，
所以「有 swap 但 used 一直是 0B」是正常的假象。

判断是否需要升配：swap 长期被占用几百 MB，说明已经到极限 —— 升内存，
或者把面板类服务（宝塔等，自己就吃 200–300MB）挪到别的机器。

## 安全清单

已内置：

- 端口只绑 `127.0.0.1`，公网进不来
- 容器降权到 `node` 运行；`cap_drop: ALL` 只加回 `CHOWN/DAC_OVERRIDE/FOWNER/SETUID/SETGID`
- `no-new-privileges`、`tmpfs /tmp`、内存与 PID 上限、日志轮转
- 首个用户即管理员，之后必须邀请码
- Passkey RP ID 绑定域名

要你自己做：

1. **主密码用长密码** —— 零知识加密，服务端只有密文，忘了谁也救不回来
2. **开两步验证**，恢复码离线存好
3. **定期备份 `data/`**
4. `.env`、`data/`、`jwt_secret` 不要进仓库、不要传网盘
5. 想更严可再套 Cloudflare Access（但客户端 App 会连不上，只适合纯网页）

已知限制：

- 用 `wrangler dev`（开发服务器）承载生产流量。功能完整、个人库够用，但 Cloudflare 未给此用法背书；升级 wrangler 需回归测试
- 无组织/合集/SSO（上游本身未实现）
- 附件单文件受反代 `client_max_body_size` 限制（默认给了 100m）

---

## 排障

| 现象 | 处理 |
|---|---|
| 容器反复重启，日志 `JWT_SECRET 少于 32 字符` | `.env` 里留空或填 ≥32 字符 |
| 页面 502 | `docker compose ps` 看是否 healthy；`docker logs nodewarden` |
| `Database initialization failed` | `docker compose down && chown -R 1000:1000 data && docker compose up -d` |
| 附件 413 | 调大反代的 `client_max_body_size` |
| 客户端同步报错 | 地址填 `https://域名`，确认反代传了 `X-Forwarded-Proto` |
| 登录后立刻掉线 | `data/jwt_secret` 被删或换了，恢复备份即可 |
