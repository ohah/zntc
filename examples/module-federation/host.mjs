// host 앱 — zntc 로 빌드한 remote 의 컴포넌트를 표준
// @module-federation/runtime 으로 소비한다. zntc 는 remote/host 양쪽
// 모두 표준 런타임 계약을 타깃하므로 별도 zntc 런타임 없이 그대로
// interop 된다(이 파일에 zntc 의존성이 전혀 없다는 점에 주목).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as hostReact from 'react';
// @module-federation/runtime 은 CJS — namespace import 후 default 추출
// (Node 의 CJS↔ESM interop. 독립 프로젝트도 동일).
import * as mfNs from '@module-federation/runtime';

const mf = mfNs.default ?? mfNs;
const { createElement } = hostReact;
const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, 'remote', 'dist');

// 1) remote **entry** 만 http 로 서빙(실제 배포에선 CDN/별도 호스트).
//    청크는 entry 의 publicPath(빌드 시 file://dist/) 로 로드된다 — Node
//    는 http import 를 지원 안 해 "entry=http / chunk=file://" 하이브
//    리드가 표준 Node interop 패턴(브라우저면 양쪽 다 http).
const server = createServer(async (request, res) => {
  try {
    const f = join(dist, request.url === '/' ? '/index.js' : request.url);
    res.writeHead(200, { 'content-type': 'application/javascript' });
    res.end(await readFile(f));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, r));
const port = server.address().port;

// 2) 표준 host. host 가 자기 react 를 shared 로 등록 → remote 의
//    `shared: { react }` 가 이 단일 인스턴스를 공유(hooks 동작 조건).
const { init, loadRemote } = mf;
init({
  name: 'host_app',
  remotes: [{ name: 'remote_app', entry: `http://localhost:${port}/index.js` }],
  shared: {
    react: {
      version: '19.0.0',
      lib: () => hostReact,
      shareConfig: { singleton: true, requiredVersion: '^19' },
    },
  },
});

// 3) remote 컴포넌트를 동적으로 가져온다(표준 loadRemote — zntc remote).
const mod = await loadRemote('remote_app/Button');
const Button = mod.default ?? mod;

// 4) 검증: (a) 컴포넌트가 함수로 도달했고 (b) remote 의 react 가 host 의
//    react 와 **동일 인스턴스**다(= shared singleton 성립, hooks 안전).
//    실제 앱이라면 여기서 react-dom 으로 <Button/> 을 렌더하면 된다.
const isComponent = typeof Button === 'function';
const sharedSingleton = mod.usedHook === hostReact.useState;
const el = isComponent ? createElement(Button) : null;

console.log('component:', isComponent, '/ shared React singleton:', sharedSingleton);
console.log('element type === Button:', el?.type === Button);
const ok = isComponent && sharedSingleton && el?.type === Button;
console.log(
  ok ? 'OK — zntc remote 컴포넌트를 표준 host 가 소비, react 단일 인스턴스 공유' : 'FAIL',
);
await new Promise((r) => server.close(r));
process.exit(ok ? 0 : 1);
