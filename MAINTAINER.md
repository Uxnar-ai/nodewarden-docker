# NodeWarden Docker 维护手册

> 这份文档写给"三个月后的自己"：怎么拼起来的、为什么这么做、上游更新时怎么跟。
> 不含任何域名、IP、凭据——那些看 `.env` 和 `data/jwt_secret`。

---

## 接手须知

隔了很久回来、或者换人接手，按这个顺序读：

1. `README.md` —— 这是什么、三种安装方式、装完要注意什么
2. `DEPLOY.md` —— 反代怎么配（**CDN 回源那节最容易踩**）、小内存调优、排障表
3. 本文档 —— 内部结构、为什么这么设计、跟进上游时要动哪里

**两个最容易忘的前提**

- 线上跑的不是 Cloudflare Workers，而是 `wrangler dev`（本地 workerd）承载生产流量，
  D1/R2/KV/DO/Cron 全部落到容器内 `/data`。行为可能和上游文档不一致，别照上游的说明排查。
- 唯一改过的上游源码是 `src/config-response.ts`（图标服务地址）。同步上游会**静默**覆盖它，
  不会报错，只表现为 `ICON_SERVICE_URL` 失效。见 §4.4。

---

## 0. 一页速查

```bash
# 服务器项目目录（宝塔规范：Python 项目进 /www/wwwroot/Python/<项目>）
cd /www/wwwroot/Python/nodewarden

docker compose ps                     # 状态，healthy 才对
docker logs --tail 100 nodewarden     # 全部日志都在这里
docker compose restart nodewarden
docker compose down / up -d

# 备份（一行等于备份整个密码库）
tar czf ~/nw-data-$(date +%F).tgz data

# 本地工程（本手册所在目录 = 项目根）
./                      # 上游源码 + Docker 文件（真实配置，不提交）
./dist/                 # 分发包产物（镜像包 / 源码包 / 一键脚本）
```

线上实例的访问域名、端口绑定都记在 `服务器项目目录/.env` 里。

---

## 1. 这套东西是怎么拼起来的

### 上游的约束

上游 `shuaiplus/nodewarden` 是一个 **Cloudflare Workers 应用**，官方只给两条部署路径：Fork 到 Cloudflare 用 Workers Builds 构建，或 `wrangler deploy`。它依赖四个云服务：

| 上游依赖 | 作用 |
|---|---|
| D1 | SQLite 数据库（用户、密文、配置） |
| R2 | 附件 / Send 文件 |
| KV | 可选的附件兜底存储 |
| Durable Objects | 通知推送、备份任务执行器 |
| Cron Trigger `*/5 * * * *` | 定时云备份 |

没有 Node 运行时，所以"搬到自己服务器"没有落点。

### 替代方案

用 Cloudflare **官方本地运行时 workerd**（通过 `wrangler dev` 启动）承载同一个 Worker，四个云依赖逐个本地化：

| 上游 | 本地实现 | 落盘位置 |
|---|---|---|
| D1 | 本地 SQLite | `/data/persist/v3/d1` |
| R2 | 本地对象存储 | `/data/persist/v3/r2` |
| KV | 本地命名空间 | `/data/persist/v3/kv` |
| Durable Objects | 本地 SQLite 存储 | `/data/persist/v3/do` |
| Cron | 容器内每 5 分钟 `curl /__scheduled` | — |

**request 链路**

```
客户端/浏览器
  → Cloudflare 边缘（HTTPS 终止）
  → cloudflared tunnel
  → Nginx :80（补 4 个转发头、封 /__scheduled）
  → 127.0.0.1:18787（容器，只绑回环）
  → wrangler dev → workerd → Worker 代码
```

### 为什么用 wrangler dev 当生产运行时

因为上游没有任何 Node/Deno/Bun 适配层，`wrangler dev` 是唯一"不改业务代码就能跑"的路径。它就是 workerd 的官方启动器，功能等价，只是 Cloudflare 没给它生产背书。

代价：wrangler 大版本升级要回归测试；容器重启靠 `restart: unless-stopped` 兜。

---

## 2. 文件职责

| 文件 | 干什么 | 上游更新会覆盖吗 |
|---|---|---|
| `Dockerfile` | 两阶段：builder 里 `npm ci` + `vite build` 出前端 dist；runtime 只装 curl/tini，全量拷 node_modules 与源码 | 不会（上游没有） |
| `docker-entrypoint.sh` | 修 `/data` 属主 → 解析 JWT_SECRET → 写 `.dev.vars` → 起 cron 循环 → `setpriv` 降权到 node 启动 | 不会 |
| `docker-compose.yml` | 端口只绑回环、`cap_drop ALL` + 5 个必需 cap、tmpfs、资源上限、健康检查 | 不会 |
| `patches/forwarded-origin.mjs` | 改 `config` 响应里的服务器地址，改用反代传来的协议/域名（幂等，锚点缺失即失败） | 不会，但**依赖上游某行代码** |
| `install.sh` | 一键：查 docker → 准备镜像（本地/导入/GHCR）→ 按域名写 `.env` → 起容器 → 等 healthy | 不会 |
| `src/config-response.ts` | **唯一改过的上游源码**：`icons` / `_icon_service_url` / `_icon_service_csp` 三处统一由 `resolveIconService` 算出，支持 `ICON_SERVICE_URL` | 会，同步上游时要重新应用 |
| `.github/workflows/build-image.yml` | push main 自动构建镜像推 GHCR | 不会 |
| `.github/workflows/release-image.yml` | 手动触发：构建 → `docker save` → 挂到指定 Release（离线包只能这样传，国内服务器上行太慢） | 不会 |
| `.env` | 域名、端口、Passkey 配置（**不在版本库**） | — |
| `data/` | 全部状态（**不在版本库**） | — |

`wrangler.toml` / `wrangler.kv.toml` 保持上游原样，本地模式下 D1/R2/DO 会自动落到 `--persist-to` 指定的目录，不需要 `database_id`。

---

## 3. 数据与迁移

`data/` 里只有两样：

```
data/
├── jwt_secret      会话签名 + 云备份凭据加密（AES-GCM 密钥派生自它）
└── persist/v3/     D1 + DO + R2 + KV
```

两条铁律：

1. **`jwt_secret` 丢不得**。丢了等于全员会话失效 + 之前配的云备份凭据解不开（要重填）。
2. **改了 `JWT_SECRET` 环境变量也等于换密钥**。`.env` 里留空最省心，容器首次启动会生成 48 字节随机串落盘。

迁移到新机器：

```bash
# 老机器
tar czf nw.tgz data
# 新机器：项目目录 + 解开的 data/ 放回去
docker compose up -d
# 若从别处拷回、属主不对（容器内是 uid 1000）：
NW_FIX_OWNER=1 docker compose up -d
```

---

## 4. 更新上游版本

### 4.1 先判断上游有没有新版

```bash
# 服务器或本机（api.github.com 比 github.com 通得稳）
curl -s https://api.github.com/repos/shuaiplus/nodewarden/releases/latest | grep -E '"tag_name"|"published_at"'
# 和本地对着看
grep '"version"' package.json
```

上游节奏不快（常常几周不发版），所以**不必天天盯**，想起来时查一次即可。

### 4.2 手动更新流程（当前做法）

```bash
cd /www/wwwroot/Python/nodewarden

# 1) 先备份数据，永远第一步
tar czf ~/nw-data-$(date +%F).tgz data

# 2) 拉上游源码（服务器直连 GitHub 不通，走代理）
curl -sL https://ghfast.top/https://github.com/shuaiplus/nodewarden/archive/refs/heads/main.tar.gz -o /tmp/nw.tgz
tar xzf /tmp/nw.tgz --strip-components=1

# 3) 重建镜像（npm ci 约 1~3 分钟，取决于网络）
docker build -t nodewarden:local .

# 4) 换容器（数据卷不动）
docker compose up -d --force-recreate

# 5) 验活
docker compose ps                       # 等 healthy
curl -s http://127.0.0.1:18787/api/config | head -c 200
docker logs --tail 40 nodewarden
```

**解压不会删掉你的文件**：`Dockerfile`、`docker-entrypoint.sh`、`docker-compose.yml`、`patches/`、`.env`、`data/` 上游都没有，覆盖不到。会被覆盖的是 `src/ webapp/ shared/ migrations/ package.json package-lock.json wrangler*.toml` —— 正是想更新的部分。

**升级后必做三件事**：

1. 浏览器登录一次，确认能进库
2. 新建/编辑一条密码，确认双向同步
3. `docker logs` 里搜 `anchor not found`（补丁锚点失效的信号）

### 4.3 如果要自动化（可选，需自己加）

两段 workflow，放 `.github/workflows/`：

```yaml
# sync-upstream.yml —— 每天 03:00 查上游，有新版就同步并触发构建
name: sync-upstream
on:
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      actions: write
    steps:
      - uses: actions/checkout@v4

      - name: 对比上游最新 tag
        id: up
        run: |
          UP=$(curl -s https://api.github.com/repos/shuaiplus/nodewarden/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
          CUR=$(grep -oP '"version":\s*"\K[^"]+' package.json)
          echo "upstream=$UP current=$CUR"
          [ "$UP" != "$CUR" ] && echo "changed=1" >> "$GITHUB_OUTPUT" || true

      - name: 覆盖源码
        if: steps.up.outputs.changed == '1'
        run: |
          curl -sL "https://codeload.github.com/shuaiplus/nodewarden/tar.gz/refs/heads/main" -o /tmp/up.tgz
          tar xzf /tmp/up.tgz --strip-components=1 \
            --exclude='Dockerfile' --exclude='docker-*' --exclude='.env*' --exclude='data'
          git -c user.name="WorkBuddy Agent" -c user.email="ai@uxnar.com" \
              add -A
          git -c user.name="WorkBuddy Agent" -c user.email="ai@uxnar.com" \
              commit -m "chore: sync upstream ${{ steps.up.outputs.up }}" || true
          git push
```

配套：`build-image.yml` 构建成功后自动发 Release（用 `softprops/action-gh-release`，`tag` 取 `package.json` 的 version），订阅者在 GitHub 点 **Watch → Custom → Releases** 就能收邮件。

那条 `sync` 里刻意用了 `--exclude`，防止上游 tarball 将来带上同名文件把 Docker 化改动覆盖掉。

### 4.4 四个耦合点，上游大改会断

| 位置 | 依赖 | 断了的症状 | 怎么办 |
|---|---|---|---|
| `patches/forwarded-origin.mjs` | `src/router-public.ts` 里 `const origin = new URL(request.url).origin;` 这一行 | 构建直接失败：`anchor not found` | 去新代码里找 config 响应的 origin 怎么算的，改锚点或改文本替换 |
| `Dockerfile` / entrypoint | `wrangler dev` 的参数 `--persist-to` `--test-scheduled` `--ip` | 容器起不来 / 定时任务不跑 | 看 `npx wrangler dev --help` 对齐参数名 |
| entrypoint | `/__scheduled` 端点、`/data/.wrangler`、`persist/v3` 目录 | 备份不跑 / 数据重建成空库 | 起容器后确认 `data/persist/v3/` 有内容，日志里搜 `__scheduled` |
| `src/config-response.ts` | 直接改的上游源码（`resolveIconService` + `ICON_SERVICE_URL`），**不是补丁** | 同步上游后被原样覆盖，`ICON_SERVICE_URL` 静默失效（图标回落本站，不报错） | 同步后重新应用：三处 `icons` / `_icon_service_url` / `_icon_service_csp` 改用 `resolveIconService`，函数签名加 `iconServiceUrl` |

前三项的失败是响的（构建报错或功能明显坏），**第四项是静默的**，同步上游后极易漏掉。
判断办法：容器里设了 `ICON_SERVICE_URL` 但 `/api/config` 的 `icons` 仍指向本站，就是被覆盖了。

第一项失败即中断是有意的：宁可红色构建，也不要产出一个所有地址都是 `http://127.0.0.1:8787` 的镜像。

---

## 5. 已知坑（都是这次真踩过的）

1. **`cap_drop: ALL` 会让容器内 root 写不了 `/app`**
   少了 `DAC_OVERRIDE`，root 不能越过文件属主写文件。必须加回 `CHOWN / DAC_OVERRIDE / FOWNER / SETUID / SETGID`。
2. **`setpriv` 降权后 `HOME` 还是 `/root`**
   wrangler 去读 `/root/.wrangler` 报 `EACCES`。降权时必须 `env HOME=/home/node`。
3. **宿主机建的 `data/` 属主是 root，容器内 node 写不了**
   entrypoint 以 root 进来先 `chown node:node /data`，再降权。只修顶层，不递归（附件多时递归很慢），需要时用 `NW_FIX_OWNER=1`。
4. **`wrangler dev` 会自己跑一遍 `[build] command`**
   每次启动都 `vite build` 一遍（约 2 秒）。镜像里虽然有 dist，但会被重建，不用管。
5. **`--test-scheduled` 把 `/__scheduled` 暴露到公网**
   后果是任何人都能反复触发备份任务。反代里 `location ^~ /__scheduled { return 404; }` 必须加。
6. **反代不传 `X-Forwarded-Proto` 会生成 `http://` 地址**
   上游用 `new URL(request.url).origin`，容器里永远是 `http://127.0.0.1:8787`。所以有了那个补丁 + 必须传头。
7. **不传 `X-Real-IP` 等于全员共享一份限流配额**
   公开接口 60 次/分钟，几个人一起用就 429。走 Cloudflare 时传 `CF-Connecting-IP`。
8. **Windows 上 `git show` 会做 autocrlf 转换**，看起来文件是 CRLF，实际仓库里是 LF。判断用 `git cat-file -p` 或 `git ls-files --eol`。shell 脚本/Dockerfile 一旦真带 CRLF，Linux 上直接 `\r: command not found`。
9. **国内拉 ghcr.io 会卡死在 `Pulling fs layer`**，`ghcr.m.daocloud.io` 代理不收（不在白名单）。国内一律走 Release 离线包。
10. **Worker 的 `env` 只来自 `.dev.vars`，`docker -e` 传的变量进不去**
    新加环境变量时，除了 compose 的 `environment` 和 `src/types` 里的字段，**必须**在
    `docker-entrypoint.sh` 的 `.dev.vars` 生成段补一行，否则 `env.XXX` 永远是 `undefined`，
    而且不报错、静默回退到默认值。`JWT_SECRET` / `WEBAUTHN_*` 都是这么来的。
11. **图标请求会把 1G 内存的容器打满**
    客户端同步时给每个条目抓 favicon，默认由容器内 Worker 抓，单张 1–4 秒。请求积压后
    `docker stats` 显示 1022MiB/1GiB，公网请求 30 秒超时，网页报「暂时无法验证会话」。
    处理：设 `ICON_SERVICE_URL` 让客户端直连官方 + 抬 `mem_limit` + 配 swap（见 DEPLOY.md）。
12. **`vm.swappiness=0` 时 swap 是摆设**
    `free -m` 显示 swap 有 1G、used 恒为 0B 就是它。内核宁可 OOM 也不换页，必须先
    `sysctl -w vm.swappiness=60`。
13. **CDN 回源时 `X-Forwarded-Host` 不能用 `$host`**
    回源 Host 若填的是回源域名，`$host` 就是它，应用会把错误地址写进 config 返回给客户端，
    导致客户端绕过 CDN、Passkey RP ID 对不上。必须固定成对外域名，详见 DEPLOY.md。
14. **带下划线的自定义回源头会被 nginx 丢弃**
    `$http_x_origin_token` 对应的是 `X-Origin-Token`（连字符）。如果 CDN 侧填成
    `X_Origin_Token`，nginx 默认 `underscores_in_headers off` 直接丢掉，表现为全站 403。
15. **国内 `docker build` 会卡在 `apt-get`**
    `deb.debian.org` 在部分国内机器上拉包无响应（日志停在 `Get Packages` 后数分钟）。
    用 `--build-arg APT_MIRROR=mirrors.cloud.tencent.com`，apt 那步从卡死变成 7 秒。
16. **`docker save` 出来的 tag 必须是 compose 里用的那个**
    打包时如果镜像是 `nodewarden:new`，用户 `docker load` 后得到 `nodewarden:new`，
    和 compose 的 `image: nodewarden:local` 对不上，容器起不来。打包前先 `docker tag`。

---

## 6. 故障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 容器 `Restarting`，日志 `JWT_SECRET 少于 32 字符` | `.env` 填了太短的值 | 留空，或换成 ≥32 字符随机串 |
| 页面 502 | 容器没起 / 端口没通 | `docker compose ps` → `docker logs nodewarden` → 查 `ss -ltnp \| grep 18787` |
| `Database initialization failed` | `data/` 属主不对 | `docker compose down && chown -R 1000:1000 data && docker compose up -d` |
| 登录后立刻掉线 | `data/jwt_secret` 被换/删 | 恢复备份，别重新生成 |
| 附件上传 413 | 反代上传上限 | 调大 `client_max_body_size` |
| 地址显示成 `127.0.0.1` | 反代没传 Host/X-Forwarded-* | 补头；确认补丁没被上游改动顶掉 |
| 同步不实时 | WebSocket 没升级 | 反代补 `Upgrade` / `Connection` |
| 定时备份没跑 | cron 循环或 `/__scheduled` 出错 | `docker logs \| grep scheduled`，确认容器内 curl 能到 127.0.0.1:8787 |
| 网页「暂时无法验证会话」+ 公网 30 秒超时 | 容器内存被打满（图标抓取） | 设 `ICON_SERVICE_URL` + 抬 `mem_limit` + 配 swap，见 DEPLOY.md |
| 全站 403，配置看着没错 | 自定义回源头名不匹配（多半写成了下划线） | 头名改连字符，CDN 重新发布 |
| 客户端地址指向回源域名 | `X-Forwarded-Host` 用了 `$host` | 固定成对外域名 |
| `docker load` 后容器起不来（image not found） | 包内 tag 与 compose 不一致 | `docker tag <实际tag> nodewarden:local` |
| `docker build` 卡在 `apt-get` 十几分钟 | `deb.debian.org` 国内断流 | `--build-arg APT_MIRROR=mirrors.cloud.tencent.com` |

---

## 7. 安全基线（别拆）

- 端口只绑 `127.0.0.1`
- 容器降权到 uid 1000 运行；`cap_drop: ALL`
- `no-new-privileges`、`tmpfs /tmp`、`memory/pids` 上限、日志轮转
- 首用户自动 admin，之后必须邀请码
- Passkey RP ID 绑定实际域名
- `/__scheduled` 在反代层封死
- `.env`、`data/`、`jwt_secret` 不进任何仓库、不上传网盘

需要用户自己守的：主密码强度（零知识，忘了只能清库）、两步验证、定期备份。

---

## 8. 这套方案的边界

- **不是官方支持的部署方式**。上游没有 Node 运行时，这是"能跑起来"的最短路径，不是上游目标场景。
- **跟着上游漂移**。三个耦合点是成本，见 §4.4。
- **单实例**。要跑多个用 `NW_PROJECT` / `NW_CONTAINER_NAME` / `NW_HOST_PORT` 区分。
- **amd64 预构建**。ARM 自建（`docker build --platform linux/amd64`）。
- **无组织/合集/SSO**，上游本身没实现。

---

*文档随代码走：改了 Dockerfile / entrypoint / 补丁，回来更新 §2、§4.4、§5。*
