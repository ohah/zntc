import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { bundleAndRun, createFixture, runZntc, runNode } from './helpers';

/**
 * #4514 회귀 가드 — dead-store 제거의 **purity 판정**이 member access / 미해결 식별자를
 * pure 로 봐서, 값이 죽었다는 이유로 **평가 부수효과까지** 지워버리던 무성 오컴파일.
 *
 *   let x = obj.p;   // p 가 getter 면 평가 자체가 부수효과
 *   x = 2;           // → `x = obj.p` 삭제 → getter 미호출
 *
 *   let y = a.b.c;   // a.b 가 undefined 면 TypeError
 *   y = 2;           // → 삭제 → TypeError 안 던짐
 *
 *   let z = undeclaredGlobal;   // ReferenceError
 *   z = 2;                      // → 삭제 → 안 던짐
 *
 * 근본 원인: dead-store 가 tree-shaking 용 `purity.isExprPure` 를 썼다. 그건 "이 **선언을
 * 안 만들어도** 되는가" 기준이라 member access 를 pure 로 친다(esbuild 동일). 하지만
 * dead-store 는 **이미 실행되기로 확정된 표현식을 삭제**하는 패스라 문 자리 DCE 와 같은
 * 엄격 술어(`purity.isRemovableAtStmtPos`)를 써야 한다.
 *
 * #4503 과 마찬가지로 빌드도 파싱도 다 통과한다 — **번들을 실제로 실행해야만** 드러난다.
 */
describe('#4514: dead-store 가 평가 부수효과를 지우지 않는다', () => {
  test('--minify: 초기화자의 getter 호출이 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          const log: string[] = [];
          const obj = { get p() { log.push("getter"); return 1; } };
          function f() {
            let x = obj.p;   // dead store 지만 obj.p 평가는 부수효과
            x = 2;
            return x;
          }
          f();
          console.log(JSON.stringify(log));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: [] (getter 가 호출되지 않음)
      expect(r.runOutput).toBe('["getter"]');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: 대입문 RHS 의 getter 호출도 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          const log: string[] = [];
          const obj = { get p() { log.push("getter"); return 1; } };
          function f() {
            let x;
            x = obj.p;
            x = 2;
            return x;
          }
          f();
          console.log(JSON.stringify(log));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('["getter"]');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: getter 가 정확히 원본과 같은 횟수로 호출된다', async () => {
    // 삭제뿐 아니라 중복 실행도 없어야 한다 (semantic-preserving 양방향).
    const files = {
      'index.ts': `
        let count = 0;
        const obj = { get p() { count++; return 1; } };
        function f() {
          let x = obj.p;
          x = obj.p;
          x = 2;
          return x;
        }
        f();
        f();
        console.log("count=" + count);
      `,
    };
    const plain = await bundleAndRun(files, 'index.ts', []);
    const min = await bundleAndRun(files, 'index.ts', ['--minify']);
    try {
      expect(plain.exitCode).toBe(0);
      expect(min.exitCode).toBe(0);
      expect(plain.runOutput).toBe('count=4');
      expect(min.runOutput).toBe(plain.runOutput);
    } finally {
      await plain.cleanup();
      await min.cleanup();
    }
  });

  test('--minify: nullish base 의 TypeError 가 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          const a: any = {};
          function f() {
            let y = a.b.c;   // a.b 는 undefined → TypeError
            y = 2;
            return y;
          }
          try { f(); console.log("NO_THROW"); }
          catch (e: any) { console.log("threw:" + e.constructor.name); }
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: "NO_THROW"
      expect(r.runOutput).toBe('threw:TypeError');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: 미해결 전역 읽기의 ReferenceError 가 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          declare const undeclaredGlobal: number;
          function f() {
            let z = undeclaredGlobal;
            z = 2;
            return z;
          }
          try { f(); console.log("NO_THROW"); }
          catch (e: any) { console.log("threw:" + e.constructor.name); }
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: "NO_THROW"
      expect(r.runOutput).toBe('threw:ReferenceError');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: computed member 의 key 평가 부수효과도 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          const log: string[] = [];
          const arr = [10, 20];
          function key() { log.push("key"); return 0; }
          function f() {
            let x = arr[key()];
            x = 2;
            return x;
          }
          f();
          console.log(JSON.stringify(log));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('["key"]');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify --format=iife: sloppy mapped arguments 가 파라미터를 aliasing 해도 보존', async () => {
    // 비엄격 함수의 파라미터는 `arguments` 객체와 양방향 aliasing 이라 `arguments[0]` 읽기가
    // 참조 배열에 파라미터 read 로 잡히지 않는다. `a = 1` 을 지우면 `arguments[0]` 이
    // 원래 인자값(0)을 보게 된다.
    //
    // **반드시 node CJS 로 실행**해야 한다 — `bun run` 은 .js 를 strict 로 돌려서 mapped
    // arguments 자체가 없다(= 버그가 안 드러난다). 그래서 `bundleAndRun`(bun) 대신
    // `runNode` 를 쓴다.
    const { dir, cleanup } = await createFixture({
      'index.js': `
        function f(a) {
          a = 1;
          const seen = arguments[0];
          a = 2;
          return seen;
        }
        console.log("seen=" + f(0));
      `,
    });
    const outFile = join(dir, 'out.js');
    try {
      const bundle = await runZntc([
        '--bundle',
        join(dir, 'index.js'),
        '-o',
        outFile,
        '--minify',
        '--format=iife',
      ]);
      expect(bundle.exitCode).toBe(0);
      const { stdout } = await runNode(outFile);
      // 버그 시: "seen=0"
      expect(stdout).toBe('seen=1');
    } finally {
      await cleanup();
    }
  });

  test('--minify 와 non-minify 의 실행 결과가 같다 (semantic-preserving)', async () => {
    const files = {
      'index.ts': `
        const log: string[] = [];
        const obj = { get p() { log.push("p"); return 1; }, get q() { log.push("q"); return 2; } };
        function f() {
          let x = obj.p;
          x = obj.q;
          x = 3;
          return x;
        }
        console.log(f() + ":" + log.join("|"));
      `,
    };
    const plain = await bundleAndRun(files, 'index.ts', []);
    const min = await bundleAndRun(files, 'index.ts', ['--minify']);
    try {
      expect(plain.exitCode).toBe(0);
      expect(min.exitCode).toBe(0);
      expect(min.runOutput).toBe(plain.runOutput);
      expect(min.runOutput).toBe('3:p|q');
    } finally {
      await plain.cleanup();
      await min.cleanup();
    }
  });

  // ─── 안티-회귀: 진짜 dead store 는 계속 제거돼야 한다 (size 회귀 방지) ───

  test('anti-regression: 리터럴 dead store 는 여전히 제거된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          function f() {
            let x = "DEAD_LITERAL_INIT";
            x = "DEAD_LITERAL_ASSIGN";
            x = "LIVE";
            return x;
          }
          console.log(f());
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('LIVE');
      expect(r.bundleOutput).not.toContain('DEAD_LITERAL_INIT');
      expect(r.bundleOutput).not.toContain('DEAD_LITERAL_ASSIGN');
    } finally {
      await r.cleanup();
    }
  });

  test('anti-regression: TDZ 없는 바인딩(var / 파라미터) 읽기 dead store 는 여전히 제거된다', async () => {
    // DSE 수익의 대부분이 여기서 나온다 — 이게 죽으면 보수화가 과했다는 뜻이다.
    const r = await bundleAndRun(
      {
        'index.ts': `
          function f(param: string) {
            var src = "VAR_SRC";
            let x = src;            // var 읽기 — TDZ 없음
            x = param;              // 파라미터 읽기 — TDZ 없음
            x = "DEAD_LITERAL";
            x = "LIVE";
            return x + src.length + param;
          }
          console.log(f("P"));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('LIVE7P');
      // 앞의 세 store 는 전부 제거된다 → `let x; x="LIVE"`.
      expect(r.bundleOutput).not.toContain('DEAD_LITERAL');
      expect(r.bundleOutput).toContain('let x;');
    } finally {
      await r.cleanup();
    }
  });

  test('block-scoped(let/const) 읽기 dead store 는 TDZ 때문에 의도적으로 유지한다', async () => {
    // `let`/`const`/`class` 읽기는 **선언이 실행되기 전**이면 ReferenceError(TDZ) 다.
    // 그런데 텍스트 순서로는 못 가른다 — 읽기가 hoisting 된 함수 안에 있고 그 함수가
    // 선언 실행 전에 불릴 수 있기 때문이다:
    //
    //   function o(){ h(); let x = 1; function h(){ let a = x; a = 2; } }   // TDZ
    //
    // 참조 노드가 어느 실행 단위인지 이 술어는 모르므로 block-scoped 읽기는 통째로
    // 유지한다. esbuild 도 이 store 를 DSE 로 지우지 않는다(상수 인라인으로 지울 뿐).
    // 유지가 곧 정답이므로 여기서 잠근다 — 나중에 "왜 안 지우지?" 로 되돌리지 말 것.
    const r = await bundleAndRun(
      {
        'index.ts':
          `
          function f() {
            const local = "SRC";
            let x = local;              // block-scoped 읽기 → 유지
            x = local + "CONCAT";       // ` +
          ` 는 ToPrimitive → valueOf 호출 가능 → 유지
            x = "LIVE";
            return x + local.length;
          }
          console.log(f());
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('LIVE3');
      expect(r.bundleOutput).toContain('CONCAT');
    } finally {
      await r.cleanup();
    }
  });
});
