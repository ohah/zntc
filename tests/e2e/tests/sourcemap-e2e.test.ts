import { test, expect } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PORTS } from './ports';

const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');
const TEST_PORT = PORTS.SOURCEMAP;

// 10줄 소스 — "console.log(greeting)"은 10번째 줄(0-indexed 9)로 CDP breakpoint 테스트에 사용.
const APP_TS = `
const greeting: string = "hello from source map";
function render(el: HTMLElement): void {
  el.textContent = greeting;
}
const root = document.getElementById("root");
if (root) {
  render(root);
}
console.log(greeting);
`;

let server: ChildProcess | null = null;
let fixtureDir: string;

test.beforeAll(async ({ request }) => {
  fixtureDir = await mkdtemp(join(tmpdir(), 'zntc-sourcemap-e2e-'));
  await writeFile(join(fixtureDir, 'app.ts'), APP_TS);

  server = spawn(
    ZNTC_BIN,
    ['--serve', '--bundle', join(fixtureDir, 'app.ts'), '--sourcemap', '--port', String(TEST_PORT)],
    { stdio: 'pipe' },
  );

  // 서버 준비 대기
  await new Promise((resolve) => setTimeout(resolve, 2000));
  // 서버는 on-demand 번들링 — .map 요청 전에 bundle.js를 한 번 warm-up
  await request.get(`http://localhost:${TEST_PORT}/bundle.js`);
});

test.afterAll(async () => {
  if (server) {
    server.kill();
    await new Promise((resolve) => server!.on('close', resolve));
  }
  await rm(fixtureDir, { recursive: true, force: true });
});

test.describe('Source map E2E', () => {
  test('bundle.js.map이 서빙되고 구조가 유효하다', async ({ request }) => {
    const res = await request.get(`http://localhost:${TEST_PORT}/bundle.js.map`);
    expect(res.status()).toBe(200);

    const map = await res.json();
    expect(map.version).toBe(3);
    expect(Array.isArray(map.sources)).toBe(true);
    expect(map.sources.length).toBeGreaterThan(0);
    expect(typeof map.mappings).toBe('string');
    expect(map.mappings.length).toBeGreaterThan(0);

    // sources 배열에 원본 TS가 있어야 함
    const appTsIdx = map.sources.findIndex((s: string) => s.endsWith('app.ts'));
    expect(appTsIdx).toBeGreaterThanOrEqual(0);

    // sourcesContent에 원본 TS 내용이 포함되어야 함
    expect(Array.isArray(map.sourcesContent)).toBe(true);
    expect(map.sourcesContent[appTsIdx]).toContain('hello from source map');
    expect(map.sourcesContent[appTsIdx]).toContain('function render(el: HTMLElement): void');
  });

  test('bundle.js에 sourceMappingURL 주석이 있다', async ({ request }) => {
    const res = await request.get(`http://localhost:${TEST_PORT}/bundle.js`);
    expect(res.status()).toBe(200);
    const js = await res.text();
    expect(js).toMatch(/\/\/[#@]\s*sourceMappingURL=/);
  });

  test('Chromium이 번들을 파싱하고 sourceMapURL을 인식한다 (CDP)', async ({ page, context }) => {
    const cdp = await context.newCDPSession(page);
    await cdp.send('Debugger.enable');

    // bundle.js가 파싱되면 sourceMapURL 필드가 채워져 있어야 함 (Chromium이 소스맵 URL 인식)
    const jsScriptPromise = new Promise<{ scriptId: string; sourceMapURL: string }>(
      (resolve, reject) => {
        const timeout = setTimeout(
          () => reject(new Error('bundle.js script not parsed within 5s')),
          5000,
        );
        cdp.on('Debugger.scriptParsed', (evt) => {
          if (evt.url.endsWith('bundle.js')) {
            clearTimeout(timeout);
            resolve({ scriptId: evt.scriptId, sourceMapURL: evt.sourceMapURL });
          }
        });
      },
    );

    await page.goto(`http://localhost:${TEST_PORT}/`);

    const js = await jsScriptPromise;
    // Chromium CDP는 sourceMappingURL 주석을 읽어 scriptParsed 이벤트의 sourceMapURL 필드에 채움
    expect(js.sourceMapURL).toBeTruthy();
    expect(js.sourceMapURL).toMatch(/bundle\.js\.map$/);

    // DevTools가 원본 JS 소스를 가져올 수 있어야 함
    const source = (await cdp.send('Debugger.getScriptSource', {
      scriptId: js.scriptId,
    })) as { scriptSource: string };
    expect(source.scriptSource).toContain('hello from source map');
  });

  test('TS 소스 파일명으로 breakpoint를 설정할 수 있다 (CDP)', async ({ page, context }) => {
    const cdp = await context.newCDPSession(page);
    await cdp.send('Debugger.enable');

    // urlRegex로 app.ts 패턴 지정 → setBreakpointByUrl은 lazy로 처리되며
    // Chromium이 소스맵을 읽어 실제 번들 JS의 매핑된 위치에 breakpoint를 건다.
    const br = (await cdp.send('Debugger.setBreakpointByUrl', {
      urlRegex: '.*app\\.ts$',
      lineNumber: 9, // `console.log(greeting);` 는 TS 10번째 줄 (0-indexed 9)
      columnNumber: 0,
    })) as {
      breakpointId: string;
      locations: Array<{ scriptId: string; lineNumber: number; columnNumber: number }>;
    };

    await page.goto(`http://localhost:${TEST_PORT}/`, { waitUntil: 'domcontentloaded' });

    expect(br.breakpointId).toBeTruthy();
    expect(Array.isArray(br.locations)).toBe(true);
  });
});
