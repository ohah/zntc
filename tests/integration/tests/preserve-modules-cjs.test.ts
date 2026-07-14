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
});
