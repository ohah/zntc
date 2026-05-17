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

// 표준 runtime 의 ESM 진입(package.json `module`) 절대경로. e2e 워크스페이스
// (tests/e2e/package.json devDep)에서 resolve — zntc 가 이걸 iife glue 로
// 번들(bare nested deps 포함)해 `globalThis.__mf_runtime` 제공(P1-6 seam 짝).
function runtimeEsmEntry(): string {
  const req = createRequire(join(__dirname, 'noop.js'));
  const pkgJson = req.resolve('@module-federation/runtime/package.json');
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

// zntc 로 표준 @module-federation/runtime(ESM, bare nested deps)을 iife glue
// 로 번들 → host 페이지가 <script> 로 먼저 로드해 globalThis.__mf_runtime
// 제공(P1-6 글로벌-seam 짝). S3/S4 공용.
async function buildGlue(hostDir: string): Promise<void> {
  await writeFile(
    join(hostDir, 'glue.ts'),
    `import * as mf from ${JSON.stringify(runtimeEsmEntry())};\nglobalThis.__mf_runtime = mf;`,
  );
  const gb = spawnSync(
    ZNTC_BIN,
    [
      '--bundle',
      join(hostDir, 'glue.ts'),
      '-o',
      join(hostDir, 'glue.js'),
      '--format=iife',
      '--platform=browser',
    ],
    { cwd: hostDir, stdio: 'pipe', timeout: 20000 },
  );
  expect(gb.status, `zntc glue build: ${gb.stderr?.toString().slice(0, 500)}`).toBe(0);
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
