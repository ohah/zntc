import { describe, test, expect } from 'bun:test';
import { bundleAndRun } from './helpers';

/**
 * #4503 회귀 가드 — dead-store 제거가 **클로저를 통한 읽기**를 놓쳐서 살아 있는 대입문을
 * 삭제하던 무성 오컴파일.
 *
 *   let buf = "";
 *   function flush() { out.push(buf); }   // ← buf 를 클로저로 읽는다
 *   function emit(t) {
 *     buf = t;      // ← dead 가 아니다. 사이의 flush() 가 읽는다.
 *     flush();
 *     buf = "";
 *   }
 *
 * DSE 는 두 store 사이의 read 유무를 `Reference` 배열의 **소스 순서**로 판정했는데,
 * 클로저 안의 read 는 소스 위치가 두 store 밖(보통 앞)이라 안 보였다. 그 결과 `buf = t`
 * 가 통째로 삭제됐다 — 빌드 exit 0, 산출물 파싱 통과, 런타임 에러 0. **오직 실행 결과를
 * 대조해야만** 드러난다. 그래서 이 파일의 모든 테스트는 산출물 문자열이 아니라
 * **번들을 실제로 실행한 값**을 검증한다 (`bundleAndRun`).
 *
 * 실제 피해 사례: highlight.js `emitMultiClass` 의 `modeBuffer = text; processKeywords();
 * modeBuffer = "";` → 하이라이팅 결과가 틀리게 렌더링.
 */
describe('#4503: dead-store 가 클로저 읽기를 놓치지 않는다', () => {
  // reader(클로저) 의 형태별로 전부 박제한다. 원래 이슈에서 형태에 따라 결과가 갈리는
  // 것처럼 보였으나 실측 결과 전부 삭제됐다 — 형태 무관하게 보존돼야 한다.
  const readerForms: Array<{ name: string; reader: string; call: string }> = [
    {
      name: '함수 선언',
      reader: 'function flush() { out.push(buf); }',
      call: 'flush();',
    },
    {
      name: '화살표 함수',
      reader: 'const flush = () => { out.push(buf); };',
      call: 'flush();',
    },
    {
      name: '함수 표현식 (var)',
      reader: 'var flush = function () { out.push(buf); };',
      call: 'flush();',
    },
    {
      name: '객체 메서드',
      reader: 'const api = { flush() { out.push(buf); } };',
      call: 'api.flush();',
    },
    {
      name: '중첩 함수 (한 단계 더 안쪽에서 읽음)',
      reader: 'function flush() { const inner = () => out.push(buf); inner(); }',
      call: 'flush();',
    },
    {
      name: '조건부 읽기',
      reader: 'function flush() { if (buf !== undefined) out.push(buf); }',
      call: 'flush();',
    },
    {
      name: '클래스 메서드',
      reader: 'class Api { flush() { out.push(buf); } }\nconst api = new Api();',
      call: 'api.flush();',
    },
  ];

  for (const form of readerForms) {
    test(`--minify: ${form.name} 클로저 읽기 — 대입문 보존 + 실행 결과 일치`, async () => {
      const r = await bundleAndRun(
        {
          'index.ts': `
            let buf = "";
            const out: string[] = [];
            ${form.reader}
            function emit(t: string) {
              buf = t;
              ${form.call}
              buf = "";
            }
            emit("hello");
            emit("world");
            console.log(out.join("|"));
          `,
        },
        'index.ts',
        ['--minify'],
      );
      try {
        expect(r.exitCode).toBe(0);
        // 버그 시: "|" (buf = t 가 삭제되어 빈 문자열 두 개가 push 됨)
        expect(r.runOutput).toBe('hello|world');
      } finally {
        await r.cleanup();
      }
    });
  }

  test('--minify: 클로저 reader 가 store 보다 뒤에 선언돼도(호이스팅) 보존', async () => {
    // reader 의 소스 위치를 store 뒤로 옮기면 클로저 read 의 ref_pos 가 두 store *뒤* 라
    // "사이에 read 없음" 판정이 또 통과한다. 앞/뒤 어느 쪽이든 보존돼야 한다.
    const r = await bundleAndRun(
      {
        'index.ts': `
          let buf = "";
          const out: string[] = [];
          function emit(t: string) {
            buf = t;
            flush();
            buf = "";
          }
          function flush() { out.push(buf); }
          emit("hello");
          emit("world");
          console.log(out.join("|"));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('hello|world');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: 함수 안 지역변수를 중첩 함수가 읽는 경우도 보존', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          const out: string[] = [];
          function outer() {
            var buf = "";
            function flush() { out.push(buf); }
            function emit(t: string) {
              buf = t;
              flush();
              buf = "";
            }
            emit("hello");
            emit("world");
          }
          outer();
          console.log(out.join("|"));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('hello|world');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: 선언 초기화자도 클로저가 읽으면 보존', async () => {
    // `let buf = "INIT";` 의 초기화자 역시 store 다. 뒤의 재대입 사이에서 클로저가 읽으면
    // 초기화자를 지우면 안 된다 (지우면 undefined 가 읽힌다).
    const r = await bundleAndRun(
      {
        'index.ts': `
          let buf = "INIT";
          const out: string[] = [];
          function flush() { out.push(String(buf)); }
          flush();
          buf = "AFTER";
          flush();
          console.log(out.join("|"));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('INIT|AFTER');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: 두 store 사이의 흐름 끊김(break)이 뒤 store 를 건너뛰면 앞 store 보존', async () => {
    // 클로저와 무관한 같은 계열의 결함: `x = 1; if (c) break lbl; x = 2;` 에서 break 시
    // 뒤 store 가 실행되지 않아 x 는 1 로 남는다. 소스 순서 분석은 그 경로를 못 본다.
    const r = await bundleAndRun(
      {
        'index.ts': `
          function f(c: boolean) {
            let x = 0;
            let pad1 = 5;
            let pad2 = 7;
            lbl: { x = 1; if (c) break lbl; x = 2; }
            return x + pad1 + pad2;
          }
          console.log(f(true), f(false));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: "12 14" (x = 1 이 삭제되어 break 경로에서 x 가 0)
      expect(r.runOutput).toBe('13 14');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify 와 non-minify 의 실행 결과가 같다 (semantic-preserving)', async () => {
    const files = {
      'index.ts': `
        let buf = "";
        const out: string[] = [];
        function flush() { out.push(buf); }
        function emit(t: string) { buf = t; flush(); buf = ""; }
        emit("a"); emit("b"); emit("c");
        console.log(out.join("|"));
      `,
    };
    const plain = await bundleAndRun(files, 'index.ts', []);
    const min = await bundleAndRun(files, 'index.ts', ['--minify']);
    try {
      expect(plain.exitCode).toBe(0);
      expect(min.exitCode).toBe(0);
      expect(min.runOutput).toBe(plain.runOutput);
      expect(min.runOutput).toBe('a|b|c');
    } finally {
      await plain.cleanup();
      await min.cleanup();
    }
  });

  // ─── 재진입(re-entrancy): read/write 가 같은 함수라도 변수가 함수 밖에 선언됐으면 위험 ───

  test('--minify: 재귀로 재진입하면 바깥 변수의 store 가 보존된다', async () => {
    // read(out.push(cur))와 write(cur = v)가 **같은 함수** 안이라 "다른 실행 단위 read" 가드는
    // 통과한다. 하지만 cur 은 run 밖에 선언돼 호출이 겹치면 바인딩을 공유 — 사이의 inner() 가
    // run 을 다시 부르면 다른 활성화가 앞 store 의 값을 읽는다.
    const r = await bundleAndRun(
      {
        'index.ts': `
          let cur: string | null = null;
          const out: (string | null)[] = [];
          let done = false;
          function inner() { if (!done) { done = true; run("second"); } }
          function run(v: string) {
            out.push(cur);
            cur = v;
            inner();
            cur = null;
          }
          run("first");
          console.log(JSON.stringify(out));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: [null,null] (cur = v 가 삭제됨)
      expect(r.runOutput).toBe('[null,"first"]');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: await 인터리빙 중 바깥 변수의 store 가 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          let buf = "";
          const out: string[] = [];
          const tick = () => new Promise<void>((res) => setTimeout(res, 0));
          async function f(v: string) {
            out.push("before=" + buf);
            buf = v;
            await tick();
            buf = "";
          }
          Promise.all([f("a"), f("b")]).then(() => console.log(out.join("|")));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: "before=|before=" (buf = v 가 삭제됨)
      expect(r.runOutput).toBe('before=|before=a');
    } finally {
      await r.cleanup();
    }
  });

  test('--minify: 사이의 호출이 예외로 빠져나가도 바깥 변수의 store 가 보존된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          let cur: number | null = null;
          const out: (number | null)[] = [];
          function boom(): void { throw new Error("x"); }
          function run(v: number) {
            out.push(cur);
            cur = v;
            if (v === 1) boom();
            cur = null;
          }
          try { run(1); } catch {}
          run(2);
          console.log(JSON.stringify(out));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      // 버그 시: [null,null] (cur = v 가 삭제됨)
      expect(r.runOutput).toBe('[null,1]');
    } finally {
      await r.cleanup();
    }
  });

  // ─── 안티-회귀: 진짜 dead store 는 계속 제거돼야 한다 (size 회귀 방지) ───

  test('anti-regression: 아무도 안 읽는 store 는 여전히 제거된다', async () => {
    const r = await bundleAndRun(
      {
        'index.ts': `
          function f() {
            let x;
            x = "DEAD_STORE_MUST_BE_REMOVED";
            x = "LIVE_STORE_KEPT";
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
      expect(r.runOutput).toBe('LIVE_STORE_KEPT');
      // 클로저 read 가 없으므로 앞 store 는 진짜 dead → 제거 유지.
      expect(r.bundleOutput).not.toContain('DEAD_STORE_MUST_BE_REMOVED');
      expect(r.bundleOutput).toContain('LIVE_STORE_KEPT');
    } finally {
      await r.cleanup();
    }
  });

  test('anti-regression: 중첩 switch/loop 의 break 는 바깥 흐름을 끊지 않는다', async () => {
    // 창 안에 완전히 포함된 loop/switch 에 묶이는 라벨 없는 break/continue, 그리고 객체 메서드의
    // return 은 바깥 statement list 흐름과 무관 → 진짜 dead store 는 계속 제거돼야 한다.
    const r = await bundleAndRun(
      {
        'index.ts': `
          function f(v: number) {
            let x;
            x = "NESTED_DEAD";
            switch (v) { case 1: console.log("one"); break; default: break; }
            for (const q of [1]) { if (q) break; }
            const o = { m() { return 1; } };
            o.m();
            x = "NESTED_LIVE";
            return x;
          }
          console.log(f(1));
        `,
      },
      'index.ts',
      ['--minify'],
    );
    try {
      expect(r.exitCode).toBe(0);
      expect(r.runOutput).toBe('one\nNESTED_LIVE');
      expect(r.bundleOutput).not.toContain('NESTED_DEAD');
    } finally {
      await r.cleanup();
    }
  });

  test('anti-regression: 클로저가 *다른* 심볼만 읽으면 dead store 는 제거된다', async () => {
    // 가드는 "그 심볼을 다른 실행 단위에서 읽는가" 로만 판정한다. 무관한 심볼을 읽는
    // 클로저가 사이에 끼어 있다고 해서 제거를 포기하면 안 된다 (과잉 보수 방지).
    const r = await bundleAndRun(
      {
        'index.ts': `
          const other = "OTHER";
          function f() {
            let x;
            x = "DEAD_WITH_UNRELATED_CLOSURE";
            console.log(other);
            x = "LIVE_WITH_UNRELATED_CLOSURE";
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
      expect(r.runOutput).toBe('OTHER\nLIVE_WITH_UNRELATED_CLOSURE');
      expect(r.bundleOutput).not.toContain('DEAD_WITH_UNRELATED_CLOSURE');
    } finally {
      await r.cleanup();
    }
  });
});
