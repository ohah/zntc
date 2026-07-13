import { describe, test, expect } from 'bun:test';
import { runZntc, createFixture } from './helpers';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

/**
 * 코드 스플리팅 산출물 **실행** 스모크 (#4492).
 *
 * 산출물 재파싱 게이트(`output-parsable.test.ts`)는 문법만 본다. 이 계열은 빌드 exit 0,
 * 산출물 전부 파싱 통과이고 **실행할 때만** 터진다 — 그래서 실제로 돌려 본다.
 *
 * 기존 `cross-chunk-symbol-naming.test.ts` 의 lock 테스트들은 전부 **소비자가 provider 와
 * 다른 청크**다. "cross-chunk 로 노출되는 심볼을 **같은 청크의 다른 모듈이** 참조" 하는
 * 형태가 하나도 없어서 #4492 가 뚫렸다.
 */

function runNode(file: string): { out: string; err: string } {
  const r = spawnSync('node', [file], { encoding: 'utf-8' });
  return { out: r.stdout.trim(), err: r.stderr.trim() };
}

describe('splitting 산출물 실행 스모크', () => {
  test('#4492 같은 청크 안의 참조가 크로스-청크 공개명으로 오염되지 않는다', async () => {
    // 전역 공개명 맵은 `(provider 모듈, export)` 키라 "다른 **어떤** 청크가 이 심볼을
    // 소비하는가" 만 말해준다 — **누가 묻는지는 모른다**. 소비자를 안 보고 적용하면
    // provider 와 **같은 청크**에 있는 소비자까지 그 청크 바깥에서만 존재하는 공개명
    // (`exports.second` 의 좌변)으로 본문이 재작성된다. `--minify` 로 로컬이 `n` 으로
    // mangle 되면 `second` 는 선언 없는 자유 변수가 되어 `ReferenceError`.
    //
    // 구조 (d3-time 의 ticks.js 위상을 축소):
    //   - second.js 를 a/b 두 소비자가 공유 → 공통 청크로 분리 + **다른 청크도 소비**
    //     → 전역 공개명이 생긴다.
    //   - ticker.js 는 second.js 와 **같은 청크**에 있고, second 를 중첩 스코프에서 참조.
    const files: Record<string, string> = {
      'shared/second.js': `export const second = { label: "second" };\n`,
      'shared/minute.js': `export const minute = { label: "minute" };\n`,
      'shared/ticker.js': `import { second } from "./second.js";
import { minute } from "./minute.js";
export function ticker() {
  const table = [[second, 1], [second, 5], [minute, 1]];
  return table.map((r) => r[0].label + ":" + r[1]).join(",");
}
`,
      'a.js': `import { ticker } from "./shared/ticker.js";
import { second } from "./shared/second.js";
export const a = () => ticker() + "|A:" + second.label;
`,
      'b.js': `import { ticker } from "./shared/ticker.js";
import { minute } from "./shared/minute.js";
export const b = () => ticker() + "|B:" + minute.label;
`,
      'entry.js': `Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) => {
  console.log(m1.a() + " / " + m2.b());
});
`,
    };

    const { dir, cleanup } = await createFixture(files);
    try {
      const outDir = join(dir, 'out');
      const build = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--splitting',
        '--outdir',
        outDir,
        '--minify',
        '--format=esm', // 기본 청크 로더는 브라우저용(script 태그) 이라 node 로 직접 실행 불가
      ]);
      expect(build.exitCode).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));

      const r = runNode(join(outDir, 'entry.js'));
      // 수정 전: `ReferenceError: second is not defined`
      expect(r.err, `모듈 평가 실패:\n${r.err}`).toBe('');
      expect(r.out).toBe(
        'second:1,second:5,minute:1|A:second / second:1,second:5,minute:1|B:minute',
      );
    } finally {
      await cleanup();
    }
  }, 120000);
});
