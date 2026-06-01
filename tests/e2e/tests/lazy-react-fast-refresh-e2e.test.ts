import { test, expect } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { writeFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { waitForServer } from '@zntc/test-helpers';
import { PORTS } from './ports';

// RFC_LAZY_DEV_MODULE_HMR §5 수용 기준 — **lazy split 버전**. `zntc dev --lazy` 에서
// 동적 import 로 코드 스플릿된 라우트의 React 컴포넌트를 편집하면, 단일 번들과 동일하게
// (a) 변경 반영 (b) **페이지 리로드 없이**(window marker 생존) (c) **컴포넌트 state 보존**
// (카운터 값 유지) 돼야 한다. 단일 번들 버전(react-fast-refresh-e2e.test.ts)은 이미 green;
// 이 테스트는 그 경로가 lazy 동적 청크에도 성립함을 닫는다(= 에픽 완결 신호).
//
// 핵심 타이밍: 첫 방문 시 watch 가 라우트 seed 를 materialize(force-parse)하며 **1회**
// graph_changed full-reload 가 발생(#4085, watch.zig:1391). 그래서 marker/state 를 세팅하기
// *전에* materialize 가 안정될 때까지 기다린 뒤 한 번 reload 해 깨끗한 post-materialize 상태로
// 만든다. 이후 컴포넌트 편집은 graph 안정 → updates 경로 → Fast Refresh accept → 리로드 없음.
//
// fixture 는 tests/e2e 하위에 만들어 react/react-dom/react-refresh 가 tests/e2e/node_modules
// 로 resolve 되게 한다(tmp /tmp 면 resolve 실패).

const ZNTC_JS_CLI = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const PORT = PORTS.LAZY_REACT_FAST_REFRESH;

// 동적 import 로 분리되는 라우트 컴포넌트(= lazy split 청크의 Fast Refresh 경계).
const ROUTE_V1 =
  "import { useState } from 'react';\n" +
  'export function Route() {\n' +
  '  const [n, setN] = useState(0);\n' +
  '  return (\n' +
  '    <div>\n' +
  '      <span data-testid="ver">LAZY_COUNTER_V1</span>\n' +
  '      <span data-testid="count">{n}</span>\n' +
  '      <button data-testid="inc" onClick={() => setN((x) => x + 1)}>inc</button>\n' +
  '    </div>\n' +
  '  );\n' +
  '}\n';

const FILES: Record<string, string> = {
  'index.html':
    '<!doctype html><html><head><meta charset="utf-8"/><title>LazyRFR</title></head>' +
    '<body><div id="root">loading</div>' +
    '<script type="module" src="/src/main.tsx"></script></body></html>',
  // 라우트를 *동적 import* 해 코드 스플릿 → lazy 청크. 로드되면 #root 에 렌더.
  'src/main.tsx':
    "import { createRoot } from 'react-dom/client';\n" +
    "const root = createRoot(document.getElementById('root'));\n" +
    "import('./Route').then(({ Route }) => root.render(<Route />));\n",
  'src/Route.tsx': ROUTE_V1,
};

test.describe.serial('Lazy split React Fast Refresh (zntc dev --lazy)', () => {
  let dir: string;
  let server: ChildProcess | null = null;

  test.beforeAll(async () => {
    dir = await mkdtemp(join(__dirname, '..', 'lazy-rfr-fixture-'));
    for (const [name, content] of Object.entries(FILES)) {
      const fp = join(dir, name);
      await mkdir(join(fp, '..'), { recursive: true });
      await writeFile(fp, content);
    }
    server = spawn(
      'bun',
      [ZNTC_JS_CLI, 'dev', dir, '--port', String(PORT), '--lazy', '--jsx=automatic-dev'],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    await waitForServer(PORT);
  });

  test.afterAll(async () => {
    server?.kill();
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  // materialize(force-parse rebuild)가 완료돼 라우트 청크가 outdir 에 emit 될 때까지 폴링.
  const outdir = () => join(dir, '.zntc-dev');
  const materialized = () => {
    try {
      return readdirSync(outdir()).some((f) => /Route-[0-9a-f]{8}\.js$/.test(f));
    } catch {
      return false;
    }
  };

  test('lazy 라우트 컴포넌트 편집 → 리로드 없이 반영 + 카운터 state 보존', async ({ page }) => {
    await page.goto(`http://localhost:${PORT}/`);
    // 동적 청크 on-demand 로드 → 라우트 렌더.
    await expect(page.getByTestId('ver')).toHaveText('LAZY_COUNTER_V1', { timeout: 20000 });

    // 첫 materialize(force-parse)는 graph_changed full-reload 를 1회 유발(#4085). 그게 끝나
    // 페이지가 안정될 때까지 기다린다 — probe marker 가 1.5s 생존하면 더 이상 reload 가 없다는
    // 뜻(materialize 완료). 이후의 편집만이 updates(Fast Refresh)를 만든다. (명시적 page.reload()는
    // materialize 의 auto-reload 와 경합해 ERR_ABORTED 나므로 쓰지 않는다.)
    for (let i = 0; i < 150 && !materialized(); i++) await page.waitForTimeout(100);
    expect(materialized()).toBe(true);
    let stable = false;
    for (let i = 0; i < 15 && !stable; i++) {
      try {
        await page.evaluate(() => ((window as { __stab?: string }).__stab = 'S'));
        await page.waitForTimeout(1500);
        stable = await page.evaluate(() => (window as { __stab?: string }).__stab === 'S');
      } catch {
        stable = false; // reload 로 실행 컨텍스트 파괴 → 재시도
      }
    }
    expect(stable).toBe(true);
    await expect(page.getByTestId('ver')).toHaveText('LAZY_COUNTER_V1', { timeout: 20000 });

    // state 를 올린다(카운터 → 2).
    await page.getByTestId('inc').click();
    await page.getByTestId('inc').click();
    await expect(page.getByTestId('count')).toHaveText('2');

    // 리로드 시 사라지는 window marker.
    await page.evaluate(() => ((window as { __rfMarker?: string }).__rfMarker = 'KEEP_ME'));

    // 라우트 컴포넌트 본문만 편집(hook signature 동일 → Fast Refresh 가 state 보존).
    writeFileSync(
      join(dir, 'src/Route.tsx'),
      ROUTE_V1.replace('LAZY_COUNTER_V1', 'LAZY_COUNTER_V2'),
    );

    // (a) 변경 반영.
    await expect(page.getByTestId('ver')).toHaveText('LAZY_COUNTER_V2', { timeout: 20000 });
    // (b) 리로드 없음(marker 생존) + (c) state 보존(카운터 여전히 2).
    expect(await page.evaluate(() => (window as { __rfMarker?: string }).__rfMarker)).toBe(
      'KEEP_ME',
    );
    await expect(page.getByTestId('count')).toHaveText('2');
  });
});
