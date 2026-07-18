import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4532 증상1 minify — `--preserve-modules --minify` 의 cross-file 심볼 네이밍.
 *
 * 배경: non-minify 증상1 은 #4570 으로 해결(전역명 `tag$1` 로 동명 붕괴 `BB`→`BC`). 그러나
 * minify 는 게이트가 `!minify_identifiers` 로 닫혀 여전히 `BB` 였다. 게이트를 열면 소비자 함수의
 * mangled nested 로컬이 전역명(예 `te`)과 충돌해 shadow → silent miscompile 이 드러난다.
 *
 * Approach 3: preserve-modules 를 splitting 과 동일한 per-chunk mangle + 전역명 브리지 모델로
 * 통합한다. 아래 테스트는 **관측 가능한 런타임 동작**(내부 네이밍 무관)을 스펙으로 고정한다 —
 * 빌드 exit 0·파싱 통과·실행만 실패하는 계열이라 반드시 node 로 돌려 값을 본다.
 */

async function buildPm(
  files: Record<string, string>,
  entry: string,
  format: 'esm' | 'cjs',
  minify: boolean,
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
  // 빌드 실패 시 temp fixture 를 먼저 정리한 뒤 throw — 안 하면 assert 가 cleanup 반환 전에
  // 던져 caller 의 finally 가 안 돌아 temp dir 이 샌다.
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  writeFileSync(
    join(outDir, 'package.json'),
    JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
  );
  return { dir, outDir, cleanup };
}

async function run(outDir: string) {
  const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
  return { stdout: stdout.trim(), stderr };
}

const FORMATS = ['esm', 'cjs'] as const;
const MINIFY = [false, true] as const;

describe('#4532 증상1 minify: preserve-modules cross-file 네이밍', () => {
  // ── 동명 export 붕괴 (BB → BC) ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`동명 export 가 붕괴하지 않는다 [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'b.js': 'export function tag(){ return "B"; }',
            'c.js': 'export function tag(){ return "C"; }',
            'a.cjs': 'module.exports = require("./b.js");\nrequire("./c.js");',
            'entry.js':
              'import { tag } from "./b.js";\n' +
              'import { tag as tag2 } from "./c.js";\n' +
              'import "./a.cjs";\n' +
              'console.log(tag() + tag2());',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          expect(stdout).toBe('BC'); // 수정 전 minify: BB
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── aliased import + 전역명 ↔ mangled 로컬 shadow 충돌 ──
  // Approach 3 핵심 가드: 소비자 함수의 mangled nested 로컬이 cross-chunk 전역명과 같은 base54
  // 이름(`te`)으로 mangle 돼도 import 를 shadow 하면 안 된다. 로컬을 2회 이상 사용해 폴딩/인라인을
  // 피하고, ~70개로 base54 가 2글자 이름(`te`)에 도달하게 강제한다.
  for (const format of FORMATS) {
    test(`aliased import: mangled 로컬이 전역명을 shadow 안 함 [${format} minify]`, async () => {
      const N = 70;
      let body = '  let s = myAlias();\n';
      for (let i = 1; i <= N; i++) body += `  const v${i} = x * ${i} + 1;\n`;
      for (let i = 1; i <= N; i++) body += `  s += v${i} * v${i};\n`;
      let expected = 7;
      for (let i = 1; i <= N; i++) {
        const v = 2 * i + 1;
        expected += v * v;
      }
      const { outDir, cleanup } = await buildPm(
        {
          'provider.js': 'export function te(){ return 7; }',
          'w.cjs': 'module.exports = require("./provider.js");',
          'entry.js':
            'import { te as myAlias } from "./provider.js";\n' +
            'import "./w.cjs";\n' +
            `export function big(x){\n${body}  return s;\n}\n` +
            'console.log(big(2));',
        },
        'entry.js',
        format,
        true,
      );
      try {
        const { stdout, stderr } = await run(outDir);
        expect(stderr).not.toContain('is not a function'); // 수정 전: te is not a function
        expect(stdout).toBe(String(expected));
      } finally {
        await cleanup();
      }
    });
  }

  // ── reserved-name(default) named import forwarding ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`default(reserved) named import forwarding [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'b.js': 'export default function foo(){ return "B"; }',
            'a.cjs': 'module.exports = require("./b.js");',
            'entry.js': 'import foo from "./b.js";\nimport "./a.cjs";\nconsole.log(foo());',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('TypeError');
          expect(stdout).toBe('B');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── re-export 배럴 (증상3) ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`re-export 배럴이 ESM-wrap dep 을 re-export [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'b.js': 'export const CONST = 42;\nexport function fn(){ return "F"; }',
            'a.cjs': 'module.exports = require("./b.js");',
            'r.js': 'export { CONST, fn } from "./b.js";',
            'entry.js':
              'import { CONST, fn } from "./r.js";\nimport "./a.cjs";\nconsole.log(CONST + "|" + fn());',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('TypeError');
          expect(stdout).toBe('42|F');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── 4-way 동명 stress ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`4-way 동명 export 가 서로 구분된다 [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'w.cjs':
            'module.exports = require("./m1.js");\nrequire("./m2.js"); require("./m3.js"); require("./m4.js");',
          'entry.js':
            'import { tag as t1 } from "./m1.js";\nimport { tag as t2 } from "./m2.js";\n' +
            'import { tag as t3 } from "./m3.js";\nimport { tag as t4 } from "./m4.js";\n' +
            'import "./w.cjs";\nconsole.log([t1(),t2(),t3(),t4()].join("|"));',
        };
        for (const n of [1, 2, 3, 4]) {
          files[`m${n}.js`] = `export function tag(){ return "T${n}"; }`;
        }
        const { outDir, cleanup } = await buildPm(files, 'entry.js', format, minify);
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          expect(stdout).toBe('T1|T2|T3|T4');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── cross-file 기본: top-level 이 mangle 돼도 파일 경계 참조가 유지된다 ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`cross-file named import/const 가 유지된다 [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'lib.js':
              'export function computeSomething(someArgument){ const intermediateValue = someArgument * 2; return intermediateValue + 1; }\n' +
              'export const LIB_CONST = 100;',
            'entry.js':
              'import { computeSomething, LIB_CONST } from "./lib.js";\n' +
              'const reallyLongLocalName = computeSomething(21);\n' +
              'console.log(reallyLongLocalName + "|" + LIB_CONST);',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          expect(stdout).toBe('43|100');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── namespace import (`import * as ns`) ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`import * as ns (leaf ESM-wrap dep) [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'lib.js': 'export const val = 1;\nexport function greet(){ return "hi"; }',
            'a.cjs': 'module.exports = require("./lib.js");',
            'entry.js':
              'import * as ns from "./lib.js";\nimport "./a.cjs";\nconsole.log(ns.val + "|" + ns.greet());',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          expect(stdout).toBe('1|hi');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── 동명 export + 각 파일 내부 로컬 (전역명 $N ↔ 내부 mangle 교차) ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`동명 export + 내부 로컬 stress [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'w.cjs': 'module.exports = require("./m1.js");\nrequire("./m2.js");',
          'entry.js':
            'import { e as e1, v as v1 } from "./m1.js";\n' +
            'import { e as e2, v as v2 } from "./m2.js";\n' +
            'import "./w.cjs";\n' +
            'console.log(e1(3) + "|" + e2(3) + "|" + v1 + "|" + v2);',
        };
        files['m1.js'] =
          'export function e(x){ const a=x+1, b=a*2, c=b-1; return "P1:"+(a+b+c); }\nexport const v = 10;';
        files['m2.js'] =
          'export function e(y){ const a=y+2, b=a*3, d=b+5; return "P2:"+(a+b+d); }\nexport const v = 20;';
        const { outDir, cleanup } = await buildPm(files, 'entry.js', format, minify);
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          // m1.e(3): a=4,b=8,c=7 → 19 ; m2.e(3): a=5,b=15,d=20 → 40
          expect(stdout).toBe('P1:19|P2:40|10|20');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── default export **값**(named 아님): 브리지로 mangle+공개 조율 ──
  // 래퍼 심볼은 제외하지만 default_export synthetic 은 mangle 후보로 유지(일반 export 브리지).
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`default export 값이 mangle 되어도 동작 [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'd.js': 'const secret = 41;\nexport default secret + 1;',
            'w.cjs': 'module.exports = require("./d.js");',
            'entry.js':
              'import myDefault from "./d.js";\nimport "./w.cjs";\nconsole.log(myDefault);',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          expect(stdout).toBe('42');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // ── CJS 래퍼(require_X): 래퍼 심볼 canonical 유지가 minify 에서도 성립 ──
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`CJS require_X 래퍼가 canonical 로 유지된다 [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'a.cjs':
              'const dep = require("./dep.cjs");\nexports.run = function(){ return "R-" + dep.helper(); };',
            'dep.cjs': 'exports.helper = function(){ return "H"; };',
            'entry.js': 'import { run } from "./a.cjs";\nconsole.log(run());',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await run(outDir);
          expect(stderr).not.toContain('Error');
          expect(stdout).toBe('R-H');
        } finally {
          await cleanup();
        }
      });
    }
  }
});
