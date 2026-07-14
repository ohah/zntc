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

async function buildPm(files: Record<string, string>, entry: string) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, entry),
    '--preserve-modules',
    '--outdir',
    outDir,
    '--format=esm',
  ]);
  expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
  writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
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
});
