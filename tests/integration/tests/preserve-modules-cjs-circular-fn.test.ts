import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4532 증상4 — `--preserve-modules --format=cjs` 순환 import 에서 **function 선언 export** 가
 * 소비자 로드 중 `undefined` 로 잡히던 것 수정.
 *
 * 근본: cjs 는 `exports.a = a` 를 모듈 본문 **끝**(require 뒤)에 방출한다. 순환에서 e2 가 e1 을
 * require 하는 시점엔 e1 의 `exports.a = a` 가 아직 실행 전 → `a`=undefined. ESM 은 function 선언이
 * hoisting 돼 live-binding 으로 항상 함수(`typeof a === "function"`).
 *
 * 수정: unwrapped pm-cjs 모듈의 **named function 선언 export** 를 `exports.<fn> = <fn>` 로 require
 * **앞**에 hoist(function 은 hoisted 라 참조 가능) + bottom 중복 제외. const/let/class 는 hoisting
 * 불가·ESM 도 순환서 TDZ 라 대상 아님. default 도 별도(module.exports 모드) 제외.
 */

async function build(
  files: Record<string, string>,
  entries: string[],
  format: 'esm' | 'cjs',
  minify = false,
) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    ...entries.map((e) => join(dir, e)),
    '--preserve-modules',
    `--preserve-modules-root=${dir}`,
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

describe('#4532 증상4: preserve-modules cjs 순환 function export live-binding', () => {
  // 순환 중 e2 가 로드되며 e1 의 function export a() 를 **호출**한다 — 수정 전엔 a=undefined → TypeError.
  for (const format of ['esm', 'cjs'] as const) {
    for (const minify of [false, true]) {
      test(`순환 중 function 호출 성공 [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await build(
          {
            'e1.js':
              'import { b } from "./e2.js";\nexport function a(){ return "A"; }\nexport function callB(){ return b(); }',
            'e2.js':
              'import { a } from "./e1.js";\nexport function b(){ return "B"; }\nglobalThis.__r = a();', // 로드 중 e1.a() 호출
            'entry.js':
              'import "./e2.js";\nimport { callB } from "./e1.js";\nconsole.log(globalThis.__r + callB());',
          },
          ['entry.js'],
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
          expect(stderr).not.toContain('TypeError');
          expect(stdout.trim()).toBe('AB'); // a()="A"(순환 중 호출), b()="B"
        } finally {
          await cleanup();
        }
      });
    }
  }

  // default 가 함께 있어도 named function export 는 순환서 hoist 돼 접근 가능해야 한다.
  // (default 자체의 순환 접근은 #4580 bind-whole + 순환 partial 로 별개 — 여기선 named 만 검증.)
  test('default 병존 시 named function 순환 접근 [cjs]', async () => {
    const { outDir, cleanup } = await build(
      {
        'e1.js':
          'import { b } from "./e2.js";\nexport default function d(){ return "D"; }\nexport function a(){ return "A"; }',
        'e2.js':
          'import { a } from "./e1.js";\nexport function b(){ return "B"; }\nglobalThis.__o = a();', // 로드 중 e1.a() 호출
        'entry.js': 'import "./e1.js";\nimport "./e2.js";\nconsole.log(globalThis.__o);',
      },
      ['entry.js'],
      'cjs',
    );
    try {
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('TypeError');
      expect(stdout.trim()).toBe('A');
    } finally {
      await cleanup();
    }
  });

  // 리뷰 [0]: --output-exports=none 은 export 를 억제하므로 hoist 도 하면 안 된다.
  test('--output-exports=none 은 function export 를 hoist 하지 않는다', async () => {
    const { dir, cleanup } = await createFixture({
      'e1.js':
        'import { b } from "./e2.js";\nexport function a(){ return "A"; }\nconsole.log(typeof b);',
      'e2.js': 'import { a } from "./e1.js";\nexport function b(){}',
    });
    const outDir = join(dir, 'dist');
    try {
      const res = await runZntc([
        '--bundle',
        join(dir, 'e1.js'),
        join(dir, 'e2.js'),
        '--preserve-modules',
        `--preserve-modules-root=${dir}`,
        '--outdir',
        outDir,
        '--format=cjs',
        '--output-exports=none',
      ]);
      expect(res.exitCode).toBe(0);
      const e1 = readFileSync(join(outDir, 'e1.js'), 'utf8');
      expect(e1).not.toContain('exports.a'); // none 이면 어떤 export 도 없어야
    } finally {
      await cleanup();
    }
  });

  test('non-circular 는 정상 (hoist 무해)', async () => {
    const { outDir, cleanup } = await build(
      {
        'm.js': 'export function a(){ return "A"; }\nexport const x = 5;',
        'entry.js': 'import { a, x } from "./m.js";\nconsole.log(a() + x);',
      },
      ['entry.js'],
      'cjs',
    );
    try {
      const { stdout } = await runNode(join(outDir, 'entry.js'));
      expect(stdout.trim()).toBe('A5');
    } finally {
      await cleanup();
    }
  });
});
