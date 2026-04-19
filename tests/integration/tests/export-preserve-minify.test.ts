/// #1633 회귀 가드:
/// `zts <file> --minify-identifiers` (단일 파일 transpile) 경로에서
/// export 심볼의 이름과 `export` 키워드가 보존되어야 한다.
/// 번들러 경로(scope hoisting)와 구분된다 — 번들러는 export 키워드를 생략해도 맞음.

import { describe, test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runZts } from "./helpers";

async function transpileMinify(src: string): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), "zts-1633-"));
  const file = join(dir, "t.ts");
  writeFileSync(file, src);
  try {
    const { stdout, exitCode, stderr } = await runZts([file, "--minify-identifiers"]);
    if (exitCode !== 0) throw new Error(`zts failed: ${stderr}`);
    return stdout;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("#1633: 단일 파일 --minify-identifiers export 보존", () => {
  test("export function 이름 + 키워드 보존", async () => {
    const out = await transpileMinify("export function myPublicApi(x) { return x*2; }");
    expect(out).toContain("export function myPublicApi");
  });

  test("export const / export let 이름 + 키워드 보존", async () => {
    const out = await transpileMinify(
      "export const THRESHOLD = 100; export let mutableExport = 0;",
    );
    expect(out).toContain("export const THRESHOLD");
    expect(out).toContain("export let mutableExport");
  });

  test("export default function named — 이름 + 키워드 보존", async () => {
    const out = await transpileMinify("export default function defaultFn(){ return 42; }");
    expect(out).toContain("export default function defaultFn");
  });

  test("export class 이름 + 키워드 보존", async () => {
    const out = await transpileMinify("export class MyExportedClass { method(){ return 'hi'; } }");
    expect(out).toContain("export class MyExportedClass");
  });

  test("export { local } — specifier 심볼이 mangle되지 않아 참조 정합", async () => {
    const out = await transpileMinify("function myLocal(){ return 1; } export { myLocal };");
    // local 선언도 export specifier도 원본 이름 유지
    expect(out).toContain("function myLocal");
    expect(out).toContain("export { myLocal }");
  });

  test("export { local as publicName } — rename specifier도 정합", async () => {
    const out = await transpileMinify(
      "const originalName = 42; export { originalName as publicName };",
    );
    expect(out).toContain("const originalName");
    expect(out).toContain("export { originalName as publicName }");
  });

  test("exported 심볼만 보존, 내부 심볼은 여전히 mangle", async () => {
    const out = await transpileMinify(
      "function helperLocal(){return 1;} export const THRESHOLD = helperLocal();",
    );
    // 내부 함수는 짧은 이름으로 mangle
    expect(out).not.toContain("function helperLocal");
    // export const 이름은 보존
    expect(out).toContain("export const THRESHOLD");
  });

  test("exported function 내부 nested는 여전히 mangle", async () => {
    const out = await transpileMinify(
      "export function api() { function internalHelper() { return 42; } return internalHelper(); }",
    );
    expect(out).toContain("export function api");
    expect(out).not.toContain("internalHelper");
  });
});
