import { describe, test, expect } from 'bun:test';
import { runZntc, createFixture } from './helpers';
import { readdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

/**
 * 실행 스모크 게이트 (#4491 / #4492 계열).
 *
 * 산출물 재파싱 게이트(`output-parsable.test.ts`)는 **문법**만 본다. 그런데 이 계열은
 * 빌드 green · 파싱 green 이고 **실행할 때만** 터진다:
 *
 * - #4491: mangler 가 모듈 게터에 `$m` 을 배정 → CJS 래퍼 파라미터가 섀도잉
 *          → `TypeError: $m is not a function` (highlight.js)
 * - #4492: splitting + mangle 시 다른 모듈에서 온 참조가 재작성되지 않음 → 자유 변수
 *          → `ReferenceError: second is not defined` (mermaid) — 별도 PR
 *
 * 그래서 **번들을 실제로 실행해 모듈 평가가 끝까지 가는지** 확인한다.
 * 두 버그 다 "모듈이 충분히 많을 때만" 드러나므로 규모가 있는 픽스처를 쓴다.
 */

function runNode(file: string): { out: string; err: string; code: number | null } {
  const r = spawnSync('node', [file], { encoding: 'utf-8' });
  return { out: r.stdout.trim(), err: r.stderr.trim(), code: r.status };
}

describe('실행 스모크 게이트', () => {
  test('#4491 CJS 모듈이 많아도 래퍼 파라미터($e/$m)가 모듈 게터를 섀도잉하지 않는다', async () => {
    // 이름 풀이 `$` 영역까지 내려가야 재현된다 — 300개면 충분(실측).
    // mangler 가 게터에 `$m` 을 배정하면 다른 CJS 래퍼 안의 `$m`(= module 객체)이 그걸
    // 섀도잉해 `TypeError: $m is not a function`. 빌드·파싱 다 통과하고 실행만 실패한다.
    const N = 300;
    const files: Record<string, string> = {};
    for (let i = 0; i < N; i++) {
      files[`m${i}.cjs`] = `module.exports = function(){ return ${i}; };\n`;
    }
    const reqs = Array.from({ length: N }, (_, i) => `  s += require("./m${i}.cjs")();`).join('\n');
    files['index.cjs'] =
      `function load(){\n  let s = 0;\n${reqs}\n  return s;\n}\nmodule.exports = { load };\n`;
    files['entry.js'] = `import idx from "./index.cjs";\nconsole.log(idx.load());\n`;

    const { dir, cleanup } = await createFixture(files);
    try {
      // `zntc build` (앱 빌드) 경로여야 이름 풀이 `$` 까지 내려간다 — `--bundle` 로는 재현 안 됨.
      writeFileSync(
        join(dir, 'index.html'),
        '<!DOCTYPE html><html><body><script type="module" src="/entry.js"></script></body></html>',
      );
      const outDir = join(dir, 'out');
      const build = await runZntc([
        'build',
        dir,
        '--entry-html',
        join(dir, 'index.html'),
        '--outdir',
        outDir,
        '--minify',
      ]);
      expect(build.exitCode).toBe(0);

      const entryChunk = readdirSync(outDir).find(
        (f) => f.startsWith('entry-') && f.endsWith('.js'),
      );
      expect(entryChunk).toBeDefined();
      const mjs = join(outDir, 'run.mjs');
      copyFileSync(join(outDir, entryChunk!), mjs);

      // 300 모듈의 0..299 합 = 44850
      const r = runNode(mjs);
      expect(r.err, `모듈 평가 실패:\n${r.err}`).toBe('');
      expect(r.out).toBe('44850');
    } finally {
      await cleanup();
    }
  }, 120000);
});
