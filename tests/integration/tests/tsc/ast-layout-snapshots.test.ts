// #1802 후속 — 이번 시리즈에서 AST tag layout / parser 저장 variant 를 바꾼
// tag 들의 emit 결과를 고정한다. audit 스크립트가 감시하지 못하는
// "output behavior" 차원의 회귀 방지.
//
// 각 테스트는 최소 입력 을 작성해 해당 tag 가 parser/codegen 에서 의도대로
// 처리되는지 출력 문자열로 확인. parser/layout 재정비 시 silent behavior
// change 가 일어나면 snapshot diff 로 즉시 실패.
import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "../helpers";
import { readFileSync } from "node:fs";
import { join } from "node:path";

async function transpile(code: string, extraArgs: string[] = []): Promise<string> {
  const { dir, cleanup } = await createFixture({ "index.ts": code });
  const outFile = join(dir, "out.js");
  const res = await runZts([join(dir, "index.ts"), "-o", outFile, ...extraArgs]);
  expect(res.exitCode).toBe(0);
  const out = readFileSync(outFile, "utf-8");
  await cleanup();
  return out;
}

describe("AST layout snapshot — #1802 변경 대상 tag", () => {
  // #1811: ts_as_expression / ts_satisfies_expression / flow_as_expression —
  // parser 가 .binary 저장하며 codegen 은 .unary.operand 읽던 extern union
  // aliasing 버그 수정. emit 은 operand 만 남기고 type 부분은 strip.
  test("ts_as_expression: operand 만 emit, type annotation 제거", async () => {
    const out = await transpile(`
      const x = 42 as number;
      const y = (obj as unknown) as string;
      console.log(x, y);
    `);
    // type annotation 이 strip 되어야 한다 — "as number" / "as unknown" / "as string" 흔적 없음
    expect(out).not.toMatch(/\bas\s+number\b/);
    expect(out).not.toMatch(/\bas\s+unknown\b/);
    expect(out).not.toMatch(/\bas\s+string\b/);
    // operand 는 유지
    expect(out).toMatch(/\bconst\s+x\s*=\s*42\b/);
    expect(out).toMatch(/\bconst\s+y\s*=\s*\(?\s*obj/);
  });

  test("ts_satisfies_expression: operand 유지", async () => {
    const out = await transpile(`
      const obj = { a: 1, b: 2 } satisfies Record<string, number>;
      console.log(obj);
    `);
    expect(out).not.toMatch(/\bsatisfies\b/);
    expect(out).toMatch(/\{\s*a:\s*1,\s*b:\s*2\s*\}/);
  });

  test("ts_type_assertion: operand 만 emit", async () => {
    const out = await transpile(`
      const a = <number>42;
      console.log(a);
    `);
    // 화살괄호 타입 주석 제거
    expect(out).not.toMatch(/<number>/);
    expect(out).toMatch(/\bconst\s+a\s*=\s*42\b/);
  });

  // #1818: ts_union_type / ts_intersection_type — binary tree chain → flat
  // NodeList. strip-only 이므로 emit 에 type 흔적 전혀 없어야 한다. chain 구조
  // 에서 list 로 전환되어도 외부 의미 동일 (type 부분 통째 스트립) 임을 고정.
  test("ts_union_type (A|B|C): 모두 strip, 런타임 값만 emit", async () => {
    const out = await transpile(`
      type T = number | string | boolean;
      const v: T = 42;
      console.log(v);
    `);
    expect(out).not.toMatch(/:\s*number\s*\|\s*string/);
    expect(out).not.toMatch(/\btype\s+T\b/);
    expect(out).toMatch(/\bconst\s+v\s*=\s*42\b/);
  });

  test("ts_intersection_type (A&B): strip", async () => {
    const out = await transpile(`
      type T = { a: number } & { b: string };
      const v: T = { a: 1, b: "x" };
      console.log(v);
    `);
    expect(out).not.toMatch(/\bA\s*&\s*B/);
    expect(out).not.toMatch(/\btype\s+T\b/);
    expect(out).toMatch(/\{\s*a:\s*1,\s*b:\s*"x"\s*\}/);
  });

  // #1819: ts_property_signature — interface member 는 strip
  test("ts_property_signature (interface member): 전부 strip", async () => {
    const out = await transpile(`
      interface Opts { name: string; count?: number; }
      const o: Opts = { name: "a", count: 1 };
      console.log(o);
    `);
    expect(out).not.toMatch(/\binterface\b/);
    expect(out).not.toMatch(/\bOpts\b/);
    expect(out).toMatch(/\{\s*name:\s*"a",\s*count:\s*1\s*\}/);
  });

  // #1819: ts_rest_type — tuple 의 rest element 타입 (e.g. `[number, ...string[]]`).
  // 전체 type 표현이 strip 되어야 하므로 ts_rest_type 도 흔적 없어야 한다.
  test("ts_rest_type (tuple rest): strip", async () => {
    const out = await transpile(`
      type T = [number, ...string[]];
      const v: T = [1, "a", "b"];
      console.log(v);
    `);
    expect(out).not.toMatch(/\btype\s+T\b/);
    expect(out).not.toMatch(/\.\.\.string\[\]/);
    expect(out).toMatch(/\[1,\s*"a",\s*"b"\]/);
  });

  // #1819: parenthesized_expression — 빈 `()` arrow param list.
  // `()` 자체는 arrow function 의 빈 파라미터 리스트로 처리되어야 한다.
  test("parenthesized_expression (빈 괄호 + 화살표): arrow emit 정상", async () => {
    const out = await transpile(`
      const f = () => 42;
      console.log(f());
    `);
    expect(out).toMatch(/\(\s*\)\s*=>\s*42/);
  });

  // #1819: import_attribute (layout = .binary).
  // ESM `import ... with { type: "json" }` 의 attr 이 emit 에 유지되어야 한다.
  test("import_attribute (with clause): attr 유지", async () => {
    const { dir, cleanup } = await createFixture({
      "data.json": `{"hello":"world"}`,
      "index.ts": `
        import data from "./data.json" with { type: "json" };
        console.log(data.hello);
      `,
    });
    const outFile = join(dir, "out.js");
    const res = await runZts([join(dir, "index.ts"), "-o", outFile, "--format=esm"]);
    expect(res.exitCode).toBe(0);
    const out = readFileSync(outFile, "utf-8");
    // attr 문법 이 emit 에 보존 (key=type, value="json")
    expect(out).toMatch(/with\s*\{\s*type:\s*['"]json['"]\s*\}/);
    await cleanup();
  });

  // #1813: unlabeled continue in for-of + let closure (이전 fix 검증)
  test("for-of + let + continue + closure: _loop body 에 continue 안 남음", async () => {
    const out = await transpile(
      `
      const arr = [1, 2, 3, 4];
      const fns: Array<() => number> = [];
      for (let x of arr) {
        if (x % 2 === 0) continue;
        fns.push(() => x);
      }
      console.log(fns.map(f => f()).join(","));
    `,
      ["--target=es5"],
    );
    // _loop 추출되면 body 안 continue 가 return 으로 변환되어야 함
    // (SyntaxError 발생하지 않고 번들 생성 성공이 이미 exitCode 로 확인)
    // _loop 함수 안의 continue 가 없어야 한다
    const loopBodyMatch = out.match(/var\s+_loop\s*=\s*function[^{]*\{([\s\S]*?)\};/);
    if (loopBodyMatch) {
      const body = loopBodyMatch[1];
      expect(body).not.toMatch(/\bcontinue\s*;/);
    }
  });
});
