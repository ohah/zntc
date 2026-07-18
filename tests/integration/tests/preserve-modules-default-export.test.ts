import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4573 — `--preserve-modules` 에서 ESM-wrap 모듈의 default export 형태별 회귀.
 *
 * 익명 `export default class {}` 가 ESM-wrap 되면(예 `a.cjs = require("./b.js")`) synthetic
 * `_default` 의 top-level `var _default;` 선언이 `__esm` 클로저 밖으로 hoist 되지 않아
 * `export { _default }` 가 미선언 참조 → `SyntaxError: Export '_default' is not defined`.
 * named class·function·value 는 정상이었다. minify·non-minify 공통.
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

const FORMATS = ['esm', 'cjs'] as const;
const MINIFY = [false, true] as const;

// default export 형태별 소스 + entry 사용 코드 + 기대 출력
const CASES: Array<{ name: string; dexpr: string; use: string; expect: string }> = [
  {
    name: '익명 class',
    dexpr: 'export default class { greet(){ return "hi"; } }',
    use: 'console.log(new D().greet());',
    expect: 'hi',
  },
  {
    name: '익명 function',
    dexpr: 'export default function(){ return "fn"; }',
    use: 'console.log(D());',
    expect: 'fn',
  },
  {
    name: '익명 arrow',
    dexpr: 'export default () => "arrow";',
    use: 'console.log(D());',
    expect: 'arrow',
  },
  {
    name: 'named class',
    dexpr: 'export default class Foo { greet(){ return "named-cls"; } }',
    use: 'console.log(new D().greet());',
    expect: 'named-cls',
  },
  {
    name: 'named function',
    dexpr: 'export default function foo(){ return "named-fn"; }',
    use: 'console.log(D());',
    expect: 'named-fn',
  },
  {
    name: 'value',
    dexpr: 'const secret = 41;\nexport default secret + 1;',
    use: 'console.log(D);',
    expect: '42',
  },
];

describe('#4573: preserve-modules ESM-wrap default export 형태', () => {
  // 익명 default class + extends (클래스 표현식, 이름 없음)
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`익명 class extends [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildPm(
          {
            'b.js':
              'class Base { base(){ return "base"; } }\n' +
              'export default class extends Base { greet(){ return "ext-" + this.base(); } }',
            'a.cjs': 'module.exports = require("./b.js");',
            'entry.js': 'import D from "./b.js";\nimport "./a.cjs";\nconsole.log(new D().greet());',
          },
          'entry.js',
          format,
          minify,
        );
        try {
          // runNode 는 non-zero exit(SyntaxError 등)에 throw 하므로, 빌드/실행 실패는 여기서
          // 던져져 테스트가 깨진다(별도 stderr 단언 불요). stdout 이 정답이면 성공.
          const { stdout } = await runNode(join(outDir, 'entry.js'));
          expect(stdout.trim()).toBe('ext-base');
        } finally {
          await cleanup();
        }
      });
    }
  }

  // 익명 default function 을 strict_execution_order(RN 프리셋)에서 — `--code-review max` 적발:
  // strict 경로는 함수를 __esm factory 안에 유지하고 `_default = function(){}` 로 할당하므로,
  // 익명 함수도 top-level `var _default;` hoist 가 없으면 미선언(SyntaxError). RN 은 strict 강제.
  // (RN downlevel 클래스는 별개 pre-existing 헬퍼 중복 버그라 여기선 function 만.)
  test('익명 default function (RN strict_execution_order)', async () => {
    const { dir, cleanup } = await createFixture({
      'b.js': 'export default function(){ return "sfn"; }',
      'a.cjs': 'module.exports = require("./b.js");',
      'entry.js': 'import D from "./b.js";\nimport "./a.cjs";\nconsole.log(D());',
    });
    const outDir = join(dir, 'dist');
    try {
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--preserve-modules',
        '--outdir',
        outDir,
        '--format=esm',
        '--platform=react-native', // strict_execution_order 강제
      ]);
      expect(res.exitCode, res.stderr).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const { stdout } = await runNode(join(outDir, 'entry.js')); // 수정 전: SyntaxError → throw
      expect(stdout.trim()).toBe('sfn');
    } finally {
      await cleanup();
    }
  });

  for (const c of CASES) {
    for (const format of FORMATS) {
      for (const minify of MINIFY) {
        test(`${c.name} [${format}${minify ? ' minify' : ''}]`, async () => {
          const { outDir, cleanup } = await buildPm(
            {
              'b.js': c.dexpr,
              'a.cjs': 'module.exports = require("./b.js");', // b 를 ESM-wrap 강제
              'entry.js': `import D from "./b.js";\nimport "./a.cjs";\n${c.use}`,
            },
            'entry.js',
            format,
            minify,
          );
          try {
            // runNode 가 non-zero exit 에 throw → 빌드/실행 실패는 여기서 던져져 테스트 fail.
            const { stdout } = await runNode(join(outDir, 'entry.js'));
            expect(stdout.trim()).toBe(c.expect);
          } finally {
            await cleanup();
          }
        });
      }
    }
  }
});
