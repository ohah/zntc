import { describe, test, expect, afterEach } from 'bun:test';
import { createServer, type Server } from 'node:http';
import { readFile } from 'node:fs/promises';
import { writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { createFixture, runZntcInDir, runNode } from './helpers';

// P1-3 (#3385) 실-런타임 interop 스모크 (S3 정방향):
// **실제 @module-federation/[email protected]**(rspack/webpack MF 가 쓰는
// 바로 그 interop 계약 패키지)이 zntc-emit container 를 자기 init/loadRemote
// 파이프라인으로 구동·실행하는지 검증. RFC §8.1 S3 를 영구 박제.
//   - 계약 키: runtime 의 loadScriptNode 가 entry 를 (exports,module,...)
//     래퍼로 vm 실행 후 module.exports 를 container 로 읽음 + 기본 글로벌
//     `__FEDERATION_<name>:custom__`.
//   - entry 는 http(runtime fetch), chunk publicPath 는 file://(Node import).
// 전체 브라우저 Playwright interop CI(S4 역방향 포함)는 P1-7.
describe('MF P1-3: 실 @module-federation/runtime interop (S3)', () => {
  let server: Server | undefined;
  let cleanup: (() => Promise<void>) | undefined;
  let driverPath: string | undefined;
  afterEach(async () => {
    await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
    server = undefined;
    if (driverPath) {
      rmSync(driverPath, { force: true });
      driverPath = undefined;
    }
    await cleanup?.();
    cleanup = undefined;
  });

  test('runtime init→loadRemote 로 zntc remote 의 expose 렌더 + lazy', async () => {
    const fx = await createFixture({
      'Widget.ts': `globalThis.__w_eval = true;\nexport default function Widget() { return "ZNTC-RT-OK"; }\nexport const meta = { from: "zntc" };`,
      'index.ts': `export const sentinel = "remote-entry";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    cleanup = fx.cleanup;
    const dist = join(fx.dir, 'dist');

    const b = await runZntcInDir(fx.dir, [
      '--bundle',
      join(fx.dir, 'index.ts'),
      '--outdir',
      dist,
      '--format=iife',
      // entry 는 http 로 서빙되지만 chunk publicPath 는 file:// (Node import).
      `--public-path=file://${dist}/`,
    ]);
    expect(b.exitCode).toBe(0);

    // dist 정적 서버 (runtime 의 Node entry 로더는 http fetch 필요).
    server = createServer(async (req, res) => {
      try {
        const f = join(dist, req.url === '/' ? '/index.js' : req.url!);
        res.writeHead(200, { 'content-type': 'application/javascript' });
        res.end(await readFile(f));
      } catch {
        res.writeHead(404).end();
      }
    });
    await new Promise<void>((r) => server!.listen(0, r));
    const port = (server.address() as { port: number }).port;

    // @module-federation/runtime 절대경로(워크스페이스 .bun 레이아웃 →
    // os-tmpdir fixture 에서 bare 해소 불가, resolve 경로 주입).
    const mfRuntime = createRequire(import.meta.url).resolve('@module-federation/runtime');
    driverPath = join(fx.dir, 'rt-driver.mjs');
    writeFileSync(
      driverPath,
      `import mf from ${JSON.stringify('file://' + mfRuntime)};
const { init, loadRemote } = mf;
init({ name: 'host-mf2', remotes: [{ name: 'app', entry: 'http://localhost:${port}/index.js' }] });
console.log('BEFORE=' + !!globalThis.__w_eval);
const m = await loadRemote('app/Widget');
const W = m && (m.default ?? m);
console.log('TYPEOF=' + typeof W);
console.log('RESULT=' + (typeof W === 'function' ? W() : ''));
console.log('META=' + JSON.stringify(m && m.meta));
console.log('AFTER=' + !!globalThis.__w_eval);
`,
    );
    const { stdout, stderr } = await runNode(driverPath);

    // 실 MF2 runtime 이 container.init→get→factory 구동, expose 실행
    expect(stdout).toContain('TYPEOF=function');
    expect(stdout).toContain('RESULT=ZNTC-RT-OK');
    expect(stdout).toContain('META={"from":"zntc"}');
    // get 전 미평가 → factory 후 평가 (lazy)
    expect(stdout).toContain('BEFORE=false');
    expect(stdout).toContain('AFTER=true');
    expect(stderr).not.toMatch(/RUNTIME-00\d|does not contain "init"/);
  }, 30000);

  // P1-4 (#3386) S2: host 가 자기 react 를 shareScope 에 등록 → zntc remote
  // (shared:{react}) 가 container.init 의 글로벌 seam 해석으로 **host 와 동일
  // react 인스턴스** 사용(singleton, useState identity). RFC §8.1 S2.
  test('S2: shared react 단일 인스턴스 — host↔zntc remote identity', async () => {
    const fx = await createFixture({
      // react external(P1-2 seam) → __mf_shared_react. usedHook 으로 host 의
      // useState 와 identity 비교.
      'Widget.ts':
        `import { useState } from "react";\n` +
        `export const usedHook = useState;\n` +
        `export default function Widget() { return typeof useState === "function" ? "S2-OK" : "S2-NO"; }`,
      'index.ts': `export const sentinel = "remote-entry";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          shared: { react: { singleton: true, requiredVersion: '^19' } },
        },
      }),
    });
    cleanup = fx.cleanup;
    const dist = join(fx.dir, 'dist');

    const b = await runZntcInDir(fx.dir, [
      '--bundle',
      join(fx.dir, 'index.ts'),
      '--outdir',
      dist,
      '--format=iife',
      `--public-path=file://${dist}/`,
    ]);
    expect(b.exitCode).toBe(0);

    server = createServer(async (req, res) => {
      try {
        const f = join(dist, req.url === '/' ? '/index.js' : req.url!);
        res.writeHead(200, { 'content-type': 'application/javascript' });
        res.end(await readFile(f));
      } catch {
        res.writeHead(404).end();
      }
    });
    await new Promise<void>((r) => server!.listen(0, r));
    const port = (server.address() as { port: number }).port;

    const mfRuntime = createRequire(import.meta.url).resolve('@module-federation/runtime');
    const reactPath = createRequire(import.meta.url).resolve('react');
    driverPath = join(fx.dir, 'rt-driver.mjs');
    writeFileSync(
      driverPath,
      `import mf from ${JSON.stringify('file://' + mfRuntime)};
import * as hostReact from ${JSON.stringify('file://' + reactPath)};
const { init, loadRemote } = mf;
// host 가 자기 react 를 shareScope 에 등록(MF2 표준 init({shared})).
init({
  name: 'host-mf2',
  remotes: [{ name: 'app', entry: 'http://localhost:${port}/index.js' }],
  shared: { react: { version: '19.2.4', lib: () => hostReact, shareConfig: { singleton: true, requiredVersion: '^19' } } },
});
const m = await loadRemote('app/Widget');
const W = m && (m.default ?? m);
console.log('RENDER=' + (typeof W === 'function' ? W() : 'no'));
// zntc remote 의 useState ≡ host 의 useState (단일 인스턴스)
console.log('SAME=' + (m && m.usedHook === hostReact.useState));
`,
    );
    const { stdout, stderr } = await runNode(driverPath);

    expect(stdout).toContain('RENDER=S2-OK'); // seam 글로벌 채워짐(init→eval 순서)
    expect(stdout).toContain('SAME=true'); // host↔remote 동일 react 인스턴스
    expect(stderr).not.toMatch(/RUNTIME-00\d|does not contain "init"|eager consumption/);
  }, 30000);
});
