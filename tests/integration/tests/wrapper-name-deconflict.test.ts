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

/**
 * #4533 회귀 가드 — 주입된 래퍼 참조가 **소비자의 스코프 바인딩**에 가려지던 결함.
 *
 * `require("./x")` 는 emit 시 그 자리에서 `require_x()` 로 재작성된다. 그 지점의 스코프 체인에
 * 래퍼 이름과 동명 바인딩이 있으면 그게 래퍼를 가린다:
 *
 *   function load(){
 *     function require_legacy(){ ... }        // 소비자의 바인딩
 *     return require("./legacy.cjs").foo();   // → require_legacy().foo() → 가려짐
 *   }
 *   → TypeError  (빌드 exit 0 · 파싱 통과 · **실행만** 실패)
 *
 * 처방(esbuild/rolldown 방식): **가리는 사용자 바인딩을 리네임**한다(래퍼 이름은 안 건드림 —
 * 래퍼는 cross-chunk 전역명·preserve-modules export·mangler 등 여러 서브시스템의 공유 키라
 * 건드리면 파급이 크다). 소비자 바인딩은 그 모듈 안에서만 참조되므로 리네임이 로컬하다.
 */
describe('#4533: 주입된 래퍼 참조 ↔ 소비자 스코프 바인딩', () => {
  const CJS_LEGACY = 'exports.foo = function(){ return "FOO"; };';

  test('(1) 중첩 스코프 바인딩', async () => {
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'entry.cjs':
        'function load(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  return require("./legacy.cjs").foo() + require_legacy();\n' +
        '}\n' +
        'console.log(load());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.cjs'), '-o', out, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOW');
    } finally {
      await cleanup();
    }
  });

  test('(2) 동적 import() 소비자', async () => {
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'entry.mjs':
        'async function load(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  const m = await import("./legacy.cjs");\n' +
        '  return m.default.foo() + require_legacy();\n' +
        '}\n' +
        'load().then(r => console.log(r));',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.mjs'), '-o', out, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOW');
    } finally {
      await cleanup();
    }
  });

  test('(3) --minify (이 경로는 mangler 가 담당 — resolveWrapperConsumerShadows 는 minify 에서 skip)', async () => {
    // ⚠️ 이 케이스는 **resolveWrapperConsumerShadows 를 되돌려도 통과한다** — minify 는 mangler 가
    // 모든 바인딩을 유일 단문자명으로 개명하고 주입 참조는 래퍼의 mangled 이름(`a()`)을 쓰므로
    // 섀도가 원천 불가하기 때문이다. 이 가드의 목적은 "minify 를 mangler 에 위임하는 결정이 안전"
    // 함을 지키는 것이지, 이 PR 의 non-minify 코드가 minify 를 고친다는 주장이 아니다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'entry.cjs':
        'function load(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  return require("./legacy.cjs").foo() + require_legacy();\n' +
        '}\n' +
        'console.log(load());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.cjs'),
        '-o',
        out,
        '--format=esm',
        '--minify',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOW');
    } finally {
      await cleanup();
    }
  });

  test('(4) preserve-modules — 래퍼 이름 불변이라 provider export 정합', async () => {
    // 이전 "래퍼 리네임" 방식은 여기서 provider 가 require_x$1 선언 + require_x export →
    // SyntaxError 였다. 소비자 바인딩만 리네임하므로 래퍼 export 는 그대로다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'consumer.js':
        'import d from "./legacy.cjs";\n' +
        'export function run(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  return d.foo() + require_legacy();\n' +
        '}',
      'entry.js': 'import { run } from "./consumer.js";\nconsole.log(run());',
    });
    try {
      const outDir = join(dir, 'dist');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--preserve-modules',
        '--outdir',
        outDir,
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('SyntaxError');
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOW');
    } finally {
      await cleanup();
    }
  });

  test('(5) code-splitting — 래퍼 이름 불변이라 cross-chunk 정합', async () => {
    // 이전 방식은 per-chunk rename_table clear + cross_chunk_global_names 로 desync 됐다.
    // helper.cjs 는 실행되는 non-entry(entry 가 import) 라 런타임까지 검증된다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'other.js': 'export const val = "OTHER";',
      'helper.cjs':
        'function build(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  return require("./legacy.cjs").foo() + require_legacy();\n' +
        '}\n' +
        'module.exports = build();',
      'entry.js':
        'import r from "./helper.cjs";\nimport("./other.js").then(m => console.log(r + m.val));',
    });
    try {
      const outdir = join(dir, 'out');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--outdir',
        outdir,
        '--splitting',
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(join(outdir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOWOTHER');
    } finally {
      await cleanup();
    }
  });

  test('(10) code-splitting — 래퍼 선언과 동명인 co-chunk 사용자 top-level (중복선언 방지)', async () => {
    // 래퍼 var require_legacy = __commonJS 가 이 청크에 선언되는데 동명 사용자 함수가 같은
    // 청크에 있고 legacy 는 다른 청크에서만 import → per-chunk reserved 가 **선언측** 래퍼를
    // 예약 안 하면 둘 다 require_legacy 로 선언 → SyntaxError. 선언측 예약으로 회피.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': 'exports.foo = function(){ return "FOO"; };',
      'user.js': 'export function require_legacy(){ return "USER"; }',
      'shared.js':
        'import { require_legacy } from "./user.js";\n' +
        'import d from "./legacy.cjs";\n' +
        'export const combined = require_legacy() + d.foo();',
      'entry.js': 'import("./shared.js").then(m => console.log(m.combined));',
    });
    try {
      const outdir = join(dir, 'out');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--outdir',
        outdir,
        '--splitting',
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(join(outdir, 'entry.js'));
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('USERFOO');
    } finally {
      await cleanup();
    }
  });

  test('(6) 섀도잉 없으면 사용자 바인딩 이름 그대로 (과잉 리네임 없음)', async () => {
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'entry.cjs': 'function load(){ return require("./legacy.cjs").foo(); }\nconsole.log(load());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.cjs'), '-o', out, '--format=esm']);
      expect(res.exitCode).toBe(0);
      const text = readFileSync(out, 'utf-8');
      expect(text).not.toContain('require_legacy$'); // 충돌 없음 → suffix 없음
    } finally {
      await cleanup();
    }
  });

  test('(7) 개명 후보가 소비자의 다른 top-level 바인딩과도 안 겹친다', async () => {
    // 후보 이름 선택(findAvailableCandidate)은 CJS 소비자의 scope-0(클로저 지역) 바인딩을
    // 못 본다 → `require_legacy$1` 이 이미 있으면 거기에 개명해 재선언/오컴파일이었다.
    // pickConsumerShadowName 이 scope-0 까지 확인해 `require_legacy$2` 로 회피한다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'entry.cjs':
        'var require_legacy$1 = "EXISTING";\n' +
        'function load(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  return require("./legacy.cjs").foo() + require_legacy() + require_legacy$1;\n' +
        '}\n' +
        'console.log(load());',
    });
    try {
      const out = join(dir, 'b.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.cjs'), '-o', out, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(out);
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOWEXISTING');
    } finally {
      await cleanup();
    }
  });

  test('(9) code-splitting — 형제 래퍼($N) 이름과도 안 겹친다', async () => {
    // 두 basename `legacy` CJS → require_legacy, require_legacy$1. 소비자 섀도를 개명할 때
    // per-chunk reserved_globals 가 래퍼 이름을 안 예약하면 require_legacy$1(2번째 래퍼)로
    // 개명해 충돌 → require_legacy$2 로 회피해야 한다.
    const { dir, cleanup } = await createFixture({
      'a/legacy.cjs': 'exports.foo = function(){ return "A"; };',
      'b/legacy.cjs': 'exports.foo = function(){ return "B"; };',
      'consumer.cjs':
        'function require_legacy(){ return "SHADOW"; }\n' +
        'module.exports = require("./a/legacy.cjs").foo() + require("./b/legacy.cjs").foo() + require_legacy();',
      'other.js': 'export const v = "V";',
      'entry.js':
        'import r from "./consumer.cjs";\nimport("./other.js").then(m => console.log(r + m.v));',
    });
    try {
      const outdir = join(dir, 'out');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--outdir',
        outdir,
        '--splitting',
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(join(outdir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('ABSHADOWV');
    } finally {
      await cleanup();
    }
  });

  test('(8) code-splitting — 섀도 모듈이 동적 청크(entry 와 다른 청크)에 있어도', async () => {
    // test (5) 는 shadow 모듈이 entry 청크에 co-locate 됐다. 이건 shadow 를 **동적 import 되는
    // 별도 청크**(chunk.cjs)에 둬 per-chunk rename(computeRenamesForModules)이 그 청크에서 도는
    // 경로를 실제로 태운다. 소비자 바인딩은 소비자(그 청크)에서 개명되므로 청크가 갈려도 정합.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': CJS_LEGACY,
      'chunk.cjs':
        'function build(){\n' +
        '  function require_legacy(){ return "SHADOW"; }\n' +
        '  return require("./legacy.cjs").foo() + require_legacy();\n' +
        '}\n' +
        'module.exports = build();',
      'entry.js': 'import("./chunk.cjs").then(m => console.log(m.default));',
    });
    try {
      const outdir = join(dir, 'out');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--outdir',
        outdir,
        '--splitting',
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      const { stdout, stderr } = await runNode(join(outdir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('FOOSHADOW');
    } finally {
      await cleanup();
    }
  });
});
