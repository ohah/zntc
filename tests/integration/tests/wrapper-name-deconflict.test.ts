import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
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
  test('동명 사용자 심볼이 여러 모듈에 있어도 $N 레벨에서 재충돌하지 않는다', async () => {
    // ⚠️ 래퍼 **이름을 바꾸는** 방식으로 풀면 안 된다 — graph finalize 의 `used_names` 와
    // linker 의 `$N` 할당기가 **서로를 못 보는 두 개의 독립 풀**이라, 한 단계 위에서 다시
    // 충돌한다(양쪽이 각각 `require_legacy$2` 를 발급 → SyntaxError).
    // 래퍼를 **예약**해서 사용자 심볼을 리네임시키면 할당기가 하나로 모인다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': LEGACY,
      'u1.js': 'import d from "./legacy.cjs";\nexport const x = () => d.foo();',
      'm1.js': 'function require_legacy(){ return "A"; }\nexport const a = require_legacy();',
      'm2.js': 'function require_legacy(){ return "B"; }\nexport const b = require_legacy();',
      'entry.js':
        'function require_legacy(){ return "C"; }\n' +
        'import d from "./legacy.cjs";\n' +
        'import { x } from "./u1.js";\n' +
        'import { a } from "./m1.js";\n' +
        'import { b } from "./m2.js";\n' +
        'console.log(require_legacy() + a + b + d.foo() + x());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', out, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('CABFOOFOO');
    } finally {
      await cleanup();
    }
  });

  test('--minify 에서도 충돌하지 않는다', async () => {
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': LEGACY,
      'u1.js': 'import d from "./legacy.cjs";\nexport const x = () => d.foo();',
      'entry.js':
        'function require_legacy(){ return "USER"; }\n' +
        'import d from "./legacy.cjs";\n' +
        'import { x } from "./u1.js";\n' +
        'console.log(require_legacy() + "|" + d.foo() + "|" + x());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '-o',
        out,
        '--format=esm',
        '--minify',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('USER|FOO|FOO');
    } finally {
      await cleanup();
    }
  });

  test('충돌이 없으면 래퍼 이름이 그대로다 (과잉 deconflict 없음)', async () => {
    // 래퍼를 **예약**하는 방식이라 래퍼는 자연스러운 이름을 유지하고, 충돌하는 **사용자
    // 심볼**만 리네임된다 — size/warm-rebuild 안정성이 낫다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': LEGACY,
      'u1.js': 'import d from "./legacy.cjs";\nexport const x = () => d.foo();',
      'entry.js':
        'import d from "./legacy.cjs";\nimport { x } from "./u1.js";\nconsole.log(d.foo() + x());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', out, '--format=esm']);
      expect(res.exitCode).toBe(0);
      const text = readFileSync(out, 'utf-8');
      expect(text).toContain('var require_legacy = __commonJS');
      expect(text).not.toContain('require_legacy$');
    } finally {
      await cleanup();
    }
  });
});
