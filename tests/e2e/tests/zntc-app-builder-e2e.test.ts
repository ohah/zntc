import { test, expect } from '@playwright/test';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

/**
 * Vite-style app builder (`zntc build` / `zntc dev` / `zntc preview`) 의 브라우저 E2E.
 *
 * tests/integration 와 packages/core/bin/zntc.test.ts 는 CLI exit code / stderr / 출력 파일까지만
 * 검증한다. 본 테스트는 빌드된 앱이 실제 브라우저에서 실행되는 것까지 확인한다 — 멀티 모듈
 * import 그래프, import.meta.env 정적 주입, HTML %VITE_*% 토큰 치환, public/ 자산 복사,
 * stylesheet rewrite 후 CSS 적용.
 */

const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');
const ZNTC_JS_CLI = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const ZNTC_JS_RUNTIME = 'bun';
const BUILD_PREVIEW_PORT = 3997;
const DEV_PORT = 3998;
const CSS_MODULE_PREVIEW_PORT = 3995;
const CSS_MODULE_DEV_PORT = 3994;
const SCSS_PREVIEW_PORT = 3993;
const SCSS_DEV_PORT = 3992;
const SASS_HTML_PREVIEW_PORT = 3991;
const SCSS_RECOVERY_DEV_PORT = 3990;
const OVERLAY_DEV_PORT = 3989;
const RUNTIME_OVERLAY_DEV_PORT = 3988;
const REJECTION_OVERLAY_DEV_PORT = 3987;

test.describe.configure({ mode: 'parallel' });

const FIXTURE: Record<string, string> = {
  'index.html': `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>%VITE_APP_TITLE%</title>
    <link rel="icon" href="/favicon.svg" />
    <link rel="stylesheet" href="/src/style.css" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>`,
  'src/main.ts': `import { greet } from "./util";
const target = document.getElementById("root")!;
target.innerHTML = \`
  <h1 data-testid="title">\${greet(import.meta.env.VITE_APP_TITLE)}</h1>
  <p data-testid="mode">\${import.meta.env.MODE}</p>
  <p data-testid="prod">\${String(import.meta.env.PROD)}</p>
\`;
`,
  'src/util.ts': `export function greet(name: string): string {
  return \`hello \${name}\`;
}
`,
  'src/style.css': `body { background: rgb(220, 230, 240); }
[data-testid="title"] { color: rgb(33, 150, 243); }
`,
  'public/favicon.svg': `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="black"/></svg>`,
  '.env.production': `VITE_APP_TITLE=Prod App
`,
  '.env.development': `VITE_APP_TITLE=Dev App
`,
};

async function writeFixture(dir: string): Promise<void> {
  for (const [name, content] of Object.entries(FIXTURE)) {
    const filePath = join(dir, name);
    await mkdir(dirname(filePath), { recursive: true });
    await writeFile(filePath, content);
  }
}

// ─── zntc build → zntc preview → 브라우저 ───
test.describe.serial('zntc build + preview E2E', () => {
  let fixtureDir: string;
  let preview: ChildProcess | null = null;

  test.beforeAll(async () => {
    fixtureDir = await mkdtemp(join(tmpdir(), 'zntc-app-build-e2e-'));
    await writeFixture(fixtureDir);

    const built = spawnSync(ZNTC_BIN, ['build', fixtureDir, '--outdir', join(fixtureDir, 'dist')], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (built.status !== 0) {
      throw new Error(
        `zntc build failed (exit ${built.status})\n--- stdout ---\n${built.stdout}\n--- stderr ---\n${built.stderr}`,
      );
    }

    preview = spawn(
      ZNTC_BIN,
      ['preview', join(fixtureDir, 'dist'), '--port', String(BUILD_PREVIEW_PORT)],
      { stdio: 'pipe' },
    );
    await new Promise((r) => setTimeout(r, 2000));
  });

  test.afterAll(async () => {
    if (preview) {
      preview.kill();
      await new Promise((r) => preview!.on('close', r));
    }
    if (fixtureDir) await rm(fixtureDir, { recursive: true, force: true });
  });

  test('페이지가 로드되고 import.meta.env 가 production 으로 정적 주입된다', async ({ page }) => {
    await page.goto(`http://localhost:${BUILD_PREVIEW_PORT}/`);
    await expect(page.getByTestId('title')).toHaveText('hello Prod App');
    await expect(page.getByTestId('mode')).toHaveText('production');
    await expect(page.getByTestId('prod')).toHaveText('true');
  });

  test('HTML title 의 %VITE_*% placeholder 가 치환된다', async ({ page }) => {
    await page.goto(`http://localhost:${BUILD_PREVIEW_PORT}/`);
    await expect(page).toHaveTitle('Prod App');
  });

  test('public/ 자산이 그대로 복사되어 서빙된다', async ({ request }) => {
    const r = await request.get(`http://localhost:${BUILD_PREVIEW_PORT}/favicon.svg`);
    expect(r.status()).toBe(200);
    expect(await r.text()).toContain('<svg');
  });

  test('HTML 의 <link rel=stylesheet> 가 빌드 산출물 경로로 rewrite 되고 CSS 가 적용된다', async ({
    page,
  }) => {
    await page.goto(`http://localhost:${BUILD_PREVIEW_PORT}/`);
    const bg = await page.locator('body').evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(bg).toBe('rgb(220, 230, 240)');
    const titleColor = await page.getByTestId('title').evaluate((el) => getComputedStyle(el).color);
    expect(titleColor).toBe('rgb(33, 150, 243)');
  });

  test('빌드된 JS 에 TS 타입 어노테이션이 남아있지 않다', async ({ request }) => {
    const html = await (await request.get(`http://localhost:${BUILD_PREVIEW_PORT}/`)).text();
    const scriptMatch = html.match(/<script[^>]+src="([^"]+)"/);
    expect(scriptMatch).not.toBeNull();
    const js = await (
      await request.get(`http://localhost:${BUILD_PREVIEW_PORT}${scriptMatch![1]}`)
    ).text();
    expect(js).toContain('hello');
    expect(js).not.toMatch(/: string\b/);
  });
});

// ─── zntc dev 직접 띄움 → 브라우저 ───
test.describe.serial('zntc dev E2E', () => {
  let fixtureDir: string;
  let server: ChildProcess | null = null;

  test.beforeAll(async () => {
    fixtureDir = await mkdtemp(join(tmpdir(), 'zntc-app-dev-e2e-'));
    await writeFixture(fixtureDir);
    server = spawn(ZNTC_BIN, ['dev', fixtureDir, '--port', String(DEV_PORT)], {
      stdio: 'pipe',
    });
    await new Promise((r) => setTimeout(r, 2500));
  });

  test.afterAll(async () => {
    if (server) {
      server.kill();
      await new Promise((r) => server!.on('close', r));
    }
    if (fixtureDir) await rm(fixtureDir, { recursive: true, force: true });
  });

  test('dev 모드에서 import.meta.env.MODE 가 development, PROD 가 false', async ({ page }) => {
    await page.goto(`http://localhost:${DEV_PORT}/`);
    await expect(page.getByTestId('title')).toHaveText('hello Dev App');
    await expect(page.getByTestId('mode')).toHaveText('development');
    await expect(page.getByTestId('prod')).toHaveText('false');
  });

  test('dev 모드 HTML title placeholder 도 치환된다', async ({ page }) => {
    await page.goto(`http://localhost:${DEV_PORT}/`);
    await expect(page).toHaveTitle('Dev App');
  });

  test('dev 모드도 public/ 와 stylesheet 자산을 서빙한다', async ({ request }) => {
    const fav = await request.get(`http://localhost:${DEV_PORT}/favicon.svg`);
    expect(fav.status()).toBe(200);
    // stylesheet 의 source path 가 link href + emit path 양쪽에서 보존된다.
    const css = await request.get(`http://localhost:${DEV_PORT}/src/style.css`);
    expect(css.status()).toBe(200);
    expect(await css.text()).toContain('rgb(220, 230, 240)');
  });

  test('dev 모드는 초기 번들 에러를 브라우저 오버레이로 보여준다', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-overlay-e2e-'));
    await mkdir(join(dir, 'src'), { recursive: true });
    await writeFile(
      join(dir, 'index.html'),
      '<div id="root">waiting for bundle</div><script type="module" src="/src/main.ts"></script>',
    );
    await writeFile(join(dir, 'src/main.ts'), 'const broken: = ;');
    const server = spawn(ZNTC_BIN, ['dev', dir, '--port', String(OVERLAY_DEV_PORT)], {
      stdio: 'pipe',
    });
    await new Promise((r) => setTimeout(r, 2500));

    try {
      await page.goto(`http://localhost:${OVERLAY_DEV_PORT}/`, { waitUntil: 'domcontentloaded' });
      await expect(page.locator('#zntc-error-overlay')).toBeVisible({ timeout: 5000 });
      await expect(page.locator('#zntc-error-overlay .title')).toContainText('Build Error');
      await expect(
        page.locator('#zntc-error-overlay .message').filter({ hasText: 'Type expected' }),
      ).toBeVisible();

      await writeFile(
        join(dir, 'src/main.ts'),
        'document.getElementById("root")!.textContent = "fixed";',
      );
      await expect(page.locator('#zntc-error-overlay')).not.toBeVisible({ timeout: 5000 });
      await expect(page.locator('#root')).toHaveText('fixed');
    } finally {
      server.kill();
      await new Promise((r) => server.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('dev 모드는 런타임 에러 스택을 브라우저 오버레이로 보여준다', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-runtime-overlay-e2e-'));
    await mkdir(join(dir, 'src'), { recursive: true });
    await writeFile(
      join(dir, 'index.html'),
      '<style>.title,.message,.close{display:none!important}</style><div id="root">waiting for runtime</div><script type="module" src="/src/main.ts"></script>',
    );
    await writeFile(
      join(dir, 'src/main.ts'),
      'document.getElementById("root")!.textContent = "before runtime error";\nthrow new Error("zntc runtime overlay check");',
    );
    const server = spawn(ZNTC_BIN, ['dev', dir, '--port', String(RUNTIME_OVERLAY_DEV_PORT)], {
      stdio: 'pipe',
    });
    await new Promise((r) => setTimeout(r, 2500));

    try {
      await page.goto(`http://localhost:${RUNTIME_OVERLAY_DEV_PORT}/`, {
        waitUntil: 'domcontentloaded',
      });
      await expect(page.locator('#zntc-error-overlay')).toBeVisible({ timeout: 5000 });
      await expect(page.locator('#zntc-error-overlay .title')).toContainText('Runtime Error');
      await expect(
        page.locator('#zntc-error-overlay .message').filter({
          hasText: 'Error: zntc runtime overlay check',
        }),
      ).toBeVisible();
      await expect(
        page.locator('#zntc-error-overlay .message').filter({ hasText: 'main.ts:2:7' }),
      ).toBeVisible();

      await page.mouse.click(12, 12);
      await expect(page.locator('#zntc-error-overlay')).toBeVisible();
      await page.locator('#zntc-error-overlay .close').click();
      await expect(page.locator('#zntc-error-overlay')).not.toBeVisible();

      await writeFile(
        join(dir, 'src/main.ts'),
        'document.getElementById("root")!.textContent = "runtime fixed";',
      );
      await expect(page.locator('#zntc-error-overlay')).not.toBeVisible({ timeout: 5000 });
      await expect(page.locator('#root')).toHaveText('runtime fixed');
    } finally {
      server.kill();
      await new Promise((r) => server.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('dev 모드는 unhandled rejection 스택도 런타임 오버레이로 보여준다', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-rejection-overlay-e2e-'));
    await mkdir(join(dir, 'src'), { recursive: true });
    await writeFile(
      join(dir, 'index.html'),
      '<div id="root">waiting for rejection</div><script type="module" src="/src/main.ts"></script>',
    );
    await writeFile(
      join(dir, 'src/main.ts'),
      'document.getElementById("root")!.textContent = "before rejection";\nPromise.reject(new Error("zntc promise overlay check"));',
    );
    const server = spawn(ZNTC_BIN, ['dev', dir, '--port', String(REJECTION_OVERLAY_DEV_PORT)], {
      stdio: 'pipe',
    });
    await new Promise((r) => setTimeout(r, 2500));

    try {
      await page.goto(`http://localhost:${REJECTION_OVERLAY_DEV_PORT}/`, {
        waitUntil: 'domcontentloaded',
      });
      await expect(page.locator('#zntc-error-overlay')).toBeVisible({ timeout: 5000 });
      await expect(page.locator('#zntc-error-overlay .title')).toContainText('Runtime Error');
      await expect(
        page.locator('#zntc-error-overlay .message').filter({
          hasText: 'Error: zntc promise overlay check',
        }),
      ).toBeVisible();
      await expect(
        page.locator('#zntc-error-overlay .message').filter({ hasText: 'main.ts:2' }),
      ).toBeVisible();
    } finally {
      server.kill();
      await new Promise((r) => server.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });
});

// ─── 서브디렉토리 같은 basename CSS 두 개가 build → preview 후 브라우저에 모두 적용된다 ───
test.describe.serial('zntc build: nested CSS path preservation E2E', () => {
  let nestedDir: string;
  let nestedPreview: ChildProcess | null = null;
  const NESTED_PORT = 3996;

  test.beforeAll(async () => {
    nestedDir = await mkdtemp(join(tmpdir(), 'zntc-app-nested-css-e2e-'));
    const files: Record<string, string> = {
      'index.html': `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>nested</title>
    <link rel="stylesheet" href="/src/a/style.css" />
    <link rel="stylesheet" href="/src/b/style.css" />
  </head>
  <body>
    <div data-testid="aaa" class="aaa">a</div>
    <div data-testid="bbb" class="bbb">b</div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>`,
      'src/main.ts': `console.log("ok");`,
      'src/a/style.css': `.aaa { color: rgb(255, 0, 0); }`,
      'src/b/style.css': `.bbb { color: rgb(0, 0, 255); }`,
    };
    for (const [name, content] of Object.entries(files)) {
      const filePath = join(nestedDir, name);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content);
    }

    const built = spawnSync(ZNTC_BIN, ['build', nestedDir, '--outdir', join(nestedDir, 'dist')], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (built.status !== 0) {
      throw new Error(`zntc build (nested CSS) failed: ${built.stderr}`);
    }

    nestedPreview = spawn(
      ZNTC_BIN,
      ['preview', join(nestedDir, 'dist'), '--port', String(NESTED_PORT)],
      { stdio: 'pipe' },
    );
    await new Promise((r) => setTimeout(r, 2000));
  });

  test.afterAll(async () => {
    if (nestedPreview) {
      nestedPreview.kill();
      await new Promise((r) => nestedPreview!.on('close', r));
    }
    if (nestedDir) await rm(nestedDir, { recursive: true, force: true });
  });

  test('같은 basename 의 서브디렉토리 CSS 두 개가 모두 서빙되고 색상이 적용된다', async ({
    page,
  }) => {
    await page.goto(`http://localhost:${NESTED_PORT}/`);
    const aColor = await page.getByTestId('aaa').evaluate((el) => getComputedStyle(el).color);
    const bColor = await page.getByTestId('bbb').evaluate((el) => getComputedStyle(el).color);
    expect(aColor).toBe('rgb(255, 0, 0)');
    expect(bColor).toBe('rgb(0, 0, 255)');
  });
});

// ─── CSS Modules: JS class map + 실제 브라우저 스타일 적용까지 검증 ───
test.describe.serial('zntc app CSS Modules E2E', () => {
  async function writeCssModuleFixture(dir: string): Promise<void> {
    const files: Record<string, string> = {
      'index.html': `<!doctype html>
<html>
  <head><meta charset="utf-8" /><title>css-modules</title></head>
  <body>
    <button data-testid="button"></button>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>`,
      'src/main.ts': `import styles, { button } from "./button.module.css";
const el = document.querySelector("[data-testid=button]")!;
el.className = \`\${styles.button} \${styles["label-text"]} \${button}\`;
el.textContent = styles.button.includes("button_button__") ? "scoped" : "raw";
`,
      'src/button.module.css': `.button {
  color: rgb(7, 92, 34);
  background: rgb(241, 244, 248);
}
.label-text {
  border-top-color: rgb(80, 90, 100);
  border-top-style: solid;
  border-top-width: 3px;
}
`,
    };
    for (const [name, content] of Object.entries(files)) {
      const filePath = join(dir, name);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content);
    }
  }

  test('build + preview applies scoped class names without a page-side workaround', async ({
    page,
  }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-css-mod-build-e2e-'));
    await writeCssModuleFixture(dir);

    const built = spawnSync(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'build', dir, '--outdir', join(dir, 'dist')],
      {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    if (built.status !== 0) {
      throw new Error(`zntc build css modules failed: ${built.stderr}`);
    }

    const preview = spawn(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'preview', join(dir, 'dist'), '--port', String(CSS_MODULE_PREVIEW_PORT)],
      { stdio: 'pipe' },
    );
    await new Promise((r) => setTimeout(r, 2000));
    try {
      await page.goto(`http://localhost:${CSS_MODULE_PREVIEW_PORT}/`);
      const button = page.getByTestId('button');
      await expect(button).toHaveText('scoped');
      const className = await button.evaluate((el) => el.className);
      expect(className).toContain('button_button__');
      expect(className).toContain('button_label_text__');
      expect(className).not.toContain(' label-text ');
      expect(await button.evaluate((el) => getComputedStyle(el).color)).toBe('rgb(7, 92, 34)');
      expect(await button.evaluate((el) => getComputedStyle(el).borderTopColor)).toBe(
        'rgb(80, 90, 100)',
      );
    } finally {
      preview.kill();
      await new Promise((r) => preview.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('dev applies CSS Modules through the app pipeline', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-css-mod-dev-e2e-'));
    await writeCssModuleFixture(dir);
    const server = spawn(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'dev', dir, '--port', String(CSS_MODULE_DEV_PORT)],
      {
        stdio: 'pipe',
      },
    );
    await new Promise((r) => setTimeout(r, 2500));

    try {
      await page.goto(`http://localhost:${CSS_MODULE_DEV_PORT}/`);
      const button = page.getByTestId('button');
      await expect(button).toHaveText('scoped');
      const className = await button.evaluate((el) => el.className);
      expect(className).toContain('button_button__');
      expect(await button.evaluate((el) => getComputedStyle(el).color)).toBe('rgb(7, 92, 34)');

      await writeFile(
        join(dir, 'src/button.module.css'),
        `.button {
  color: rgb(120, 10, 10);
  background: rgb(241, 244, 248);
}
.label-text {
  border-top-color: rgb(80, 90, 100);
  border-top-style: solid;
  border-top-width: 3px;
}
`,
      );
      await expect
        .poll(() => button.evaluate((el) => getComputedStyle(el).color), { timeout: 6000 })
        .toBe('rgb(120, 10, 10)');
    } finally {
      server.kill();
      await new Promise((r) => server.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });
});

// ─── Sass/SCSS: optional Sass compiler 경로를 실제 브라우저에서 검증 ───
test.describe.serial('zntc app Sass/SCSS E2E', () => {
  async function writeScssFixture(dir: string): Promise<void> {
    const files: Record<string, string> = {
      'index.html': `<!doctype html>
<html>
  <head><meta charset="utf-8" /><title>scss</title></head>
  <body>
    <section data-testid="panel" class="panel"><span class="label">SCSS</span></section>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>`,
      'src/main.ts': `import "./style.scss";
document.querySelector("[data-testid=panel]")!.setAttribute("data-ready", "yes");
`,
      'src/_tokens.scss': `$panel-color: rgb(10, 70, 120);
$label-color: rgb(140, 30, 20);
`,
      'src/style.scss': `@use "./tokens" as *;
.panel {
  color: $panel-color;
  .label {
    color: $label-color;
  }
}
`,
    };
    for (const [name, content] of Object.entries(files)) {
      const filePath = join(dir, name);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content);
    }
  }

  test('build + preview compiles SCSS imports and nesting', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-scss-build-e2e-'));
    await writeScssFixture(dir);

    const built = spawnSync(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'build', dir, '--outdir', join(dir, 'dist')],
      {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    if (built.status !== 0) {
      throw new Error(`zntc build scss failed: ${built.stderr}`);
    }

    const preview = spawn(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'preview', join(dir, 'dist'), '--port', String(SCSS_PREVIEW_PORT)],
      { stdio: 'pipe' },
    );
    await new Promise((r) => setTimeout(r, 2000));
    try {
      await page.goto(`http://localhost:${SCSS_PREVIEW_PORT}/`);
      await expect(page.getByTestId('panel')).toHaveAttribute('data-ready', 'yes');
      expect(await page.getByTestId('panel').evaluate((el) => getComputedStyle(el).color)).toBe(
        'rgb(10, 70, 120)',
      );
      expect(await page.locator('.label').evaluate((el) => getComputedStyle(el).color)).toBe(
        'rgb(140, 30, 20)',
      );
    } finally {
      preview.kill();
      await new Promise((r) => preview.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('build + preview compiles HTML-linked indented .sass', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-sass-html-e2e-'));
    const files: Record<string, string> = {
      'index.html': `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>sass-html</title>
    <link rel="stylesheet" href="/src/direct.sass" />
  </head>
  <body>
    <article data-testid="direct" class="direct"><span class="direct-label">SASS</span></article>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>`,
      'src/main.ts': `document.querySelector("[data-testid=direct]")!.setAttribute("data-ready", "yes");`,
      'src/direct.sass': `$direct-color: rgb(42, 80, 110)
$label-color: rgb(170, 20, 60)
.direct
  color: $direct-color
  .direct-label
    color: $label-color
`,
    };
    for (const [name, content] of Object.entries(files)) {
      const filePath = join(dir, name);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content);
    }

    const built = spawnSync(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'build', dir, '--outdir', join(dir, 'dist')],
      {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    if (built.status !== 0) {
      throw new Error(`zntc build .sass failed: ${built.stderr}`);
    }

    const preview = spawn(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'preview', join(dir, 'dist'), '--port', String(SASS_HTML_PREVIEW_PORT)],
      { stdio: 'pipe' },
    );
    await new Promise((r) => setTimeout(r, 2000));
    try {
      await page.goto(`http://localhost:${SASS_HTML_PREVIEW_PORT}/`);
      const direct = page.getByTestId('direct');
      await expect(direct).toHaveAttribute('data-ready', 'yes');
      expect(await direct.evaluate((el) => getComputedStyle(el).color)).toBe('rgb(42, 80, 110)');
      expect(await page.locator('.direct-label').evaluate((el) => getComputedStyle(el).color)).toBe(
        'rgb(170, 20, 60)',
      );
    } finally {
      preview.kill();
      await new Promise((r) => preview.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('dev recompiles SCSS through full reload fallback', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-scss-dev-e2e-'));
    await writeScssFixture(dir);
    const server = spawn(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'dev', dir, '--port', String(SCSS_DEV_PORT)],
      {
        stdio: 'pipe',
      },
    );
    await new Promise((r) => setTimeout(r, 2500));

    try {
      await page.goto(`http://localhost:${SCSS_DEV_PORT}/`);
      const panel = page.getByTestId('panel');
      expect(await panel.evaluate((el) => getComputedStyle(el).color)).toBe('rgb(10, 70, 120)');

      await writeFile(
        join(dir, 'src/style.scss'),
        `@use "./tokens" as *;
.panel {
  color: rgb(20, 100, 40);
  .label {
    color: $label-color;
  }
}
`,
      );
      await expect
        .poll(() => panel.evaluate((el) => getComputedStyle(el).color), { timeout: 7000 })
        .toBe('rgb(20, 100, 40)');
    } finally {
      server.kill();
      await new Promise((r) => server.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('dev recovers after an SCSS syntax error is fixed', async ({ page }) => {
    const dir = await mkdtemp(join(tmpdir(), 'zntc-app-scss-recovery-e2e-'));
    await writeScssFixture(dir);
    const server = spawn(
      ZNTC_JS_RUNTIME,
      [ZNTC_JS_CLI, 'dev', dir, '--port', String(SCSS_RECOVERY_DEV_PORT)],
      {
        stdio: 'pipe',
      },
    );
    await new Promise((r) => setTimeout(r, 2500));

    try {
      await page.goto(`http://localhost:${SCSS_RECOVERY_DEV_PORT}/`);
      const panel = page.getByTestId('panel');
      expect(await panel.evaluate((el) => getComputedStyle(el).color)).toBe('rgb(10, 70, 120)');

      await writeFile(join(dir, 'src/style.scss'), '.panel { color: rgb(1, 1, ');
      await new Promise((r) => setTimeout(r, 800));
      await writeFile(
        join(dir, 'src/style.scss'),
        `@use "./tokens" as *;
.panel {
  color: rgb(90, 45, 135);
  .label {
    color: $label-color;
  }
}
`,
      );
      await expect
        .poll(() => panel.evaluate((el) => getComputedStyle(el).color), { timeout: 9000 })
        .toBe('rgb(90, 45, 135)');
    } finally {
      server.kill();
      await new Promise((r) => server.on('close', r));
      await rm(dir, { recursive: true, force: true });
    }
  });
});
