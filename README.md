# NodeWarden Docker

把 [NodeWarden](https://github.com/shuaiplus/nodewarden)（Bitwarden 兼容的密码库服务端）
打包成可自托管的 Docker 镜像 —— **不需要 Cloudflare 账号，不需要任何云资源**。

```
Cloudflare Tunnel / Nginx / Caddy  →  127.0.0.1:18787 (容器)  →  workerd
```

## 为什么需要这个仓库

上游只能在 Cloudflare Workers 上跑，依赖 D1、R2、KV、Durable Objects 四个云服务，
想搬到自己服务器上无处落脚（没有官方 Node 运行时）。

这个仓库用 Cloudflare 官方的本地运行时（workerd，经 `wrangler dev` 启动）承载同一个 Worker，
把四个云依赖逐个换成容器内的本地实现：

| 上游依赖 | 本仓库替代 |
|---|---|
| D1（SQLite 数据库） | 本地 SQLite 文件 |
| R2（附件 / Send 文件） | 本地对象目录 |
| KV | 本地命名空间 |
| Durable Objects | 本地 SQLite 存储 |
| Cron Trigger `*/5 * * * *` | 容器内每 5 分钟调一次 `/__scheduled`（仅容器内可达） |

所有状态落在容器 `/data`，**迁移时只拷这一个目录**。

## 快速开始

### 方式一：用预构建镜像（推荐，免构建免联网）

从 [Releases](../../releases/latest) 下载 `nodewarden-kit-*.tar.gz`，解压后：

```bash
tar xzf nodewarden-kit-*.tar.gz && cd nodewarden-kit
chmod +x install.sh
./install.sh vault.example.com      # 换成你的域名；不填则只能内网 IP 访问
```

脚本会导入镜像、按域名写好 Passkey 配置、起容器并等到健康。

> 预构建镜像是 **x86_64（amd64）**。ARM 机器请用方式二自行构建。

### 方式二：从源码构建

```bash
git clone git@github.com:Uxnar-ai/nodewarden-docker.git && cd nodewarden-docker
docker build -t nodewarden:local .
./install.sh vault.example.com
```

构建需要访问 `registry.npmjs.org`（约 1.1k 个依赖），首次 3~8 分钟。

### 装完之后

1. 浏览器打开 `http://127.0.0.1:18787` 确认活着
2. 配反向代理对外（**必须照 [DEPLOY.md](DEPLOY.md) 的要求传 4 个头**，否则限流/同步/地址生成都会出问题）
3. **第一个注册的账号自动成为管理员**，之后所有注册都必须填邀请码（管理员在「用户管理」生成）
4. 登录后开两步验证，恢复码离线存好

客户端（浏览器扩展 / 手机 / 桌面）在登录界面选「自托管」，服务器地址填 `https://你的域名`。

## 反向代理三个必做项

1. 传 `Host`、`X-Forwarded-Proto`、`X-Real-IP`（或 `CF-Connecting-IP`）、`Upgrade`/`Connection`
2. 封掉 `/__scheduled` —— 那是内部定时任务端点，暴露出去任何人都能反复触发你的备份
3. 上传上限调到 100m 量级（附件 / Send 文件）

Nginx、Caddy、Cloudflare Tunnel 三种现成配置见 [DEPLOY.md](DEPLOY.md)。

## 安全设计

- 端口只绑 `127.0.0.1`，公网必须经反向代理
- 容器降权到 `node` 用户运行（entrypoint 先修挂载目录属主，再 `setpriv` 降权）
- `cap_drop: ALL`，只加回 `CHOWN / DAC_OVERRIDE / FOWNER / SETUID / SETGID`
- `no-new-privileges`、`tmpfs /tmp`、内存与 PID 上限、日志轮转
- 注册默认封闭：首个用户即管理员，之后必须邀请码
- Passkey 的 RP ID 绑定访问域名

需要你自己守的：**主密码要强**（零知识加密，服务端只有密文，忘了谁也救不回来）、**开两步验证**、
**定期备份 `data/`**、`.env` 与 `data/` 不进任何仓库。

## 备份与迁移

```bash
tar czf nw-backup-$(date +%F).tgz data
```

`data/` 里有 `jwt_secret`（会话签名 + 备份凭据加密，丢了全员掉线）和 `persist/v3/`
（数据库、Durable Objects、附件）。换机器：项目目录 + `data/` 拷过去，`docker compose up -d`。

## 更新

```bash
tar czf nw-backup-$(date +%F).tgz data
curl -sL https://ghfast.top/https://github.com/shuaiplus/nodewarden/archive/refs/heads/main.tar.gz -o /tmp/nw.tgz
tar xzf /tmp/nw.tgz --strip-components=1
docker build -t nodewarden:local .
docker compose up -d --force-recreate
```

构建时会跑 `patches/forwarded-origin.mjs`：上游用 `new URL(request.url).origin` 生成
config 里的服务器地址，容器里那永远是 `http://127.0.0.1:8787`，补丁改成采信
`X-Forwarded-Proto` / `X-Forwarded-Host`。上游若改了那行锚点，补丁会报 `anchor not found`
并让构建失败 —— 这是有意的，而不是默默生成一堆错误地址。

## 已知限制

- 用 `wrangler dev`（开发服务器）承载生产流量。功能完整、个人/小团队够用，
  但 Cloudflare 没有给这个用法背书；升级 wrangler 需要回归测试。
- 无组织 / 合集 / SSO（上游本身未实现）。
- 单文件附件受反向代理上传上限约束。

## 授权

[LGPL-3.0](LICENSE)，与上游一致。

本项目是 [shuaiplus/nodewarden](https://github.com/shuaiplus/nodewarden) 的部署封装，
所有协议实现、前端、加密逻辑均为上游成果；本仓库只增加容器化、配置与运维文档。
上游文档见 [docs/upstream-README.md](docs/upstream-README.md)，问题不要报给上游。
