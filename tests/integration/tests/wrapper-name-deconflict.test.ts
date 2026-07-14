import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4530 회귀 가드 — 생성된 **래퍼 심볼**이 사용자 top-level 심볼과 deconflict 되지 않던 결함.
 *
 * wrap 된 모듈은 emitter 가 래퍼 심볼을 직접 찍는다:
 *   - CJS      : `var require_<basename> = __commonJS({...})`
 *   - ESM-wrap : `var init_<basename> = __esm({...})`, `var exports_<basename> = {}`
 *
 * 그런데 `registerWrapperSymbols` 의 deconflict 풀이 **래퍼 이름끼리만** 봤다(#4475 는
 * basename 충돌 — `a/logo.png` vs `b/logo.png` — 만 다뤘다). 사용자 코드에 같은 이름의
 * top-level 심볼이 있으면 **중복 선언**이다:
 *
 *   var require_legacy = __commonJS({...});   // emitter
 *   function require_legacy(){ ... }          // 사용자 코드
 *   → SyntaxError: Identifier 'require_legacy' has already been declared
 *
 * **단일 번들에서도** 재현된다(번들 스코프에 모든 모듈의 top-level 이 호이스팅되므로).
 * → 사용자 top-level 심볼도 같은 풀에 seed 한다.
 */

const LEGACY = 'module.exports = { foo(){ return "FOO"; } };';

describe('#4530: 래퍼 심볼 ↔ 사용자 top-level 심볼 deconflict', () => {
  test('단일 번들: CJS 래퍼(require_X)가 동명 사용자 심볼과 충돌하지 않는다', async () => {
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': LEGACY,
      // 소비자 2개 — 래퍼가 인라인되지 않고 named 로 남게 한다.
      'u1.js': 'import d from "./legacy.cjs";\nexport const x = () => d.foo();',
      'entry.js':
        'function require_legacy(){ return "USER"; }\n' +
        'import d from "./legacy.cjs";\n' +
        'import { x } from "./u1.js";\n' +
        'console.log(require_legacy() + "|" + d.foo() + "|" + x());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', out, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      // 버그 시: SyntaxError: Identifier 'require_legacy' has already been declared
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('USER|FOO|FOO');
    } finally {
      await cleanup();
    }
  });

  test('단일 번들: ESM-wrap 래퍼(init_X / exports_X)도 충돌하지 않는다', async () => {
    const { dir, cleanup } = await createFixture({
      'b.js': 'export function tag(){ return "T"; }',
      // b.js 를 CJS 가 require → ESM-wrap 됨
      'a.cjs': 'const b = require("./b.js");\nmodule.exports = { run: () => b.tag() };',
      'entry.js':
        'function init_b(){ return "USER-INIT"; }\n' +
        'var exports_b = "USER-EXP";\n' +
        'import a from "./a.cjs";\n' +
        'console.log(init_b() + "|" + exports_b + "|" + a.run());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', out, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('USER-INIT|USER-EXP|T');
    } finally {
      await cleanup();
    }
  });

  for (const format of ['esm', 'cjs'] as const) {
    test(`--preserve-modules ${format}: 래퍼 이름이 사용자 심볼과 충돌하지 않는다`, async () => {
      // preserve-modules 는 래퍼 이름이 **파일 경계를 넘는 공개 키**이기도 하다 —
      // deconflict 결과가 provider/consumer 양쪽에서 같은 값이어야 한다.
      const { dir, cleanup } = await createFixture({
        'b.js': 'export function tag(){ return "T"; }',
        'a.cjs': 'const b = require("./b.js");\nmodule.exports = { run: () => b.tag() };',
        'entry.js':
          'function init_b(){ return "USER-INIT"; }\n' +
          'var exports_b = "USER-EXP";\n' +
          'import a from "./a.cjs";\n' +
          'console.log(init_b() + "|" + exports_b + "|" + a.run());',
      });
      try {
        const outDir = join(dir, 'dist');
        const res = await runZntc([
          '--bundle',
          join(dir, 'entry.js'),
          '--preserve-modules',
          '--outdir',
          outDir,
          `--format=${format}`,
        ]);
        expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
        if (format === 'esm') {
          writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
        }
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('SyntaxError');
        expect(stdout.trim()).toBe('USER-INIT|USER-EXP|T');
      } finally {
        await cleanup();
      }
    });
  }
});
