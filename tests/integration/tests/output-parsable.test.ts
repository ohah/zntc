import { describe, test, expect } from 'bun:test';
import { runZntc, createFixture } from './helpers';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

/**
 * 산출물 재파싱 게이트 (#4472 / #4481 / #4482 / #4483 계열).
 *
 * 이 계열의 버그는 전부 **빌드 exit 0 + 산출물이 파싱 불가** 였다. codegen 이 필수 괄호를
 * 빠뜨리거나(`c&&{x:a}=o`) 인접 토큰을 합쳐(`f(---t)`) 놓아도 빌드는 성공하고, 문자열 비교
 * 테스트는 needle 만 맞으면 통과했다. 실제 라이브러리(d3 · monaco · codemirror)가
 * 프로덕션에서 통째로 죽고 나서야 발견됐다.
 *
 * 여기서는 방출물을 **다시 파싱**하고(`node --check`), 나아가 **실행해서 값까지** 원본과
 * 비교한다 — `f(-(-t))` → `f(--t)` 처럼 파싱은 되면서 의미만 바뀌는 silent miscompile 은
 * 재파싱만으로는 못 잡기 때문이다.
 *
 * (codegen 유닛 레이어의 대칭 게이트는 `src/codegen/codegen_test/helpers.zig` 의
 *  `expectReparses` — 자체 파서로 모든 e2e 테스트 산출물을 재파싱한다.)
 */

/** 위험 패턴 코퍼스. 각 항목은 `globalThis.out` 에 결과를 문자열로 남긴다. */
const HAZARD_CORPUS = `
// --- #4481: if → &&/?: 폴딩 시 필수 괄호 ---
let a, b, m;
const obj = { x: 1, y: 2 };
const cond = globalThis.__c !== 0;
if (cond) ({ x: a, y: b } = obj);                 // c && ({x:a,y:b} = obj)
const results = [a + "," + b];

const f = () => 7;
if ((m = f())) results.push("cond-assign:" + m);  // (m=f()) && ...  (괄호 없으면 의미가 바뀜)

function chain(g, h) { let n; if ((n = g())) { return h(n); } else { return 0; } }
results.push("chain:" + chain(() => 3, (v) => v * 2));

function fall(g) { let n; if ((n = g())) return 1; return 2; }
results.push("fall:" + fall(() => 0));

const q = (x, y) => { if ((x ?? y)) return "nullish"; return "no"; };  // (a??b) && — 혼용 금지
results.push("nullish:" + q(null, 1));

// --- #4482: 단항 토큰 병합 + prefix-단항 리터럴 괄호 ---
let t = 5;
const id = (x) => x;
results.push("unary:" + id(-(--t)) + ":" + t);    // f(- --t) — f(---t) 는 SyntaxError
let u = 5;
results.push("dbl-neg:" + id(-(-u)) + ":" + u);   // f(- -u) — f(--u) 는 u 를 감소시킴
const two = 2;
results.push("pow:" + String((-two) ** 2));       // (-2)**2 — -2**2 는 SyntaxError
results.push("neg-member:" + (-two).toString());  // (-2).toString() — 문자열 "-2"
results.push("bool-member:" + true.toString());   // (!0).toString()
results.push("void-pow:" + String(undefined ** 2));

// --- #4472: comma-sequence 접기 시 statement-start 괄호 ---
let c1, c2;
if (cond) { ({ x: c1, y: c2 } = obj); results.push("seq:" + c1 + c2); }

globalThis.out = results.join("|");
console.log(globalThis.out);
`;

/** emit 시점 상수 fold 를 타는 경로 (#4482 리뷰 — 번들 linking_metadata 전용). */
const FOLD_FLAGS = `export const ON = true;
export const U = undefined;
export const NEG_SRC = 2;
`;

const FOLD_ENTRY = `import { ON, U, NEG_SRC } from "./flags.js";
const out = [];
out.push("pow-fold:" + String((ON && -1) ** 2));      // (-1)**2 — fold 로 살아남는 분기
out.push("pow-cond:" + String((ON ? -1 : 2) ** 2));
out.push("sub-fold:" + String(10 - (ON ? -1 : 1)));   // 10- -1 — 10--1 은 SyntaxError
const t = { v: 3 };
out.push("neg-fold:" + String(-(ON ? -t.v : t.v)));   // - -3 — --t.v 는 silent miscompile
out.push("undef-pow:" + String(U ** 2));              // (void 0)**2
out.push("undef-member:" + String(U ?? "dflt"));
out.push("const-member:" + NEG_SRC.toString());       // 2 .toString()
globalThis.out = out.join("|");
console.log(globalThis.out);
`;

/** 번들 후 `node --check` 로 재파싱. 실패하면 산출물 전문과 함께 터진다. */
function expectParsable(outFile: string, label: string) {
  const r = spawnSync('node', ['--check', outFile], { encoding: 'utf-8' });
  if (r.status !== 0) {
    const code = readFileSync(outFile, 'utf-8');
    throw new Error(
      `[${label}] 산출물이 파싱되지 않는다 — 빌드는 green 인데 런타임에 죽는다\n` +
        `${r.stderr}\n--- 산출물 ---\n${code}`,
    );
  }
}

function runNode(outFile: string): string {
  const r = spawnSync('node', [outFile], { encoding: 'utf-8' });
  if (r.status !== 0) throw new Error(`실행 실패:\n${r.stderr}`);
  return r.stdout.trim();
}

/** minify 유무에 따라 산출물이 달라져도 **의미는 같아야** 한다. */
const OPTION_MATRIX: { label: string; args: string[] }[] = [
  { label: 'plain', args: [] },
  { label: 'minify-syntax', args: ['--minify-syntax'] },
  { label: 'minify-whitespace', args: ['--minify-whitespace'] },
  { label: 'minify', args: ['--minify'] },
  { label: 'minify + es2015', args: ['--minify', '--target=es2015'] },
  { label: 'minify + es5', args: ['--minify', '--target=es5'] },
];

describe('산출물 재파싱 게이트', () => {
  test('위험 패턴 코퍼스가 모든 옵션 조합에서 파싱되고 의미가 보존된다', async () => {
    const { dir, cleanup } = await createFixture({ 'entry.js': HAZARD_CORPUS });
    try {
      // 기준값: node 가 원본 소스를 직접 실행한 결과.
      const expected = runNode(join(dir, 'entry.js'));
      expect(expected.length).toBeGreaterThan(0);

      for (const { label, args } of OPTION_MATRIX) {
        const outFile = join(dir, `out-${label.replace(/[^a-z0-9]/gi, '_')}.js`);
        const bundle = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', outFile, ...args]);
        expect(bundle.exitCode).toBe(0);

        expectParsable(outFile, label);
        expect(runNode(outFile), `[${label}] 의미가 바뀌었다`).toBe(expected);
      }
    } finally {
      await cleanup();
    }
  }, 60000);

  test('emit 시점 상수 fold 경로도 파싱되고 의미가 보존된다', async () => {
    const { dir, cleanup } = await createFixture({
      'flags.js': FOLD_FLAGS,
      'entry.js': FOLD_ENTRY,
    });
    try {
      // 기준값은 fold 가 없는 esm 실행 결과 (node 가 직접 실행).
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ type: 'module' }));
      const expected = runNode(join(dir, 'entry.js'));

      for (const { label, args } of OPTION_MATRIX) {
        const outFile = join(dir, `fold-${label.replace(/[^a-z0-9]/gi, '_')}.js`);
        const bundle = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', outFile, ...args]);
        expect(bundle.exitCode).toBe(0);

        expectParsable(outFile, label);
        expect(runNode(outFile), `[${label}] 의미가 바뀌었다`).toBe(expected);
      }
    } finally {
      await cleanup();
    }
  }, 60000);

  test('for-await 다운레벨 산출물이 모든 타겟에서 파싱된다 (#4488)', async () => {
    const src = `
async function collect(xs) { const out = []; for await (const x of xs) out.push(x); return out; }
const arrow = async (xs) => { const out = []; for await (const x of xs) out.push(x); return out; };
collect([Promise.resolve(1), 2]).then((r) => arrow([3, 4]).then((s) => console.log(r.join(",") + "|" + s.join(","))));
`;
    const { dir, cleanup } = await createFixture({ 'entry.js': src });
    try {
      const expected = runNode(join(dir, 'entry.js'));
      for (const target of ['es5', 'es2015', 'es2016', 'es2017', 'esnext']) {
        const outFile = join(dir, `fa-${target}.js`);
        const bundle = await runZntc([
          '--bundle',
          join(dir, 'entry.js'),
          '-o',
          outFile,
          `--target=${target}`,
        ]);
        expect(bundle.exitCode).toBe(0);
        // generator 안에 raw await 가 남으면 파싱 불가:
        // "'await' is not allowed in non-async function"
        expectParsable(outFile, target);
        expect(runNode(outFile), `[${target}] 의미가 바뀌었다`).toBe(expected);
      }
    } finally {
      await cleanup();
    }
  }, 60000);
});
