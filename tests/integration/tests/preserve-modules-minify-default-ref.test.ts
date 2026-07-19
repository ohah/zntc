import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4579 — `--preserve-modules --minify(-identifiers)` 에서 소비자의 **default import** body 참조가
 * 발산해 실패하던 것 수정.
 *
 * 근본(타이밍): import 문 로컬명과 body 참조 둘 다 `resolveToLocalName(provider,"default")` →
 * `rename_table` 을 읽는다. import 블록은 `computeRenamesForModules`(per-chunk `clearCanonicalNames`)
 * **전**에 돌아 provider chunk 의 mangle(`foo→t`)을 보지만, body(effective_target, emitModule)는 **후**라
 * provider mangle 이 wipe돼 stale 원본 `foo` 로 fallback → `const t=require();foo()` (foo undefined).
 * default 는 public 명이 없어(`module.exports=X`) 특히 그렇다.
 *
 * 수정: import 블록이 이미 rename_table 유효 시점에 구한 로컬(`t`)을 **무조건** `consumer_import_local`
 * 에 기록해(#4576 deconflict 시에만 → 무조건, preserve_modules 게이트), body 의 effective_target 이
 * 그 값을 읽어 정합. 이 fix 로 #4576(동명 default)·#4580(default interop) 의 minify 도 함께 풀린다.
 *
 * ⚠️ 무조건 write 는 non-minify preserve-modules 에도 적용되므로(리뷰 [0]), minify/non-minify 양쪽을
 *    검증해 always-write 회귀를 가드한다.
 */

async function buildRun(files: Record<string, string>, format: 'esm' | 'cjs', minify: boolean) {
  const { dir, cleanup } = await createFixture(files);
  try {
    const outDir = join(dir, 'dist');
    const res = await runZntc([
      '--bundle',
      join(dir, 'entry.js'),
      '--preserve-modules',
      `--preserve-modules-root=${dir}`,
      '--outdir',
      outDir,
      `--format=${format}`,
      ...(minify ? ['--minify'] : []),
    ]);
    if (res.exitCode !== 0) throw new Error(`빌드 실패:\n${res.stderr}`);
    writeFileSync(
      join(outDir, 'package.json'),
      JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
    );
    // runNode 는 non-zero exit(런타임 ReferenceError/TypeError) 시 throw → 그 자체가 가드.
    // exit-0 wrong-output 은 stdout 단언이 가드.
    const { stdout } = await runNode(join(outDir, 'entry.js'));
    return stdout.trim();
  } finally {
    await cleanup();
  }
}

const FORMATS = ['esm', 'cjs'] as const;
const MINIFY = [false, true] as const;

const CASES: Array<{ name: string; files: Record<string, string>; expect: string }> = [
  {
    name: '단일 default',
    files: {
      'm1.js': 'export default function foo(){ return "D1"; }',
      'entry.js': 'import a from "./m1.js";\nconsole.log(a());',
    },
    expect: 'D1',
  },
  {
    name: '동명 default 2개 (#4576 minify)',
    files: {
      'm1.js': 'export default function foo(){ return "D1"; }',
      'm2.js': 'export default function foo(){ return "D2"; }',
      'entry.js': 'import a from "./m1.js";\nimport b from "./m2.js";\nconsole.log(a() + b());',
    },
    expect: 'D1D2',
  },
  {
    name: 'default + named',
    files: {
      'm1.js': 'export default function foo(){ return "D1"; }\nexport const bar = "B";',
      'entry.js': 'import a, { bar } from "./m1.js";\nconsole.log(a() + bar);',
    },
    expect: 'D1B',
  },
  {
    name: 'default class',
    files: {
      'm1.js': 'export default class Foo { greet(){ return "C"; } }',
      'entry.js': 'import A from "./m1.js";\nconsole.log(new A().greet());',
    },
    expect: 'C',
  },
];

describe('#4579: preserve-modules default import body 참조 정합 (minify/non-minify)', () => {
  for (const c of CASES) {
    for (const format of FORMATS) {
      for (const minify of MINIFY) {
        test(`${c.name} [${format}${minify ? ' --minify' : ''}]`, async () => {
          expect(await buildRun(c.files, format, minify)).toBe(c.expect);
        });
      }
    }
  }
});
