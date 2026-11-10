// 自托管补丁：让 config 响应里的服务器地址使用反向代理传来的协议/域名。
//
// 原因：Worker 跑在容器里，request.url 永远是 http://127.0.0.1:8787，
// 上游代码用 new URL(request.url).origin 生成 vault / api / identity 等地址，
// 客户端拿到 http:// 的地址后可能在 https 页面里被当混合内容拦掉。
//
// 幂等：已经打过补丁直接退出。
import fs from 'node:fs';

const file = 'src/router-public.ts';
let src = fs.readFileSync(file, 'utf8');

if (src.includes('resolvePublicOrigin')) {
  console.log('[patch] already applied');
  process.exit(0);
}

const anchor = 'const origin = new URL(request.url).origin;';
if (!src.includes(anchor)) {
  console.error('[patch] anchor not found in ' + file + ', upstream changed?');
  process.exit(1);
}
src = src.replace(anchor, 'const origin = resolvePublicOrigin(request);');

const helper = `
// [self-host patch] 反代后面 request.url 的 scheme/host 都是容器的，
// 优先采信 X-Forwarded-Proto / X-Forwarded-Host / Host。
function resolvePublicOrigin(request: Request): string {
  const url = new URL(request.url);
  const rawProto = (request.headers.get('X-Forwarded-Proto') || '').split(',')[0].trim().toLowerCase();
  const proto = rawProto === 'https' || rawProto === 'http' ? rawProto : url.protocol.replace(':', '');
  const forwardedHost = (request.headers.get('X-Forwarded-Host') || '').split(',')[0].trim();
  const host = forwardedHost || request.headers.get('Host') || url.host;
  return proto + '://' + host;
}
`;

const importAnchor = "import { buildConfigResponse } from './config-response';";
if (!src.includes(importAnchor)) {
  console.error('[patch] import anchor not found');
  process.exit(1);
}
src = src.replace(importAnchor, importAnchor + '\n' + helper);

fs.writeFileSync(file, src);
console.log('[patch] applied to ' + file);
