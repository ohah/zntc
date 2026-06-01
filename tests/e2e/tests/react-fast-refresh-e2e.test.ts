import { test, expect } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { waitForServer } from '@zntc/test-helpers';
import { PORTS } from './ports';

// React Fast Refresh (web native `zntc dev`) — RFC_LAZY_DEV_MODULE_HMR §5 수용 기준의
// 메인-번들 버전. 컴포넌트 파일 편집 → (a) 변경 반영 (b) **페이지 리로드 없이**(window
// marker 생존) (c) **컴포넌트 state 보존**(카운터 값 유지). dev 서버가 react-refresh 런타임
// preamble 을 앱보다 먼저 주입(injectIntoGlobalHook)하고, 번들러가 컴포넌트에 $RefreshReg$ +
// `__zntc_make_hot(id).accept(boundary)` 를 emit 한 뒤, watch rebuild → module update broadcast
// → __zntc_apply_update → performReactRefresh 로 state 를 보존한 채 재렌더한다.
//
// fixture 는 tests/e2e 하위에 만들어 react/react-dom/react-refresh 가 tests/e2e/node_modules
// 로 resolve 되게 한다(tmp /tmp 면 resolve 실패).

const ZNTC_JS_CLI = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const PORT = PORTS.REACT_FAST_REFRESH;

// classic JSX(React.createElement) + 명시 `import * as React` — automatic JSX runtime
// import 의 dev-mode 바인딩 이슈와 무관하게 Fast Refresh 자체를 가드한다.
const APP_V1 =
  "import * as React from 'react';\n" +
  'export function App() {\n' +
  '  const [n, setN] = React.useState(0);\n' +
  '  return (\n' +
  '    <div>\n' +
  '      <span data-testid="ver">COUNTER_V1</span>\n' +
  '      <span data-testid="count">{n}</span>\n' +
  '      <button data-testid="inc" onClick={() => setN((x) => x + 1)}>inc</button>\n' +
  '    </div>\n' +
  '  );\n' +
  '}\n';

const FILES: Record<string, string> = {
  'index.html':
    '<!doctype html><html><head><meta charset="utf-8"/><title>RFR</title></head>' +
    '<body><div id="root">loading</div>' +
    '<script type="module" src="/src/main.tsx"></script></body></html>',
  'src/main.tsx':
    "import * as React from 'react';\n" +
    "import { createRoot } from 'react-dom/client';\n" +
    "import { App } from './App';\n" +
    "createRoot(document.getElementById('root')).render(<App />);\n",
  'src/App.tsx': APP_V1,
};

test.describe.serial('React Fast Refresh (web native zntc dev)', () => {
  let dir: string;
  let server: ChildProcess | null = null;

  test.beforeAll(async () => {
    // tests/e2e 하위에 fixture 생성 → node_modules resolution 이 tests/e2e/node_modules 도달.
    dir = await mkdtemp(join(__dirname, '..', 'rfr-fixture-'));
    for (const [name, content] of Object.entries(FILES)) {
      const fp = join(dir, name);
      await mkdir(join(fp, '..'), { recursive: true });
      await writeFile(fp, content);
    }
    server = spawn('bun', [ZNTC_JS_CLI, 'dev', dir, '--port', String(PORT)], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    await waitForServer(PORT);
  });

  test.afterAll(async () => {
    server?.kill();
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  test('preamble 이 앱보다 먼저 주입되고 react-refresh 런타임을 글로벌에 노출', async ({
    page,
  }) => {
    await page.goto(`http://localhost:${PORT}/`);
    await expect(page.getByTestId('ver')).toHaveText('COUNTER_V1', { timeout: 15000 });
    // preamble 이 injectIntoGlobalHook + __ReactRefresh 를 깔았다.
    const installed = await page.evaluate(
      () =>
        (window as { __zntc_react_refresh_preamble__?: boolean })
          .__zntc_react_refresh_preamble__ === true &&
        typeof (window as { __ReactRefresh?: unknown }).__ReactRefresh === 'object',
    );
    expect(installed).toBe(true);
  });

  test('컴포넌트 편집 → 리로드 없이 반영 + 카운터 state 보존', async ({ page }) => {
    await page.goto(`http://localhost:${PORT}/`);
    await expect(page.getByTestId('ver')).toHaveText('COUNTER_V1', { timeout: 15000 });

    // state 를 올린다(카운터 → 2).
    await page.getByTestId('inc').click();
    await page.getByTestId('inc').click();
    await expect(page.getByTestId('count')).toHaveText('2');

    // 리로드 시 사라지는 window marker.
    await page.evaluate(() => ((window as { __rfMarker?: string }).__rfMarker = 'KEEP_ME'));

    // 컴포넌트 본문만 편집(hook signature 동일 → Fast Refresh 가 state 보존).
    writeFileSync(join(dir, 'src/App.tsx'), APP_V1.replace('COUNTER_V1', 'COUNTER_V2'));

    // (a) 변경 반영.
    await expect(page.getByTestId('ver')).toHaveText('COUNTER_V2', { timeout: 15000 });
    // (b) 리로드 없음(marker 생존) + (c) state 보존(카운터 여전히 2).
    expect(await page.evaluate(() => (window as { __rfMarker?: string }).__rfMarker)).toBe(
      'KEEP_ME',
    );
    await expect(page.getByTestId('count')).toHaveText('2');
  });
});
