import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4576 — preserve-modules 에서 서로 다른 파일이 **같은 로컬명으로 `export default`** 하고
 * 한 소비자가 둘 다 default import 하면, 소비자 import 블록이 `import { default as foo }` 를
 * 두 번 방출해 `Identifier 'foo' has already been declared`(SyntaxError)로 파싱 실패.
 *
 * 근본: 소비자 import 블록(chunks.zig)의 `$N` deconflict 는 `key == binding` 분기에서만 했다.
 * default 는 key=`default`, binding=`foo`(또는 익명 `_default`)라 `key != binding` 분기로 가는데
 * 거기서 deconflict 를 안 해 로컬명이 중복. 수정: 선언 로컬은 항상 binding 이므로 count 를
 * **binding-keyed 로 통일** + `key != binding` 분기도 binding 충돌 시 `binding$N` deconflict +
 * consumer_import_local(#4572) 맵에 기록해 body 참조를 맞춘다.
 *
 * ⚠️ 별개 선행 버그(이 PR 범위 밖, 별도 후속):
 *  - `--minify-identifiers`: mangler 가 소비자 default import local 은 개명하는데 body 참조는 다른
 *    심볼로 취급해 발산(silent). #4576 fix 유무와 무관(main 도 동일).
 *  - cjs: `module.exports = foo` provider 를 소비자가 `{ default: foo }` 로 구조분해하는 default
 *    interop 오류. 단일 default 도 실패(중복과 무관). #4576 fix 로 **중복선언 SyntaxError 는 제거**
 *    되지만 interop 오류는 남는다 → 아래 cjs 테스트는 중복-제거(emit)만 검증한다.
 */

async function buildPmEsm(files: Record<string, string>, minifyFlags: string[]) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, 'entry.js'),
    '--preserve-modules',
    `--preserve-modules-root=${dir}`,
    '--outdir',
    outDir,
    '--format=esm',
    ...minifyFlags,
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
  return { outDir, cleanup };
}

// identifier mangling 은 별개 선행 버그라 제외. whitespace/syntax 는 정상 동작.
const ESM_VARIANTS: Array<{ label: string; flags: string[] }> = [
  { label: 'plain', flags: [] },
  { label: 'minify-whitespace', flags: ['--minify-whitespace'] },
  { label: 'minify-syntax', flags: ['--minify-syntax'] },
];

const CASES: Array<{ name: string; files: Record<string, string>; expect: string }> = [
  {
    name: 'named default 동명 foo',
    files: {
      'm1.js': 'export default function foo(){ return "D1"; }',
      'm2.js': 'export default function foo(){ return "D2"; }',
      'entry.js': 'import a from "./m1.js";\nimport b from "./m2.js";\nconsole.log(a() + b());',
    },
    expect: 'D1D2',
  },
  {
    name: '익명 default 동명 (_default)',
    files: {
      'm1.js': 'export default function(){ return "A1"; }',
      'm2.js': 'export default function(){ return "A2"; }',
      'entry.js': 'import a from "./m1.js";\nimport b from "./m2.js";\nconsole.log(a() + b());',
    },
    expect: 'A1A2',
  },
  {
    name: 'cross-branch named(key==binding) + default(key!=binding) 동명',
    files: {
      'm1.js': 'export const foo = () => "N1";',
      'm2.js': 'export default function foo(){ return "D2"; }',
      'entry.js':
        'import { foo } from "./m1.js";\nimport d from "./m2.js";\nconsole.log(foo() + d());',
    },
    expect: 'N1D2',
  },
  {
    name: '3-way: 충돌 2 + 비충돌 1',
    files: {
      'm1.js': 'export default function foo(){ return "1"; }',
      'm2.js': 'export default function foo(){ return "2"; }',
      'm3.js': 'export default function bar(){ return "3"; }',
      'entry.js':
        'import a from "./m1.js";\nimport b from "./m2.js";\nimport c from "./m3.js";\nconsole.log(a() + b() + c());',
    },
    expect: '123',
  },
  {
    // 리뷰 [0]: dedup 이름(`foo$2`)이 **다른 심볼의 자연명** `foo$2` 와 충돌하면 안 됨.
    // per-binding 카운터는 여기서 둘 다 `foo$2` 를 내 SyntaxError. used_locals 는 `foo$3` 로 회피.
    name: 'dedup 이름이 자연 foo$2 심볼과 충돌 회피',
    files: {
      'm1.js': 'export default function foo(){ return "1"; }',
      'm2.js': 'export default function foo(){ return "2"; }',
      'm3.js': 'export function foo$2(){ return "3"; }',
      'entry.js':
        'import a from "./m1.js";\nimport b from "./m2.js";\nimport { foo$2 } from "./m3.js";\nconsole.log(a() + b() + foo$2());',
    },
    expect: '123',
  },
];

describe('#4576: preserve-modules 동명 export default deconflict (esm)', () => {
  for (const c of CASES) {
    for (const v of ESM_VARIANTS) {
      test(`${c.name} [${v.label}]`, async () => {
        const { outDir, cleanup } = await buildPmEsm(c.files, v.flags);
        try {
          const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
          expect(stderr).not.toContain('SyntaxError'); // 중복 선언
          expect(stderr).not.toContain('ReferenceError');
          expect(stdout.trim()).toBe(c.expect);
        } finally {
          await cleanup();
        }
      });
    }
  }
});

/**
 * cjs — #4576 fix 는 **중복 선언 자체를 제거**한다(로컬 `foo`/`foo$2`). 런타임은 별개의 cjs
 * default interop 선행 버그로 실패하므로 여기선 emit 에 동일 로컬 이중 선언이 없음만 확인한다.
 */
describe('#4576: cjs 동명 default 는 중복 로컬 선언을 만들지 않는다', () => {
  test('두 default → 서로 다른 로컬 (const 중복 없음)', async () => {
    const { dir, cleanup } = await createFixture({
      'm1.js': 'export default function foo(){ return "D1"; }',
      'm2.js': 'export default function foo(){ return "D2"; }',
      'entry.js': 'import a from "./m1.js";\nimport b from "./m2.js";\nconsole.log(a() + b());',
    });
    const outDir = join(dir, 'dist');
    try {
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--preserve-modules',
        `--preserve-modules-root=${dir}`,
        '--outdir',
        outDir,
        '--format=cjs',
      ]);
      expect(res.exitCode).toBe(0);
      const entry = readFileSync(join(outDir, 'entry.js'), 'utf8');
      // 같은 로컬명 `foo` 를 두 번 선언하면 SyntaxError. deconflict 되면 `foo` 는 정확히 1회,
      // 두 번째는 `foo$2`. 두 조건 모두 단언(음성 vacuous 방지 — 출력이 사라져도 통과하면 안 됨).
      const bareFoo = entry.match(/default:\s*foo(?![\w$])/g) ?? []; // 정확히 `foo`
      const deconflicted = entry.match(/default:\s*foo\$\d+/g) ?? []; // `foo$2` 등
      expect(bareFoo.length).toBe(1); // 정확히 1회 (0 이면 출력 소실, 2 면 중복)
      expect(deconflicted.length).toBe(1); // 두 번째는 deconflict
    } finally {
      await cleanup();
    }
  });
});

/**
 * 리뷰 [1]: ESM-wrap(전역명 고정) default 와 plain default 가 동명이면, wrap 쪽은 이름을 못 바꾸므로
 * plain 쪽이 deconflict 돼야 한다. import 순서와 무관하게 성립해야 함(pre-pass 로 전역명 예약).
 */
describe('#4576: 전역명 고정 default + plain default 동명 (순서 무관)', () => {
  for (const wrapFirst of [false, true]) {
    test(`plain deconflict [wrap ${wrapFirst ? '먼저' : '나중'}]`, async () => {
      const imports = wrapFirst
        ? 'import w from "./wrap.js";\nimport p from "./plain.js";'
        : 'import p from "./plain.js";\nimport w from "./wrap.js";';
      const { dir, cleanup } = await createFixture({
        'plain.js': 'export default function foo(){ return "P"; }',
        'wrap.js': 'export default function foo(){ return "W"; }',
        'a.cjs': 'module.exports = require("./wrap.js");', // wrap 을 ESM-wrap 강제(전역명 부여)
        'entry.js': `${imports}\nimport "./a.cjs";\nconsole.log(p() + w());`,
      });
      const outDir = join(dir, 'dist');
      try {
        const res = await runZntc([
          '--bundle',
          join(dir, 'entry.js'),
          '--preserve-modules',
          `--preserve-modules-root=${dir}`,
          '--outdir',
          outDir,
          '--format=esm',
        ]);
        expect(res.exitCode).toBe(0);
        writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('SyntaxError');
        expect(stdout.trim()).toBe('PW');
      } finally {
        await cleanup();
      }
    });
  }
});
