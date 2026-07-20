import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4587 (target a) — `--preserve-modules --format=cjs` 에서 **재할당되는 export 바인딩**
 * (`export let A=0; A=1`)의 live-binding.
 *
 * 근본: cjs 가 export 바인딩을 로컬 `var A` + 모듈 끝 `exports.A = A`(스냅샷) 으로 낮춰,
 * (1) 소비자가 `const {A}=require()` 로 import 시점 스냅샷, (2) provider 가 끝에서 한 번만 반영
 * → 순환/재할당에서 undefined 박제. ESM 은 live binding.
 *
 * 수정(rollup parity): 재할당 바인딩(write_count>0, let/var, 비 const/class/fn, identity)을
 * `exports.A` **저장소**로 (선언→`exports.A=init`, 읽기/쓰기 rewrite, 끝-할당 skip) + 소비자는
 * `const ns=require(); ns.A` 라이브 접근. const/class 는 rollup 도 안 하는 층이라 제외(사이드
 * 이펙트 회피).
 */

async function build(files: Record<string, string>, entries: string[], minify = false) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    ...entries.map((e) => join(dir, e)),
    '--preserve-modules',
    `--preserve-modules-root=${dir}`,
    '--outdir',
    outDir,
    '--format=cjs',
    ...(minify ? ['--minify'] : []),
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
  return { outDir, cleanup };
}

describe('#4587(a): preserve-modules cjs 재할당 export live-binding', () => {
  // 핵심: 순환 A↔B 에서 재할당된 let 을 순환 해소 후 읽으면 최신값. 수정 전 undefinedvB.
  for (const minify of [false, true]) {
    test(`순환 재할당 let 이 라이브${minify ? ' [min]' : ''}`, async () => {
      const { outDir, cleanup } = await build(
        {
          'a.mjs':
            'import { getB } from "./b.mjs";\nexport let A = "init";\nA = "vA";\nconsole.log("R:" + getB());',
          'b.mjs':
            'import { A } from "./a.mjs";\nexport const B = "vB";\nexport function getB() { return A + B; }',
        },
        ['a.mjs'],
        minify,
      );
      try {
        expect((await runNode(join(outDir, 'a.js'))).stdout.trim()).toBe('R:vAvB');
      } finally {
        await cleanup();
      }
    });
  }

  // provider codegen: 재할당 let → exports.A 저장소(로컬 var 없음·끝-할당 없음).
  test('provider 가 재할당 바인딩을 exports.X 저장소로 방출', async () => {
    const { outDir, cleanup } = await build(
      {
        'a.mjs': 'export let A = 1;\nA = 2;\nexport const S = "s";',
        'e.mjs': 'import { A, S } from "./a.mjs";\nconsole.log("R:" + A + S);',
      },
      ['e.mjs'],
    );
    try {
      const a = readFileSync(join(outDir, 'a.js'), 'utf8');
      // 재할당 A: exports.A = 1; exports.A = 2; (로컬 `let A`/`var A` 없음)
      expect(a).toMatch(/exports\.A\s*=\s*1/);
      expect(a).toMatch(/exports\.A\s*=\s*2/);
      expect(a).not.toMatch(/\b(let|var|const)\s+A\b/);
      // const S 는 저장소화 안 함(로컬 유지) — 사이드이펙트 회피 스코프 가드
      expect(a).toMatch(/const\s+S\s*=/);
      // consumer 는 재할당 A 를 ns 접근, const S 는 구조분해
      const e = readFileSync(join(outDir, 'e.js'), 'utf8');
      expect(e).toMatch(/=\s*require\("\.\/a\.js"\)/);
      expect((await runNode(join(outDir, 'e.js'))).stdout.trim()).toBe('R:2s');
    } finally {
      await cleanup();
    }
  });

  // 혼합 한 모듈: 재할당 let + const + function 이 각각 올바른 시맨틱.
  test('재할당 let + const + fn 혼합 (ESM 좌→우 라이브)', async () => {
    const { outDir, cleanup } = await build(
      {
        'm.mjs':
          'export let n = 1;\nn = 2;\nexport const s = "y";\nexport function f() { return 3; }',
        'c.mjs': 'import { n, s, f } from "./m.mjs";\nconsole.log("R:" + n + s + f());',
      },
      ['c.mjs'],
    );
    try {
      expect((await runNode(join(outDir, 'c.js'))).stdout.trim()).toBe('R:2y3');
    } finally {
      await cleanup();
    }
  });

  // 스코프 가드: const 는 저장소화하지 않는다(#4587(b) 미채택 — rollup 도 실패하는 층).
  // 순환 const 는 undefined 로 남지만 크래시/파손은 없어야 한다.
  test('const 는 저장소화 안 함 (스코프 밖, 무크래시)', async () => {
    const { outDir, cleanup } = await build(
      {
        'a.mjs':
          'import { getB } from "./b.mjs";\nexport const A = "vA";\nconsole.log("R:" + getB());',
        'b.mjs':
          'import { A } from "./a.mjs";\nexport const B = "vB";\nexport function getB() { return A + B; }',
      },
      ['a.mjs'],
    );
    try {
      const a = readFileSync(join(outDir, 'a.js'), 'utf8');
      // A 는 로컬 바인딩으로 유지(저장소화 안 함) — 순환이라 const→var 강등될 수 있음(#2198).
      expect(a).toMatch(/\b(var|const|let)\s+A\s*=\s*"vA"/);
      expect(a).not.toMatch(/exports\.A\s*=\s*"vA"/); // 선언을 exports.A 저장소로 바꾸지 않음
      // 순환 const 는 여전히 undefined(문서화된 한계) — 크래시만 없으면 됨.
      const out = (await runNode(join(outDir, 'a.js'))).stdout.trim();
      expect(out.startsWith('R:')).toBe(true);
    } finally {
      await cleanup();
    }
  });
});
