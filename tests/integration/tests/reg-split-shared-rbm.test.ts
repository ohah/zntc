import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync, readdirSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4555 — reg_split(iife/umd/amd)·cjs multi-entry 가 **공유 run-before-main** 을 쓰면 RBM 이 common
 * 청크로 가고, entry 청크가 그 init 을 **ESM `import`** 로 가져와 실패했다:
 *  - iife/umd/amd: `import { init_setup }` 이 factory 함수 안이라 SyntaxError.
 *  - cjs: CommonJS 출력에 ESM `import` → 로드 불가.
 *  - esm 은 top-level import 라 유일하게 정상이었다.
 *
 * 수정: emitRunBeforeMainCrossImports 를 포맷-aware 로 — reg_split → `const { init } =
 * __zntc_require("<reg_id>")`, cjs → `const { init } = require("<path>")`, esm → 기존 import.
 * 또 cjs-wrap RBM 이 청크에서 raw-require 되면 메인 forwarding 과 이중 선언되므로 cross-import skip.
 */

// node --check 로 파싱 유효성만 확인(런타임 실행 X — iife 는 청크 미로드로 런타임 실패가 정상).
async function parseValid(file: string): Promise<boolean> {
  const p = Bun.spawn(['node', '--check', file], { stdout: 'pipe', stderr: 'pipe' });
  await p.exited;
  return p.exitCode === 0;
}

async function build(
  format: 'iife' | 'umd' | 'amd' | 'cjs' | 'esm',
  files: Record<string, string>,
  rbm: string,
  minify = false,
) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, 'a.js'),
    join(dir, 'b.js'),
    '--splitting',
    `--format=${format}`,
    '--platform=node',
    `--run-before-main=${join(dir, rbm)}`,
    '--outdir',
    outDir,
    ...(minify ? ['--minify'] : []),
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  return { dir, outDir, cleanup };
}

const ESM_SETUP = {
  'setup.js': 'globalThis.__setup = "SETUP_DONE";',
  'a.js': 'import "./setup.js";\nconsole.log("a:" + globalThis.__setup);',
  'b.js': 'import "./setup.js";\nconsole.log("b:" + globalThis.__setup);',
};

describe('#4555: reg_split/cjs multi-entry 공유 run-before-main', () => {
  // reg_split(iife/umd/amd): factory 안 ESM import 없음 + 파싱 유효(SyntaxError 제거).
  for (const format of ['iife', 'umd', 'amd'] as const) {
    for (const minify of [false, true]) {
      test(`${format}: RBM cross-import 가 registry (파싱 유효)${minify ? ' [min]' : ''}`, async () => {
        const { outDir, cleanup } = await build(format, ESM_SETUP, 'setup.js', minify);
        try {
          const a = readFileSync(join(outDir, 'a.js'), 'utf8');
          expect(a).not.toMatch(/import\s*\{\s*init_/); // ESM import 면 SyntaxError
          expect(a).toContain('__zntc_require('); // registry 결합
          expect(await parseValid(join(outDir, 'a.js'))).toBe(true); // 진짜 파싱되는지
        } finally {
          await cleanup();
        }
      });
    }
  }

  // iife/umd: 청크를 로드 순서대로(common → entry) 넣으면 RBM 이 실행돼 setup 이 돈다.
  for (const format of ['iife', 'umd'] as const) {
    test(`${format}: 청크 로드 순서대로면 RBM 실행 (브라우저 script 순서)`, async () => {
      const { dir, outDir, cleanup } = await build(format, ESM_SETUP, 'setup.js');
      try {
        const chunk = readdirSync(outDir).find((f) => f.startsWith('chunk-'))!;
        writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
        const harness = join(dir, 'harness.js');
        writeFileSync(
          harness,
          `globalThis.__zntc_public_path="";\nrequire(${JSON.stringify(join(outDir, chunk))});\nrequire(${JSON.stringify(join(outDir, 'a.js'))});\n`,
        );
        const { stdout, stderr } = await runNode(harness);
        expect(stderr).not.toContain('SyntaxError');
        expect(stdout.trim()).toBe('a:SETUP_DONE');
      } finally {
        await cleanup();
      }
    });
  }

  // cjs: require 가 청크를 동기 로드하므로 직접 실행이 그대로 동작.
  test('cjs: 공유 RBM 이 직접 실행에서 동작', async () => {
    const { outDir, cleanup } = await build('cjs', ESM_SETUP, 'setup.js');
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      const a = readFileSync(join(outDir, 'a.js'), 'utf8');
      expect(a).not.toMatch(/import\s*\{\s*init_/);
      expect((await runNode(join(outDir, 'a.js'))).stdout.trim()).toBe('a:SETUP_DONE');
      expect((await runNode(join(outDir, 'b.js'))).stdout.trim()).toBe('b:SETUP_DONE');
    } finally {
      await cleanup();
    }
  });

  // cjs --minify: 직접 실행 동작. (#4586 이전엔 common 청크가 wrapper 명 init_X 를 mangle 하는데
  // entry 는 canonical 참조 → TypeError 라 파싱만 검증했으나, #4586 이 RBM init 을 mangle 제외해 해소.)
  test('cjs --minify: 공유 RBM 이 직접 실행에서 동작', async () => {
    const { outDir, cleanup } = await build('cjs', ESM_SETUP, 'setup.js', true);
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      const a = readFileSync(join(outDir, 'a.js'), 'utf8');
      expect(a).not.toMatch(/import\s*\{\s*init_/);
      expect(a).toContain('=require(');
      expect((await runNode(join(outDir, 'a.js'))).stdout.trim()).toBe('a:SETUP_DONE');
    } finally {
      await cleanup();
    }
  });

  // (#4586) iife --minify: 청크 로드 순서대로면 RBM 이 실행. wrapper init 이 canonical 유지돼야 정합.
  test('iife --minify: 청크 로드 순서대로면 RBM 실행', async () => {
    const { dir, outDir, cleanup } = await build('iife', ESM_SETUP, 'setup.js', true);
    try {
      const chunk = readdirSync(outDir).find((f) => f.startsWith('chunk-'))!;
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      const harness = join(dir, 'harness.js');
      writeFileSync(
        harness,
        `globalThis.__zntc_public_path="";\nrequire(${JSON.stringify(join(outDir, chunk))});\nrequire(${JSON.stringify(join(outDir, 'a.js'))});\n`,
      );
      const { stdout } = await runNode(harness);
      expect(stdout.trim()).toBe('a:SETUP_DONE');
    } finally {
      await cleanup();
    }
  });

  // esm: 회귀 방지.
  test('esm: 공유 RBM 정상 (회귀 방지)', async () => {
    const { outDir, cleanup } = await build('esm', ESM_SETUP, 'setup.js');
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      expect((await runNode(join(outDir, 'a.js'))).stdout.trim()).toBe('a:SETUP_DONE');
    } finally {
      await cleanup();
    }
  });

  // [리뷰 3] cjs-wrap RBM: 청크가 raw-require 하면(import함) 메인 forwarding 과 이중선언되면 안 됨.
  test('cjs-wrap RBM (엔트리가 import함): 이중선언 없이 실행', async () => {
    const { outDir, cleanup } = await build(
      'cjs',
      {
        'setup.cjs': 'module.exports.ready = 1;\nglobalThis.__setup = "CJS";',
        'a.js': 'require("./setup.cjs");\nconsole.log("a:" + globalThis.__setup);',
        'b.js': 'require("./setup.cjs");\nconsole.log("b:" + globalThis.__setup);',
      },
      'setup.cjs',
    );
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      const a = readFileSync(join(outDir, 'a.js'), 'utf8');
      const decls = a.match(/\brequire_setup\s*=/g) ?? [];
      expect(decls.length).toBeLessThanOrEqual(1); // 이중선언이면 SyntaxError
      expect((await runNode(join(outDir, 'a.js'))).stdout.trim()).toBe('a:CJS');
    } finally {
      await cleanup();
    }
  });

  // [리뷰 3] cjs-wrap RBM: 엔트리가 import 안 하면(run_before_main 만) cross-import 로 바인딩돼 실행.
  test('cjs-wrap RBM (import 안함): cross-import 로 바인딩돼 실행', async () => {
    const { outDir, cleanup } = await build(
      'cjs',
      {
        'setup.cjs': 'globalThis.__setup = "CJS2";',
        'a.js': 'console.log("a:" + (globalThis.__setup || "MISS"));',
        'b.js': 'console.log("b:" + (globalThis.__setup || "MISS"));',
      },
      'setup.cjs',
    );
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      expect((await runNode(join(outDir, 'a.js'))).stdout.trim()).toBe('a:CJS2');
    } finally {
      await cleanup();
    }
  });
});
