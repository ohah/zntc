import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { realpathSync } from 'node:fs';
import { createFixture } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// dev + automatic JSX 다중모듈 바인딩 회귀: dev wrap-all(__esm) 에서 helper import(jsx-runtime
// 의 `_jsx`/`_jsxs`/`_jsxDEV`)가 여러 모듈에 겹치면 deconflict 가 두 번째 모듈의 심볼을
// `_jsx$1` 로 rename 한다. 참조/할당(`_jsx$1 = require(...)`, `_jsx$1(...)`)은 canonical 명을
// 썼으나, hoisted **선언**(`var _jsx;`)이 *원본* 명을 써서 `_jsx$1` 이 선언 없이 쓰여
// `ReferenceError: _jsx$1 is not defined` → 브라우저에서 앱이 렌더 안 됨. (esm_wrap.zig 의
// helper hoist 가 getCanonicalByRef 로 canonical 명을 쓰도록 수정.)

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// `var X;` / `var X, Y;` / `var A, X;` / `var X, Y, Z;` 등 콤마-리스트 선언에서도 X 가
// *선언*됐는지 본다(emitter 가 같은 모듈의 helper 들을 한 `var` 로 묶을 수 있음).
function isDeclared(out: string, name: string): boolean {
  return new RegExp(`(?:\\bvar\\s+|,\\s*)${escapeRe(name)}\\s*[;,=]`).test(out);
}

describe('NAPI dev automatic-JSX helper binding (multi-module)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // jsx:'automatic'(_jsx/_jsxs) 와 'automatic-dev'(_jsxDEV) 둘 다 가드 — `zntc dev` 기본은
  // automatic-dev 라 후자가 실사용 경로.
  test.each([
    { jsx: 'automatic' as const, runtimeFile: 'jsx-runtime.js', helper: '_jsx' },
    { jsx: 'automatic-dev' as const, runtimeFile: 'jsx-dev-runtime.js', helper: '_jsxDEV' },
  ])(
    'jsx=$jsx: 겹치는 jsx helper 의 hoisted 선언이 canonical(rename) 명과 일치 — 미선언 없음',
    async ({ jsx, runtimeFile, helper }) => {
      // 두 모듈이 모두 같은 helper 를 써서 collision → 한쪽은 `$1` 로 rename.
      const fixture = await createFixture({
        'node_modules/react/package.json': '{"name":"react","version":"19.0.0","main":"index.js"}',
        'node_modules/react/index.js': 'module.exports={};',
        'node_modules/react/jsx-runtime.js':
          'exports.jsx=function(){return {}};exports.jsxs=function(){return {}};exports.Fragment={};',
        'node_modules/react/jsx-dev-runtime.js':
          'exports.jsxDEV=function(){return {}};exports.Fragment={};',
        'App.tsx': 'export function App(){ return <div>X</div>; }',
        'main.tsx':
          "import { App } from './App';\nexport function render(){ return <App />; }\nrender();",
      });
      cleanup = fixture.cleanup;
      void runtimeFile;
      const dir = realpathSync(fixture.dir);

      const r = await build({
        entryPoints: [join(dir, 'main.tsx')],
        platform: 'browser',
        devMode: true, // wrap-all(__esm) — collision + hoisted 선언 경로
        format: 'iife',
        jsx,
      });
      expect(r.errors ?? []).toHaveLength(0);
      const out = r.outputFiles!.map((o) => o.text).join('\n');

      // collision 으로 rename 된 helper(`<helper>$N`)가 실제로 emit 됐다(가드 — 미발생이면
      // 테스트가 의미 없음). 그리고 *모든* rename 식별자는 대응 선언이 있어야 한다(없으면
      // 그 식별자가 선언 없이 할당/사용돼 ReferenceError = 정확한 버그 형상).
      const reHelper = new RegExp(`\\b(${escapeRe(helper)}\\$\\d+)\\b`, 'g');
      const renamed = [...new Set([...out.matchAll(reHelper)].map((m) => m[1]))];
      expect(renamed.length).toBeGreaterThan(0);
      for (const name of renamed) {
        expect(isDeclared(out, name)).toBe(true);
      }
    },
  );
});
