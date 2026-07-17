import { describe, test, expect } from 'bun:test';
import { runZntc, createFixture } from './helpers';
import { writeFileSync, readFileSync, readdirSync } from 'node:fs';
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

  test('#4492 splitting: `import * as ns` 의 멤버 접근도 같은 청크 참조가 오염되지 않는다', async () => {
    // 같은 루트커즈의 **다른 표면** — ns 멤버 재작성(`ns.second` → 식별자)도 게이트 없이
    // 전역 공개명을 썼다. materialize 된 ns **객체 getter** 는 #4502 에서 별도로 고쳤다
    // (아래 테스트).
    const files: Record<string, string> = {
      'shared/p.js': `export const second = { label: "second" };\nexport const other = { label: "other" };\n`,
      'shared/consumer.js': `import * as ns from "./p.js";
export function member() { return ns.second.label; }
`,
      'a.js': `import { member } from "./shared/consumer.js";
import { second } from "./shared/p.js";               // 다른 청크가 second 를 소비 → 전역 공개명 생성
export const a = () => member() + "|A:" + second.label;
`,
      'b.js': `import { member } from "./shared/consumer.js";
import { other } from "./shared/p.js";
export const b = () => member() + "|B:" + other.label;
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
        '--format=esm',
      ]);
      expect(build.exitCode).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));

      const r = runNode(join(outDir, 'entry.js'));
      // 수정 전: `ReferenceError: second is not defined`
      expect(r.err, `모듈 평가 실패:\n${r.err}`).toBe('');
      expect(r.out).toBe('second|A:second / second|B:other');
    } finally {
      await cleanup();
    }
  }, 120000);

  test('#4560 splitting: `import * as ns` 멤버가 다른 청크에 있으면 크로스-청크로 등록된다', async () => {
    // #4492 계열이 **over-registration**(같은 청크인데 전역 공개명 오염) 이라면 #4560 은
    // 정반대 **under-registration**: `ns.member` 는 linker 가 bare `member` 로 평탄화하는데,
    // 그 member 가 **다른 청크**(공통 청크)에 있고 named-import 로 소비하는 데가 하나도 없으면
    // (오직 namespace 멤버 접근만) `computeCrossChunkLinks` 의 어느 경로도 소비자 청크
    // `imports_from` 에 등록하지 않는다 → 소비자 청크서 bare `member` = 선언 없는 자유 변수
    // → `ReferenceError`. (mermaid: 각 다이어그램 청크가 자체 `fade` 를 정의하고 그 안에서
    // 공통 청크의 `khroma.channel` 을 namespace 멤버로 부름.)
    //
    // 핵심 조건: channel 을 **named-import 하는 소비자가 없어야** 한다. 있으면 import_bindings
    // 루프가 이미 등록해버려 버그가 안 난다(#4492 는 named-import 가 있었다).
    const files: Record<string, string> = {
      // 함수라 minify 인라인 불가 → 공통 청크에 실제 심볼로 남는다.
      'pkg/channel.js': `export const channel = (c, ch) => { let v = 0; for (const k in c) if (k === ch) v = c[k]; return v * 2; };\n`,
      // 각 다이어그램이 fade 를 **자체 정의**(mermaid 처럼 중복) → k.channel 이 leaf 청크서 평탄화.
      'diagram1.js': `import * as k from "./pkg/channel.js";
function fade(c) { return k.channel(c, "r") + "," + k.channel(c, "g"); }
export const d1 = () => "d1:" + fade({ r: 1, g: 2 });
`,
      'diagram2.js': `import * as k from "./pkg/channel.js";
function fade(c) { return k.channel(c, "b") + "," + k.channel(c, "g"); }
export const d2 = () => "d2:" + fade({ b: 3, g: 4 });
`,
      'entry.js': `Promise.all([import("./diagram1.js"), import("./diagram2.js")]).then(([m1, m2]) => {
  console.log(m1.d1() + " / " + m2.d2());
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
        '--format=esm',
      ]);
      expect(build.exitCode).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));

      // cross-chunk 경계를 **실제로** 검증한다 (런타임 출력만 보면 청킹 휴리스틱이
      // channel.js 를 다이어그램 청크마다 복제해버려도 green 이라 fix 가 우회된다).
      // diagram 청크가 별도 청크에서 `channel` 을 import 하는 edge 가 있어야 한다.
      const chunkFiles = readdirSync(outDir).filter(
        (f) => f.startsWith('diagram') && f.endsWith('.js'),
      );
      expect(chunkFiles.length).toBeGreaterThan(0);
      const importsChannel = chunkFiles.some((f) =>
        /import\{[^}]*\bchannel\b[^}]*\}from"\.\/chunk-/.test(
          readFileSync(join(outDir, f), 'utf-8'),
        ),
      );
      expect(
        importsChannel,
        'diagram 청크가 channel 을 cross-chunk import 하지 않음 — fix 우회',
      ).toBe(true);

      const r = runNode(join(outDir, 'entry.js'));
      // 수정 전: `ReferenceError: channel is not defined`
      expect(r.err, `모듈 평가 실패:\n${r.err}`).toBe('');
      expect(r.out).toBe('d1:2,4 / d2:6,8');
    } finally {
      await cleanup();
    }
  }, 120000);

  test('#4502 splitting: materialize 된 ns 객체 getter 가 같은 청크의 chunk-local 이름을 쓴다', async () => {
    // 네 번째 표면 — ns 를 **값으로** 쓰면(`const o = ns`) 정적 멤버 재작성이 불가능해
    // 객체가 materialize 된다: `var ns_ns = {get second(){return <name>}, ...}`.
    // 이 객체 리터럴은 **정의자 청크**(p.js 가 있는 공유 청크) preamble 로 들어가는데,
    // getter 본문이 cross-chunk 전역 공개명(`second`)을 쓰면 그 청크엔 그 이름의 선언이
    // 없다(로컬은 `--minify` 로 `n`) → `ReferenceError: second is not defined`.
    //
    //   let n={label:"second"}, r={label:"other"};
    //   var ns_ns = {get second(){return second}, get other(){return r}};
    //                             ^^^^^^ 선언 없음      ^ 얘는 맞음(비-cross-chunk)
    //
    // 순진하게 "같은 청크면 exp.local" 로 게이트하면 #4101 이 회귀한다 — 리터럴 생성
    // 시점에 chunk-local rename 이 미확정이라 exp.local 이 미-deconflict 원본 이름이기
    // 때문. 처방은 리터럴 생성을 per-chunk rename **이후**로 미루는 것.
    // (#4101 lock 은 cross-chunk-reexport.test.ts 의 'namespace re-export collision' 테스트.)
    const files: Record<string, string> = {
      'shared/p.js': `export const second = { label: "second" };\nexport const other = { label: "other" };\n`,
      'shared/consumer.js': `import * as ns from "./p.js";
export function useNs() {
  const o = ns;                      // ns 를 값으로 → 객체 materialize 강제
  return o.second.label + "+" + o.other.label + "+" + Object.keys(o).length;
}
`,
      'a.js': `import { useNs } from "./shared/consumer.js";
import { second } from "./shared/p.js";               // 다른 청크가 second 를 소비 → 전역 공개명 생성
export const a = () => useNs() + "|A:" + second.label;
`,
      'b.js': `import { useNs } from "./shared/consumer.js";
import { other } from "./shared/p.js";
export const b = () => useNs() + "|B:" + other.label;
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
        '--format=esm',
      ]);
      expect(build.exitCode).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));

      const r = runNode(join(outDir, 'entry.js'));
      // 수정 전: `ReferenceError: second is not defined`
      expect(r.err, `모듈 평가 실패:\n${r.err}`).toBe('');
      expect(r.out).toBe('second+other+2|A:second / second+other+2|B:other');
    } finally {
      await cleanup();
    }
  }, 120000);
});
