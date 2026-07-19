import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4580 — `--preserve-modules --format=cjs` 에서 **default-only 모듈**(default export 만, named 없음)
 * 은 `module.exports = X`(default = exports 전체) 로 방출된다. 그런데 소비자가 그 default 를
 * `const { default: foo } = require("./m1.js")` 로 **`.default` 구조분해**해 읽으면 `foo`=undefined
 * → `TypeError: foo is not a function`. `require()` 결과 **전체**가 default 이므로
 * `const foo = require("./m1.js")` 로 바인딩해야 한다(Node `module.exports = foo` 계약).
 *
 * default+named(mixed) 모듈은 `exports.default = X` + `__esModule` 로 방출되므로 구조분해가 맞다.
 *
 * ⚠️ `--minify-identifiers`(따라서 `--minify`)는 별개 선행 mangler 버그(#4579 계열)로 소비자 default
 *    import 로컬과 body 참조가 발산해 실패한다 — 이 fix 유무·구조분해/전체바인딩 무관, main 도 동일.
 *    따라서 여기선 non-minify 만 런타임 검증한다.
 */

async function buildPmCjs(files: Record<string, string>) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, 'entry.js'),
    '--preserve-modules',
    `--preserve-modules-root=${dir}`,
    '--outdir',
    outDir,
    '--format=cjs',
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
  return { outDir, cleanup };
}

describe('#4580: preserve-modules cjs default interop', () => {
  test('default-only → 전체 바인딩 (const x = require)', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'm1.js': 'export default function foo(){ return "D1"; }',
      'entry.js': 'import a from "./m1.js";\nconsole.log(a());',
    });
    try {
      const entry = readFileSync(join(outDir, 'entry.js'), 'utf8');
      expect(entry).toMatch(/const foo = require\("\.\/m1\.js"\)/); // 전체 바인딩
      expect(entry).not.toMatch(/\{\s*default:\s*foo\s*\}\s*=\s*require\("\.\/m1\.js"\)/); // 구조분해 아님
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('D1');
    } finally {
      await cleanup();
    }
  });

  test('default + named → 구조분해 유지 (exports.default + __esModule)', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'm1.js': 'export default function foo(){ return "D1"; }\nexport const bar = "B";',
      'entry.js': 'import a, { bar } from "./m1.js";\nconsole.log(a() + bar);',
    });
    try {
      const entry = readFileSync(join(outDir, 'entry.js'), 'utf8');
      expect(entry).toMatch(/default:\s*foo/); // 구조분해 유지
      const { stdout } = await runNode(join(outDir, 'entry.js'));
      expect(stdout.trim()).toBe('D1B');
    } finally {
      await cleanup();
    }
  });

  test('re-export 배럴 (default-only barrel)', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'm1.js': 'export default function foo(){ return "D1"; }',
      'barrel.js': 'export { default } from "./m1.js";',
      'entry.js': 'import a from "./barrel.js";\nconsole.log(a());',
    });
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('D1');
    } finally {
      await cleanup();
    }
  });

  test('mixed 배럴 (default 재-export + named)', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'm1.js': 'export default function foo(){ return "D1"; }',
      'barrel.js': 'export { default } from "./m1.js";\nexport const extra = "E";',
      'entry.js': 'import a, { extra } from "./barrel.js";\nconsole.log(a() + extra);',
    });
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('D1E');
    } finally {
      await cleanup();
    }
  });

  test('동명 default 2개 (#4576 deconflict + #4580 interop 협업)', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'm1.js': 'export default function foo(){ return "1"; }',
      'm2.js': 'export default function foo(){ return "2"; }',
      'entry.js': 'import a from "./m1.js";\nimport b from "./m2.js";\nconsole.log(a() + b());',
    });
    try {
      const entry = readFileSync(join(outDir, 'entry.js'), 'utf8');
      // 각각 전체 바인딩 + deconflict: const foo = require(m1); const foo$2 = require(m2);
      expect(entry).toMatch(/const foo = require\("\.\/m1\.js"\)/);
      expect(entry).toMatch(/const foo\$2 = require\("\.\/m2\.js"\)/);
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('SyntaxError');
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('12');
    } finally {
      await cleanup();
    }
  });

  test('[리뷰 0] export default + export *(소스 named 0) → 전체 바인딩', async () => {
    // provider 는 star 를 flatten 해 named 0 → `module.exports = X`(default-only). 소비자도
    // star 를 재귀 flatten 해 default-only 로 판정하고 전체 바인딩해야 한다(구조분해면 TypeError).
    const { outDir, cleanup } = await buildPmCjs({
      'consts.js': 'export default 99;', // star 는 default 를 재-export 안 함 → named 0
      'm1.js': 'export default function foo(){ return "D1"; }\nexport * from "./consts.js";',
      'entry.js': 'import a from "./m1.js";\nconsole.log(a());',
    });
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('D1');
    } finally {
      await cleanup();
    }
  });

  test('export default + export *(소스 named 有) → 구조분해 유지', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'consts.js': 'export const z = "Z";',
      'm1.js': 'export default function foo(){ return "D1"; }\nexport * from "./consts.js";',
      'entry.js': 'import a, { z } from "./m1.js";\nconsole.log(a() + z);',
    });
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('D1Z');
    } finally {
      await cleanup();
    }
  });

  test('named-only 모듈은 영향 없음', async () => {
    const { outDir, cleanup } = await buildPmCjs({
      'm1.js': 'export const a = "A";\nexport const b = "B";',
      'entry.js': 'import { a, b } from "./m1.js";\nconsole.log(a + b);',
    });
    try {
      const entry = readFileSync(join(outDir, 'entry.js'), 'utf8');
      expect(entry).toMatch(/\{[^}]*\}\s*=\s*require\("\.\/m1\.js"\)/); // 구조분해 유지
      const { stdout } = await runNode(join(outDir, 'entry.js'));
      expect(stdout.trim()).toBe('AB');
    } finally {
      await cleanup();
    }
  });
});
