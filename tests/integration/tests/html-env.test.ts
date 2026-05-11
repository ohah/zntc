import { describe, test, expect } from 'bun:test';
import { mkdtemp, rm, writeFile, mkdir, readFile } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';

/**
 * `zntc build` (app 모드) 가 index.html 안의 EJS 스타일 `<%= ZNTC_X %>` 토큰을
 * .env 값으로 치환하는지 e2e 검증. transformHtmlEnvTokens / applyHtmlEnvTokens 의
 * 단위 테스트는 packages/web/src/html-env.test.ts 에 있고, 본 파일은 caller hook
 * (runAppBuild → applyHtmlEnvTokens) 이 실제로 작동하는지 회귀를 보장한다.
 *
 * NAPI binding (packages/core/zntc.node) 와 @zntc/web 의 dist 빌드가 모두 필요.
 */

const ZNTC_MJS = resolve(import.meta.dir, '../../../packages/core/bin/zntc.mjs');

async function makeApp(
  files: Record<string, string>,
): Promise<{ dir: string; cleanup: () => Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), 'zntc-html-env-'));
  for (const [name, content] of Object.entries(files)) {
    const p = join(dir, name);
    await mkdir(dirname(p), { recursive: true });
    await writeFile(p, content);
  }
  return { dir, cleanup: () => rm(dir, { recursive: true, force: true }) };
}

async function runBuild(
  dir: string,
): Promise<{ exitCode: number | null; stdout: string; stderr: string }> {
  const proc = Bun.spawn(['bun', ZNTC_MJS, 'build', dir, '--outdir', join(dir, 'dist')], {
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  return { exitCode, stdout, stderr };
}

describe('html-env EJS token replacement — zntc build (app mode)', () => {
  test('replaces ZNTC_* tokens, keeps VITE_* as-is, fills missing keys with empty string', async () => {
    const { dir, cleanup } = await makeApp({
      '.env':
        'ZNTC_APP_TITLE=My ZNTC App\nZNTC_BUILD_VERSION=2026.05\nVITE_SECRET=should-not-leak\n',
      'index.html': `<!DOCTYPE html>
<html>
  <head>
    <title><%= ZNTC_APP_TITLE %></title>
    <meta name="v" content="<%= ZNTC_BUILD_VERSION %>" />
    <meta name="missing" content="<%= ZNTC_UNDEFINED %>" />
    <meta name="api" content="<%= VITE_SECRET %>" />
  </head>
  <body><div id="root"></div><script type="module" src="./src/main.ts"></script></body>
</html>`,
      'src/main.ts': "console.log('hi');\n",
    });
    try {
      const { exitCode, stderr } = await runBuild(dir);
      expect(exitCode).toBe(0);

      const html = await readFile(join(dir, 'dist', 'index.html'), 'utf8');
      expect(html).toContain('<title>My ZNTC App</title>');
      expect(html).toContain('content="2026.05"');
      expect(html).toContain('content=""');
      // VITE_ prefix 는 원본 보존, 값이 노출되지 않아야 함
      expect(html).toContain('<%= VITE_SECRET %>');
      expect(html).not.toContain('should-not-leak');

      // warnings: 미발견 키 + 잘못된 prefix 둘 다 [html-env] 로 기록
      expect(stderr).toContain('[html-env]');
      expect(stderr).toContain('ZNTC_UNDEFINED');
      expect(stderr).toContain('VITE_SECRET');
    } finally {
      await cleanup();
    }
  });

  test('escapes <, >, &, " in env values', async () => {
    const { dir, cleanup } = await makeApp({
      '.env': `ZNTC_BIO=<script>alert("&")</script>\n`,
      'index.html': `<!DOCTYPE html>
<html>
  <head><title>x</title></head>
  <body><div data="<%= ZNTC_BIO %>"></div><script type="module" src="./src/main.ts"></script></body>
</html>`,
      'src/main.ts': "console.log('hi');\n",
    });
    try {
      const { exitCode } = await runBuild(dir);
      expect(exitCode).toBe(0);

      const html = await readFile(join(dir, 'dist', 'index.html'), 'utf8');
      expect(html).toContain('&lt;script&gt;');
      expect(html).toContain('&quot;');
      expect(html).toContain('&amp;');
      // raw script 태그가 HTML 본문에 그대로 들어가서는 안 됨 (XSS 방어)
      expect(html).not.toContain('<script>alert(');
    } finally {
      await cleanup();
    }
  });

  test('html without any token leaves file untouched', async () => {
    const original = `<!DOCTYPE html>
<html>
  <head><title>static</title></head>
  <body><div id="root"></div><script type="module" src="./src/main.ts"></script></body>
</html>`;
    const { dir, cleanup } = await makeApp({
      'index.html': original,
      'src/main.ts': "console.log('hi');\n",
    });
    try {
      const { exitCode } = await runBuild(dir);
      expect(exitCode).toBe(0);

      const html = await readFile(join(dir, 'dist', 'index.html'), 'utf8');
      // build 가 script src 를 hashed 파일로 rewrite — 그 외 본문은 보존돼야 함
      expect(html).toContain('<title>static</title>');
    } finally {
      await cleanup();
    }
  });
});
