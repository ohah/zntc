import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { init } from "../index";
import { loadConfig } from "./config-loader";

beforeAll(() => init());

describe("loadConfig", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-config-loader-"));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test(".ts: TS 문법 + export default 로드", async () => {
    const path = join(dir, "ts.config.ts");
    writeFileSync(
      path,
      `interface Cfg { format: string; entryPoints: string[] }
       const cfg: Cfg = { format: "esm", entryPoints: ["./src/index.ts"] };
       export default cfg;`,
    );
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "esm", entryPoints: ["./src/index.ts"] });
  });

  test(".mts: TS export default", async () => {
    const path = join(dir, "mts.config.mts");
    writeFileSync(path, `export default { format: "cjs" as const };`);
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "cjs" });
  });

  test(".cts: TS export default", async () => {
    const path = join(dir, "cts.config.cts");
    writeFileSync(path, `export default { minify: true };`);
    const config = await loadConfig(path);
    expect(config).toEqual({ minify: true });
  });

  test(".mjs: ESM export default", async () => {
    const path = join(dir, "mjs.config.mjs");
    writeFileSync(path, `export default { format: "esm" };`);
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "esm" });
  });

  test(".js: ESM export default (Bun 실행 환경)", async () => {
    const path = join(dir, "js.config.js");
    writeFileSync(path, `export default { format: "esm" };`);
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "esm" });
  });

  test(".cjs: CommonJS module.exports", async () => {
    const path = join(dir, "cjs.config.cjs");
    writeFileSync(path, `module.exports = { format: "cjs" };`);
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "cjs" });
  });

  test(".json: 그대로 파싱", async () => {
    const path = join(dir, "json.config.json");
    writeFileSync(path, `{"format":"esm","minify":true}`);
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "esm", minify: true });
  });

  test("defineConfig 헬퍼로 정의된 객체 로드", async () => {
    const path = join(dir, "define.config.ts");
    writeFileSync(
      path,
      `import { defineConfig } from "${resolveImportPath()}";
       export default defineConfig({ format: "esm", entryPoints: ["./a.ts"] });`,
    );
    const config = await loadConfig(path);
    expect(config).toEqual({ format: "esm", entryPoints: ["./a.ts"] });
  });

  test("default export 가 없으면 namespace 객체로 fallback", async () => {
    const path = join(dir, "named.config.mjs");
    writeFileSync(path, `export const format = "esm"; export const minify = false;`);
    const config = await loadConfig(path);
    expect(config.format).toBe("esm");
    expect(config.minify).toBe(false);
  });

  test("파일 부재 시 명확한 에러", async () => {
    const path = join(dir, "does-not-exist.config.ts");
    await expect(loadConfig(path)).rejects.toThrow(/config file not found/);
  });

  test("미지원 확장자 거부", async () => {
    const path = join(dir, "weird.config.toml");
    writeFileSync(path, `format = "esm"`);
    await expect(loadConfig(path)).rejects.toThrow(/unsupported config extension/);
  });

  test("TS 컴파일 실패 시 사용자에게 에러 노출", async () => {
    const path = join(dir, "broken.config.ts");
    writeFileSync(path, `export default { format: "esm" `); // 닫는 brace 없음
    await expect(loadConfig(path)).rejects.toThrow();
  });

  test("JSON 파싱 실패 시 친절한 에러", async () => {
    const path = join(dir, "broken.config.json");
    writeFileSync(path, `{ "format": "esm",,, }`);
    await expect(loadConfig(path)).rejects.toThrow(/failed to parse JSON config/);
  });

  test("non-object export 거부 (배열/숫자)", async () => {
    const path = join(dir, "array.config.mjs");
    writeFileSync(path, `export default [1, 2, 3];`);
    await expect(loadConfig(path)).rejects.toThrow(/must export an object/);
  });

  // watch 재로드 (mtime 기반 cache-bust) 는 #2107 (Phase 2-5) 에서 본격 처리.
  // .ts/.mts/.cts 경로는 매 호출마다 새 tmp 파일을 생성하므로 자연스럽게 캐시를 우회한다.
  test(".ts 재호출: 매번 fresh transpile (tmp 파일 random)", async () => {
    const path = join(dir, "rerun.config.ts");
    writeFileSync(path, `export default { format: "esm" as const };`);
    const first = await loadConfig(path);
    expect(first.format).toBe("esm");

    writeFileSync(path, `export default { format: "cjs" as const };`);
    const second = await loadConfig(path);
    expect(second.format).toBe("cjs");
  });
});

function resolveImportPath(): string {
  // 테스트에서 임시 디렉토리에 작성된 .ts config 가 @zts/core 의 defineConfig 를
  // import 하려면 절대 경로 또는 file:// URL 이 필요하다. 여기서는 packages/core/index.ts
  // 의 절대 경로를 반환한다.
  const here = new URL(import.meta.url);
  // src/config-loader.test.ts → ../index.ts
  const indexUrl = new URL("../index.ts", here);
  return indexUrl.href;
}
