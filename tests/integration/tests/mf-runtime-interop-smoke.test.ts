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
    expect(hostSrc).toContain('globalThis.__mf_runtime.loadRemote("appA/X")');
    expect(hostSrc).toContain('globalThis.__mf_runtime.loadRemote("appB/Y")');

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
});

function readFileSyncSafe(p: string): string {
  try {
    return require('node:fs').readFileSync(p, 'utf8');
  } catch {
    return '';
  }
}
