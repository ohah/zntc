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
 * S4 역방향(zntc host → 표준 rspack+@module-federation/enhanced remote)은
 * RFC §8.1 상 P1-비차단(S3 가 양방향 *계약* 증명 + Node host-emit 스모크가
 * zntc-host 로직 박제) → 별도 후속 이슈.
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

    // zntc 로 표준 runtime → iife glue 번들(globalThis.__mf_runtime 제공).
    await writeFile(
      join(hostDir, 'glue.ts'),
      `import * as mf from ${JSON.stringify(runtimeEsmEntry())};\n` +
        `globalThis.__mf_runtime = mf;`,
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
