// examples 의 `zntc build` 산출물이 실제 브라우저에서 크래시 없이 로드되는지
// 회귀 가드. zntc build (app builder) 의 번들 회귀 — 타입체크/유닛이 못 잡는
// 런타임 크래시 (예: emotion weak-memoize splitting DCE 누락, JSX classic +
// React 미import) 를 잡는다. 둘 다 이 세션에서 발견된 실제 회귀.
//
// build → zntc preview 정적 서빙 → 헤드리스 Chromium 로드 → pageerror /
// console.error 0 검증. (verify --browser 와 동일 로직을 E2E 잡에 편입.)

import { test, expect } from '@playwright/test';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { resolve } from 'node:path';
import { waitForServer } from '@zntc/test-helpers';
import { PORTS } from './ports';

const ZNTC = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const ROOT = resolve(__dirname, '../../..');

// `zntc build` (app builder) 로 빌드 가능한 예제만 대상. react-19-zntc /
// react-19-vite 는 config 에 JS 플러그인(react-compiler adapter)이 있어 app build
// 가 미지원(`--bundle` 또는 Vite 경유), rspack 은 rspack 빌드라 별도 — 이들은
// 각자 다른 빌드 경로라 zntc build app 회귀 가드 대상이 아니다.
const EXAMPLES = [
  { name: 'web (styled-components + emotion)', dir: 'examples/web', port: PORTS.EXAMPLE_WEB_SMOKE },
];

test.describe('examples — zntc build 산출물 브라우저 smoke', () => {
  for (const ex of EXAMPLES) {
    test(`${ex.name}: build → preview → 브라우저 크래시 없이 로드`, async ({ page }) => {
      const dir = resolve(ROOT, ex.dir);

      const build = spawnSync('node', [ZNTC, 'build'], { cwd: dir, encoding: 'utf8' });
      expect(build.status, `build failed:\n${build.stderr}`).toBe(0);

      const srv: ChildProcess = spawn(
        'node',
        [ZNTC, 'preview', 'dist', '--port', String(ex.port)],
        {
          cwd: dir,
          stdio: 'pipe',
        },
      );
      try {
        await waitForServer(ex.port);

        const errors: string[] = [];
        page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
        page.on('console', (m) => {
          if (m.type() !== 'error') return;
          const text = m.text();
          // favicon 미존재 404 는 앱 무관 노이즈 — 제외.
          if (/favicon/i.test(text)) return;
          errors.push(`console.error: ${text}`);
        });

        await page.goto(`http://localhost:${ex.port}/`, { waitUntil: 'networkidle' });
        expect(errors, errors.join('\n')).toEqual([]);
      } finally {
        srv.kill();
        await new Promise((r) => srv.on('close', r));
      }
    });
  }
});
