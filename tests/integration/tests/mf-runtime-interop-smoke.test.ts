import { describe, test, expect, afterEach } from 'bun:test';
import { createServer, type Server } from 'node:http';
import { readFile, readdir } from 'node:fs/promises';
import { writeFileSync, rmSync, readFileSync } from 'node:fs';
import { createHash, randomBytes, createPublicKey, verify as cryptoVerify } from 'node:crypto';
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
  let server2: Server | undefined; // 다중-remote(P0) — 두 번째 origin
  let cleanup: (() => Promise<void>) | undefined;
  let driverPath: string | undefined;
  afterEach(async () => {
    await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
    await new Promise<void>((r) => (server2 ? server2.close(() => r()) : r()));
    server = undefined;
    server2 = undefined;
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

  // #4-2 (#3318): named share scope 다중 완결 박제. S2 와 동일하나 react
  // 를 **non-default named scope "ui"** 로. zntc remote: shared.react.
  // shareScope='ui'(#4-0 표면). 컨테이너 init: SC=(o&&o.shareScopeMap)?
  // o.shareScopeMap["ui"]:s(#4-1 emit). 표준 @module-federation/runtime
  // host 는 remote 를 shareScope:'ui' 로 등록(runtime-core shareScopeKeys
  // =['ui'] → localShareScopeMap['ui'] 생성·remoteEntryInitOptions.
  // shareScopeMap 으로 전달) + react 를 scope:'ui' 로 등록(registerShared
  // → shareScopeMap['ui']['react']). 실 [email protected] 으로 named
  // scope 경유 singleton identity 검증 = #4-0+#4-1 end-to-end 완결.
  test('#4-2 named scope "ui": zntc remote shared 가 host named scope 에서 해석 (singleton)', async () => {
    const fx = await createFixture({
      'Widget.ts':
        `import { useState } from "react";\n` +
        `export const usedHook = useState;\n` +
        `export default function Widget() { return typeof useState === "function" ? "UI-OK" : "UI-NO"; }`,
      'index.ts': `export const sentinel = "remote-entry";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          // #4-0: per-shared shareScope = non-default "ui"
          shared: { react: { singleton: true, requiredVersion: '^19', shareScope: 'ui' } },
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

    // #4-1 emit 형태 직접 확인: "ui" scope ternary (||s 오결합 아님)
    const entrySrc = readFileSync(join(dist, 'index.js'), 'utf8');
    expect(entrySrc).toContain('init:function(s,i,o){');
    expect(entrySrc).toMatch(/var SC=\(o&&o\.shareScopeMap\)\?o\.shareScopeMap\["ui"\]:s;/);

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
// remote 를 named scope 'ui' 로 등록(runtime-core remoteInfo.shareScope
// → shareScopeKeys=['ui'] → o.shareScopeMap['ui'] 생성·전달).
// react 를 scope:'ui' 로 등록(registerShared → shareScopeMap['ui'].react).
init({
  name: 'host-mf2',
  remotes: [{ name: 'app', entry: 'http://localhost:${port}/index.js', shareScope: 'ui' }],
  shared: { react: { version: '19.2.4', scope: 'ui', lib: () => hostReact, shareConfig: { singleton: true, requiredVersion: '^19' } } },
});
const m = await loadRemote('app/Widget');
const W = m && (m.default ?? m);
console.log('RENDER=' + (typeof W === 'function' ? W() : 'no'));
console.log('SAME=' + (m && m.usedHook === hostReact.useState));
`,
    );
    const { stdout, stderr } = await runNode(driverPath);

    expect(stdout).toContain('RENDER=UI-OK'); // 'ui' scope seam 해석 성공
    expect(stdout).toContain('SAME=true'); // named scope 경유 동일 react 인스턴스
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

  // #3468: expose 가 CSS import 시 그 CSS 청크 산출을 manifest
  // exposes[].assets.css.async 에 게시 → 표준 preloadRemote 가
  // stylesheet 도 prefetch(JS 와 동일 lazy). CSS 없는 expose 는 빈
  // [] 유지(무회귀). css_emit.planChunkHrefs(chunk→CSS basename) ↔
  // chunk_graph.getModuleChunk(expose 모듈) 연결(단일 소스).
  test('#3468 CSS assets: expose CSS import → manifest css.async 게시', async () => {
    const fx = await createFixture({
      'w.css': `.w{color:red}`,
      'Widget.ts': `import "./w.css";\nexport default function W(){ return "CSS-OK"; }`,
      // CSS 미import expose — css.async 빈 [] 유지(무회귀 박제)
      'Plain.ts': `export default function P(){ return "PLAIN"; }`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts', './Plain': './Plain.ts' } },
      }),
    });
    cleanup = fx.cleanup;
    const dist = join(fx.dir, 'dist');
    expect(
      (
        await runZntcInDir(fx.dir, [
          '--bundle',
          join(fx.dir, 'index.ts'),
          '--outdir',
          dist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const files = await readdir(dist);
    const mani = JSON.parse(await readFile(join(dist, 'mf-manifest.json'), 'utf8'));
    const w = mani.exposes.find((e: { name: string }) => e.name === './Widget');
    // CSS import expose → css.async = [실제 산출 CSS 파일](preloadRemote 가
    // 이걸 prefetch). 매니페스트가 가리키는 파일이 실재해야 함.
    expect(w.assets.css.async.length).toBe(1);
    expect(files).toContain(w.assets.css.async[0]);
    expect(w.assets.css.async[0]).toMatch(/\.css$/);
    expect(w.assets.css.sync).toEqual([]); // sync 는 js 와 동일 사유 []
    expect(w.assets.js.async.length).toBe(1); // js 경로 무회귀
    const p = mani.exposes.find((e: { name: string }) => e.name === './Plain');
    // CSS 미import expose → 빈 [] 유지(무회귀: 기존 동작 불변)
    expect(p.assets.css.async).toEqual([]);
    expect(p.assets.css.sync).toEqual([]);
  });

  // P2-0 (#3420): manifest.shared 정밀. mf.shared → ManifestShared
  // (@module-federation/sdk: id/name/version/singleton/requiredVersion/
  // hash/assets). 표준 generateSnapshotFromManifest 가 name/version 으로
  // 버전협상 — P1 한계(#3419 가드 shared==[]) 해소. remotes 는 P2-1 까지
  // [] 유지(host 경로, scope 분리). version 은 requiredVersion 대용
  // (SharedEntry 에 설치버전 없음 — 정밀해석 P2 비-목표).
  test('P2-0 manifest.shared 정밀: SharedEntry → ManifestShared', async () => {
    const fx = await createFixture({
      'Widget.ts': `import { useState } from "react";\nexport default () => typeof useState;`,
      'index.ts': `export const sentinel = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          shared: {
            react: { singleton: true, requiredVersion: '^19' },
            'react-dom': {},
          },
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
    ]);
    expect(b.exitCode).toBe(0);
    const mani = JSON.parse(await readFile(join(dist, 'mf-manifest.json'), 'utf8'));
    expect(Array.isArray(mani.shared)).toBe(true);
    expect(mani.shared.length).toBe(2);
    const r = mani.shared.find((s: { name: string }) => s.name === 'react');
    expect(r.id).toBe('app:react');
    expect(r.singleton).toBe(true);
    expect(r.requiredVersion).toBe('^19');
    expect(r.version).toBe('^19'); // requiredVersion 대용(P2 경계)
    // ManifestShared.hash 는 runtime 미소비(generateSnapshotFromManifest
    // 가 안 읽음) → 의도적 빈값 유지. 무결성은 별도 sidecar(P2-2,
    // mf-manifest.json.integrity.json) — 표준 schema 불침습.
    expect(r.hash).toBe('');
    // ManifestShared 필수 7필드 전부 + StatsAssets 형태(seam 처리 → 빈)
    expect(r.assets).toEqual({
      js: { sync: [], async: [] },
      css: { sync: [], async: [] },
    });
    const rd = mani.shared.find((s: { name: string }) => s.name === 'react-dom');
    expect(rd.id).toBe('app:react-dom');
    expect(rd.singleton).toBe(false); // 미지정 → false
    expect(rd.requiredVersion).toBe(''); // 미지정 → 빈
    expect(rd.version).toBe(''); // version=requiredVersion 경계(값 없음 쪽도 박제)
    // remotes 미선언 → [] (P2-1 은 remotes 선언 시 채움 — 별 테스트)
    expect(mani.remotes).toEqual([]);
    expect(Array.isArray(mani.exposes) && mani.exposes.length).toBe(1);
  });

  // #2 감사: shareStrategy/strictVersion config 표면. strictVersion →
  // ManifestShared 게시(producer contract, sdk 호환). shareStrategy →
  // host R.init({…,shareStrategy}) 배선(표준 runtime Options.share
  // Strategy 가 협상순서 적용 — D1 위임). 런타임 강제·P3-2 fail-fast
  // 격상은 표준 runtime/별 PR. 여기선 config→manifest/init emit 박제.
  test('#2 shareStrategy/strictVersion: manifest 게시 + host init 배선', async () => {
    // remote: shared react strictVersion → manifest.shared[].strictVersion
    const rfx = await createFixture({
      'Widget.ts': `import { useState } from "react";\nexport default () => typeof useState;`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          shared: {
            react: { singleton: true, requiredVersion: '^19', strictVersion: true },
            'react-dom': { requiredVersion: '^19' }, // strictVersion 미지정 → false
          },
        },
      }),
    });
    cleanup = rfx.cleanup;
    const rdist = join(rfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(rfx.dir, [
          '--bundle',
          join(rfx.dir, 'index.ts'),
          '--outdir',
          rdist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const mani = JSON.parse(await readFile(join(rdist, 'mf-manifest.json'), 'utf8'));
    const r = mani.shared.find((s: { name: string }) => s.name === 'react');
    expect(r.strictVersion).toBe(true); // 명시 → true
    const rd = mani.shared.find((s: { name: string }) => s.name === 'react-dom');
    expect(rd.strictVersion).toBe(false); // 미지정 → false(P2-0 7필드 + strictVersion)
    await rfx.cleanup();
    cleanup = undefined;

    // host: shareStrategy → R.init({…,"shareStrategy":"loaded-first"})
    const hfx = await createFixture({
      'index.ts': `globalThis.__x = import("app/W");`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'host',
          remotes: { app: 'app@http://x/r.js' },
          shareStrategy: 'loaded-first',
        },
      }),
    });
    const hostOut = join(hfx.dir, 'host.js');
    expect(
      (
        await runZntcInDir(hfx.dir, [
          '--bundle',
          join(hfx.dir, 'index.ts'),
          '-o',
          hostOut,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const hsrc = readFileSyncSafe(hostOut);
    // 표준 @module-federation/runtime 이 읽는 Options.shareStrategy 위치
    expect(hsrc).toContain('"shareStrategy":"loaded-first"');
    expect(hsrc).toContain('R.init({"name":"host"'); // 기존 init 보존
    await hfx.cleanup();

    // 미지정 → runtime default 와 동일 "version-first" 명시 emit
    const hfx2 = await createFixture({
      'index.ts': `globalThis.__y = import("a/Z");`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'h2', remotes: { a: 'a@http://x/y' } },
      }),
    });
    cleanup = hfx2.cleanup;
    const o2 = join(hfx2.dir, 'h2.js');
    expect(
      (
        await runZntcInDir(hfx2.dir, [
          '--bundle',
          join(hfx2.dir, 'index.ts'),
          '-o',
          o2,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    expect(readFileSyncSafe(o2)).toContain('"shareStrategy":"version-first"');
  });

  // #2 PR#2: P3-2 strictVersion 빌드타임 fail-fast 격상. host
  // strictVersion 선언 + remote 게시 concrete version 이 host
  // requiredVersion 불만족 → version_warn(비차단) 대신 **빌드 차단**.
  // 정밀 fail-fast 불변: 판정 불가(remote.version 비-concrete=zntc
  // P2-0 range)는 strict 여도 ok(거짓 빌드중단 금지).
  test('#2 strictVersion fail-fast: concrete 비호환+strict→차단; non-strict/판정불가→통과', async () => {
    const rfx = await createFixture({
      'Widget.ts': `import { useState } from "react";\nexport default () => typeof useState;`,
      'index.ts': `export const s = "re";`,
      // remote singleton:true (host 와 일치 → singleton_conflict 가 version
      // 검사를 가리지 않게). requiredVersion ^19 → manifest version 대용.
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          shared: { react: { singleton: true, requiredVersion: '^19' } },
        },
      }),
    });
    cleanup = rfx.cleanup;
    const rdist = join(rfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(rfx.dir, [
          '--bundle',
          join(rfx.dir, 'index.ts'),
          '--outdir',
          rdist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const sidecarAbs = join(rdist, 'mf-manifest.json.integrity.json');
    // 외부 빌더 remote 모사: react shared version 을 concrete 로 재작성
    // (zntc P2-0 는 version=range 라 strict 판정불가 — concrete 필요).
    // sidecar 제거 → P3-3 무결성 검증 skip(아니면 변조로 먼저 fail).
    const m = JSON.parse(readFileSync(manifestAbs, 'utf8'));
    m.shared.find((s: { name: string }) => s.name === 'react').version = '19.2.4';
    writeFileSync(manifestAbs, JSON.stringify(m));
    rmSync(sidecarAbs, { force: true });

    const buildHost = async (requiredVersion: string, strictVersion: boolean) => {
      const hfx = await createFixture({
        'index.ts': `globalThis.__x = import("app/Widget");`,
        'zntc.config.json': JSON.stringify({
          mf: {
            name: 'host',
            remotes: { app: `app@${manifestAbs}` },
            shared: { react: { singleton: true, requiredVersion, strictVersion } },
          },
        }),
      });
      const r = await runZntcInDir(hfx.dir, [
        '--bundle',
        join(hfx.dir, 'index.ts'),
        '-o',
        join(hfx.dir, 'host.js'),
        '--format=iife',
      ]);
      await hfx.cleanup();
      return r;
    };

    // ① strict + concrete 비호환(^18 ⊅ 19.2.4) → 빌드 fail-fast
    const bad = await buildHost('^18', true);
    expect(bad.exitCode).not.toBe(0);
    expect(bad.stderr).toContain('MF shared strictVersion 위반');
    // ② non-strict + 동일 비호환 → version_warn(비차단, 빌드 성공)
    const warn = await buildHost('^18', false);
    expect(warn.exitCode).toBe(0);
    expect(warn.stderr).toContain('MF shared 버전 경고');
    // ③ strict + 호환(^19 ⊇ 19.2.4) → 격상 안 함(빌드 성공)
    expect((await buildHost('^19', true)).exitCode).toBe(0);

    // ④ 정밀 fail-fast: zntc remote(version=range "^19", sidecar 복원)
    //    → satisfies 판정불가 → strict 여도 ok(거짓 빌드중단 금지).
    await runZntcInDir(rfx.dir, [
      '--bundle',
      join(rfx.dir, 'index.ts'),
      '--outdir',
      rdist,
      '--format=iife',
    ]); // 원본 재빌드(version=range, sidecar 재생성)
    expect((await buildHost('^18', true)).exitCode).toBe(0);
  });

  // dedup(누적 후속): 같은 remote 를 여러 expose 로 import 해도 무결성·
  // shared 검증/경고는 remote 당 1회(seen_remotes). expose 검사(P3-1)
  // 만 per-spec. 같은 spec 다중/정적∩동적은 seen_specs 로 1회.
  test('dedup: 같은 remote 다중 import → shared 경고 1회 + expose per-spec 유지', async () => {
    const rfx = await createFixture({
      'Widget.ts': `import { useState } from "react";\nexport default () => typeof useState;`,
      'Btn.ts': `import { useState } from "react";\nexport default () => "B";`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts', './Btn': './Btn.ts' },
          shared: { react: { singleton: true, requiredVersion: '^19' } },
        },
      }),
    });
    cleanup = rfx.cleanup;
    const rdist = join(rfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(rfx.dir, [
          '--bundle',
          join(rfx.dir, 'index.ts'),
          '--outdir',
          rdist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    // react version concrete 비호환 유발 + sidecar 제거(P3-3 skip →
    // version_warn 경로 도달). host requiredVersion ^18 ⊅ 19.2.4.
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const m = JSON.parse(readFileSync(manifestAbs, 'utf8'));
    m.shared.find((s: { name: string }) => s.name === 'react').version = '19.2.4';
    writeFileSync(manifestAbs, JSON.stringify(m));
    rmSync(join(rdist, 'mf-manifest.json.integrity.json'), { force: true });

    const buildHost = async (indexSrc: string) => {
      const hfx = await createFixture({
        'index.ts': indexSrc,
        'zntc.config.json': JSON.stringify({
          mf: {
            name: 'host',
            remotes: { app: `app@${manifestAbs}` },
            shared: { react: { singleton: true, requiredVersion: '^18' } },
          },
        }),
      });
      const r = await runZntcInDir(hfx.dir, [
        '--bundle',
        join(hfx.dir, 'index.ts'),
        '-o',
        join(hfx.dir, 'host.js'),
        '--format=iife',
      ]);
      await hfx.cleanup();
      return r;
    };

    // 같은 remote app 을 정적 1 + 동적 2(총 3 spec, 2 distinct subpath)
    // import → version_warn 은 remote 당 1회만(dedup 전이면 다중).
    const multi = await buildHost(
      `import W from "app/Widget";\n` +
        `async function m(){ await import("app/Widget"); await import("app/Btn"); globalThis.__r = typeof W; }\nm();`,
    );
    expect(multi.exitCode).toBe(0); // version_warn=비차단
    const warnCount = (multi.stderr.match(/MF shared 버전 경고/g) ?? []).length;
    expect(warnCount).toBe(1); // dedup: remote 당 1회 (이전: spec 당 → 다중)

    // expose 는 per-spec 유지 — 부재 expose 는 dedup 무관하게 fail-fast.
    const bad = await buildHost(`import X from "app/Nope";\nawait import("app/Widget");`);
    expect(bad.exitCode).not.toBe(0);
    expect(bad.stderr).toContain('MF expose 계약 위반');
    expect(bad.stderr).toContain('"app/Nope"');
  });

  // P2-1 (#3421): exposes 있는 remote 가 remotes 도 선언 → manifest.remotes
  // = ManifestRemote[](Omit<RemoteWithEntry,'name'> & {federationContainer
  // Name,moduleName,alias}). 표준 generateSnapshotFromManifest 가
  // federationContainerName+entry 로 transitive remote 인지. host-only
  // (exposes 0)는 manifest 미산출(표준 일치 — manifest=remote-producer 산출).
  test('P2-1 manifest.remotes 정밀: mf.remotes → ManifestRemote', async () => {
    const fx = await createFixture({
      'W.ts': `export default () => "W";`,
      'index.ts': `export const sentinel = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'mid',
          exposes: { './W': './W.ts' },
          remotes: {
            up: 'up_ctr@http://localhost:9/mf-manifest.json',
            bare: 'http://localhost:8/remoteEntry.js', // @ 없음 → name=key
          },
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
    ]);
    expect(b.exitCode).toBe(0);
    const mani = JSON.parse(await readFile(join(dist, 'mf-manifest.json'), 'utf8'));
    expect(Array.isArray(mani.remotes)).toBe(true);
    expect(mani.remotes.length).toBe(2);
    const up = mani.remotes.find((r: { alias: string }) => r.alias === 'up');
    expect(up.entry).toBe('http://localhost:9/mf-manifest.json');
    expect(up.federationContainerName).toBe('up_ctr'); // <name>@<entry> 의 name
    expect(up.moduleName).toBe('up_ctr');
    // ManifestRemote 4필드 전부(name 은 Omit)
    expect(Object.keys(up).sort()).toEqual([
      'alias',
      'entry',
      'federationContainerName',
      'moduleName',
    ]);
    const bare = mani.remotes.find((r: { alias: string }) => r.alias === 'bare');
    expect(bare.entry).toBe('http://localhost:8/remoteEntry.js');
    expect(bare.federationContainerName).toBe('bare'); // @ 없음 → KV.key fallback
    // P2-0 무회귀: shared 도 정밀 유지
    expect(Array.isArray(mani.shared) && mani.shared.length).toBe(0);
    expect(mani.exposes.length).toBe(1);
  });

  // P2-2 (#3422): SHA-256 무결성 sidecar. 파일명 content-hash 는 Wyhash
  // 불변(§9), 무결성만 SHA-256. 표준 schema 불침습(별도 파일, runtime
  // 미fetch — S3/S4 interop 무영향). P2-3 RS256 서명의 토대. 런타임 강제
  // verify=P3/P4(비-목표) — 여기선 산출·정확성·결정성·변조탐지 박제.
  test('P2-2 SHA-256 무결성 sidecar: 정확성·결정성·변조탐지', async () => {
    const files = {
      'W.ts': `export default () => "W";`,
      'index.ts': `export const sentinel = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './W': './W.ts' }, shared: { react: { singleton: true } } },
      }),
    };
    const fx = await createFixture(files);
    cleanup = fx.cleanup;
    const dist = join(fx.dir, 'dist');
    const args = ['--bundle', join(fx.dir, 'index.ts'), '--outdir', dist, '--format=iife'];
    expect((await runZntcInDir(fx.dir, args)).exitCode).toBe(0);

    const dir = await readdir(dist);
    expect(dir).toContain('mf-manifest.json.integrity.json');
    const sc = JSON.parse(await readFile(join(dist, 'mf-manifest.json.integrity.json'), 'utf8'));
    expect(sc.version).toBe(1);
    expect(sc.algorithm).toBe('sha256');
    // manifest + 모든 JS 출력 청크 무결성(파일명 정렬·SRI 형식)
    const sri = (f: string) =>
      'sha256-' +
      createHash('sha256')
        .update(readFileSync(join(dist, f)))
        .digest('base64');
    const jsFiles = dir.filter((f) => f.endsWith('.js'));
    for (const f of [...jsFiles, 'mf-manifest.json']) {
      expect(sc.files[f]).toMatch(/^sha256-[A-Za-z0-9+/]+=*$/);
      // Zig SHA-256 ≡ Node crypto (정확성 교차검증)
      expect(sc.files[f], `integrity ${f}`).toBe(sri(f));
    }
    // 결정성: 동일 fixture 재빌드 → sidecar byte-동일
    const fx2 = await createFixture(files);
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await fx2.cleanup();
    };
    const dist2 = join(fx2.dir, 'dist');
    expect(
      (
        await runZntcInDir(fx2.dir, [
          '--bundle',
          join(fx2.dir, 'index.ts'),
          '--outdir',
          dist2,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const sc2 = await readFile(join(dist2, 'mf-manifest.json.integrity.json'), 'utf8');
    expect(sc2).toBe(await readFile(join(dist, 'mf-manifest.json.integrity.json'), 'utf8'));

    // 변조탐지: 청크 1바이트 수정 → 재계산 SRI ≠ sidecar(P3/P4 검증 토대)
    const chunk = jsFiles[0];
    writeFileSync(join(dist, chunk), readFileSync(join(dist, chunk), 'utf8') + '//x');
    expect(sri(chunk)).not.toBe(sc.files[chunk]);
  });

  // P2-3 (#3423): Ed25519 서명 에미터. P2-2 sidecar 를 서명한 별도 .sig
  // (자기참조 순환 회피). RS256 비채택(Zig std RSA 부재) — alg="ed25519"
  // 정직 표기. opt-in(--mf-sign-key). 런타임 강제 verify=P3/P4(비-목표).
  // raw 32B ed25519 pubkey → SPKI DER 래핑(prefix 302a300506032b6570032100).
  const SPKI_ED25519 = Buffer.from('302a300506032b6570032100', 'hex');
  const edPub = (b64: string) =>
    createPublicKey({
      key: Buffer.concat([SPKI_ED25519, Buffer.from(b64, 'base64')]),
      format: 'der',
      type: 'spki',
    });
  test('P2-3 Ed25519 서명: opt-in·round-trip·변조탐지·결정성·fail-fast', async () => {
    const files = {
      'W.ts': `export default () => "W";`,
      'index.ts': `export const sentinel = "re";`,
      'zntc.config.json': JSON.stringify({ mf: { name: 'app', exposes: { './W': './W.ts' } } }),
    };
    // (1) opt-in off — 키 없으면 .sig 미산출
    const off = await createFixture(files);
    cleanup = off.cleanup;
    const offDist = join(off.dir, 'dist');
    expect(
      (
        await runZntcInDir(off.dir, [
          '--bundle',
          join(off.dir, 'index.ts'),
          '--outdir',
          offDist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    expect(await readdir(offDist)).not.toContain('mf-manifest.json.integrity.json.sig');

    // (2) 서명 산출 + Node Ed25519 교차검증
    const fx = await createFixture(files);
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await fx.cleanup();
    };
    const keyPath = join(fx.dir, 'sign.key');
    writeFileSync(keyPath, randomBytes(32).toString('base64'));
    const dist = join(fx.dir, 'dist');
    const args = [
      '--bundle',
      join(fx.dir, 'index.ts'),
      '--outdir',
      dist,
      '--format=iife',
      `--mf-sign-key=${keyPath}`,
    ];
    expect((await runZntcInDir(fx.dir, args)).exitCode).toBe(0);
    const sidecarBytes = readFileSync(join(dist, 'mf-manifest.json.integrity.json'));
    const sig = JSON.parse(
      await readFile(join(dist, 'mf-manifest.json.integrity.json.sig'), 'utf8'),
    );
    expect(sig.version).toBe(1);
    expect(sig.alg).toBe('ed25519');
    // Zig Ed25519 ≡ Node crypto verify (정확성 교차검증)
    expect(
      cryptoVerify(null, sidecarBytes, edPub(sig.publicKey), Buffer.from(sig.signature, 'base64')),
    ).toBe(true);
    // 변조: sidecar 1바이트 → 검증 실패
    expect(
      cryptoVerify(
        null,
        Buffer.concat([sidecarBytes, Buffer.from('x')]),
        edPub(sig.publicKey),
        Buffer.from(sig.signature, 'base64'),
      ),
    ).toBe(false);

    // (3) 결정성: 동일 fixture+키 재빌드 → .sig byte-동일(결정적 서명)
    const fx2 = await createFixture(files);
    const prev2 = cleanup;
    cleanup = async () => {
      await prev2?.();
      await fx2.cleanup();
    };
    const kp2 = join(fx2.dir, 'sign.key');
    writeFileSync(kp2, readFileSync(keyPath)); // 동일 키
    const dist2 = join(fx2.dir, 'dist');
    expect(
      (
        await runZntcInDir(fx2.dir, [
          '--bundle',
          join(fx2.dir, 'index.ts'),
          '--outdir',
          dist2,
          '--format=iife',
          `--mf-sign-key=${kp2}`,
        ])
      ).exitCode,
    ).toBe(0);
    expect(await readFile(join(dist2, 'mf-manifest.json.integrity.json.sig'), 'utf8')).toBe(
      await readFile(join(dist, 'mf-manifest.json.integrity.json.sig'), 'utf8'),
    );

    // (4) fail-fast: 잘못된 키(짧음/비-base64) → 빌드 실패
    const bad = await createFixture(files);
    const prev3 = cleanup;
    cleanup = async () => {
      await prev3?.();
      await bad.cleanup();
    };
    writeFileSync(join(bad.dir, 'bad.key'), 'not-a-valid-32byte-seed');
    expect(
      (
        await runZntcInDir(bad.dir, [
          '--bundle',
          join(bad.dir, 'index.ts'),
          '--outdir',
          join(bad.dir, 'dist'),
          '--format=iife',
          `--mf-sign-key=${join(bad.dir, 'bad.key')}`,
        ])
      ).exitCode,
    ).not.toBe(0);
  });

  // P2-4 (#3424): metafile MF 산출 표식. esbuild 메타파일 스키마
  // ({inputs,outputs}) 불변 — additive 최상위 `zntcMf` 키(분석기 무시).
  // 산출 파일명 결정적 상수(P1-5/P2-2/P2-3) 포인터 + config 메타. 非-MF
  // 빌드엔 zntcMf 부재(호환 회귀 가드).
  test('P2-4 metafile zntcMf 표식: additive·esbuild 호환 불변', async () => {
    const keyName = 'mfk';
    const fx = await createFixture({
      'W.ts': `export default () => "W";`,
      'index.ts': `export const sentinel = "re";`,
      [keyName]: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './W': './W.ts' },
          shared: { react: { singleton: true } },
          remotes: { up: 'u@http://h/mf-manifest.json' },
        },
      }),
    });
    cleanup = fx.cleanup;
    const meta = join(fx.dir, 'meta.json');
    expect(
      (
        await runZntcInDir(fx.dir, [
          '--bundle',
          join(fx.dir, 'index.ts'),
          '--outdir',
          join(fx.dir, 'dist'),
          '--format=iife',
          `--metafile=${meta}`,
          `--mf-sign-key=${join(fx.dir, keyName)}`,
        ])
      ).exitCode,
    ).toBe(0);
    const m = JSON.parse(await readFile(meta, 'utf8'));
    // esbuild 스키마 불변
    expect(m.inputs).toBeDefined();
    expect(m.outputs).toBeDefined();
    // additive zntcMf
    expect(m.zntcMf).toEqual({
      name: 'app',
      manifest: 'mf-manifest.json',
      integrity: 'mf-manifest.json.integrity.json',
      signature: 'mf-manifest.json.integrity.json.sig', // 키 지정 → .sig
      exposes: ['./W'],
      shared: ['react'],
      remotes: ['up'],
    });

    // 키 미지정 → signature:null
    const fx2 = await createFixture({
      'W.ts': `export default () => "W";`,
      'index.ts': `export const sentinel = "re";`,
      'zntc.config.json': JSON.stringify({ mf: { name: 'app', exposes: { './W': './W.ts' } } }),
    });
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await fx2.cleanup();
    };
    const meta2 = join(fx2.dir, 'meta.json');
    expect(
      (
        await runZntcInDir(fx2.dir, [
          '--bundle',
          join(fx2.dir, 'index.ts'),
          '--outdir',
          join(fx2.dir, 'dist'),
          '--format=iife',
          `--metafile=${meta2}`,
        ])
      ).exitCode,
    ).toBe(0);
    const m2 = JSON.parse(await readFile(meta2, 'utf8'));
    expect(m2.zntcMf.signature).toBe(null);
    expect(m2.zntcMf.shared).toEqual([]);
    expect(m2.zntcMf.remotes).toEqual([]);

    // 非-MF 빌드: zntcMf 부재(esbuild 호환 회귀 가드)
    const fx3 = await createFixture({ 'p.ts': `export const s = 1;\nconsole.log(s);` });
    const prev3 = cleanup;
    cleanup = async () => {
      await prev3?.();
      await fx3.cleanup();
    };
    const meta3 = join(fx3.dir, 'meta.json');
    expect(
      (
        await runZntcInDir(fx3.dir, [
          '--bundle',
          join(fx3.dir, 'p.ts'),
          '-o',
          join(fx3.dir, 'o.js'),
          `--metafile=${meta3}`,
        ])
      ).exitCode,
    ).toBe(0);
    const m3 = JSON.parse(await readFile(meta3, 'utf8'));
    expect(m3.inputs).toBeDefined();
    expect(m3.zntcMf).toBeUndefined();
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
    // 원격 동적 import 재작성 — P3-5 런타임 가드 경유(인자 그대로
    // forward) + 가드 정의(내부서 표준 loadRemote 호출 = interop 보존)
    expect(hostSrc).toContain('globalThis.__mfGuardedLoad("remoteA/Widget")');
    expect(hostSrc).toContain('globalThis.__mfGuardedLoad=function(');
    expect(hostSrc).toContain('RR.loadRemote.apply(RR,a)');

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

  // PR-2 (#3459): 정적 `import X from "remote/x"` 가 표준
  // @module-federation/[email protected] 으로 **실제 동작**. emitHostInit
  // async preload-gate(Promise.all([__mfGuardedLoad]).then(seam 대입)
  // .then(body)) — 정적 import 구문은 PR-1 이 elide·seam binding 만
  // 남기고, gate 가 loadRemote 결과를 seam 글로벌에 채운 뒤 body 실행.
  // default→`.default`·named→`.x`·namespace→whole(PR-2 metadata).
  test('PR-2 정적 import: default/named/namespace 3형태 표준 runtime 실행', async () => {
    const remoteFx = await createFixture({
      'Widget.ts': `export default function W(){ return "DEF-OK"; }\nexport const meta = "MET-OK";`,
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

    const hostFx = await createFixture({
      // 정적 3형태 — PR-1 이 import 구문 elide, PR-2 gate 가 런타임 채움
      'index.ts':
        `import W from "remoteA/Widget";\n` +
        `import { meta } from "remoteA/Widget";\n` +
        `import * as NS from "remoteA/Widget";\n` +
        `console.log("PR2=" + W() + "|" + meta + "|" + (typeof NS.default) + "|" + NS.meta);`,
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
    expect(hb.exitCode, hb.stderr).toBe(0);
    const hostSrc = readFileSyncSafe(hostOut);
    // 게이트 형태: 3 정적 import → 1 spec dedupe + seam 대입 + body deferral
    expect(hostSrc).toContain('Promise.all([globalThis.__mfGuardedLoad("remoteA/Widget")])');
    expect(hostSrc).toContain('globalThis.__mf_remote_remoteA_Widget=__mfm[0];');
    expect(hostSrc).toContain('}).then(function(){');
    expect(hostSrc).toContain('var W = __mf_remote_remoteA_Widget.default;'); // default→.default
    expect(hostSrc).toContain('var meta = __mf_remote_remoteA_Widget.meta;'); // named→.x
    expect(hostSrc).toContain('var NS = __mf_remote_remoteA_Widget;'); // namespace→whole

    const mfRuntime = createRequire(import.meta.url).resolve('@module-federation/runtime');
    driverPath = join(hostFx.dir, 'pr2-driver.mjs');
    writeFileSync(
      driverPath,
      `import mf from ${JSON.stringify('file://' + mfRuntime)};\n` +
        `globalThis.__mf_runtime = mf;\n` +
        `await import(${JSON.stringify('file://' + hostOut)});\n` +
        `await new Promise(r => setTimeout(r, 600));\n`,
    );
    const { stdout, stderr } = await runNode(driverPath);
    // 성공 경로: gate→loadRemote→seam→body. default/named/namespace 정확.
    expect(stdout).toContain('PR2=DEF-OK|MET-OK|function|MET-OK');
    expect(stderr).not.toMatch(/RUNTIME-00\d|runtime guard|does not contain "init"/);
  }, 30000);

  // PR-3 (#3459): 정적 import 도 P3-1 expose 계약 검증. 정적 import 는
  // codegen elide → verifyHostContract 의 동적 `import(` 스캔에 안 잡혀
  // 검증 갭이었음. metadata.zig 수집 정적 spec 을 verifyHostContract
  // 가 동적과 동일 per-spec 검증(verifyOneRemoteSpec 단일소스) →
  // 정적 부재 expose 도 빌드 fail-fast(S6).
  test('PR-3 정적 import P3-1: 부재 expose 정적 import → 빌드 fail-fast', async () => {
    const rfx = await createFixture({
      'Widget.ts': `export default function W(){ return "OK"; }`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    const rdist = join(rfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(rfx.dir, [
          '--bundle',
          join(rfx.dir, 'index.ts'),
          '--outdir',
          rdist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await rfx.cleanup();
    };
    const buildHost = async (importLine: string) => {
      const hfx = await createFixture({
        'index.ts': `${importLine}\nglobalThis.__r = 1;`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'host', remotes: { app: `app@${manifestAbs}` } },
        }),
      });
      const r = await runZntcInDir(hfx.dir, [
        '--bundle',
        join(hfx.dir, 'index.ts'),
        '-o',
        join(hfx.dir, 'host.js'),
        '--format=iife',
      ]);
      await hfx.cleanup();
      return r;
    };
    // 정적 존재 expose → 빌드 성공(정밀 — blanket 아님)
    expect((await buildHost('import W from "app/Widget";')).exitCode).toBe(0);
    // 정적 부재 expose → 빌드 fail-fast(verifyOneRemoteSpec 정적 경로)
    const bad = await buildHost('import X from "app/Missing";');
    expect(bad.exitCode).not.toBe(0);
    expect(bad.stderr).toContain('MF expose 계약 위반');
    expect(bad.stderr).toContain('"app/Missing"');
  }, 30000);

  // P3-1 (#3436): 빌드타임 expose 계약 검증(D3, 스파이크 S6). host import
  // 가 remote 의 게시 mf-manifest.json exposes 에 **없으면 빌드 fail-fast**
  // (런타임 깨짐 아님 — MF2 의 stale 런타임-실패 대비 차별화). resolve
  // 불가 remote(http=네트워크 비-목표 P4 / 로컬 부재)는 검증 불가 ≠ 위반
  // → skip(정밀 fail-fast, 기존 http host interop 무회귀 보장).
  test('P3-1 expose 계약: 부재 expose → 빌드 fail-fast(S6); 존재·http·부재manifest 통과', async () => {
    // zntc remote 빌드 → rdist/mf-manifest.json (exposes name "./Widget")
    const remoteFx = await createFixture({
      'Widget.ts': `export default function W(){ return "OK"; }`,
      'index.ts': `export const s = "re";`,
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
    ]);
    expect(rb.exitCode).toBe(0);
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await remoteFx.cleanup();
    };

    // host 빌드 헬퍼 — 동적 import spec·remote entry 가변(단일파일 iife,
    // host-emit 게이트 동일: app=external 라 split 없음 → output.len>0).
    const buildHost = async (spec: string, entry: string) => {
      const hostFx = await createFixture({
        'index.ts': `async function m(){ const x = await import(${JSON.stringify(spec)}); console.log(x); }\nm();`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'host', remotes: { app: `app@${entry}` } },
        }),
      });
      const r = await runZntcInDir(hostFx.dir, [
        '--bundle',
        join(hostFx.dir, 'index.ts'),
        '-o',
        join(hostFx.dir, 'host.js'),
        '--format=iife',
      ]);
      await hostFx.cleanup();
      return r;
    };

    // ① 존재 expose → 빌드 성공
    expect((await buildHost('app/Widget', manifestAbs)).exitCode).toBe(0);

    // ② 부재 expose → 빌드 fail-fast(런타임 아님) + 명확한 메시지.
    //    성공-우회 명시 배제(거짓통과 차단).
    const bad = await buildHost('app/Missing', manifestAbs);
    expect(bad.exitCode).not.toBe(0);
    expect(bad.stderr).toContain('MF expose 계약 위반');
    expect(bad.stderr).toContain('mf-manifest.json exposes');

    // ③ http remote(네트워크 비-목표) → 검증 불가 ≠ 위반 → 빌드 통과
    //    (정밀 fail-fast: 기존 http host interop 무회귀).
    expect((await buildHost('app/Whatever', 'http://localhost:9/index.js')).exitCode).toBe(0);

    // ④ 로컬 manifest 부재(네트워크 아님) → 검증 불가 → 통과(부재 ≠ 위반)
    const noMani = join(remoteFx.dir, 'nope', 'mf-manifest.json');
    expect((await buildHost('app/Whatever', noMani)).exitCode).toBe(0);
  }, 30000);

  // P3-2 (#3437): 빌드타임 shared 버전 호환 검증(D3). host 가 import 하는
  // remote 의 게시 shared 와 host shared 선언이: singleton 불일치 →
  // **빌드 fail-fast**(결정적·인스턴스 분열); 버전 비호환 → 경고(비차단,
  // semver). remote.version 이 비-concrete(zntc P2-0 = version=range 대용)
  // 면 판정 불가 → 통과(정밀 fail-fast — 거짓 빌드중단 금지).
  test('P3-2 shared 호환: singleton 불일치 → 빌드 fail-fast; 일치·무선언 통과', async () => {
    // zntc remote: ./Widget expose + shared react(singleton:true,^19).
    // manifest.shared = [{react, version:"^19"(P2-0 range 대용), singleton:true}]
    const remoteFx = await createFixture({
      'Widget.ts': `import { useState } from "react";\nexport default function W(){ return typeof useState; }`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          shared: { react: { singleton: true, requiredVersion: '^19' } },
        },
      }),
    });
    const rdist = join(remoteFx.dir, 'dist');
    const rb = await runZntcInDir(remoteFx.dir, [
      '--bundle',
      join(remoteFx.dir, 'index.ts'),
      '--outdir',
      rdist,
      '--format=iife',
    ]);
    expect(rb.exitCode).toBe(0);
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await remoteFx.cleanup();
    };

    // host 빌드 — shared 선언 가변(undefined=무선언). import("app/Widget")
    // 로 verifyHostContract 의 loadContract 패스 트리거.
    const buildHost = async (sharedCfg: unknown) => {
      const mf: Record<string, unknown> = {
        name: 'host',
        remotes: { app: `app@${manifestAbs}` },
      };
      if (sharedCfg !== undefined) mf.shared = sharedCfg;
      const hostFx = await createFixture({
        'index.ts': `async function m(){ const x = await import("app/Widget"); console.log(x); }\nm();`,
        'zntc.config.json': JSON.stringify({ mf }),
      });
      const r = await runZntcInDir(hostFx.dir, [
        '--bundle',
        join(hostFx.dir, 'index.ts'),
        '-o',
        join(hostFx.dir, 'host.js'),
        '--format=iife',
      ]);
      await hostFx.cleanup();
      return r;
    };

    // ① singleton 불일치(host:false ↔ remote:true) → 빌드 fail-fast.
    //    성공-우회 명시 배제(거짓통과 차단).
    const conflict = await buildHost({ react: { singleton: false, requiredVersion: '^19' } });
    expect(conflict.exitCode).not.toBe(0);
    expect(conflict.stderr).toContain('MF shared singleton 충돌');

    // ② singleton 일치 → 통과(remote.version="^19" 비-concrete → 버전
    //    판정 불가 → 정밀 fail-fast 로 경고 없이 통과).
    expect((await buildHost({ react: { singleton: true, requiredVersion: '^19' } })).exitCode).toBe(
      0,
    );

    // ③ host shared 무선언 → 페어링 없음 → 통과(expose 는 존재).
    expect((await buildHost(undefined)).exitCode).toBe(0);
  }, 30000);

  // P3-3 (#3438): 빌드타임 무결성 검증(D3 런타임가드의 빌드타임 절반).
  // host 가 소비하는 remote 의 게시 manifest 가 sidecar(P2-2 SHA-256)/
  // `.sig`(P2-3 Ed25519)와 불일치(stale/변조)면 **빌드 fail-fast**.
  // sidecar/sig 부재 = 검증 불가 ≠ 위반 → 통과(비-zntc·미서명 무회귀).
  test('P3-3 무결성: 변조 manifest·서명 → 빌드 fail-fast; 정상·sidecar부재 통과', async () => {
    const buildHost = async (manifestAbs: string) => {
      const hostFx = await createFixture({
        'index.ts': `async function m(){ const x = await import("app/Widget"); console.log(x); }\nm();`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'host', remotes: { app: `app@${manifestAbs}` } },
        }),
      });
      const r = await runZntcInDir(hostFx.dir, [
        '--bundle',
        join(hostFx.dir, 'index.ts'),
        '-o',
        join(hostFx.dir, 'host.js'),
        '--format=iife',
      ]);
      await hostFx.cleanup();
      return r;
    };

    // ── SHA-256 sidecar (서명 없음, 항상 산출) ──
    const rfx = await createFixture({
      'Widget.ts': `export default function W(){ return "OK"; }`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    const rdist = join(rfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(rfx.dir, [
          '--bundle',
          join(rfx.dir, 'index.ts'),
          '--outdir',
          rdist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const sidecarAbs = join(rdist, 'mf-manifest.json.integrity.json');
    const orig = readFileSync(manifestAbs);
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await rfx.cleanup();
    };

    // ① 정상 → 통과
    expect((await buildHost(manifestAbs)).exitCode).toBe(0);

    // ② manifest 변조(유효 JSON 유지 — loadContract 는 통과하되 바이트가
    //    달라 sidecar SHA 불일치) → 무결성 fail-fast.
    const t = JSON.parse(orig.toString());
    t.__tampered = true; // unknown 키(parseContract 는 무시) — 바이트만 변경
    writeFileSync(manifestAbs, JSON.stringify(t));
    const tampered = await buildHost(manifestAbs);
    expect(tampered.exitCode).not.toBe(0);
    expect(tampered.stderr).toContain('MF 무결성 위반');
    writeFileSync(manifestAbs, orig); // 복원

    // ③ sidecar 부재 → 검증 불가 ≠ 위반 → 통과(비-zntc remote 무회귀)
    rmSync(sidecarAbs, { force: true });
    expect((await buildHost(manifestAbs)).exitCode).toBe(0);

    // ── Ed25519 `.sig` (P2-3 opt-in) ──
    const sfx = await createFixture({
      'Widget.ts': `export default function W(){ return "OK"; }`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    const prev2 = cleanup;
    cleanup = async () => {
      await prev2?.();
      await sfx.cleanup();
    };
    const keyPath = join(sfx.dir, 'sign.key');
    writeFileSync(keyPath, randomBytes(32).toString('base64'));
    const sdist = join(sfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(sfx.dir, [
          '--bundle',
          join(sfx.dir, 'index.ts'),
          '--outdir',
          sdist,
          '--format=iife',
          `--mf-sign-key=${keyPath}`,
        ])
      ).exitCode,
    ).toBe(0);
    const sManifest = join(sdist, 'mf-manifest.json');
    const sigAbs = join(sdist, 'mf-manifest.json.integrity.json.sig');

    // ④ 정상 서명 → 통과(SHA + Ed25519 모두 일치)
    expect((await buildHost(sManifest)).exitCode).toBe(0);

    // ⑤ `.sig` 변조(sidecar 는 그대로 → SHA 통과 후 서명 검증 실패) →
    //    빌드 fail-fast.
    const sigJson = JSON.parse(readFileSync(sigAbs, 'utf8'));
    sigJson.signature = Buffer.from(randomBytes(64)).toString('base64'); // 무효 서명
    writeFileSync(sigAbs, JSON.stringify(sigJson));
    const badSig = await buildHost(sManifest);
    expect(badSig.exitCode).not.toBe(0);
    expect(badSig.stderr).toContain('MF 서명 위반');
  }, 30000);

  // 갭 보강(레퍼런스 module-federation/core 대비). zntc remote dir 빌드 +
  // .js entry http 서빙(S3/host-emit 검증 형태, Node-safe — chunk=file://).
  async function buildZntcRemote(
    name: string,
    expose: string,
    src: string,
    srv: 'a' | 'b',
  ): Promise<number> {
    const fx = await createFixture({
      [`${expose}.ts`]: src,
      'index.ts': `export const sentinel = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name, exposes: { [`./${expose}`]: `./${expose}.ts` } },
      }),
    });
    const dist = join(fx.dir, 'dist');
    const b = await runZntcInDir(fx.dir, [
      '--bundle',
      join(fx.dir, 'index.ts'),
      '--outdir',
      dist,
      '--format=iife',
      `--public-path=file://${dist}/`,
    ]);
    expect(b.exitCode, `build ${name}: ${b.stderr?.slice(0, 300)}`).toBe(0);
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await fx.cleanup();
    };
    const s = createServer(async (req, res) => {
      try {
        const u = req.url === '/' ? '/index.js' : req.url!;
        res.writeHead(200, {
          'content-type': u.endsWith('.json') ? 'application/json' : 'application/javascript',
        });
        res.end(await readFile(join(dist, u)));
      } catch {
        res.writeHead(404).end();
      }
    });
    if (srv === 'a') server = s;
    else server2 = s;
    await new Promise<void>((r) => s.listen(0, r));
    return (s.address() as { port: number }).port;
  }

  // P0: 다중 remote — emitHostInit/isRemoteSpec 가 2+ remote 를 prelude
  // 배열·loadRemote 재작성 양쪽에서 정확히 처리(레퍼런스 load-remote.spec
  // /snapshot.spec 가 2 remote 테스트, zntc 는 단일만 검증돼 있었음).
  test('P0 다중 remote: zntc host 가 2개 zntc remote 동시 소비', async () => {
    const pa = await buildZntcRemote('appA', 'X', `export default () => "X-OK";`, 'a');
    const pb = await buildZntcRemote('appB', 'Y', `export default () => "Y-OK";`, 'b');
    const hostFx = await createFixture({
      'index.ts':
        `async function main(){` +
        ` const a = await import("appA/X"); const b = await import("appB/Y");` +
        ` console.log("MR=" + (a.default ?? a)() + "," + (b.default ?? b)()); }\nmain();`,
      'zntc.config.json': JSON.stringify({
        mf: {
          name: 'host',
          remotes: {
            appA: `appA@http://localhost:${pa}/index.js`,
            appB: `appB@http://localhost:${pb}/index.js`,
          },
        },
      }),
    });
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await hostFx.cleanup();
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
    // prelude remotes 배열에 두 remote 모두 + 각각 loadRemote 재작성
    expect(hostSrc).toMatch(/"name":"appA","entry":"http:\/\/localhost:\d+\/index\.js"/);
    expect(hostSrc).toMatch(/"name":"appB","entry":"http:\/\/localhost:\d+\/index\.js"/);
    expect(hostSrc).toContain('globalThis.__mfGuardedLoad("appA/X")'); // P3-5 가드 경유
    expect(hostSrc).toContain('globalThis.__mfGuardedLoad("appB/Y")');

    const mfRuntime = createRequire(import.meta.url).resolve('@module-federation/runtime');
    driverPath = join(hostFx.dir, 'mr-driver.mjs');
    writeFileSync(
      driverPath,
      `import mf from ${JSON.stringify('file://' + mfRuntime)};\n` +
        `globalThis.__mf_runtime = mf;\n` +
        `await import(${JSON.stringify('file://' + hostOut)});\n` +
        `await new Promise(r => setTimeout(r, 700));\n`,
    );
    const { stdout, stderr } = await runNode(driverPath);
    expect(stdout).toContain('MR=X-OK,Y-OK'); // 두 remote 동시 소비
    expect(stderr).not.toMatch(/RUNTIME-00\d|does not contain "init"/);
  }, 40000);

  // P0: negative 계약 — 없는 expose 는 container throw("does not exist in
  // container <name>"), 없는 remote 는 RUNTIME 에러(무한대기 아님). 기존
  // 테스트는 happy-path 의 RUNTIME-00x *부재*만 봤음.
  test('P0 negative: 없는 expose/remote 가 명확히 실패', async () => {
    const p = await buildZntcRemote('app', 'Widget', `export default () => "OK";`, 'a');
    const mfRuntime = createRequire(import.meta.url).resolve('@module-federation/runtime');
    const fx = await createFixture({ 'noop.txt': '' });
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await fx.cleanup();
    };
    driverPath = join(fx.dir, 'neg-driver.mjs');
    writeFileSync(
      driverPath,
      `import mf from ${JSON.stringify('file://' + mfRuntime)};\n` +
        `const { init, loadRemote } = mf;\n` +
        `init({ name: "neg", remotes: [{ name: "app", entry: "http://localhost:${p}/index.js" }] });\n` +
        `try { await loadRemote("app/Missing"); console.log("EXP=NOFAIL"); }\n` +
        `catch (e) { console.log("EXP=" + (e && (e.message || e))); }\n` +
        `try { await Promise.race([loadRemote("nope/Z"),` +
        ` new Promise((_, j) => setTimeout(() => j(new Error("TIMEOUT")), 5000))]);` +
        ` console.log("REM=NOFAIL"); }\n` +
        `catch (e) { console.log("REM=" + (e && (e.message || e))); }\n`,
    );
    const { stdout } = await runNode(driverPath);
    // 없는 expose → zntc container 의 throw 메시지(실 runtime 통과).
    // 성공-우회(NOFAIL) 명시 배제로 거짓통과 차단.
    expect(stdout).not.toContain('EXP=NOFAIL');
    expect(stdout).toContain('does not exist in container app');
    // 없는 remote → 에러로 귀결: 무한대기(TIMEOUT)·조용한 성공(NOFAIL) 아님
    // + 실제 에러 문자열 존재(분리 단언으로 lookahead 우회 여지 제거).
    expect(stdout).not.toContain('REM=NOFAIL');
    expect(stdout).not.toContain('REM=TIMEOUT');
    expect(stdout).toMatch(/REM=\S/);
  }, 30000);

  // P3-4 (#3439): 소유권 경계 린트. 연합 경계 모듈(expose/shared 폐포)
  // 이 host-owned store/Provider 를 자체 생성하면 **비-차단 빌드 경고**
  // (#3336 진단 선례 미러 — 탐지→경고, 빌드 실패 아님). 휴리스틱이라
  // FP 가능(RFC §7.3 ②): store *생성* 심볼만 매칭, 주입·소비(createSlice
  // /useSelector/atom)는 비매칭. 경계 모듈만 — 비-경계는 무경고.
  test('P3-4 소유권 경계: 경계 모듈 store 자체생성 → 비-차단 경고; 주입·비경계 무경고', async () => {
    // 로컬 stub node_modules(@reduxjs/toolkit) — bare import 가 resolve
    // 되어 IIFE 번들에 포함(P1 제약: 미해결 bare external 은 IIFE emit
    // 불가). 린트는 import 바인딩(specifier+심볼)만 보므로 stub 으로 충분.
    const rtkStub = {
      'node_modules/@reduxjs/toolkit/package.json': '{"name":"@reduxjs/toolkit","main":"index.js"}',
      'node_modules/@reduxjs/toolkit/index.js':
        'export const configureStore=()=>({});\nexport const createSlice=()=>({});',
    };

    // ① 경계(expose) 모듈이 configureStore 자체 생성 → 경고 + 빌드 성공
    const fxBad = await createFixture({
      ...rtkStub,
      'Widget.ts': `import { configureStore } from "@reduxjs/toolkit";\nexport default function W(){ return typeof configureStore; }`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    cleanup = fxBad.cleanup;
    const bad = await runZntcInDir(fxBad.dir, [
      '--bundle',
      join(fxBad.dir, 'index.ts'),
      '--outdir',
      join(fxBad.dir, 'dist'),
      '--format=iife',
    ]);
    expect(bad.exitCode).toBe(0); // 경고는 비-차단(빌드 성공)
    expect(bad.stderr).toContain('소유권 경계');
    expect(bad.stderr).toContain('Redux configureStore');
    await fxBad.cleanup();
    cleanup = undefined;

    // ② GOOD 패턴(경계는 createSlice 주입) + 비-경계 entry 의
    //    configureStore → 경고 없음(휴리스틱 정밀: 생성 심볼만·경계만).
    const fxOk = await createFixture({
      ...rtkStub,
      'Widget.ts': `import { createSlice } from "@reduxjs/toolkit";\nexport default function W(){ return typeof createSlice; }`,
      // index.ts(비-경계 entry)는 configureStore 써도 무경고(경계 아님)
      'index.ts': `import { configureStore } from "@reduxjs/toolkit";\nexport const store = configureStore;`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    cleanup = fxOk.cleanup;
    const ok = await runZntcInDir(fxOk.dir, [
      '--bundle',
      join(fxOk.dir, 'index.ts'),
      '--outdir',
      join(fxOk.dir, 'dist'),
      '--format=iife',
    ]);
    expect(ok.exitCode).toBe(0);
    expect(ok.stderr).not.toContain('소유권 경계');
    // 주: shared 패키지는 seam 으로 external 화 → 그 모듈은 graph 에
    // 없어 lintOwnershipBoundary(graph 순회) 대상이 아님. external dep
    // 내부의 store 생성은 RFC §7.3 ②(외부/완전 데이터플로 미탐지 =
    // 문서화된 휴리스틱 한계, 비-목표) — expose 경계 모듈만 린트 대상.
  }, 30000);

  // PR-1 (#3459): 정적 `import X from "remote/x"` seam 인프라(토대).
  // 기존엔 `unresolved import ... IIFE format` 빌드 에러 → 이제 per-spec
  // seam 글로벌(`__mf_remote_<san>`)로 binding 재작성, 빌드 성공.
  // **런타임 값은 PR-2 async preload-gate 가 채움**(현재 미정의 —
  // P3-0 "토대, 검증 없음" 방식: 빌드/emit 형태만 박제, 실행 아님).
  test('PR-1 정적 import seam: 빌드 에러 소멸 + 3형태 seam 글로벌 재작성', async () => {
    const rfx = await createFixture({
      'Widget.ts': `export default function W(){ return "S-OK"; }\nexport const meta = "m";`,
      'index.ts': `export const s = "re";`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
      }),
    });
    const rdist = join(rfx.dir, 'dist');
    expect(
      (
        await runZntcInDir(rfx.dir, [
          '--bundle',
          join(rfx.dir, 'index.ts'),
          '--outdir',
          rdist,
          '--format=iife',
        ])
      ).exitCode,
    ).toBe(0);
    const manifestAbs = join(rdist, 'mf-manifest.json');
    const hfx = await createFixture({
      // default · named · namespace 3형태
      'index.ts': `import W from "app/Widget";\nimport { meta } from "app/Widget";\nimport * as NS from "app/Widget";\nglobalThis.__r = [typeof W, meta, typeof NS];`,
      'zntc.config.json': JSON.stringify({
        mf: { name: 'host', remotes: { app: `app@${manifestAbs}` } },
      }),
    });
    const prev = cleanup;
    cleanup = async () => {
      await prev?.();
      await rfx.cleanup();
      await hfx.cleanup();
    };
    const hostOut = join(hfx.dir, 'host.js');
    const hb = await runZntcInDir(hfx.dir, [
      '--bundle',
      join(hfx.dir, 'index.ts'),
      '-o',
      hostOut,
      '--format=iife',
      '--platform=browser',
    ]);
    // 빌드 에러 소멸(P1 IIFE bare-external 거부 우회)
    expect(hb.exitCode, hb.stderr).toBe(0);
    expect(hb.stderr).not.toContain('cannot be emitted in IIFE');
    const src = readFileSync(hostOut, 'utf8');
    // 3형태 → per-spec seam 글로벌 binding + PR-2 async preload-gate.
    // remote=ESM namespace 라 default→`.default`(PR-2 metadata 정정 —
    // 동적경로 `m.default` 와 일관), named→`.x`, namespace→whole.
    expect(src).toContain('var W = __mf_remote_app_Widget.default;'); // default→.default
    expect(src).toContain('var meta = __mf_remote_app_Widget.meta;'); // named
    expect(src).toContain('var NS = __mf_remote_app_Widget;'); // namespace
    // PR-2: 정적 import 발견 → async preload-gate emit(seam 채움 후 body)
    expect(src).toContain('Promise.all([globalThis.__mfGuardedLoad("app/Widget")])');
    expect(src).toContain('globalThis.__mf_remote_app_Widget=__mfm[0];');
    // 정적 import 구문은 IIFE 출력에 잔존하지 않음(codegen elide)
    expect(src).not.toMatch(/(^|\n)\s*import\b.*["']app\/Widget["']/);
  }, 30000);
});

function readFileSyncSafe(p: string): string {
  try {
    return require('node:fs').readFileSync(p, 'utf8');
  } catch {
    return '';
  }
}
