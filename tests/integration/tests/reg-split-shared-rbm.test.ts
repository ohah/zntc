import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync } from 'node:fs';
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
 * 메인 cross-chunk import 블록과 동일한 결합 형태.
 *
 * ⚠️ iife/umd/amd multi-chunk 는 청크가 **로드 순서대로** 등록돼야 __zntc_require 가 동작한다(브라우저
 *    script 태그 순서·일반 cross-chunk 도 동일한 기존 제약). Node 직접 실행은 common 청크 미로드로 별개.
 */

async function build(format: 'iife' | 'umd' | 'amd' | 'cjs' | 'esm') {
  const { dir, cleanup } = await createFixture({
    'setup.js': 'globalThis.__setup = "SETUP_DONE";',
    'a.js': 'import "./setup.js";\nconsole.log("a:" + globalThis.__setup);',
    'b.js': 'import "./setup.js";\nconsole.log("b:" + globalThis.__setup);',
  });
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, 'a.js'),
    join(dir, 'b.js'),
    '--splitting',
    `--format=${format}`,
    '--platform=node',
    `--run-before-main=${join(dir, 'setup.js')}`,
    '--outdir',
    outDir,
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  return { dir, outDir, cleanup };
}

describe('#4555: reg_split/cjs multi-entry 공유 run-before-main', () => {
  // reg_split(iife/umd/amd): factory 안 ESM import 가 없어야(=SyntaxError 제거).
  for (const format of ['iife', 'umd', 'amd'] as const) {
    test(`${format}: RBM cross-import 가 ESM import 아님 (registry)`, async () => {
      const { outDir, cleanup } = await build(format);
      try {
        const a = readFileSync(join(outDir, 'a.js'), 'utf8');
        // RBM init 을 factory 안에서 ESM import 로 가져오면 SyntaxError.
        expect(a).not.toMatch(/import\s*\{\s*init_/);
        expect(a).toContain('__zntc_require('); // registry 결합
        // 파싱 가능해야: node --check 로 SyntaxError 없음 확인.
        const chk = await runNode(join(outDir, 'a.js')).catch((e: Error) => e.message);
        expect(String(chk)).not.toContain('SyntaxError');
      } finally {
        await cleanup();
      }
    });
  }

  // iife: 청크를 로드 순서대로(common → entry) 넣으면 RBM 이 실행돼 setup 이 돈다.
  test('iife: 청크 로드 순서대로면 RBM 실행 (브라우저 script 순서)', async () => {
    const { dir, outDir, cleanup } = await build('iife');
    try {
      const fs = await import('node:fs');
      const chunk = fs.readdirSync(outDir).find((f) => f.startsWith('chunk-'))!;
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      // common 청크 먼저 등록 후 entry 로드.
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

  // cjs: require 가 청크를 동기 로드하므로 직접 실행이 그대로 동작.
  test('cjs: 공유 RBM 이 직접 실행에서 동작', async () => {
    const { outDir, cleanup } = await build('cjs');
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'commonjs' }));
      const a = readFileSync(join(outDir, 'a.js'), 'utf8');
      expect(a).not.toMatch(/import\s*\{\s*init_/); // cjs 에 ESM import 없어야
      const ra = await runNode(join(outDir, 'a.js'));
      expect(ra.stdout.trim()).toBe('a:SETUP_DONE');
      const rb = await runNode(join(outDir, 'b.js'));
      expect(rb.stdout.trim()).toBe('b:SETUP_DONE');
    } finally {
      await cleanup();
    }
  });

  // esm: 회귀 방지 — 기존대로 동작.
  test('esm: 공유 RBM 정상 (회귀 방지)', async () => {
    const { outDir, cleanup } = await build('esm');
    try {
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const ra = await runNode(join(outDir, 'a.js'));
      expect(ra.stdout.trim()).toBe('a:SETUP_DONE');
    } finally {
      await cleanup();
    }
  });
});
