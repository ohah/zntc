import { describe, test, expect, afterEach } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { bundleAndRun, createFixture, runZntc } from './helpers';

// Unified Mangler (#1760) Phase A/B 통합 회귀.
//
// unified_mangler.zig 가 linker.computeMangling 에서 호출되어 cross-module
// top-level (Phase A, frequency-sort) + per-module nested (Phase B, liveness)
// 를 하나의 reserved set 으로 묶는다. unified_mangler.zig 의 단위 테스트는
// mangleAll API 형태만 검증하므로 실제 번들 파이프라인에서의 회귀는 별도
// 통합 가드가 필요. 이 파일은 4가지 contract 를 잡는다:
//   1. cross-module Phase A reserved → Phase B nested 상속 (shadow 차단)
//   2. 빈도 다양한 cross-module helper 가 mangle 후에도 모두 정확 동작
//   3. `--mangle-report=<path>` JSON 출력 구조
//   4. `ZNTC_DEBUG=mangle_audit` stderr 출력 (Phase A/B 라인)
describe('unified mangler — Phase A/B 통합 회귀', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // date-fns 회귀 패턴을 단순화: moduleA 의 top-level helper 가 Phase A 에서
  // 짧은 mangled 이름을 받고, moduleB 의 nested 안에서 *그 짧은 이름과 겹칠
  // 만한 자리에* outer 를 참조하는 경우. Phase B 가 Phase A reserved 를 상속하지
  // 않으면 nested local 이 outer 와 같은 이름을 받아 shadowing → outer 호출이
  // 잘못된 값.
  test('cross-module Phase A reserved 가 Phase B nested 와 충돌하지 않는다', async () => {
    const result = await bundleAndRun(
      {
        // helper 5개 — compute.ts 의 nested inner1~5 와 1:1 대응. Phase A 가
        // 5개 top-level 을 짧은 base54 이름으로 reserve 한 뒤 Phase B 가 같은
        // pool 에서 nested inner 를 mangle 할 때 충돌이 노출됨.
        'helpers.ts': `
          export function helperA(x: number): number { return x + 1; }
          export function helperB(x: number): number { return x + 2; }
          export function helperC(x: number): number { return x + 3; }
          export function helperD(x: number): number { return x + 4; }
          export function helperE(x: number): number { return x + 5; }
        `,
        'compute.ts': `
          import { helperA, helperB, helperC, helperD, helperE } from './helpers.ts';
          export function compute(p: number): number {
            const inner1 = helperA(p);
            const inner2 = helperB(inner1);
            const inner3 = helperC(inner2);
            const inner4 = helperD(inner3);
            const inner5 = helperE(inner4);
            return inner5;
          }
        `,
        'index.ts': `
          import { compute } from './compute.ts';
          console.log(compute(10));
        `,
      },
      'index.ts',
      ['--minify', '--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain('ReferenceError');
    expect(result.runStderr).not.toContain('SyntaxError');
    expect(result.exitCode).toBe(0);
    // 10 + 1 + 2 + 3 + 4 + 5 = 25
    expect(result.runOutput).toBe('25');
  });

  // Phase A 의 frequency-sort 가 동작하는지: 호출 횟수가 다른 helper 들이 모두
  // 정확하게 호출되는지 (Tie-breaker 가 deterministic 하므로 mangled 이름은
  // 안정적이지만, 정확한 이름은 base54 시퀀스에 의존하므로 *결과* 만 검증).
  test('frequency 가 다른 cross-module helper 들이 mangle 후 모두 정확 동작', async () => {
    const result = await bundleAndRun(
      {
        'math.ts': `
          export function hot(x: number): number { return x * 2; }
          export function warm(x: number): number { return x + 100; }
          export function cold(x: number): number { return x - 50; }
        `,
        // hot 을 빈도 1위로 (다수 호출). warm 2위, cold 1회.
        'index.ts': `
          import { hot, warm, cold } from './math.ts';
          let acc = 0;
          for (let i = 0; i < 5; i++) acc += hot(i);   // hot ×5
          acc += warm(1);                              // warm ×1
          acc += warm(2);                              // warm ×1 (총 2)
          acc += cold(10);                             // cold ×1
          console.log(acc);
        `,
      },
      'index.ts',
      ['--minify', '--platform=node'],
    );
    cleanup = result.cleanup;

    // hot: 0+2+4+6+8 = 20, warm: 101+102 = 203, cold: -40 → 합 183
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('183');
  });

  // `--mangle-report=<path>` 가 mangle_report.zig 의 JSON 스키마대로 파일을
  // emit 하는지. Phase A/B 통계가 collector 에 흘러들어가고 직렬화 되는지 가드.
  // `bundleAndRun` 대신 createFixture+runZntc 직접 호출 — report path 를 fixture
  // 내부 절대경로로 두어야 test runner cwd 오염 없이 격리됨.
  test('--mangle-report 가 JSON 출력 파일을 생성한다', async () => {
    const fixture = await createFixture({
      'index.ts': `
        function alpha(x: number): number { return x + 1; }
        function beta(y: number): number { return alpha(y) * 2; }
        console.log(beta(3));
      `,
    });
    cleanup = fixture.cleanup;

    const entry = join(fixture.dir, 'index.ts');
    const outFile = join(fixture.dir, 'out.js');
    const reportPath = join(fixture.dir, 'mangle-report.json');

    const bundle = await runZntc([
      '--bundle',
      entry,
      '-o',
      outFile,
      '--minify',
      '--platform=node',
      `--mangle-report=${reportPath}`,
    ]);
    expect(bundle.exitCode).toBe(0);

    const raw = readFileSync(reportPath, 'utf-8');
    const json = JSON.parse(raw);
    expect(json).toHaveProperty('top_level');
    expect(json).toHaveProperty('nested');
    expect(json).toHaveProperty('totals');
    expect(json).toHaveProperty('bundle_size_bytes');
    expect(Array.isArray(json.nested)).toBe(true);
    expect(typeof json.bundle_size_bytes).toBe('number');
    expect(json.bundle_size_bytes).toBeGreaterThan(0);
    for (const key of ['top_level', 'totals']) {
      expect(json[key]).toHaveProperty('slot_count');
      expect(json[key]).toHaveProperty('slot_name_length_sum');
      expect(json[key]).toHaveProperty('renamed_symbol_count');
    }
  });

  // `ZNTC_DEBUG=mangle_audit` 가 unified_mangler 의 PhaseA/PhaseB[total] 두 라인을
  // stderr 에 출력하는지. 통계 키 (slot, counter, skips, skips_1char, reserved_size)
  // 가 모두 노출되고, counter ≥ slot invariant (skips ≥ 0) 가 성립하는지.
  test('ZNTC_DEBUG=mangle_audit 가 PhaseA/PhaseB[total] 라인을 stderr 에 출력', async () => {
    // helpers.ts:209-211 의 spawn 은 env 가 set 되면 process.env 를 *대체* 하므로
    // PATH 등이 누락된다 — spread 로 명시 상속.
    const result = await bundleAndRun(
      {
        'a.ts': `export function a(x: number): number { return x + 1; }`,
        'b.ts': `export function b(x: number): number { return x + 2; }`,
        'index.ts': `
          import { a } from './a.ts';
          import { b } from './b.ts';
          console.log(a(1) + b(2));
        `,
      },
      'index.ts',
      ['--minify', '--platform=node'],
      { env: { ...process.env, ZNTC_DEBUG: 'mangle_audit' } },
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('6'); // 2 + 4

    const phaseA = result.bundleStderr.match(
      /PhaseA: slot=(\d+) counter=(\d+) skips=(\d+) skips_1char=(\d+) reserved_size=(\d+)/,
    );
    expect(phaseA).not.toBeNull();
    expect(+phaseA![2]).toBeGreaterThanOrEqual(+phaseA![1]); // counter ≥ slot

    const phaseB = result.bundleStderr.match(
      /PhaseB\[total\]: modules=(\d+) slot_sum=(\d+) counter_sum=(\d+) skips_sum=(\d+) skips_1char_sum=(\d+)/,
    );
    expect(phaseB).not.toBeNull();
    expect(+phaseB![3]).toBeGreaterThanOrEqual(+phaseB![2]); // counter_sum ≥ slot_sum
  });
});
