import { test, expect } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { serve, closeServer } from './serve';

/**
 * MF interop E2E — **실 Chromium** 에서 표준 `@module-federation/[email protected]`
 * 가 zntc-빌드 remote 를 manifest-driven `loadRemote` 로 소비 (#3318 §8.1 S3
 * 정방향, P1-7).
 *
 * Node 스모크(tests/integration/tests/mf-runtime-interop-smoke.test.ts)는
 * 같은 계약을 실 runtime 으로 박제하나 **Node 가 http chunk `import()` 미지원**
 * → entry 를 직접 `.js`(file:// chunk)로 우회했다. 본 e2e 는 그 이월분을
 * 실브라우저에서 닫는다: **mf-manifest.json entry + http(cross-origin) chunk**
 * 전체경로(P1-5/P1-6 주석이 "P1-7" 로 명시한 갭).
 *
 * S4 역방향(#3415): zntc-emit host(P1-6) 가 실 @module-federation/runtime
 * 으로 **표준 rspack+@module-federation/[email protected] remote**(remoteEntry.js
 * +mf-manifest.json)를 manifest-driven 소비. rspack remote 는 테스트 런타임
 * spawnSync 빌드(temp fixture, abs-path 로 cli/enhanced 해소 — 산출은
 * throwaway, 동작만 영구 박제). S3+S4 = 실브라우저 양방향 interop.
 */
const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');

// 패키지의 진입(package.json `module`||`main`) 절대경로. e2e 워크스페이스
// (tests/e2e/package.json devDep)에서 resolve — zntc 가 iife glue 로 번들
// (bare nested deps 포함). runtime=`__mf_runtime` seam(P1-6), react=공유
// 인스턴스 제공(P2-5).
function pkgEntry(spec: string): string {
  const req = createRequire(join(__dirname, 'noop.js'));
  const pkgJson = req.resolve(`${spec}/package.json`);
  const pkg = req(pkgJson) as { module?: string; main: string };
  return resolve(dirname(pkgJson), pkg.module ?? pkg.main);
}

// @rspack/cli 실행 bin 절대경로(e2e devDep). temp fixture 라 bare resolve
// 불가 → 워크스페이스에서 abs 해소 후 `node <bin>` 실행(rspack 은 자기 위치
// 기준으로 @rspack/core·loader 해소 — temp dir node_modules 불요).
function rspackBin(): string {
  const req = createRequire(join(__dirname, 'noop.js'));
  const cliPkg = req.resolve('@rspack/cli/package.json');
  const cli = req(cliPkg) as { bin: string | Record<string, string> };
  return resolve(dirname(cliPkg), typeof cli.bin === 'string' ? cli.bin : cli.bin.rspack);
}

// @module-federation/enhanced 의 rspack ModuleFederationPlugin 진입 abs
// (rspack.config.cjs 가 abs require — temp fixture 에 node_modules 없음).
function enhancedRspackPath(): string {
  return createRequire(join(__dirname, 'noop.js')).resolve('@module-federation/enhanced/rspack');
}

// zntc 로 pkg 를 iife glue 로 번들 → host 페이지가 <script> 로 먼저 로드.
// `<srcTs>` 내용을 zntc 빌드해 `<outJs>` 산출. S3/S4/P2-5 공용 단일 소스.
async function buildIifeGlue(
  dir: string,
  srcTs: string,
  outJs: string,
  source: string,
): Promise<void> {
  await writeFile(join(dir, srcTs), source);
  const b = spawnSync(
    ZNTC_BIN,
    ['--bundle', join(dir, srcTs), '-o', join(dir, outJs), '--format=iife', '--platform=browser'],
    { cwd: dir, stdio: 'pipe', timeout: 20000 },
  );
  expect(b.status, `zntc glue build (${outJs}): ${b.stderr?.toString().slice(0, 500)}`).toBe(0);
}

// 표준 @module-federation/runtime → globalThis.__mf_runtime(P1-6 seam 짝).
async function buildGlue(hostDir: string): Promise<void> {
  await buildIifeGlue(
    hostDir,
    'glue.ts',
    'glue.js',
    `import * as mf from ${JSON.stringify(pkgEntry('@module-federation/runtime'))};\nglobalThis.__mf_runtime = mf;`,
  );
}

test('S3 정방향: 표준 @module-federation/runtime(실브라우저) 가 zntc remote 를 manifest-driven 소비', async ({
  page,
}) => {
  // 빌드 2회(remote+glue, 각 20s timeout) + 15s wait — CI(느림) 여유 위해
  // 케이스 timeout 상향(기본 30s 는 이론상 빠듯).
  test.setTimeout(90_000);
  const remoteDir = await mkdtemp(join(tmpdir(), 'zntc-mf-remote-'));
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-mf-host-'));
  let remoteSrv: Awaited<ReturnType<typeof serve>> | undefined;
  let hostSrv: Awaited<ReturnType<typeof serve>> | undefined;
  try {
    const remoteDist = join(remoteDir, 'dist');
    await mkdir(remoteDist, { recursive: true });
    // remote origin 먼저 serve(동적 port) → 그 port 로 --public-path 빌드.
    // serve 는 요청마다 파일을 읽으므로 빌드를 serve 후 수행해도 무방.
    remoteSrv = await serve(remoteDist, { 'Access-Control-Allow-Origin': '*' });
    const rOrigin = `http://localhost:${remoteSrv.port}`;

    await writeFile(
      join(remoteDir, 'Widget.ts'),
      `globalThis.__w_eval = true;\n` + `export default function Widget() { return "ZNTC-RT-OK"; }`,
    );
    await writeFile(join(remoteDir, 'index.ts'), `export const sentinel = "remote-entry";`);
    await writeFile(
      join(remoteDir, 'zntc.config.json'),
      JSON.stringify({ mf: { name: 'app', exposes: { './Widget': './Widget.ts' } } }),
    );
    const rb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(remoteDir, 'index.ts'),
        '--outdir',
        remoteDist,
        '--format=iife',
        '--platform=browser',
        // 브라우저는 http chunk import 가능 → Node 제약(file://) 해소.
        `--public-path=${rOrigin}/`,
      ],
      // cwd=remoteDir — zntc 가 zntc.config.json(mf) 을 cwd 에서 로드
      // (Node 스모크 runZntcInDir 와 동일). 미설정 시 mf emit 0 → manifest 없음.
      { cwd: remoteDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(rb.status, `zntc remote build: ${rb.stderr?.toString().slice(0, 500)}`).toBe(0);

    await buildGlue(hostDir);

    // host 페이지: glue 먼저 → 표준 runtime init/loadRemote(manifest entry).
    await writeFile(
      join(hostDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script src="./glue.js"></script></head><body><div id="out">pending</div>` +
        `<script>(async()=>{try{` +
        `var R=globalThis.__mf_runtime;` +
        `window.__before=!!globalThis.__w_eval;` +
        `R.init({name:"host-mf2",remotes:[{name:"app",entry:${JSON.stringify(
          `${rOrigin}/mf-manifest.json`,
        )}}]});` +
        `var m=await R.loadRemote("app/Widget");var W=(m&&(m.default||m));` +
        `document.getElementById("out").textContent=(typeof W==="function"?W():"NOFN");` +
        `window.__after=!!globalThis.__w_eval;window.__done=true;` +
        `}catch(e){window.__err=String(e&&e.stack||e);window.__done=true;}})();</script>` +
        `</body></html>`,
    );
    hostSrv = await serve(hostDir);

    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    const seen: Record<string, number> = {};
    page.on('response', (r) => {
      const u = r.url();
      if (u.includes('mf-manifest.json')) seen.manifest = r.status();
      // expose lazy 청크(script). 해시 접미 가능 → script resourceType +
      // remote origin + Widget 포함으로 엄격 매칭(manifest URL 오캡처 배제).
      if (
        r.request().resourceType() === 'script' &&
        u.startsWith(rOrigin) &&
        u.includes('Widget')
      ) {
        seen.chunk = r.status();
      }
    });

    await page.goto(`http://localhost:${hostSrv.port}/`);
    await page.waitForFunction(() => (window as { __done?: boolean }).__done === true, {
      timeout: 15000,
    });

    const err = await page.evaluate(() => (window as { __err?: string }).__err);
    expect(err, `host runtime error: ${err}`).toBeFalsy();
    // 표준 runtime 이 zntc container 를 manifest-driven 으로 구동 → expose 렌더
    expect(await page.locator('#out').textContent()).toBe('ZNTC-RT-OK');
    // lazy: loadRemote 전 Widget 미평가 → 후 평가
    expect(await page.evaluate(() => (window as { __before?: boolean }).__before)).toBe(false);
    expect(await page.evaluate(() => (window as { __after?: boolean }).__after)).toBe(true);
    // manifest + cross-origin http chunk 가 실제 200 (Node 이월분 = 실브라우저 확증)
    expect(seen.manifest, 'mf-manifest.json fetched').toBe(200);
    expect(seen.chunk, 'remote chunk http-loaded').toBe(200);
    expect(errors, `browser errors: ${errors.join(', ')}`).toHaveLength(0);
    // manifest-driven 이라 zntc remote 빌드물에 mf-manifest.json 실재
    expect((await readFile(join(remoteDist, 'mf-manifest.json'), 'utf8')).length).toBeGreaterThan(
      0,
    );
  } finally {
    if (remoteSrv) await closeServer(remoteSrv.server);
    if (hostSrv) await closeServer(hostSrv.server);
    await rm(remoteDir, { recursive: true, force: true });
    await rm(hostDir, { recursive: true, force: true });
  }
});

test('S4 역방향: zntc host(실브라우저) 가 표준 rspack+@module-federation/enhanced remote 소비', async ({
  page,
}) => {
  // rspack remote 빌드 1회(cold, 네이티브 binding 첫 로드 — CI 느림) +
  // zntc 빌드 2회(host/glue) + wait. CI cold 마진 확보 위해 180s.
  test.setTimeout(180_000);
  const rspackDir = await mkdtemp(join(tmpdir(), 'rspack-remote-'));
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-host-'));
  let remoteSrv: Awaited<ReturnType<typeof serve>> | undefined;
  let hostSrv: Awaited<ReturnType<typeof serve>> | undefined;
  try {
    const rspackDist = join(rspackDir, 'dist');
    await mkdir(join(rspackDir, 'src'), { recursive: true });
    remoteSrv = await serve(rspackDist, { 'Access-Control-Allow-Origin': '*' });
    const rOrigin = `http://localhost:${remoteSrv.port}`;

    // 표준 rspack+enhanced remote fixture. `.mjs` = 모호성 없는 ESM(rspack
    // 이 type 추론 불요). config 는 require → `.cjs`, enhanced 는 abs.
    // @module-federation/manifest StatsManager.getBuildInfo 가 package.json
    // `name` 을 읽음 → 없으면 crash. 최소 매니페스트 제공.
    await writeFile(
      join(rspackDir, 'package.json'),
      JSON.stringify({ name: 'rspack-remote', version: '1.0.0', private: true }),
    );
    await writeFile(
      join(rspackDir, 'src', 'Card.mjs'),
      `export default function Card() { return "RSPACK-REMOTE-OK"; }`,
    );
    await writeFile(join(rspackDir, 'src', 'index.mjs'), `export const sentinel = 1;`);
    await writeFile(
      join(rspackDir, 'rspack.config.cjs'),
      `const { ModuleFederationPlugin } = require(${JSON.stringify(enhancedRspackPath())});\n` +
        `module.exports = { mode: 'production', devtool: false, target: 'web',\n` +
        `  entry: ${JSON.stringify(join(rspackDir, 'src', 'index.mjs'))},\n` +
        `  output: { path: ${JSON.stringify(rspackDist)}, publicPath: ${JSON.stringify(
          `${rOrigin}/`,
        )}, clean: true },\n` +
        `  plugins: [ new ModuleFederationPlugin({ name: 'remote_mf2',` +
        ` filename: 'remoteEntry.js',` +
        ` exposes: { './Card': ${JSON.stringify(join(rspackDir, 'src', 'Card.mjs'))} } }) ] };`,
    );
    const rs = spawnSync(
      process.execPath,
      [rspackBin(), 'build', '-c', join(rspackDir, 'rspack.config.cjs')],
      { cwd: rspackDir, stdio: 'pipe', timeout: 100000 },
    );
    expect(
      rs.status,
      `rspack remote build: ${rs.stderr?.toString().slice(0, 600)}${rs.stdout
        ?.toString()
        .slice(0, 400)}`,
    ).toBe(0);
    // 표준 remote 산출 계약(P1-5 가 zntc 측으로 박제한 것의 표준 원본)
    expect((await readFile(join(rspackDist, 'mf-manifest.json'), 'utf8')).length).toBeGreaterThan(
      0,
    );

    // zntc host: P1-6 emit(init prelude + import("remote/x")→loadRemote).
    await writeFile(
      join(hostDir, 'index.ts'),
      `async function main(){ const m = await import("remote_mf2/Card");` +
        ` document.getElementById("out").textContent = (m && (m.default || m))();` +
        ` window.__done = true; }\n` +
        `main().catch((e) => { window.__err = String((e && e.stack) || e); window.__done = true; });`,
    );
    await writeFile(
      join(hostDir, 'zntc.config.json'),
      JSON.stringify({
        mf: { name: 'host', remotes: { remote_mf2: `remote_mf2@${rOrigin}/mf-manifest.json` } },
      }),
    );
    const hb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(hostDir, 'index.ts'),
        '-o',
        join(hostDir, 'host.js'),
        '--format=iife',
        '--platform=browser',
      ],
      { cwd: hostDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(hb.status, `zntc host build: ${hb.stderr?.toString().slice(0, 500)}`).toBe(0);

    await buildGlue(hostDir);
    // glue(__mf_runtime) → zntc host(prelude init + loadRemote 재작성).
    await writeFile(
      join(hostDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script src="./glue.js"></script></head><body><div id="out">pending</div>` +
        `<script src="./host.js"></script></body></html>`,
    );
    hostSrv = await serve(hostDir);

    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    // manifest-driven 증명(S3 대칭): runtime 이 rspack remote 의
    // mf-manifest.json 을 cross-origin http 로 실제 fetch.
    const seen: Record<string, number> = {};
    page.on('response', (r) => {
      if (r.url() === `${rOrigin}/mf-manifest.json`) seen.manifest = r.status();
    });
    await page.goto(`http://localhost:${hostSrv.port}/`);
    await page.waitForFunction(() => (window as { __done?: boolean }).__done === true, {
      timeout: 15000,
    });

    const err = await page.evaluate(() => (window as { __err?: string }).__err);
    expect(err, `zntc host runtime error: ${err}`).toBeFalsy();
    // zntc-emit host 가 실 @module-federation/runtime 으로 표준 rspack
    // remote 의 expose 를 manifest-driven 소비·렌더
    expect(await page.locator('#out').textContent()).toBe('RSPACK-REMOTE-OK');
    expect(seen.manifest, 'rspack remote mf-manifest.json fetched').toBe(200);
    expect(errors, `browser errors: ${errors.join(', ')}`).toHaveLength(0);
  } finally {
    if (remoteSrv) await closeServer(remoteSrv.server);
    if (hostSrv) await closeServer(hostSrv.server);
    await rm(rspackDir, { recursive: true, force: true });
    await rm(hostDir, { recursive: true, force: true });
  }
});

test('P2-5 다중 expose: 표준 runtime 이 zntc remote 의 2 expose 동시 로드', async ({ page }) => {
  test.setTimeout(90_000);
  const remoteDir = await mkdtemp(join(tmpdir(), 'zntc-mx-remote-'));
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-mx-host-'));
  let remoteSrv: Awaited<ReturnType<typeof serve>> | undefined;
  let hostSrv: Awaited<ReturnType<typeof serve>> | undefined;
  try {
    const remoteDist = join(remoteDir, 'dist');
    await mkdir(remoteDist, { recursive: true });
    remoteSrv = await serve(remoteDist, { 'Access-Control-Allow-Origin': '*' });
    const rOrigin = `http://localhost:${remoteSrv.port}`;
    await writeFile(join(remoteDir, 'A.ts'), `export default () => "A-OK";`);
    await writeFile(join(remoteDir, 'B.ts'), `export default () => "B-OK";`);
    await writeFile(join(remoteDir, 'index.ts'), `export const sentinel = "re";`);
    await writeFile(
      join(remoteDir, 'zntc.config.json'),
      JSON.stringify({ mf: { name: 'app', exposes: { './A': './A.ts', './B': './B.ts' } } }),
    );
    const rb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(remoteDir, 'index.ts'),
        '--outdir',
        remoteDist,
        '--format=iife',
        '--platform=browser',
        `--public-path=${rOrigin}/`,
      ],
      { cwd: remoteDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(rb.status, `build: ${rb.stderr?.toString().slice(0, 400)}`).toBe(0);
    // manifest 가 2 expose 정밀(P1-5/P2-0 동형)
    const mani = JSON.parse(await readFile(join(remoteDist, 'mf-manifest.json'), 'utf8'));
    expect(mani.exposes.length).toBe(2);

    await buildGlue(hostDir);
    await writeFile(
      join(hostDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script src="./glue.js"></script></head><body><div id="out">pending</div>` +
        `<script>(async()=>{try{var R=globalThis.__mf_runtime;` +
        `R.init({name:"h",remotes:[{name:"app",entry:${JSON.stringify(`${rOrigin}/mf-manifest.json`)}}]});` +
        `var a=await R.loadRemote("app/A");var b=await R.loadRemote("app/B");` +
        `document.getElementById("out").textContent=((a.default||a)())+","+((b.default||b)());` +
        `window.__done=true;}catch(e){window.__err=String(e&&e.stack||e);window.__done=true;}})();` +
        `</script></body></html>`,
    );
    hostSrv = await serve(hostDir);
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(`http://localhost:${hostSrv.port}/`);
    await page.waitForFunction(() => (window as { __done?: boolean }).__done === true, {
      timeout: 15000,
    });
    expect(await page.evaluate(() => (window as { __err?: string }).__err)).toBeFalsy();
    expect(await page.locator('#out').textContent()).toBe('A-OK,B-OK'); // 2 expose 동시
    expect(errors, errors.join(', ')).toHaveLength(0);
  } finally {
    if (remoteSrv) await closeServer(remoteSrv.server);
    if (hostSrv) await closeServer(hostSrv.server);
    await rm(remoteDir, { recursive: true, force: true });
    await rm(hostDir, { recursive: true, force: true });
  }
});

test('P2-5 shared singleton(실브라우저): host react ≡ zntc remote react', async ({ page }) => {
  // P1-4 shareScope→글로벌 seam 을 실 Chromium + manifest-driven + http
  // chunk 로 확증(Node S2 의 브라우저판 — P1-7 가 shared 는 이월했던 경로).
  // 빌드 3회(remote+glue+react-glue, react CJS 번들이 최중량) — CI cold
  // 마진 위해 120s(S4 동형).
  test.setTimeout(120_000);
  const remoteDir = await mkdtemp(join(tmpdir(), 'zntc-sh-remote-'));
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-sh-host-'));
  let remoteSrv: Awaited<ReturnType<typeof serve>> | undefined;
  let hostSrv: Awaited<ReturnType<typeof serve>> | undefined;
  try {
    const remoteDist = join(remoteDir, 'dist');
    await mkdir(remoteDist, { recursive: true });
    remoteSrv = await serve(remoteDist, { 'Access-Control-Allow-Origin': '*' });
    const rOrigin = `http://localhost:${remoteSrv.port}`;
    await writeFile(
      join(remoteDir, 'Widget.ts'),
      `import { useState } from "react";\n` +
        `export const usedHook = useState;\n` +
        `export default () => (typeof useState === "function" ? "SH-OK" : "SH-NO");`,
    );
    await writeFile(join(remoteDir, 'index.ts'), `export const sentinel = "re";`);
    await writeFile(
      join(remoteDir, 'zntc.config.json'),
      JSON.stringify({
        mf: {
          name: 'app',
          exposes: { './Widget': './Widget.ts' },
          shared: { react: { singleton: true, requiredVersion: '^19' } },
        },
      }),
    );
    const rb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(remoteDir, 'index.ts'),
        '--outdir',
        remoteDist,
        '--format=iife',
        '--platform=browser',
        `--public-path=${rOrigin}/`,
      ],
      { cwd: remoteDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(rb.status, `build: ${rb.stderr?.toString().slice(0, 400)}`).toBe(0);

    await buildGlue(hostDir); // __mf_runtime
    // host 가 자기 react 를 글로벌로 제공(P1-2 seam 의 host 책임)
    await buildIifeGlue(
      hostDir,
      'react-glue.ts',
      'react-glue.js',
      `import * as R from ${JSON.stringify(pkgEntry('react'))};\nglobalThis.__host_react = R.default || R;`,
    );
    await writeFile(
      join(hostDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script src="./glue.js"></script><script src="./react-glue.js"></script>` +
        `</head><body><div id="out">pending</div><script>(async()=>{try{` +
        `var R=globalThis.__mf_runtime, HR=globalThis.__host_react;` +
        `R.init({name:"h",remotes:[{name:"app",entry:${JSON.stringify(`${rOrigin}/mf-manifest.json`)}}],` +
        `shared:{react:{version:"19.2.4",lib:function(){return HR;},` +
        `shareConfig:{singleton:true,requiredVersion:"^19"}}}});` +
        `var m=await R.loadRemote("app/Widget");var W=(m&&(m.default||m));` +
        `document.getElementById("out").textContent=(typeof W==="function"?W():"NOFN");` +
        `window.__same=(m&&m.usedHook===HR.useState);window.__done=true;` +
        `}catch(e){window.__err=String(e&&e.stack||e);window.__done=true;}})();</script>` +
        `</body></html>`,
    );
    hostSrv = await serve(hostDir);
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    const seen: Record<string, number> = {};
    page.on('response', (r) => {
      if (r.url().includes('mf-manifest.json')) seen.manifest = r.status();
    });
    await page.goto(`http://localhost:${hostSrv.port}/`);
    await page.waitForFunction(() => (window as { __done?: boolean }).__done === true, {
      timeout: 15000,
    });
    expect(await page.evaluate(() => (window as { __err?: string }).__err)).toBeFalsy();
    expect(await page.locator('#out').textContent()).toBe('SH-OK'); // seam 채워짐
    // host react ≡ zntc remote react (singleton, 실브라우저 + http chunk)
    expect(await page.evaluate(() => (window as { __same?: boolean }).__same)).toBe(true);
    expect(seen.manifest, 'manifest fetched').toBe(200);
    expect(errors, errors.join(', ')).toHaveLength(0);
  } finally {
    if (remoteSrv) await closeServer(remoteSrv.server);
    if (hostSrv) await closeServer(hostSrv.server);
    await rm(remoteDir, { recursive: true, force: true });
    await rm(hostDir, { recursive: true, force: true });
  }
});

// P3-5 (#3440): D3 "빌드 핀 + 런타임 가드" 양쪽을 영구 박제.
// (A) 빌드-핀: 로컬 resolve 가능 remote 의 부재 expose import → 빌드
//     fail-fast(S6, P3-1). (B) 런타임-가드: http/도달불가 remote(빌드타임
//     검증 불가→skip)가 런타임에 거부 → __mfGuardedLoad 가 폴백, 셸
//     생존(white-screen 아님). 표준 @module-federation/[email protected].
test('P3-5 빌드-핀(S6): 로컬 remote 부재 expose import → 빌드 fail-fast', async () => {
  test.setTimeout(90_000);
  const remoteDir = await mkdtemp(join(tmpdir(), 'zntc-p35bf-remote-'));
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-p35bf-host-'));
  try {
    const remoteDist = join(remoteDir, 'dist');
    await mkdir(remoteDist, { recursive: true });
    await writeFile(join(remoteDir, 'Widget.ts'), `export default () => "OK";`);
    await writeFile(join(remoteDir, 'index.ts'), `export const s = "re";`);
    await writeFile(
      join(remoteDir, 'zntc.config.json'),
      JSON.stringify({ mf: { name: 'app', exposes: { './Widget': './Widget.ts' } } }),
    );
    const rb = spawnSync(
      ZNTC_BIN,
      ['--bundle', join(remoteDir, 'index.ts'), '--outdir', remoteDist, '--format=iife'],
      { cwd: remoteDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(rb.status, `remote build: ${rb.stderr?.toString().slice(0, 400)}`).toBe(0);
    const manifestAbs = join(remoteDist, 'mf-manifest.json');

    const buildHost = async (spec: string) => {
      await writeFile(
        join(hostDir, 'index.ts'),
        `async function m(){ const x = await import(${JSON.stringify(spec)}); console.log(x); }\nm();`,
      );
      await writeFile(
        join(hostDir, 'zntc.config.json'),
        JSON.stringify({ mf: { name: 'host', remotes: { app: `app@${manifestAbs}` } } }),
      );
      return spawnSync(
        ZNTC_BIN,
        ['--bundle', join(hostDir, 'index.ts'), '-o', join(hostDir, 'host.js'), '--format=iife'],
        { cwd: hostDir, stdio: 'pipe', timeout: 20000 },
      );
    };
    // 존재 expose → 빌드 성공(정밀 fail-fast: blanket 아님)
    expect((await buildHost('app/Widget')).status).toBe(0);
    // 부재 expose → 빌드 fail-fast(런타임 깨짐 아님)
    const bad = await buildHost('app/Missing');
    expect(bad.status).not.toBe(0);
    expect(bad.stderr?.toString()).toContain('MF expose 계약 위반');
  } finally {
    await rm(remoteDir, { recursive: true, force: true });
    await rm(hostDir, { recursive: true, force: true });
  }
});

test('P3-5 런타임-가드(실브라우저): 도달불가 remote → 폴백 렌더, 셸 생존', async ({ page }) => {
  test.setTimeout(90_000);
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-p35rg-host-'));
  let hostSrv: Awaited<ReturnType<typeof serve>> | undefined;
  try {
    // http 도달불가 remote(port 1=connection refused). http → P3-1/2/3
    // 빌드타임 검증 skip(검증 불가 ≠ 위반) → 빌드 성공 → 런타임 가드
    // 가 유일 안전망. m.__mfUnavailable 폴백 감지 → 셸 생존.
    // 폴백 모듈(F())의 default 를 **실제 호출** — noop 이 throw 없이
    // null 반환해야 실사용 셸 생존(GUARD_DEF default:()=>null 계약 회귀
    // 방어: __mfUnavailable 만 보면 default() 회귀를 못 잡음).
    await writeFile(
      join(hostDir, 'index.ts'),
      `async function main(){ const m = await import("app/Widget");` +
        ` const v = (m && (m.default || m))();` +
        ` document.getElementById("out").textContent =` +
        ` (m && m.__mfUnavailable && v === null) ? "GUARD-OK"` +
        ` : ("NO-GUARD:" + String(m && m.__mfUnavailable) + ":" + String(v));` +
        ` window.__done = true; }\n` +
        `main().catch((e) => { window.__err = String((e && e.stack) || e); window.__done = true; });`,
    );
    await writeFile(
      join(hostDir, 'zntc.config.json'),
      JSON.stringify({
        mf: { name: 'host', remotes: { app: 'app@http://127.0.0.1:1/mf-manifest.json' } },
      }),
    );
    const hb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(hostDir, 'index.ts'),
        '-o',
        join(hostDir, 'host.js'),
        '--format=iife',
        '--platform=browser',
      ],
      { cwd: hostDir, stdio: 'pipe', timeout: 20000 },
    );
    // http remote 라 빌드타임 검증 skip → 빌드 성공(런타임 가드 시나리오)
    expect(hb.status, `zntc host build: ${hb.stderr?.toString().slice(0, 500)}`).toBe(0);

    await buildGlue(hostDir);
    await writeFile(
      join(hostDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script src="./glue.js"></script></head><body><div id="out">pending</div>` +
        `<script src="./host.js"></script></body></html>`,
    );
    hostSrv = await serve(hostDir);

    const pageErrors: string[] = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    const consoleErrs: string[] = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrs.push(msg.text());
    });
    await page.goto(`http://localhost:${hostSrv.port}/`);
    await page.waitForFunction(() => (window as { __done?: boolean }).__done === true, {
      timeout: 20000,
    });

    // 가드가 거부를 catch → main() 정상 완료(throw 아님), 셸 생존
    expect(await page.evaluate(() => (window as { __err?: string }).__err)).toBeFalsy();
    expect(await page.locator('#out').textContent()).toBe('GUARD-OK');
    // 폴백은 silent 아님 — 관측가능한 console.error
    expect(
      consoleErrs.some((t) => t.includes('[mf] runtime guard')),
      `console errors: ${consoleErrs.join(' | ')}`,
    ).toBe(true);
    // unhandled pageerror 없음(가드가 흡수 — white-screen 방지)
    expect(pageErrors, `pageerror: ${pageErrors.join(', ')}`).toHaveLength(0);
  } finally {
    if (hostSrv) await closeServer(hostSrv.server);
    await rm(hostDir, { recursive: true, force: true });
  }
});

// P3-5 보강: 런타임 가드는 **네트워크 거부만이 아니라 모든 loadRemote
// 거부**(expose 런타임 부재 등)를 흡수해야 한다. reachable zntc remote
// (./Widget)를 http 서빙하되 host 는 부재 expose `app/Missing` import →
// http remote 라 빌드타임 P3-1 skip(빌드 성공) → 표준 runtime
// loadRemote 가 expose-missing 으로 reject → 가드 폴백 → 셸 생존.
test('P3-5 런타임-가드(실브라우저): 도달가능 remote의 런타임 expose 부재 → 폴백', async ({
  page,
}) => {
  test.setTimeout(90_000);
  const remoteDir = await mkdtemp(join(tmpdir(), 'zntc-p35rg2-remote-'));
  const hostDir = await mkdtemp(join(tmpdir(), 'zntc-p35rg2-host-'));
  let remoteSrv: Awaited<ReturnType<typeof serve>> | undefined;
  let hostSrv: Awaited<ReturnType<typeof serve>> | undefined;
  try {
    const remoteDist = join(remoteDir, 'dist');
    await mkdir(remoteDist, { recursive: true });
    remoteSrv = await serve(remoteDist, { 'Access-Control-Allow-Origin': '*' });
    const rOrigin = `http://localhost:${remoteSrv.port}`;
    await writeFile(join(remoteDir, 'Widget.ts'), `export default () => "REAL";`);
    await writeFile(join(remoteDir, 'index.ts'), `export const sentinel = "re";`);
    await writeFile(
      join(remoteDir, 'zntc.config.json'),
      JSON.stringify({ mf: { name: 'app', exposes: { './Widget': './Widget.ts' } } }),
    );
    const rb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(remoteDir, 'index.ts'),
        '--outdir',
        remoteDist,
        '--format=iife',
        '--platform=browser',
        `--public-path=${rOrigin}/`,
      ],
      { cwd: remoteDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(rb.status, `remote build: ${rb.stderr?.toString().slice(0, 400)}`).toBe(0);

    // host 는 **존재하지 않는** expose import. http manifest entry →
    // 빌드타임 P3-1 검증 skip(네트워크=비-목표) → 빌드 성공.
    await writeFile(
      join(hostDir, 'index.ts'),
      `async function main(){ const m = await import("app/Missing");` +
        ` const v = (m && (m.default || m))();` +
        ` document.getElementById("out").textContent =` +
        ` (m && m.__mfUnavailable && v === null) ? "GUARD-OK"` +
        ` : ("NO-GUARD:" + String(m && m.__mfUnavailable) + ":" + String(v));` +
        ` window.__done = true; }\n` +
        `main().catch((e) => { window.__err = String((e && e.stack) || e); window.__done = true; });`,
    );
    await writeFile(
      join(hostDir, 'zntc.config.json'),
      JSON.stringify({
        mf: { name: 'host', remotes: { app: `app@${rOrigin}/mf-manifest.json` } },
      }),
    );
    const hb = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(hostDir, 'index.ts'),
        '-o',
        join(hostDir, 'host.js'),
        '--format=iife',
        '--platform=browser',
      ],
      { cwd: hostDir, stdio: 'pipe', timeout: 20000 },
    );
    expect(hb.status, `host build: ${hb.stderr?.toString().slice(0, 500)}`).toBe(0);

    await buildGlue(hostDir);
    await writeFile(
      join(hostDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script src="./glue.js"></script></head><body><div id="out">pending</div>` +
        `<script src="./host.js"></script></body></html>`,
    );
    hostSrv = await serve(hostDir);

    const pageErrors: string[] = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    const consoleErrs: string[] = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrs.push(msg.text());
    });
    await page.goto(`http://localhost:${hostSrv.port}/`);
    await page.waitForFunction(() => (window as { __done?: boolean }).__done === true, {
      timeout: 20000,
    });

    expect(await page.evaluate(() => (window as { __err?: string }).__err)).toBeFalsy();
    // expose-missing reject(네트워크 아님) 도 가드가 흡수 → 폴백 noop=null
    expect(await page.locator('#out').textContent()).toBe('GUARD-OK');
    expect(
      consoleErrs.some((t) => t.includes('[mf] runtime guard')),
      `console errors: ${consoleErrs.join(' | ')}`,
    ).toBe(true);
    expect(pageErrors, `pageerror: ${pageErrors.join(', ')}`).toHaveLength(0);
  } finally {
    if (remoteSrv) await closeServer(remoteSrv.server);
    if (hostSrv) await closeServer(hostSrv.server);
    await rm(remoteDir, { recursive: true, force: true });
    await rm(hostDir, { recursive: true, force: true });
  }
});
