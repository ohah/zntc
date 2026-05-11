import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { readFile } from 'node:fs/promises';

import { createFixture, runZntcInDir } from './helpers';

/**
 * `zntc build` (app 모드) 가 index.html 안의 EJS 스타일 `<%= ZNTC_X %>` 토큰을
 * .env 값으로 치환하는지 e2e 검증. transformHtmlEnvTokens / applyHtmlEnvTokens 의
 * 단위 테스트는 packages/web/src/html-env.test.ts 에 있고, 본 파일은 caller hook
 * (runAppBuild → applyHtmlEnvTokens) 이 실제로 작동하는지 회귀를 보장한다.
 *
 * 의존: NAPI binding (packages/core/zntc.node) + @zntc/web dist 가 모두 빌드돼야 통과.
 */

// app build 는 entry script 가 있어야 동작 — 본문 검증 대상은 HTML 이지만 build 파이프
// 라인 진입 조건을 충족하기 위한 최소 stub.
const MAIN_TS = "console.log('hi');\n";

async function buildApp(
  dir: string,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return runZntcInDir(dir, ['build', dir, '--outdir', join(dir, 'dist')], { bin: 'js' });
}

describe('html-env EJS token replacement — zntc build (app mode)', () => {
  test.concurrent('replaces ZNTC_* tokens, keeps VITE_* as-is, fills missing keys with empty string', async () => {
    const { dir, cleanup } = await createFixture({
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
      'src/main.ts': MAIN_TS,
    });
    try {
      const { exitCode, stderr } = await buildApp(dir);
      expect(exitCode === 0 ? '' : stderr).toBe('');

      const html = await readFile(join(dir, 'dist', 'index.html'), 'utf8');
      expect(html).toContain('<title>My ZNTC App</title>');
      expect(html).toContain('content="2026.05"');
      expect(html).toContain('content=""');
      // VITE_ prefix 는 원본 보존, 값이 노출돼서는 안 됨
      expect(html).toContain('<%= VITE_SECRET %>');
      expect(html).not.toContain('should-not-leak');

      // 미발견 키 + 잘못된 prefix 둘 다 [html-env] 로 기록
      expect(stderr).toContain('[html-env]');
      expect(stderr).toContain('ZNTC_UNDEFINED');
      expect(stderr).toContain('VITE_SECRET');
    } finally {
      await cleanup();
    }
  });

  test.concurrent('escapes <, >, &, " in env values (XSS 방어)', async () => {
    const { dir, cleanup } = await createFixture({
      '.env': `ZNTC_BIO=<script>alert("&")</script>\n`,
      'index.html': `<!DOCTYPE html>
<html>
  <head><title>x</title></head>
  <body><div data="<%= ZNTC_BIO %>"></div><script type="module" src="./src/main.ts"></script></body>
</html>`,
      'src/main.ts': MAIN_TS,
    });
    try {
      const { exitCode, stderr } = await buildApp(dir);
      expect(exitCode === 0 ? '' : stderr).toBe('');

      const html = await readFile(join(dir, 'dist', 'index.html'), 'utf8');
      expect(html).toContain('&lt;script&gt;');
      // raw script 태그가 HTML 본문에 그대로 들어가서는 안 됨
      expect(html).not.toContain('<script>alert(');
    } finally {
      await cleanup();
    }
  });

  test.concurrent('html without any token leaves file untouched + no warning', async () => {
    const { dir, cleanup } = await createFixture({
      'index.html': `<!DOCTYPE html>
<html>
  <head><title>static</title></head>
  <body><div id="root"></div><script type="module" src="./src/main.ts"></script></body>
</html>`,
      'src/main.ts': MAIN_TS,
    });
    try {
      const { exitCode, stderr } = await buildApp(dir);
      expect(exitCode === 0 ? '' : stderr).toBe('');

      const html = await readFile(join(dir, 'dist', 'index.html'), 'utf8');
      expect(html).toContain('<title>static</title>');
      expect(html).toContain('<div id="root">');
      // 토큰 0 개 → applyHtmlEnvTokens 가 changed=false 로 write/warning 둘 다 생략해야 함
      expect(html).not.toContain('<%=');
      expect(stderr).not.toContain('[html-env]');
    } finally {
      await cleanup();
    }
  });
});
