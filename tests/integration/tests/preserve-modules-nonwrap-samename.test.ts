import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4572 — `--preserve-modules` 에서 **비-ESM-wrap** 동명 export 붕괴.
 *
 * 서로 다른 파일이 동명 export(`tag`)를 내고, provider 가 CJS-flatten(`a.cjs = require(...)`)을
 * 안 거쳐 **ESM-wrap 이 아니면**, 소비자 본문이 한 이름으로 붕괴한다(예 `t1()+t3()` 가 둘 다
 * m1 의 `tag`). import 문은 `import { tag as tag$3 }` 로 deconflict 되는데 body 참조가
 * `resolveToLocalName(canonical)` = `tag` 로 발산하는 게 근본. 전역명이 ESM-wrap owner 로
 * 한정(#4559)돼 non-wrap owner 는 전역명이 안 붙었다. minify·non-minify 공통.
 *
 * 관측 가능한 런타임 값으로 스펙 고정 — node 로 실행해 값을 본다.
 */

async function buildPm(files: Record<string, string>, format: 'esm' | 'cjs', minify: boolean) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, 'entry.js'),
    '--preserve-modules',
    '--outdir',
    outDir,
    `--format=${format}`,
    ...(minify ? ['--minify'] : []),
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  writeFileSync(
    join(outDir, 'package.json'),
    JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
  );
  return { outDir, cleanup };
}

const FORMATS = ['esm', 'cjs'] as const;
const MINIFY = [false, true] as const;

describe('#4572: preserve-modules 비-ESM-wrap 동명 export', () => {
  // 기본: m1·m2 는 ESM-wrap(a.cjs 가 require), m3 은 non-wrap(entry 만 import)
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`혼합(wrap m1·m2 + non-wrap m3) [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'a.cjs': 'module.exports = require("./m1.js");\nrequire("./m2.js");',
          'entry.js':
            'import { tag as t1 } from "./m1.js";\nimport { tag as t2 } from "./m2.js";\n' +
            'import { tag as t3 } from "./m3.js";\nimport "./a.cjs";\n' +
            'console.log(t1() + t2() + t3());',
        };
        for (const n of [1, 2, 3]) files[`m${n}.js`] = `export function tag(){ return "T${n}"; }`;
        const { outDir, cleanup } = await buildPm(files, format, minify);
        try {
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('T1T2T3'); // 수정 전: T1T2T1
        } finally {
          await cleanup();
        }
      });
    }
  }

  // 순수 non-wrap: 아무도 ESM-wrap 되지 않은 동명 import (CJS-flatten 없음)
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`순수 non-wrap 동명 [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'entry.js':
            'import { tag as t1 } from "./m1.js";\nimport { tag as t2 } from "./m2.js";\n' +
            'import { tag as t3 } from "./m3.js";\n' +
            'console.log(t1() + t2() + t3());',
        };
        for (const n of [1, 2, 3]) files[`m${n}.js`] = `export function tag(){ return "N${n}"; }`;
        const { outDir, cleanup } = await buildPm(files, format, minify);
        try {
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('N1N2N3');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // 동명 const export (함수 아님)
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`non-wrap 동명 const [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'entry.js':
            'import { v as v1 } from "./m1.js";\nimport { v as v2 } from "./m2.js";\n' +
            'console.log(v1 + "|" + v2);',
          'm1.js': 'export const v = "A";',
          'm2.js': 'export const v = "B";',
        };
        const { outDir, cleanup } = await buildPm(files, format, minify);
        try {
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('A|B');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // non-wrap 동명을 re-export 배럴 경유로 소비 (배럴 local 도 전역명 브리지 필요)
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`non-wrap 동명 re-export 배럴 [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'm1.js': 'export function tag(){ return "R1"; }',
          'm2.js': 'export function tag(){ return "R2"; }',
          'r1.js': 'export { tag } from "./m1.js";',
          'r2.js': 'export { tag } from "./m2.js";',
          'entry.js':
            'import { tag as a } from "./r1.js";\nimport { tag as b } from "./r2.js";\n' +
            'console.log(a() + b());',
        };
        const { outDir, cleanup } = await buildPm(files, format, minify);
        try {
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('R1R2'); // 수정 전: 붕괴/크래시
        } finally {
          await cleanup();
        }
      });
    }
  }

  // 다단계 re-export 체인(top → mid → m) 동명
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`non-wrap 동명 다단계 re-export 체인 [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'm1.js': 'export function tag(){ return "C1"; }',
          'm2.js': 'export function tag(){ return "C2"; }',
          'mid1.js': 'export { tag } from "./m1.js";',
          'top1.js': 'export { tag } from "./mid1.js";',
          'top2.js': 'export { tag } from "./m2.js";',
          'entry.js':
            'import { tag as a } from "./top1.js";\nimport { tag as b } from "./top2.js";\n' +
            'console.log(a() + b());',
        };
        const { outDir, cleanup } = await buildPm(files, format, minify);
        try {
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('C1C2');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // non-wrap provider 를 두 소비자가 각각 import (전역명 일관성)
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`non-wrap 동명 + 2 consumer [${format}${minify ? ' minify' : ''}]`, async () => {
        const files: Record<string, string> = {
          'm1.js': 'export function tag(){ return "X1"; }',
          'm2.js': 'export function tag(){ return "X2"; }',
          'mid.js':
            'import { tag as a } from "./m1.js";\nimport { tag as b } from "./m2.js";\n' +
            'export function combined(){ return a() + b(); }',
          'entry.js':
            'import { tag as t1 } from "./m1.js";\nimport { tag as t2 } from "./m2.js";\n' +
            'import { combined } from "./mid.js";\n' +
            'console.log(t1() + t2() + "|" + combined());',
        };
        const { outDir, cleanup } = await buildPm(files, format, minify);
        try {
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('X1X2|X1X2');
        } finally {
          await cleanup();
        }
      });
    }
  }
});
