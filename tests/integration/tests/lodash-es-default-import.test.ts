import { describe, test, expect, afterEach } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { readFileSync, symlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createFixture, hasPackage, runZntcInDir, bundleAndRun } from './helpers';

const PROJECT_ROOT = resolve(import.meta.dir, '../../..');
const ROOT_NODE_MODULES = join(PROJECT_ROOT, 'node_modules');

// `export default <id>` 가 imported binding 일 때 codegen 의 `_default$N = <id>`
// 할당이 누락되는 회귀 가드.
//
// 패턴:
//   // a.ts
//   import x from './x';
//   export default x;
//
//   // b.ts (consumer)
//   export { default } from './a';
//
//   // entry
//   import _ from './b';
//
// 기존 동작: a.ts 의 `export default x;` 가 `has_side_effects=false` (inner 가
// pure identifier_reference) 로 판정되어 statement 가 reachable_stmts 에 들어가지
// 않고, codegen 이 `_default$N = x;` 할당을 emit 하지 않음. 결과적으로 b.ts 의
// `_default$M = _default$N;` 어셈블리에서 RHS `_default$N` 가 미선언되어
// `ReferenceError: _default$N is not defined` 가 런타임에 발생.
//
// 수정: `export default <identifier_reference>` 는 codegen 의 합성 변수 할당이
// 외부 모듈에 관찰 가능한 binding establishment 라 항상 has_side_effects=true 로
// 분류 (`src/bundler/purity.zig`).

/** 번들에 `_default$N = _default$M;` 어셈블리가 있다면 RHS 가 같은 파일에 var 선언돼야. */
function expectNoDanglingDefaultRefs(bundleSrc: string) {
  const danglingDefaultRef = /_default\$(\d+)\s*=\s*_default\$(\d+)\s*;/g;
  let match: RegExpExecArray | null;
  while ((match = danglingDefaultRef.exec(bundleSrc)) !== null) {
    const declRegex = new RegExp(`(var|let|const)\\s+_default\\$${match[2]}\\b`);
    expect(bundleSrc).toMatch(declRegex);
  }
}

describe('export default <imported_id>: dangling _default reference 회귀 가드', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('imported binding 의 default re-export 가 ReferenceError 를 일으키지 않는다', async () => {
    // 합성 fixture — 외부 패키지 의존 없이 동일 패턴 검증.
    const result = await bundleAndRun({
      'index.ts': `
        import wrapped from './barrel';
        // 깨지면 ReferenceError 로 emit 자체 실패한다.
        console.log(typeof wrapped);
      `,
      'barrel.ts': `
        // lodash.js 의 \`export { default } from './lodash.default.js';\` 와 동치.
        export { default } from './alias';
      `,
      'alias.ts': `
        // lodash.default.js 의 \`import lodash from './wrapperLodash.js'; export default lodash;\` 와 동치.
        import inner from './inner';
        export default inner;
      `,
      'inner.ts': `
        // wrapperLodash.js 의 \`var lodash = (...) => {...}; export default lodash;\` 와 동치.
        function f() { return "OK"; }
        export default f;
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runStderr).not.toMatch(/ReferenceError|is not defined/);
    expect(result.runOutput).toBe('function');
    expectNoDanglingDefaultRefs(result.bundleOutput);
  });

  test('alias 가 들어간 import (`import { default as renamed }; export default renamed;`) 도 동일 처리', async () => {
    const result = await bundleAndRun({
      'index.ts': `
        import wrapped from './barrel';
        console.log(typeof wrapped);
      `,
      'barrel.ts': `export { default } from './alias';`,
      'alias.ts': `
        import { default as renamed } from './inner';
        export default renamed;
      `,
      'inner.ts': `
        function g() { return "OK"; }
        export default g;
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runStderr).not.toMatch(/ReferenceError|is not defined/);
    expect(result.runOutput).toBe('function');
    expectNoDanglingDefaultRefs(result.bundleOutput);
  });

  test('export default <named function> 는 영향 없음 (function declaration arm)', async () => {
    // identifier_reference 만 has_side_effects=true 로 변경. function/class
    // declaration 은 기존대로 false (declaring stmt 자체로 BFS 도달).
    const result = await bundleAndRun({
      'index.ts': `
        import wrapped from './lib';
        console.log(wrapped());
      `,
      'lib.ts': `export default function named() { return "OK"; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('OK');
    expectNoDanglingDefaultRefs(result.bundleOutput);
  });

  test.skipIf(!hasPackage('lodash-es'))(
    'lodash-es: 종합 import 패턴 — dangling _default 가 발생하지 않는다',
    async () => {
      // lodash-es 는 위 합성 fixture 와 동일한 default re-export chain 을 가진다
      // (lodash.js → lodash.default.js → wrapperLodash.js). 실제 패키지로 회귀 검증.
      const fixture = await createFixture({
        'package.json': '{"type":"module"}',
        'entry.ts': `
          import { uniq, chunk } from 'lodash-es';
          import _ from 'lodash-es';
          import * as L from 'lodash-es';
          import uniqDirect from 'lodash-es/uniq.js';

          // 직접 사용되는 named/namespace/subpath 함수는 정상 동작 검증.
          // \`_\` (default) 는 lodash.default.js 의 mutation 까지 살리는 별도 작업
          // (graph-level lazy import resolution) 이 필요해 typeof 만 확인.
          const out = {
            named_uniq: uniq([1, 1, 2, 2, 3]),
            named_chunk: chunk([1, 2, 3, 4, 5], 2),
            namespace_zip: L.zip(['a', 'b'], [1, 2]),
            subpath: uniqDirect([7, 7, 8]),
            default_typeof: typeof _,
          };
          console.log(JSON.stringify(out));
        `,
      });
      cleanup = fixture.cleanup;

      symlinkSync(ROOT_NODE_MODULES, join(fixture.dir, 'node_modules'));

      const outFile = join(fixture.dir, 'out.js');
      const bundle = await runZntcInDir(fixture.dir, [
        '--bundle',
        join(fixture.dir, 'entry.ts'),
        '-o',
        outFile,
        '--platform=node',
      ]);
      expect(bundle.exitCode).toBe(0);

      const stdout = execFileSync('node', [outFile], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      const parsed = JSON.parse(stdout.trim());
      expect(parsed.named_uniq).toEqual([1, 2, 3]);
      expect(parsed.named_chunk).toEqual([[1, 2], [3, 4], [5]]);
      expect(parsed.namespace_zip).toEqual([
        ['a', 1],
        ['b', 2],
      ]);
      expect(parsed.subpath).toEqual([7, 8]);
      // _ 가 function 형태로 import 되어야 (실제 method 호출은 별도 PR 에서 수정).
      expect(parsed.default_typeof).toBe('function');

      expectNoDanglingDefaultRefs(readFileSync(outFile, 'utf8'));
    },
  );
});
