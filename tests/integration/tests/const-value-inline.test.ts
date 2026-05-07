import { describe, test, expect, afterEach } from 'bun:test';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { bundleAndRun, createFixture, runZntc } from './helpers';

// 크로스-모듈 const_value 인라인의 correctness 보장.
// 핵심 버그: `let` 재할당이 있는데도 초기값을 const처럼 인라인하는 pre-existing 이슈.
// 수정은 2단계 설계:
//   1. analyzer: const/let 모두 const_value로 수집 (write_count 추적)
//   2. metadata.buildCrossModuleConstValues: `write_count == 0`일 때만 인라인 (const promotion)
// 결과적으로 재할당 있는 `let`은 차단, 재할당 없는 `let`은 `const`처럼 인라인되는 oxc/rolldown 수준 동작.
describe('const_value cross-module 인라인 correctness', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // ========================================================================
  // 버그 재현 케이스: let 재할당 → 초기값 인라인 금지
  // ========================================================================

  test('let 숫자를 += 로 재할당하면 import 시점의 현재 값이 보여야 한다', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let counter = 42;
          export function inc() { counter += 1; }
        `,
        'index.ts': `
          import { counter, inc } from "./lib";
          inc();
          console.log(counter);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('43');
  });

  test('let 숫자를 = 로 직접 재할당해도 올바른 값이 보여야 한다', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let value = 100;
          export function set(n: number) { value = n; }
        `,
        'index.ts': `
          import { value, set } from "./lib";
          set(999);
          console.log(value);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('999');
  });

  test('let 문자열 재할당 시 초기값 인라인 금지', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let label = "initial";
          export function rename(n: string) { label = n; }
        `,
        'index.ts': `
          import { label, rename } from "./lib";
          rename("updated");
          console.log(label);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('updated');
  });

  test('let boolean 재할당', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let flag = true;
          export function toggle() { flag = !flag; }
        `,
        'index.ts': `
          import { flag, toggle } from "./lib";
          toggle();
          console.log(flag);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('false');
  });

  test('let null → 다른 값으로 재할당', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let state: number | null = null;
          export function set() { state = 7; }
        `,
        'index.ts': `
          import { state, set } from "./lib";
          set();
          console.log(state);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('7');
  });

  test('let ++ 증감 연산자', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let n = 0;
          export function bump() { n++; }
        `,
        'index.ts': `
          import { n, bump } from "./lib";
          bump(); bump(); bump();
          console.log(n);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('3');
  });

  test('--minify와 함께 작동', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let score = 10;
          export function update(x: number) { score = x; }
        `,
        'index.ts': `
          import { score, update } from "./lib";
          update(555);
          console.log(score);
        `,
      },
      'index.ts',
      ['--platform=node', '--minify'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('555');
  });

  // ========================================================================
  // 긍정 케이스: const는 여전히 인라인되어야 한다
  // ========================================================================

  test('const true는 cross-module에서 인라인된다', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `export const ENABLED = true;`,
        'index.ts': `
          import { ENABLED } from "./lib";
          console.log(ENABLED);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('true');
  });

  test('const false 인라인', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `export const DISABLED = false;`,
        'index.ts': `
          import { DISABLED } from "./lib";
          console.log(DISABLED);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('false');
  });

  test('const null 인라인', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `export const EMPTY = null;`,
        'index.ts': `
          import { EMPTY } from "./lib";
          console.log(EMPTY);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('null');
  });

  test('const undefined 인라인', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `export const NONE = undefined;`,
        'index.ts': `
          import { NONE } from "./lib";
          console.log(NONE);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('undefined');
  });

  test('const number는 cross-module에서 materialize되고 산술 fold된다', async () => {
    const fx = await createFixture({
      'lib.ts': `export const n = 1;`,
      'index.ts': `
        import { n } from "./lib";
        console.log(n + 2);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    expect(src).toMatch(/console\.log\(3\)/);
    expect(src).not.toContain('n + 2');
  });

  test('const number는 exponent와 hex literal도 원본 숫자 literal로 전파한다', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export const exp = 1e3;
          export const hex = 0x10;
        `,
        'index.ts': `
          import { exp, hex } from "./lib";
          console.log(exp + 2, hex + 2);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('1002 18');
  });

  test('numeric const chain은 deep cross-module export에서도 대량 축소된다', async () => {
    const files: Record<string, string> = {
      'mod-0.ts': `export const v0 = 1;`,
    };
    for (let i = 1; i < 40; i++) {
      files[`mod-${i}.ts`] = `
        import { v${i - 1} } from "./mod-${i - 1}";
        export const v${i} = v${i - 1} + 1;
      `;
    }
    files['index.ts'] = `
      import { v39 } from "./mod-39";
      console.log(v39);
    `;

    const fx = await createFixture(files);
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    expect(src).toMatch(/console\.log\(40\)/);
    expect((src.match(/const v\d+/g) ?? []).length).toBeLessThanOrEqual(2);
  });

  test('numeric expression seed도 cross-module chain에 같은 값으로 전파된다', async () => {
    const fx = await createFixture({
      'seed.ts': `export const base = (20 + 2) * 2;`,
      'middle.ts': `
        import { base } from "./seed";
        export const value = base + 1;
      `,
      'index.ts': `
        import { value } from "./middle";
        console.log(value);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const build = await runZntc([
      '--bundle',
      join(fx.dir, 'index.ts'),
      '-o',
      out,
      '--platform=node',
    ]);
    expect(build.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    expect(src).toMatch(/console\.log\(45\)/);
    expect(src).not.toContain('20 + 2');

    const run = await Bun.$`node ${out}`.text();
    expect(run.trim()).toBe('45');
  });

  test('numeric const는 object shorthand를 구문 깨지는 literal로 materialize하지 않는다', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `export const n = 1;`,
        'index.ts': `
          import { n } from "./lib";
          console.log(JSON.stringify({ n }));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('{"n":1}');
  });

  test('numeric post-pass 이후 top-level rename metadata가 stale하지 않다', async () => {
    const r = await bundleAndRun(
      {
        'seed.ts': `export const base = 1;`,
        'left.ts': `
          import { base } from "./seed";
          export const _empty = base + 1;
          export const left = _empty;
        `,
        'right.ts': `
          export const _empty = 10;
          export const right = _empty;
        `,
        'index.ts': `
          import { left } from "./left";
          import { right } from "./right";
          console.log(left, right);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('2 10');
  });

  test('numeric post-pass는 기존 namespace reachability를 뒤늦게 바꾸지 않는다', async () => {
    const fx = await createFixture({
      'seed.ts': `export const base = 1;`,
      'node.ts': `
        export class EmptyNode {
          tag = "EmptyNode";
        }
        export function isEmptyNode(value: unknown) {
          return value instanceof EmptyNode;
        }
        export const unused = "drop";
      `,
      'map.ts': `
        import * as Node from "./node";
        import { base } from "./seed";
        const _empty = new Node.EmptyNode();
        export const value = Node.isEmptyNode(_empty) ? base + 1 : 0;
      `,
      'other.ts': `
        export const _empty = 99;
        export const other = _empty;
      `,
      'index.ts': `
        import { value } from "./map";
        import { other } from "./other";
        console.log(value, other);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const build = await runZntc([
      '--bundle',
      join(fx.dir, 'index.ts'),
      '-o',
      out,
      '--platform=node',
    ]);
    expect(build.exitCode).toBe(0);

    const src = readFileSync(out, 'utf8');
    expect(src).toContain('class EmptyNode');
    expect(src).not.toContain('unused');
    expect(src.match(/\b(?:const|let|var)\s+_empty(?![$\w])/g) ?? []).toHaveLength(1);

    const run = await Bun.$`node ${out}`.text();
    expect(run.trim()).toBe('2 99');
  });

  test('numeric post-pass resync는 re-export alias symbol을 최신 semantic에 맞춘다', async () => {
    const fx = await createFixture({
      'seed.ts': `export const base = 1;`,
      'left.ts': `
        import { base } from "./seed";
        const unusedLocal = 123;
        export const value = base + 1;
      `,
      'barrel.ts': `export { value as answer } from "./left";`,
      'index.ts': `
        import { answer } from "./barrel";
        console.log(answer);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const build = await runZntc([
      '--bundle',
      join(fx.dir, 'index.ts'),
      '-o',
      out,
      '--platform=node',
    ]);
    expect(build.exitCode).toBe(0);

    const src = readFileSync(out, 'utf8');
    expect(src).toMatch(/console\.log\(2\)/);
    expect(src).not.toContain('unusedLocal');

    const run = await Bun.$`node ${out}`.text();
    expect(run.trim()).toBe('2');
  });

  test('--minify 에서 pre-shake materialize 이후 numeric post-pass 미발화 경로도 emit 정상', async () => {
    // #2502 회귀 방지. inner refreshLinkMetadataAfterPreShakeMutation 가 좁은 populate*
    // 만 실행하고 ast_mutated_after_link 를 sticky 유지해 outer finalize 가 항상 발화해야
    // resynced symbol id 가 emit 단계에 반영된다. 시드는 boolean 만 — numeric post-pass gate
    // (`anyModuleHasExportedNumberConst`) 가 닫혀 inner 의 mutation 이 outer 발화를 일으키는
    // 유일한 경로가 된다. helper 의 mangle 결과가 valid JS 로 실행되는 것으로 확인.
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export const FLAG = true;
          export const FALLBACK = false;
        `,
        'index.ts': `
          import { FLAG, FALLBACK } from "./lib";
          function helperFunctionThatGetsMangled() { return 84; }
          function unusedFunctionThatGetsMangled() { return 99; }
          if (FLAG && !FALLBACK) {
            console.log(helperFunctionThatGetsMangled());
          } else {
            console.log(unusedFunctionThatGetsMangled());
          }
        `,
      },
      'index.ts',
      ['--platform=node', '--minify'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('84');
  });

  test('dynamic import 가 섞여도 numeric chain 이 static importer 까지 전파된다', async () => {
    // #2506 회귀 방지: numeric BFS 가 reverse_deps 를 import_records 로부터 재구성하던
    // 시절엔 dynamic_importers 까지 큐에 들어갔다 (헛일이지만 무해). Module.importers
    // 직접 사용으로 바꾸면 dynamic 은 제외되는데, static chain 전파는 그대로 동작해야.
    const r = await bundleAndRun(
      {
        'seed.ts': `export const N = 7;`,
        'static.ts': `
          import { N } from "./seed";
          export const X = N + 1;
        `,
        'index.ts': `
          import { X } from "./static";
          // dynamic import 자체는 평가만 시도 (시드 모듈에 side-effect 없음).
          import("./seed").then((m) => console.log(X, m.N));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('8 7');
  });

  // ========================================================================
  // Edge cases: local let (not exported) / 같은 모듈 내 참조
  // ========================================================================

  test('local let이 같은 모듈 내에서만 쓰여도 인라인되지 않는다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          let local = 1;
          function update() { local = 99; }
          update();
          console.log(local);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('99');
  });

  test('closure 내 let 재할당도 안전 (const_value 인라인 금지)', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let count = 5;
          const mutator = () => { count = count * 2; };
          export function run() { mutator(); }
        `,
        'index.ts': `
          import { count, run } from "./lib";
          run(); run();
          console.log(count);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('20');
  });

  // ========================================================================
  // Const promotion: 재할당 없는 let도 const처럼 인라인 (write_count==0 체크)
  // ========================================================================

  test('재할당 없는 let boolean은 cross-module에서 인라인된다 (const promotion)', async () => {
    // bundle 결과를 읽어 literal이 call site에 직접 박혀 있는지 검증.
    const fx = await createFixture({
      'lib.ts': `export let FLAG = true;`,
      'index.ts': `
        import { FLAG } from "./lib";
        console.log(FLAG);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    // console.log 호출부에 literal "true"가 나타나야 함 (인라인됨).
    expect(src).toMatch(/console\.log\(true\)/);
  });

  test('재할당 없는 let null은 인라인된다', async () => {
    const fx = await createFixture({
      'lib.ts': `export let MISSING = null;`,
      'index.ts': `
        import { MISSING } from "./lib";
        console.log(MISSING);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    expect(src).toMatch(/console\.log\(null\)/);
  });

  test('재할당 있는 let boolean은 const promotion 대상이 아님 — 동적 값 유지', async () => {
    const fx = await createFixture({
      'lib.ts': `
        export let OPEN = false;
        export function open() { OPEN = true; }
      `,
      'index.ts': `
        import { OPEN, open } from "./lib";
        open();
        console.log(OPEN);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    // 인라인되면 console.log(false) 가 될 것 — 재할당 있으니 금지.
    expect(src).not.toMatch(/console\.log\(false\)/);
  });

  test('재할당 있는 let null — 초기값 인라인 금지', async () => {
    const fx = await createFixture({
      'lib.ts': `
        export let target: any = null;
        export function set(v: any) { target = v; }
      `,
      'index.ts': `
        import { target, set } from "./lib";
        set({ ok: true });
        console.log(target);
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    // console.log에 null literal이 인라인되면 안 됨.
    expect(src).not.toMatch(/console\.log\(null\)/);
  });

  test('const와 재할당 없는 let 모두 if 분기 DCE 트리거 (DEV=false 패턴)', async () => {
    // --conditions=production의 esm-env 스타일 패턴 — DEV=false면 if 분기 삭제.
    const fx = await createFixture({
      'env.ts': `export let DEV = false;`,
      'index.ts': `
        import { DEV } from "./env";
        if (DEV) console.log("debug-only");
        console.log("always");
      `,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const r = await runZntc(['--bundle', join(fx.dir, 'index.ts'), '-o', out, '--platform=node']);
    expect(r.exitCode).toBe(0);
    const src = readFileSync(out, 'utf8');
    // DEV이 false로 인라인되면 if 분기가 DCE로 제거되어 "debug-only"는 출력에 없어야 함.
    expect(src).not.toContain('debug-only');
    expect(src).toContain('always');
  });

  // ========================================================================
  // Edge: 증감 연산자, destructuring assignment, for-in/of
  // ========================================================================

  test('= !foo 꼴 재할당 (복합 표현식 LHS)도 write로 카운트', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let enabled = true;
          export function flip() { enabled = !enabled; }
        `,
        'index.ts': `
          import { enabled, flip } from "./lib";
          flip();
          console.log(enabled);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    // flip 후 false. enabled=true로 인라인되면 true가 나옴.
    expect(r.runOutput).toBe('false');
  });

  // ========================================================================
  // Edge: destructuring LHS, 함수 파라미터, for-of 루프 변수
  // ========================================================================

  test('array destructuring assignment `[x] = arr`도 write_count 증가', async () => {
    // `[val] = [...]` 패턴의 array_assignment_target 경로에서 write 감지 확인.
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let val = true;
          export function reset() { [val] = [false]; }
        `,
        'index.ts': `
          import { val, reset } from "./lib";
          reset();
          console.log(val);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    // 재할당 후 false. 인라인되면 true가 나옴.
    expect(r.runOutput).toBe('false');
  });

  test('object destructuring assignment `({x} = obj)`도 write_count 증가', async () => {
    const r = await bundleAndRun(
      {
        'lib.ts': `
          export let v = null;
          export function set(o: any) { ({ v } = o); }
        `,
        'index.ts': `
          import { v, set } from "./lib";
          set({ v: true });
          console.log(v);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    // set() 후 true. 인라인되면 null이 나옴.
    expect(r.runOutput).toBe('true');
  });

  test('함수 param 재할당은 외부 심볼과 무관 (독립 스코프 + 동명 import 영향 없음)', async () => {
    // 함수 parameter는 자체 scope 심볼이라 외부 export 인라인에 영향을 주지 않아야 함.
    // 동일 이름 import와 param이 공존하는 상황에서 정합성 확인.
    const r = await bundleAndRun(
      {
        'lib.ts': `export const OK = true;`,
        'index.ts': `
          import { OK } from "./lib";
          function f(OK: boolean) { OK = false; return OK; }
          console.log(OK, f(true));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    // import된 OK는 true (인라인), 함수 내 OK는 param reassign으로 false.
    expect(r.runOutput).toBe('true false');
  });

  test('for-of 루프 변수와 외부 const 인라인이 독립 동작', async () => {
    // `for (let x of arr) x = ...` 같은 loop-local 재할당은 외부 인라인에 영향 없어야 함.
    const r = await bundleAndRun(
      {
        'lib.ts': `export const FLAG = true;`,
        'index.ts': `
          import { FLAG } from "./lib";
          let result = "";
          for (let x of [1, 2]) { x = x * 10; result += x + ","; }
          console.log(FLAG, result);
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe('true 10,20,');
  });
});
