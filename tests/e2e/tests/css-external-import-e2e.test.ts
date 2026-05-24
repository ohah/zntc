import { test, expect } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { serve, closeServer } from './serve';

/**
 * CSS external `@import` URL preservation E2E — bundler 가 보존한
 * `@import "https://..."` 가 실제 브라우저에서 fetch + cascade 적용되는지
 * 검증한다 (#3321 P0-3).
 *
 * 통합 테스트(bun test)는 출력 CSS 의 `@import` 라인 존재까지만 본다.
 * 본 테스트는 page.route 로 external URL 응답을 mock 해서 실 브라우저
 * 가 그 stylesheet 를 fetch + 적용하는 전 과정을 검증.
 */
const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');

const FIXTURE: Record<string, string> = {
  'index.ts': `
import "./style.css";
const box = document.createElement('div');
box.setAttribute('data-testid', 'box');
box.textContent = 'hello';
document.body.appendChild(box);
(window as any).__loaded = true;
`,
  // 의도적으로 흔치 않은 색 → mock external 가 응답한 것만 적용 검증
  'style.css':
    `@import "https://cdn.zntc-e2e.test/external.css";\n` + `.local { color: rgb(7, 7, 7); }`,
};

test('external @import URL 이 브라우저 fetch + cascade 적용된다', async ({ page }) => {
  const dir = await mkdtemp(join(tmpdir(), 'zntc-css-ext-e2e-'));
  try {
    for (const [name, content] of Object.entries(FIXTURE)) {
      await writeFile(join(dir, name), content);
    }
    const dist = join(dir, 'dist');
    await mkdir(dist, { recursive: true });

    const build = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(dir, 'index.ts'),
        '-o',
        join(dist, 'index.js'),
        '--format=esm',
        '--platform=browser',
      ],
      { stdio: 'pipe', timeout: 15000 },
    );
    expect(build.status, `ZNTC build failed: ${build.stderr?.toString().slice(0, 400)}`).toBe(0);

    // bundler 가 external @import 를 보존했는지 빌드 산출물 단계 가드
    const builtCss = await readFile(join(dist, 'index.css'), 'utf-8');
    expect(builtCss).toContain('@import "https://cdn.zntc-e2e.test/external.css"');
    expect(builtCss.indexOf('@import')).toBeLessThan(builtCss.indexOf('.local'));

    await writeFile(
      join(dist, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8"><link rel="stylesheet" href="./index.css"></head><body><script type="module" src="./index.js"></script></body></html>`,
    );

    // mock external CSS — 실 네트워크 의존성 제거
    let externalFetched = false;
    await page.route('https://cdn.zntc-e2e.test/external.css', async (route) => {
      externalFetched = true;
      await route.fulfill({
        status: 200,
        contentType: 'text/css',
        body: `[data-testid="box"] { background-color: rgb(3, 4, 5); }`,
      });
    });

    const { server, port } = await serve(dist);
    try {
      const errors: string[] = [];
      page.on('pageerror', (e) => errors.push(e.message));

      await page.goto(`http://localhost:${port}/`);
      await page.waitForFunction(() => (window as any).__loaded === true, {
        timeout: 5000,
      });

      // 브라우저가 external @import URL 을 실제로 fetch 했는지
      expect(externalFetched, 'external @import URL was not fetched by browser').toBe(true);

      // external stylesheet 가 cascade 에 들어가 box 에 적용됐는지 (background)
      // + 로컬 규칙 (.local 은 안 붙임) 과 별개로 background 만 검증.
      const bg = await page.evaluate(() => {
        const el = document.querySelector('[data-testid="box"]')!;
        return getComputedStyle(el).backgroundColor;
      });
      expect(bg).toBe('rgb(3, 4, 5)');

      expect(errors, `browser errors: ${errors.join(', ')}`).toHaveLength(0);
    } finally {
      await closeServer(server);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('external @import + media query → media clause 가 브라우저에 전달된다', async ({ page }) => {
  const dir = await mkdtemp(join(tmpdir(), 'zntc-css-ext-mq-e2e-'));
  try {
    await writeFile(
      join(dir, 'index.ts'),
      `import "./style.css";\nconst box = document.createElement('div'); box.setAttribute('data-testid','b'); document.body.appendChild(box);\n(window as any).__loaded = true;\n`,
    );
    // media query 가 specifier 뒤에 살아있어야 함 — print only 라 viewport 에선 적용 X
    await writeFile(
      join(dir, 'style.css'),
      `@import "https://cdn.zntc-e2e.test/print.css" print;\n` +
        `[data-testid="b"] { color: rgb(2, 2, 2); }`,
    );

    const dist = join(dir, 'dist');
    await mkdir(dist, { recursive: true });

    const build = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(dir, 'index.ts'),
        '-o',
        join(dist, 'index.js'),
        '--format=esm',
        '--platform=browser',
      ],
      { stdio: 'pipe', timeout: 15000 },
    );
    expect(build.status).toBe(0);

    const builtCss = await readFile(join(dist, 'index.css'), 'utf-8');
    // media clause 가 specifier 뒤에 살아있어야 함
    expect(builtCss).toMatch(/@import\s+"https:\/\/cdn\.zntc-e2e\.test\/print\.css"\s+print\s*;/);

    await writeFile(
      join(dist, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8"><link rel="stylesheet" href="./index.css"></head><body><script type="module" src="./index.js"></script></body></html>`,
    );

    let printFetched = false;
    await page.route('https://cdn.zntc-e2e.test/print.css', async (route) => {
      printFetched = true;
      await route.fulfill({
        status: 200,
        contentType: 'text/css',
        // print 매체에서만 적용 — viewport 에선 영향 0
        body: `[data-testid="b"] { color: rgb(255, 0, 0) !important; }`,
      });
    });

    const { server, port } = await serve(dist);
    try {
      await page.goto(`http://localhost:${port}/`);
      await page.waitForFunction(() => (window as any).__loaded === true, { timeout: 5000 });

      // print-only stylesheet 라도 브라우저는 fetch 한다 (matchMedia 와 무관, lazy 가능)
      // 핵심: viewport 에선 cascade 적용 X → local 의 rgb(2,2,2) 가 유지돼야 함.
      const color = await page.evaluate(() => {
        const el = document.querySelector('[data-testid="b"]')!;
        return getComputedStyle(el).color;
      });
      expect(color).toBe('rgb(2, 2, 2)');

      // print emulate 로 매체 전환 시 external print.css 가 cascade 진입
      await page.emulateMedia({ media: 'print' });
      // print 매체에선 fetch 트리거 (lazy load 됐을 수 있음)
      await page.waitForFunction(() => true);
      const colorPrint = await page.evaluate(() => {
        const el = document.querySelector('[data-testid="b"]')!;
        return getComputedStyle(el).color;
      });
      // print emulate 후 매체 매칭으로 external 규칙 적용 → red
      expect(colorPrint).toBe('rgb(255, 0, 0)');
      expect(printFetched, 'print-only external CSS was not fetched').toBe(true);
    } finally {
      await closeServer(server);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
