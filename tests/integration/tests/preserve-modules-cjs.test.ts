import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4524 회귀 가드 — `--preserve-modules` × CJS.
 *
 * 루트커즈: **CJS 는 정적 export 가 없어 파일 경계를 넘을 수단이 `require_X` 썽크뿐인데**,
 * preserve-modules 가 그걸 export 하지 않았다. 소비자는 그 썽크를 **렉시컬 참조**했는데
 * 그건 다른 파일의 지역변수다 → `ReferenceError: require_legacy is not defined`.
 * 정적 import 조차 못 썼고, 동적 import 는 빈 namespace 였다.
 *
 * 처방(rolldown 동일): 파일이 썽크를 export(`export { require_X }`)하고 소비자가 import 한다.
 * interop 은 소비자가 자기 preamble(`var d = require_X()`)로 이미 하고 있으므로 이름만
 * 건너오면 된다. 동적 import 는 소비자가 `.then((m)=>__toESM(m.default))` 로 namespace 를
 * 합성한다 — provider 의 `default` 는 raw `module.exports` 여야 하므로(단독 import 시 node
 * CJS↔ESM 계약) namespace 를 실을 수 없기 때문이다.
 *
 * 빌드 exit 0 · 파싱 통과 · **실행만** 실패하는 계열이라 반드시 node 로 돌려 값을 본다.
 */

const LEGACY = 'module.exports = { foo() { return "FOO"; }, bar: 42 };';

async function buildPm(
  files: Record<string, string>,
  entry: string,
  format: 'esm' | 'cjs' = 'esm',
  minify = false,
) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, entry),
    '--preserve-modules',
    '--outdir',
    outDir,
    `--format=${format}`,
    ...(minify ? ['--minify'] : []),
  ]);
  expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
  if (format === 'esm') {
    writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
  }
  return { dir, outDir, cleanup };
}

describe('#4524: --preserve-modules × CJS', () => {
  test('정적 import (default + named) 가 동작한다', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'entry.js':
          'import d, { foo } from "./legacy.cjs";\n' +
          'console.log("default.bar:" + d.bar + "|foo:" + foo());',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      // 버그 시: ReferenceError: require_legacy is not defined
      expect(stderr).not.toContain('ReferenceError');
      expect(stdout.trim()).toBe('default.bar:42|foo:FOO');
    } finally {
      await cleanup();
    }
  });

  test('동적 import 가 named 멤버를 노출한다 (빈 namespace 아님)', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'entry.js':
          'const m = await import("./legacy.cjs");\n' +
          'console.log("keys:" + Object.keys(m).sort().join(",") + "|foo:" + (typeof m.foo === "function" ? m.foo() : "MISSING"));',
      },
      'entry.js',
    );
    try {
      const { stdout } = await runNode(join(outDir, 'entry.js'));
      // 버그 시: `keys:` (빈 namespace) / `foo:MISSING`
      expect(stdout.trim()).toBe('keys:bar,default,foo|foo:FOO');
    } finally {
      await cleanup();
    }
  });

  test('`import * as ns` 도 동작한다', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'entry.js':
          'import * as ns from "./legacy.cjs";\n' +
          'console.log("ns.bar:" + ns.bar + "|ns.foo:" + ns.foo());',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('ReferenceError');
      expect(stdout.trim()).toBe('ns.bar:42|ns.foo:FOO');
    } finally {
      await cleanup();
    }
  });

  test('anti-regression: ESM 전용 그래프는 중복 export 없이 그대로 동작한다', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'dep.js': 'export const v = 1;\nexport function f(){ return "ESM"; }',
        'entry.js': 'import { v, f } from "./dep.js";\nconsole.log(v + " " + f());',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      // 중복 export 면 `SyntaxError: Duplicate export`
      expect(stderr).toBe('');
      expect(stdout.trim()).toBe('1 ESM');
    } finally {
      await cleanup();
    }
  });
  test('--format=cjs 도 동작한다 (provider/consumer 술어가 어긋나지 않는다)', async () => {
    // provider 에만 `format == .esm` 조건이 있으면, 소비자는 `const { require_X } =
    // require("./x.js")` 를 내는데 provider 는 아무것도 안 깔아 `require_X is not a function`.
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'entry.js':
          'import d, { foo } from "./legacy.cjs";\n' +
          'console.log("default.bar:" + d.bar + "|foo:" + foo());',
      },
      'entry.js',
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('default.bar:42|foo:FOO');
    } finally {
      await cleanup();
    }
  });
  test('CJS 가 ESM 형제를 require 해도 동작한다 (래퍼 심볼 init_X/exports_X)', async () => {
    // wrap 된 ESM 모듈은 본문이 `__esm` 클로저 안이라 파일 top-level 에 남는 게 `init_X` /
    // `exports_X` 뿐이다. 그걸 export 하지 않으면 소비자가 **다른 파일의 지역변수**를
    // 렉시컬 참조한다 → `ReferenceError: init_b is not defined`.
    // 가장 흔한 레거시 interop 모양인데 예전엔 통째로 깨졌다.
    const { outDir, cleanup } = await buildPm(
      {
        'b.js': 'export const NAME = "B";\nexport function tag(){ return "B-tag"; }',
        'a.cjs': 'const b = require("./b.js");\nmodule.exports = { run: () => "A-" + b.tag() };',
        'entry.js': 'import a from "./a.cjs";\nconsole.log(a.run());',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('ReferenceError');
      expect(stdout.trim()).toBe('A-B-tag');
    } finally {
      await cleanup();
    }
  });

  test('CJS ↔ CJS 순환이 node 처럼 동작한다 (래퍼를 eager 호출하지 않는다)', async () => {
    // provider 가 `export default require_X();` 로 래퍼를 **호출**하면 CJS 본문이 파일 평가
    // 시점에 실행된다 → 순환에서 아직 미평가인 상대 파일의 `require_Y`(hoisted var, undefined)
    // 를 호출해 `TypeError: require_Y is not a function`. node 는 require 가 lazy 라 정상이다.
    // 래퍼 **선언만** export 해서 호출 시점을 소비자에게 남긴다.
    const { outDir, cleanup } = await buildPm(
      {
        'a.cjs': 'const b = require("./b.cjs");\nexports.a = function a(){ return "A+" + b.b(); };',
        'b.cjs': 'const a = require("./a.cjs");\nexports.b = function b(){ return "B"; };',
        'entry.js': 'import { a } from "./a.cjs";\nconsole.log("result:", a());',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('result: A+B');
    } finally {
      await cleanup();
    }
  });

  test('CJS 로부터의 named re-export 가 동작한다', async () => {
    // `imports_from` 에는 re-export 해석으로 CJS 의 export 명(`foo`)이 등록되는데, wrap 된
    // 모듈은 그걸 파일 밖으로 내지 않는다. 심볼 분기가 래퍼 분기보다 먼저 타면 provider 가
    // 내지도 않는 `import { foo } from "./legacy.js"` 를 내고 소비자 preamble 의
    // `require_legacy` 는 미-import → `SyntaxError: Identifier 'foo' has already been declared`.
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'reexp.js': 'export { foo } from "./legacy.cjs";',
        'entry.js': 'import { foo } from "./reexp.js";\nconsole.log(foo());',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('FOO');
    } finally {
      await cleanup();
    }
  });

  test('같은 CJS 를 두 번 동적 import 해도 suffix 가 중복되지 않는다', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'entry.js':
          'const m1 = await import("./legacy.cjs");\n' +
          'const m2 = await import("./legacy.cjs");\n' +
          'console.log(m1.foo() + "|" + m2.bar);',
      },
      'entry.js',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).toBe('');
      expect(stdout.trim()).toBe('FOO|42');
    } finally {
      await cleanup();
    }
  });
  test('#4526 --format=cjs 에서도 CJS ↔ CJS 순환이 동작한다 (구조분해 금지)', async () => {
    // ⚠️ cjs 소비자가 `const { require_b } = require("./b.js")` 로 **구조분해**하면 로드 시점에
    // 값을 **복사**한다. 순환에서 b.js 가 아직 평가 중인 a.js 를 require 하면
    // `exports.require_a` 가 미할당 → **undefined 를 박제** → 나중에 호출 시
    // `TypeError: require_a is not a function`.
    // node 는 require 가 lazy 라 순환을 정상 처리하고, ESM 은 live binding 이라 무사하다.
    // cjs 만 이 지연이 없어서, 래퍼 심볼(함수)을 lazy forwarding 으로 바인딩한다.
    const { outDir, cleanup } = await buildPm(
      {
        'a.cjs': 'const b = require("./b.cjs");\nexports.a = function a(){ return "A+" + b.b(); };',
        'b.cjs': 'const a = require("./a.cjs");\nexports.b = function b(){ return "B"; };',
        'entry.js': 'import { a } from "./a.cjs";\nconsole.log("result:", a());',
      },
      'entry.js',
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('result: A+B');
    } finally {
      await cleanup();
    }
  });

  test('#4526 --format=cjs 에서 CJS 가 ESM 형제를 require 해도 동작한다', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'b.js': 'export function tag(){ return "B-tag"; }',
        'a.cjs': 'const b = require("./b.js");\nmodule.exports = { run: () => "A-" + b.tag() };',
        'entry.js': 'import a from "./a.cjs";\nconsole.log(a.run());',
      },
      'entry.js',
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('ReferenceError');
      expect(stdout.trim()).toBe('A-B-tag');
    } finally {
      await cleanup();
    }
  });
  test('#4526 forwarding 이 사용자 top-level 심볼과 충돌하지 않는다 (holder 변수 없음)', async () => {
    // `const __zntc_w0 = require(...)` 처럼 우리가 이름을 지어 top-level 에 깔면 그 이름은
    // deconflict 를 안 거쳐서 사용자 코드의 동명 심볼과 **중복 선언**(SyntaxError) 이 난다.
    // `require()` 는 memoize 되므로 forwarding 안에서 다시 부르면 holder 자체가 불필요하다.
    const { outDir, cleanup } = await buildPm(
      {
        'legacy.cjs': LEGACY,
        'entry.js':
          'const __zntc_w0 = "USER";\n' +
          'import d from "./legacy.cjs";\n' +
          'console.log(__zntc_w0 + "|" + d.foo());',
      },
      'entry.js',
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      // 버그 시: SyntaxError: Identifier '__zntc_w0' has already been declared
      expect(stderr).not.toContain('SyntaxError');
      expect(stdout.trim()).toBe('USER|FOO');
    } finally {
      await cleanup();
    }
  });

  test('#4526 --format=cjs: ESM-wrap 모듈이 순환에 껴도 동작한다', async () => {
    const { outDir, cleanup } = await buildPm(
      {
        'b.js': 'import { a } from "./a.cjs";\nexport function tag(){ return "B(" + a() + ")"; }',
        'a.cjs':
          'const b = require("./b.js");\n' +
          'exports.a = function a(){ return "A"; };\n' +
          'exports.run = function(){ return b.tag(); };',
        'entry.js': 'import a from "./a.cjs";\nconsole.log(a.run());',
      },
      'entry.js',
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('ReferenceError');
      expect(stdout.trim()).toBe('B(A)');
    } finally {
      await cleanup();
    }
  });
  test('#4526 --format=cjs: ESM-wrap dep 이 순환에 껴도 exports_X 가 undefined 로 박제되지 않는다', async () => {
    // `exports_X` 는 **객체**라 forwarding 으로 감쌀 수 없다. eager 복사만 두면 순환에서 dep 이
    // **아직 평가 중**일 때 provider 의 `exports.exports_X = …` 가 아직 안 깔려 **undefined 를
    // 박제**하고, 나중에 `__toCommonJS(undefined)` →
    // `TypeError: Cannot convert undefined or null to object` 로 죽는다.
    //
    // 소비자의 사용처가 **항상** `(init_X(), __toCommonJS(exports_X))` — 즉 `init_X()` 가 먼저
    // 평가되는 순차식이므로, `let` 으로 선언하고 **init forwarding 안에서 갱신**하면 읽히기
    // 직전에 진짜 객체로 채워진다.
    //
    // ⚠️ entry 가 **b.js(ESM) 를 먼저** import 해야 b 가 먼저 평가되며 이 순서가 재현된다.
    const { outDir, cleanup } = await buildPm(
      {
        'b.js':
          'import { helper } from "./a.cjs";\nexport function tag(){ return "B+" + helper(); }',
        'a.cjs':
          'const b = require("./b.js");\n' +
          'exports.helper = function(){ return "H"; };\n' +
          'exports.callB = function(){ return b.tag(); };',
        'entry.js': 'import { callB } from "./a.cjs";\nconsole.log(callB());',
      },
      'entry.js',
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      // 버그 시: TypeError: Cannot convert undefined or null to object
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('B+H');
    } finally {
      await cleanup();
    }
  });
  // ─── #4528: wrap 된 모듈의 남은 구멍 3건 ───

  const WRAPPED = {
    'b.js': 'import { helper } from "./a.cjs";\nexport function tag(){ return "B+" + helper(); }',
    'a.cjs':
      'const b = require("./b.js");\n' +
      'exports.helper = function(){ return "H"; };\n' +
      'exports.callB = function(){ return b.tag(); };',
    'entry.js':
      'import { tag } from "./b.js";\n' +
      'import { callB } from "./a.cjs";\n' +
      'console.log(tag() + "|" + callB());',
  };

  for (const format of ['esm', 'cjs'] as const) {
    test(`#4528 ${format}: wrap 된 ESM dep 의 named import 가 바인딩된다`, async () => {
      // ⚠️ **wrap 종류마다 규칙이 다르다.**
      // - CJS: 본문 **전체**가 `__commonJS` 클로저 안 → top-level 에 export 명이 없다(래퍼뿐).
      // - ESM-wrap: 클로저에 들어가는 건 **부수효과 문장뿐**이고 `function tag(){}` 같은
      //   **선언은 파일 top-level 에 남는다** → 소비자도 bare 로 참조한다(단일 번들과 동일).
      // 그래서 CJS dep 만 심볼 목록을 버리고, ESM-wrap dep 은 래퍼 **와 함께** 심볼도 가져와야
      // 한다. 예전엔 둘 다 버려서 `ReferenceError: tag is not defined`.
      const { outDir, cleanup } = await buildPm(WRAPPED, 'entry.js', format);
      try {
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('Error');
        expect(stdout.trim()).toBe('B+H|B+H');
      } finally {
        await cleanup();
      }
    });

    test(`#4528 ${format} --minify: 래퍼 이름이 provider/consumer/본문 3자에서 일치한다`, async () => {
      // `rename_table` 은 **청크별**이라 provider emit 시점과 consumer emit 시점에 같은 심볼이
      // 다른 이름으로 해석됐다 → `import{o}` vs `export{require_a}` → `--minify` 가 통째로 깨졌다.
      // 래퍼 선언은 emitter 가 직접 찍어서 codegen 의 rename 대상이 아니다(=본문은 canonical 을
      // 쓴다) → canonical 하나로 통일하면 3자가 항상 일치한다.
      const { outDir, cleanup } = await buildPm(
        {
          'a.cjs':
            'const b = require("./b.cjs");\nexports.a = function a(){ return "A+" + b.b(); };',
          'b.cjs': 'const a = require("./a.cjs");\nexports.b = function b(){ return "B"; };',
          'entry.js': 'import { a } from "./a.cjs";\nconsole.log("result:", a());',
        },
        'entry.js',
        format,
        true,
      );
      try {
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('Error');
        expect(stdout.trim()).toBe('result: A+B');
      } finally {
        await cleanup();
      }
    });

    test(`#4528 ${format}: CJS user entry 가 본문을 실행한다`, async () => {
      // wrap 된 CJS 진입점은 아무도 `require_X()` 를 부르지 않아 **본문이 아예 실행되지
      // 않았다**(console.log 조차 안 찍힘). 진입점만 직접 호출한다 — dep 는 여전히 lazy 다
      // (eager 호출은 CJS 순환을 죽인다).
      // ⚠️ preserve-modules 는 **모든 모듈이 자기 entry_point 청크**라 chunk 종류로는 못 가른다.
      const { outDir, cleanup } = await buildPm(
        { 'main.cjs': 'console.log("ENTRY BODY RAN");\nmodule.exports = { x: 1 };' },
        'main.cjs',
        format,
      );
      try {
        const { stdout } = await runNode(join(outDir, 'main.js'));
        expect(stdout.trim()).toBe('ENTRY BODY RAN');
      } finally {
        await cleanup();
      }
    });
  }
  // ─── #4528 후속: /code-review max 가 잡은 회귀 4건 ───

  for (const format of ['esm', 'cjs'] as const) {
    test(`#4528 ${format}: wrap 된 ESM dep 의 class/const/let export 가 undefined 로 스냅샷되지 않는다`, async () => {
      // cjs 는 `exports.X = X` 로 **값 스냅샷**인데, ESM-wrap 모듈의 `const`/`class` 는
      // `__esm` 클로저(=`init_X()`) 안에서 **늦게 대입**된다 → 파일 top-level 스냅샷은
      // **undefined**. 함수 선언만 hoisting 으로 우연히 살아남아 버그가 가려진다.
      // → provider 는 **getter** 로 노출하고, 소비자는 **init 시점에 갱신**한다.
      // ⚠️ 선-init(`init_X()` 를 export 전에 호출)은 답이 아니다 — ESM-wrap 끼리 순환하면
      // 아직 미평가인 상대의 `init_Y`(undefined)를 부르게 된다.
      const { outDir, cleanup } = await buildPm(
        {
          'b.js':
            'export const CONST = "C";\n' +
            'export class W { hi(){ return "W"; } }\n' +
            'export let mut = "M";\n' +
            'export function fn(){ return "F"; }',
          'a.cjs':
            'const b = require("./b.js");\n' +
            'module.exports = { run: () => [b.CONST, new b.W().hi(), b.mut, b.fn()].join("|") };',
          'entry.js':
            'import a from "./a.cjs";\n' +
            'import { CONST, W, mut, fn } from "./b.js";\n' +
            'console.log(a.run() + " / " + [CONST, new W().hi(), mut, fn()].join("|"));',
        },
        'entry.js',
        format,
      );
      try {
        const { stdout } = await runNode(join(outDir, 'entry.js'));
        // 버그 시: `undefined|...` (함수만 살아남음)
        expect(stdout.trim()).toBe('C|W|M|F / C|W|M|F');
      } finally {
        await cleanup();
      }
    });

    test(`#4528 ${format}: ESM-wrap 모듈끼리 순환해도 심볼이 undefined 로 박제되지 않는다`, async () => {
      const { outDir, cleanup } = await buildPm(
        {
          'b.js': 'import { tagC } from "./c.js";\nexport function tag(){ return "B" + tagC(); }',
          'c.js':
            'import { tag } from "./b.js";\n' +
            'export function tagC(){ return "C"; }\n' +
            'export function useB(){ return tag(); }',
          'a.cjs':
            'const b = require("./b.js");\n' +
            'const c = require("./c.js");\n' +
            'module.exports = { run: () => b.tag() + "/" + c.useB() };',
          'entry.js': 'import a from "./a.cjs";\nconsole.log(a.run());',
        },
        'entry.js',
        format,
      );
      try {
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('TypeError');
        expect(stdout.trim()).toBe('BC/BC');
      } finally {
        await cleanup();
      }
    });

    test(`#4528 ${format}: ESM-wrap user entry 도 본문을 실행한다`, async () => {
      // `pm_entry_call` 이 `.cjs` 만 보면 ESM-wrap entry 는 `init_X()` 가 아무 데서도 안 불려
      // 본문이 통째로 미실행이다 — 같은 결함의 절반만 고친 꼴.
      const { outDir, cleanup } = await buildPm(
        {
          'entry.js':
            'console.log("ENTRY BODY RAN");\nimport { h } from "./a.cjs";\nexport const e = 1;',
          'a.cjs': 'const e = require("./entry.js");\nexports.h = function(){ return "H"; };',
        },
        'entry.js',
        format,
      );
      try {
        const { stdout } = await runNode(join(outDir, 'entry.js'));
        expect(stdout.trim()).toBe('ENTRY BODY RAN');
      } finally {
        await cleanup();
      }
    });

    test(`#4528 ${format}: CJS entry 의 module.exports 교체가 썽크 export 를 지우지 않는다`, async () => {
      // cjs 는 `module.exports = require_X()` 가 exports **객체를 교체**한다 — 바로 위에서 깐
      // `exports.require_X` 가 사라져, 이 entry 를 import 하는 다른 파일의 forwarding 썽크가
      // `undefined.apply` 로 죽는다. 교체 뒤에 **다시 붙인다**.
      const { outDir, cleanup } = await buildPm(
        {
          'main.cjs':
            'exports.m = function(){ return "M"; };\n' +
            'setTimeout(() => { console.log(require("./b.cjs").useMain()); }, 0);',
          'b.cjs':
            'const m = require("./main.cjs");\n' +
            'exports.useMain = function(){ return "via:" + m.m(); };',
        },
        'main.cjs',
        format,
      );
      try {
        const { stdout, stderr } = await runNode(join(outDir, 'main.js'));
        expect(stderr).not.toContain('TypeError');
        expect(stdout.trim()).toBe('via:M');
      } finally {
        await cleanup();
      }
    });
  }
  // ─── #4528 3차: 리뷰가 "고쳐지지 않았다" 고 잡은 2건 ───

  for (const format of ['esm', 'cjs'] as const) {
    test(`#4528 ${format}: 소비자 자신의 init 이 첫 호출이어도 const/class 가 undefined 가 아니다`, async () => {
      // ⚠️ forwarding 안에서 심볼 갱신을 `init_X()` **호출 전에** 하면 여전히 undefined 다
      // (값이 `__esm` 클로저 안에서 대입되므로). init 은 memoize 라 재갱신 기회도 없다.
      // → **init 을 먼저 돌리고 그 다음 갱신**해야 한다.
      //
      // ⚠️ 이 픽스처는 entry 가 **b.js 를 먼저** import 한다 — 그래야 소비자 자신의 `init_b()`
      // 가 첫 호출이 되어 버그가 드러난다. a.cjs 를 먼저 import 하면 provider 의 init 이 먼저
      // 돌아 **버그가 가려진다**(이전 테스트가 딱 그래서 통과하고 있었다).
      const { outDir, cleanup } = await buildPm(
        {
          'b.js':
            'export const CONST = "C";\n' +
            'export class W { hi(){ return "W"; } }\n' +
            'export let mut = "M";\n' +
            'export function fn(){ return "F"; }',
          'a.cjs': 'const b = require("./b.js");\nmodule.exports = { run: () => b.CONST };',
          'entry.js':
            'import { CONST, W, mut, fn } from "./b.js";\n' +
            'import a from "./a.cjs";\n' +
            'console.log([CONST, new W().hi(), mut, fn()].join("|") + " " + a.run());',
        },
        'entry.js',
        format,
      );
      try {
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        // 버그 시: TypeError: W is not a constructor (CONST/mut 은 undefined, 함수만 살아남음)
        expect(stderr).not.toContain('TypeError');
        expect(stdout.trim()).toBe('C|W|M|F C');
      } finally {
        await cleanup();
      }
    });

    test(`#4528 ${format}: 동명 심볼을 내는 wrap 된 dep 이 둘이어도 중복 선언되지 않는다`, async () => {
      // `let tag;` 가 두 번 나오면 **파싱 불가**(SyntaxError). 심볼 분기와 **같은** `$N`
      // deconflict 를 써야 한다.
      const { outDir, cleanup } = await buildPm(
        {
          'b.js': 'export function tag(){ return "B"; }',
          'c.js': 'export function tag(){ return "C"; }',
          'a.cjs':
            'const b = require("./b.js");\nconst c = require("./c.js");\nmodule.exports = { x: 1 };',
          'entry.js':
            'import { tag } from "./b.js";\n' +
            'import a from "./a.cjs";\n' +
            'console.log(tag() + a.x);',
        },
        'entry.js',
        format,
      );
      try {
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('SyntaxError');
        expect(stdout.trim()).toBe('B1');
      } finally {
        await cleanup();
      }
    });
  }
});
