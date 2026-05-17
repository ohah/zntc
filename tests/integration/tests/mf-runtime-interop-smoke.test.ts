import { describe, test, expect, afterEach } from 'bun:test';
import { createServer, type Server } from 'node:http';
import { readFile, readdir } from 'node:fs/promises';
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

  // P1-5 (#3387): mf-manifest.json 에미터. webpack/rspack MF 호환 스키마
  // (@module-federation/sdk@2.4.0 Manifest 타입 + runtime-core
  // SnapshotHandler:161 필수키 metaData/exposes/shared). content-hash
  // 청크 배선(S5 재사용). manifest-driven 실브라우저 loadRemote 전체 실행
  // 은 P1-7(Playwright — Node 는 http chunk import 미지원). 여기선
  // 결정적 스키마 + 실제 산출 파일명 배선 검증.
  test('mf-manifest.json: S4 스키마 + content-hash 청크 배선', async () => {
    const fx = await createFixture({
      'Widget.ts': `export default function Widget() { return "M-OK"; }`,
      'index.ts': `export const sentinel = "remote-entry";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts', './a/B': './Widget.ts' } },
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
    ]);
    expect(b.exitCode).toBe(0);

    const files = await readdir(dist);
    expect(files).toContain('mf-manifest.json');
    const mani = JSON.parse(await readFile(join(dist, 'mf-manifest.json'), 'utf8'));

    // runtime-core SnapshotHandler:161 필수키(없으면 assert throw)
    expect(mani.metaData).toBeDefined();
    expect(Array.isArray(mani.exposes)).toBe(true);
    expect(Array.isArray(mani.shared)).toBe(true);
    expect(Array.isArray(mani.remotes)).toBe(true);
    // top-level + metaData (S4 박제)
    expect(mani.id).toBe('app');
    expect(mani.name).toBe('app');
    expect(mani.metaData.globalName).toBe('app');
    expect(mani.metaData.type).toBe('app');
    expect(mani.metaData.remoteEntry.type).toBe('global');
    expect(mani.metaData.publicPath).toBe('auto'); // --public-path 미지정 → runtime 추론
    expect(mani.metaData.buildInfo.buildVersion).toBeTruthy();
    // remoteEntry.name == 실제 산출된 entry 청크 파일명
    const entryFile = files.find(
      (f) =>
        f.endsWith('.js') &&
        f !== 'mf-manifest.json' &&
        readFileSyncSafe(join(dist, f)).includes('__zntc_mf_container'),
    );
    expect(mani.metaData.remoteEntry.name).toBe(entryFile);
    // exposes: id="app:<short>", name=키, assets.js.async=실제 lazy 청크
    expect(mani.exposes.length).toBe(2);
    const w = mani.exposes.find((e: { name: string }) => e.name === './Widget');
    expect(w.id).toBe('app:Widget');
    expect(w.path).toBe('./Widget');
    expect(w.assets.js.sync).toEqual([]);
    expect(w.assets.js.async.length).toBe(1);
    expect(files).toContain(w.assets.js.async[0]); // 매니페스트가 가리키는 청크 실재
    expect(w.assets.css).toEqual({ sync: [], async: [] });
    const ab = mani.exposes.find((e: { name: string }) => e.name === './a/B');
    expect(ab.id).toBe('app:a/B'); // './' 만 제거(중첩 경로 보존)
  });

  // P1-6 (#3388): zntc-빌드 host 가 실 @module-federation/runtime 로 remote
  // 소비. zntc 가 emit 한 init prelude + `import("remote/x")`→loadRemote
  // 재작성 코드가 **실 스펙 런타임**으로 동작(host-emit 검증, D1 — 자체
  // 재구현 안 함). remote=zntc(P1-3/5 container+mf-manifest). 정적 import
  // async 강등·split-host·실브라우저 = P1-7/후속.
  test('host-emit: zntc host 가 실 runtime 으로 zntc remote 소비', async () => {
    // 1) zntc remote 빌드(container+mf-manifest, chunk publicPath=file://)
    const remoteFx = await createFixture({
      'Widget.ts': `export default function Widget() { return "HOST-CONSUMED-OK"; }`,
      'index.ts': `export const sentinel = "remote-entry";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    const rdist = join(remoteFx.dir, 'dist');
    const rb = await runZntcInDir(remoteFx.dir, [
      '--bundle',
      join(remoteFx.dir, 'index.ts'),
      '--outdir',
      rdist,
      '--format=iife',
      `--public-path=file://${rdist}/`,
    ]);
    expect(rb.exitCode).toBe(0);

    // remote dist http 서빙(.json→application/json — runtime manifest 감지)
    server = createServer(async (req, res) => {
      try {
        const u = req.url === '/' ? '/index.js' : req.url!;
        const ct = u.endsWith('.json') ? 'application/json' : 'application/javascript';
        res.writeHead(200, { 'content-type': ct });
        res.end(await readFile(join(rdist, u)));
      } catch {
        res.writeHead(404).end();
      }
    });
    await new Promise<void>((r) => server!.listen(0, r));
    const port = (server.address() as { port: number }).port;

    // 2) zntc host 빌드(단일파일 iife). mf.remotes → init prelude +
    //    import("remoteA/Widget")→globalThis.__mf_runtime.loadRemote 재작성.
    const hostFx = await createFixture({
      'index.ts':
        `async function main(){ const m = await import("remoteA/Widget");` +
        ` console.log("HOST=" + (m.default ?? m)()); }\nmain();`,
      // 직접 remoteEntry(.js) — runtime 이 http fetch(S3 검증 형태). manifest
      // (.json) entry 는 publicPath-derived chunk 가 Node http import 불가
      // (P1-5 분석) → P1-7 Playwright. remote 는 chunk publicPath=file://.
      'zntc.config.json': JSON.stringify({
        mf: { name: 'host', remotes: { remoteA: `remoteA@http://localhost:${port}/index.js` } },
      }),
    });
    cleanup = async () => {
      await hostFx.cleanup();
      await remoteFx.cleanup();
    };
    const hostOut = join(hostFx.dir, 'host.js');
    const hb = await runZntcInDir(hostFx.dir, [
      '--bundle',
      join(hostFx.dir, 'index.ts'),
      '-o',
      hostOut,
      '--format=iife',
    ]);
    expect(hb.exitCode).toBe(0);
    const hostSrc = readFileSyncSafe(hostOut);
    // init prelude: var R=globalThis.__mf_runtime;if(R&&R.init)R.init({...})
    expect(hostSrc).toContain('var R=globalThis.__mf_runtime');
    expect(hostSrc).toContain(
      'R.init({"name":"host","remotes":[{"name":"remoteA","entry":"http://localhost:',
    );
    // 원격 동적 import 재작성
    expect(hostSrc).toContain('globalThis.__mf_runtime.loadRemote("remoteA/Widget")');

    // 3) 실 @module-federation/runtime 을 글로벌로 제공 후 host 번들 실행
    const mfRuntime = createRequire(import.meta.url).resolve('@module-federation/runtime');
    driverPath = join(hostFx.dir, 'host-driver.mjs');
    writeFileSync(
      driverPath,
      `import mf from ${JSON.stringify('file://' + mfRuntime)};\n` +
        `globalThis.__mf_runtime = mf;\n` +
        `await import(${JSON.stringify('file://' + hostOut)});\n` +
        `await new Promise(r => setTimeout(r, 500));\n`,
    );
    const { stdout, stderr } = await runNode(driverPath);
    expect(stdout).toContain('HOST=HOST-CONSUMED-OK'); // zntc host→실 runtime→zntc remote
    expect(stderr).not.toMatch(/RUNTIME-00\d|does not contain "init"/);
  }, 30000);
});

function readFileSyncSafe(p: string): string {
  try {
    return require('node:fs').readFileSync(p, 'utf8');
  } catch {
    return '';
  }
}
