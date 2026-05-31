import { test, expect } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { writeFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { waitForServer } from '@zntc/test-helpers';

// #4079 dev materialize — 실제 브라우저로 lazy compilation 의 end-to-end 를 닫는다:
//   (1) lazy 라우트 방문 → on-demand 컴파일 + cross-chunk 런타임(__zntc_load_chunk/__zntc_require)
//       이 브라우저에서 동작해 라우트가 렌더된다.
//   (2) 라우트 *안쪽 깊은 파일*(route → Chart → util, 2단계) 편집 → watch 가 그 seed 를
//       materialize 해 깊은 파일을 감시 중이므로 rebuild → HMR(full reload) → 화면 갱신.
// (2) 가 #4079 가 고친 핵심 — materialize 전엔 깊은 파일이 unwatched 라 편집해도 무반응이었다.

const ZNTC_JS_CLI = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const PORT = 3971;

const FILES: Record<string, string> = {
  'index.html':
    '<!doctype html><html><head><meta charset="utf-8"/><title>Lazy</title></head>' +
    '<body><div id="root" data-testid="out">loading</div>' +
    '<script type="module" src="/src/main.ts"></script></body></html>',
  // 진입 시 lazy 라우트를 동적 import 해 그 출력을 #root 에 렌더.
  'src/main.ts':
    "async function go(){ const m = await import('./route'); " +
    "document.getElementById('root')!.textContent = m.render(); }\ngo();",
  'src/route.ts': "import { chart } from './Chart';\nexport function render(){ return chart(); }",
  'src/Chart.ts': "import { fmt } from './util';\nexport function chart(){ return fmt('chart'); }",
  'src/util.ts': "export function fmt(s: string){ return 'UTIL_V1[' + s + ']'; }",
};

test.describe.serial('lazy dev materialize (브라우저 e2e #4079)', () => {
  let dir: string;
  let server: ChildProcess | null = null;

  test.beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), 'zntc-lazy-e2e-'));
    for (const [name, content] of Object.entries(FILES)) {
      const fp = join(dir, name);
      await mkdir(join(fp, '..'), { recursive: true });
      await writeFile(fp, content);
    }
    server = spawn('bun', [ZNTC_JS_CLI, 'dev', dir, '--port', String(PORT), '--lazy'], {
      env: { ...process.env, ZNTC_LAZY: '' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    await waitForServer(PORT);
  });

  test.afterAll(async () => {
    server?.kill();
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  test('lazy 라우트 방문 → 브라우저에서 렌더(cross-chunk 런타임)', async ({ page }) => {
    await page.goto(`http://localhost:${PORT}/`);
    // entry 로드 → __zntc_load_chunk(route 청크) on-demand fetch → __zntc_require resolve → 렌더.
    await expect(page.getByTestId('out')).toHaveText('UTIL_V1[chart]', { timeout: 15000 });
  });

  test('라우트 안쪽 깊은 파일(util.ts, 2단계) 편집 → HMR 로 화면 갱신(#4079 핵심)', async ({
    page,
  }) => {
    await page.goto(`http://localhost:${PORT}/`);
    await expect(page.getByTestId('out')).toHaveText('UTIL_V1[chart]', { timeout: 15000 });

    // 방문 직후엔 materialize(force-parse rebuild)가 진행 중일 수 있다 — util 이 watch 그래프에
    // 들어가 감시되기까지 기다린다. 고정 sleep 대신 라우트 청크가 outdir 에 emit(=materialize 완료,
    // subtree 감시 시작)될 때까지 폴링(결정론적, 느린 CI 에도 안정).
    const outdir = join(dir, '.zntc-dev');
    const materialized = () => {
      try {
        return readdirSync(outdir).some((f) => /route-[0-9a-f]{8}\.js$/.test(f));
      } catch {
        return false;
      }
    };
    for (let i = 0; i < 100 && !materialized(); i++) await page.waitForTimeout(100);
    expect(materialized()).toBe(true);

    // 깊은 파일 편집 → watch rebuild → lazy 모드 full-reload HMR 로 화면이 *자동* 갱신돼야 한다
    // (수동 새로고침 없이). lazy split 청크는 module-level HMR 불가라 full-reload 로 갈음.
    writeFileSync(
      join(dir, 'src/util.ts'),
      "export function fmt(s: string){ return 'UTIL_V2[' + s + ']'; }",
    );
    await expect(page.getByTestId('out')).toHaveText('UTIL_V2[chart]', { timeout: 15000 });
  });

  // 에픽 수용 기준(RFC_LAZY_DEV_MODULE_HMR §5) — 이상적 fix: 깊은 파일 편집이 *리로드 없이*
  // 모듈만 hot-replace 되고 앱 state 가 보존돼야 한다(main 번들 HMR 동급). 현재는 full-reload
  // 폴백이라 window state 가 소실돼 fail → test.fixme 로 목표만 명시. 에픽(split dev 모듈별 HMR,
  // #4038 재해결) 완료 시 일반 test 로 전환한다.
  test.fixme('이상적: 깊은 파일 편집이 리로드 없이 hot-replace + 앱 state 보존', async ({
    page,
  }) => {
    await page.goto(`http://localhost:${PORT}/`);
    await expect(page.getByTestId('out')).toContainText('[chart]', { timeout: 15000 });
    // 리로드 시 사라지는 사용자 state.
    await page.evaluate(() => ((window as any).__userState = 'KEEP_ME'));

    writeFileSync(
      join(dir, 'src/util.ts'),
      "export function fmt(s: string){ return 'UTIL_V3[' + s + ']'; }",
    );
    // (a) 변경 반영 + (b) 리로드 없음(state 생존) = 진짜 module HMR.
    await expect(page.getByTestId('out')).toHaveText('UTIL_V3[chart]', { timeout: 15000 });
    expect(await page.evaluate(() => (window as any).__userState)).toBe('KEEP_ME');
  });
});
