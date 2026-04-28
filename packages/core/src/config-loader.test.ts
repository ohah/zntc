import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { init } from "../index";
import {
  CONFIG_EXT_PRIORITY,
  findConfigPath,
  findModeConfigPath,
  loadConfig,
  mergeUserConfigs,
} from "./config-loader";

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
    // packages/core/index.ts 를 file:// URL 로 참조 — 임시 디렉토리에 작성된
    // .ts config 가 ZTS transpile 후 동적 import 될 때 절대 경로로 해석.
    const indexUrl = new URL("../index.ts", import.meta.url).href;
    writeFileSync(
      path,
      `import { defineConfig } from "${indexUrl}";
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

describe("findConfigPath", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-find-config-"));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  function reset() {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir);
  }

  test("config 부재 시 null", () => {
    reset();
    expect(findConfigPath(dir)).toBeNull();
  });

  test(".ts 단독", () => {
    reset();
    writeFileSync(join(dir, "zts.config.ts"), `export default {};`);
    expect(findConfigPath(dir)).toBe(join(dir, "zts.config.ts"));
  });

  test(".json 단독", () => {
    reset();
    writeFileSync(join(dir, "zts.config.json"), `{}`);
    expect(findConfigPath(dir)).toBe(join(dir, "zts.config.json"));
  });

  test("우선순위: .ts > .mts > .cts > .mjs > .js > .cjs > .json", () => {
    // CONFIG_EXT_PRIORITY 가 [".ts", ".mts", ".cts", ".mjs", ".js", ".cjs", ".json"] 임을 검증.
    reset();
    // 모든 확장자 동시 존재 → .ts 선택
    for (const ext of CONFIG_EXT_PRIORITY) {
      writeFileSync(join(dir, `zts.config${ext}`), ext === ".json" ? "{}" : `export default {};`);
    }
    expect(findConfigPath(dir)).toBe(join(dir, "zts.config.ts"));
  });

  test("점진적 fallback: .ts 만 제거하면 .mts", () => {
    reset();
    writeFileSync(join(dir, "zts.config.mts"), `export default {};`);
    writeFileSync(join(dir, "zts.config.json"), `{}`);
    expect(findConfigPath(dir)).toBe(join(dir, "zts.config.mts"));
  });

  test("점진적 fallback: .mjs 단독이면 .mjs", () => {
    reset();
    writeFileSync(join(dir, "zts.config.mjs"), `export default {};`);
    expect(findConfigPath(dir)).toBe(join(dir, "zts.config.mjs"));
  });

  test("점진적 fallback: .cjs 단독이면 .cjs", () => {
    reset();
    writeFileSync(join(dir, "zts.config.cjs"), `module.exports = {};`);
    expect(findConfigPath(dir)).toBe(join(dir, "zts.config.cjs"));
  });

  test("findConfigPath + loadConfig 통합", async () => {
    reset();
    writeFileSync(join(dir, "zts.config.ts"), `export default { format: "esm" as const };`);
    const path = findConfigPath(dir);
    expect(path).toBe(join(dir, "zts.config.ts"));
    const config = await loadConfig(path!);
    expect(config.format).toBe("esm");
  });

  test("zts.config 가 아닌 다른 이름은 무시", () => {
    reset();
    writeFileSync(join(dir, "zts.ts"), `export default {};`);
    writeFileSync(join(dir, "config.ts"), `export default {};`);
    writeFileSync(join(dir, "zts-config.ts"), `export default {};`);
    expect(findConfigPath(dir)).toBeNull();
  });
});

// ─── 함수형 config (#2103 / Phase 2-1) ───

describe("loadConfig: 함수형 config", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-fn-config-"));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("함수형 config: env 인자로 호출되어 객체 반환", async () => {
    const path = join(dir, "fn.config.ts");
    writeFileSync(
      path,
      `export default ({ command, mode }: { command: string; mode: string }) => ({
         format: command === "bundle" ? "esm" : "cjs",
         minify: mode === "production",
       });`,
    );
    const config = await loadConfig(path, {
      command: "bundle",
      mode: "production",
      env: {},
    });
    expect(config).toEqual({ format: "esm", minify: true });
  });

  test("함수형 config: serve mode 분기", async () => {
    const path = join(dir, "fn-serve.config.ts");
    writeFileSync(
      path,
      `export default ({ command }: { command: string }) => ({
         minify: command === "bundle",
       });`,
    );
    const buildResult = await loadConfig(path, {
      command: "bundle",
      mode: "production",
      env: {},
    });
    expect(buildResult.minify).toBe(true);

    const serveResult = await loadConfig(path, {
      command: "serve",
      mode: "development",
      env: {},
    });
    expect(serveResult.minify).toBe(false);
  });

  test("함수형 config: env 인자 없이 호출 시 production bundle 기본값", async () => {
    const path = join(dir, "fn-default.config.ts");
    writeFileSync(
      path,
      `export default ({ command, mode }: { command: string; mode: string }) => ({
         banner: "/* " + command + ":" + mode + " */",
       });`,
    );
    const config = await loadConfig(path);
    expect(config.banner).toBe("/* bundle:production */");
  });

  test("함수형 config: async 함수도 지원", async () => {
    const path = join(dir, "fn-async.config.ts");
    writeFileSync(
      path,
      `export default async ({ command }: { command: string }) => {
         return { format: command === "bundle" ? "esm" as const : "cjs" as const };
       };`,
    );
    const config = await loadConfig(path, {
      command: "bundle",
      mode: "production",
      env: {},
    });
    expect(config.format).toBe("esm");
  });

  test("함수형 config: object 반환 안 하면 throw", async () => {
    const path = join(dir, "fn-bad.config.ts");
    writeFileSync(path, `export default () => "not an object";`);
    await expect(loadConfig(path)).rejects.toThrow(/functional config must return an object/);
  });

  test("객체 형태 config 도 변경 없이 동작 (regression)", async () => {
    const path = join(dir, "obj.config.ts");
    writeFileSync(path, `export default { format: "esm" as const };`);
    const config = await loadConfig(path, {
      command: "bundle",
      mode: "production",
      env: {},
    });
    expect(config).toEqual({ format: "esm" });
  });
});

// ─── mode-specific config (#2110 / Phase 3-3) ────────────────────────────────

describe("findModeConfigPath", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-find-mode-cfg-"));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  function reset() {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir);
  }

  test("mode 빈 문자열이면 null", () => {
    reset();
    writeFileSync(join(dir, "zts.config.ts"), `export default {};`);
    expect(findModeConfigPath(dir, "")).toBeNull();
  });

  test("mode-specific 파일 부재 시 null", () => {
    reset();
    writeFileSync(join(dir, "zts.config.ts"), `export default {};`);
    expect(findModeConfigPath(dir, "production")).toBeNull();
  });

  test(".ts > .json 우선순위", () => {
    reset();
    writeFileSync(join(dir, "zts.config.production.ts"), `export default {};`);
    writeFileSync(join(dir, "zts.config.production.json"), `{}`);
    expect(findModeConfigPath(dir, "production")).toBe(join(dir, "zts.config.production.ts"));
  });

  test("mode 별 분기: production / development", () => {
    reset();
    writeFileSync(join(dir, "zts.config.production.ts"), `export default {};`);
    writeFileSync(join(dir, "zts.config.development.ts"), `export default {};`);
    expect(findModeConfigPath(dir, "production")).toBe(join(dir, "zts.config.production.ts"));
    expect(findModeConfigPath(dir, "development")).toBe(join(dir, "zts.config.development.ts"));
    expect(findModeConfigPath(dir, "staging")).toBeNull();
  });

  test("`.json` 도 자동 탐색 대상", () => {
    reset();
    writeFileSync(join(dir, "zts.config.production.json"), `{}`);
    expect(findModeConfigPath(dir, "production")).toBe(join(dir, "zts.config.production.json"));
  });
});

describe("mergeUserConfigs", () => {
  test("scalar: mode 가 base 를 override", () => {
    const merged = mergeUserConfigs({ format: "esm", target: "es2020" }, { format: "iife" });
    expect(merged).toEqual({ format: "iife", target: "es2020" });
  });

  test("undefined 인 mode 키는 무시 (base 보존)", () => {
    const merged = mergeUserConfigs({ format: "esm" }, { format: undefined });
    expect(merged).toEqual({ format: "esm" });
  });

  test("객체 (define): shallow merge — base 키 + mode 키, mode 우선", () => {
    const merged = mergeUserConfigs(
      { define: { __VER__: '"v1"', __BUILD__: '"prod"' } },
      { define: { __BUILD__: '"override"', __NEW__: '"x"' } },
    );
    expect(merged.define).toEqual({
      __VER__: '"v1"',
      __BUILD__: '"override"',
      __NEW__: '"x"',
    });
  });

  test("객체 (alias): shallow merge", () => {
    const merged = mergeUserConfigs(
      { alias: { "@a": "/path/a", "@b": "/path/b" } },
      { alias: { "@b": "/override/b" } },
    );
    expect(merged.alias).toEqual({
      "@a": "/path/a",
      "@b": "/override/b",
    });
  });

  test("배열 (entryPoints): mode 가 base 를 완전 대체 (concat 안 함)", () => {
    const merged = mergeUserConfigs({ entryPoints: ["./base.ts"] }, { entryPoints: ["./mode.ts"] });
    expect(merged.entryPoints).toEqual(["./mode.ts"]);
  });

  test("배열 (external): mode 가 base 대체", () => {
    const merged = mergeUserConfigs({ external: ["react"] }, { external: ["react", "react-dom"] });
    expect(merged.external).toEqual(["react", "react-dom"]);
  });

  test("plugins: 예외적으로 concat (Vite 호환)", () => {
    const basePlugin = { name: "base-p", setup() {} };
    const modePlugin = { name: "mode-p", setup() {} };
    const merged = mergeUserConfigs({ plugins: [basePlugin] }, { plugins: [modePlugin] });
    expect(merged.plugins).toEqual([basePlugin, modePlugin]);
  });

  test("base 에 없는 mode 전용 키 추가", () => {
    const merged = mergeUserConfigs({ format: "esm" }, { minify: true });
    expect(merged).toEqual({ format: "esm", minify: true });
  });

  test("mode 에 없는 base 전용 키 보존", () => {
    const merged = mergeUserConfigs({ format: "esm", target: "es2020" }, { minify: true });
    expect(merged).toEqual({ format: "esm", target: "es2020", minify: true });
  });

  test("배열 vs 객체 mismatch — mode 가 type 무관 override", () => {
    // 비정상 입력이지만 panic 안 하고 mode 값으로 override.
    const merged = mergeUserConfigs(
      { external: ["react"] } as { external: string[] },
      { external: undefined } as { external: undefined },
    );
    expect(merged.external).toEqual(["react"]); // undefined 는 skip
  });
});

// ─── extends 상속 (#2108 / Phase 3-1) ──────────────────────────────────────

describe("loadConfig: extends 상속", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-extends-"));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  function reset() {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir);
  }

  test("단일 string extends: base 머지 + override", async () => {
    reset();
    writeFileSync(
      join(dir, "base.config.ts"),
      `export default { format: "esm" as const, banner: "/* base */" };`,
    );
    writeFileSync(
      join(dir, "main.config.ts"),
      `export default { extends: "./base.config.ts", banner: "/* override */" };`,
    );
    const config = await loadConfig(join(dir, "main.config.ts"));
    expect(config.format).toBe("esm");
    expect(config.banner).toBe("/* override */");
    expect((config as { extends?: unknown }).extends).toBeUndefined();
  });

  test("배열 extends: 왼쪽부터 적용 (오른쪽이 더 우선)", async () => {
    reset();
    writeFileSync(join(dir, "a.json"), JSON.stringify({ banner: "/* a */", target: "es2020" }));
    writeFileSync(join(dir, "b.json"), JSON.stringify({ banner: "/* b */" }));
    writeFileSync(
      join(dir, "main.json"),
      JSON.stringify({ extends: ["./a.json", "./b.json"], minify: true }),
    );
    const config = await loadConfig(join(dir, "main.json"));
    // a → b → main 순서로 머지. b 가 a.banner override.
    expect(config.banner).toBe("/* b */");
    expect(config.target).toBe("es2020");
    expect(config.minify).toBe(true);
  });

  test("3단계 chain: A extends B extends C", async () => {
    reset();
    writeFileSync(join(dir, "c.json"), JSON.stringify({ format: "esm", banner: "/* c */" }));
    writeFileSync(join(dir, "b.json"), JSON.stringify({ extends: "./c.json", banner: "/* b */" }));
    writeFileSync(join(dir, "a.json"), JSON.stringify({ extends: "./b.json", minify: true }));
    const config = await loadConfig(join(dir, "a.json"));
    expect(config.format).toBe("esm");
    expect(config.banner).toBe("/* b */"); // c 의 banner 를 b 가 override
    expect(config.minify).toBe(true);
  });

  test("define 객체 머지: extends + 현재 키 단위 합쳐짐", async () => {
    reset();
    writeFileSync(
      join(dir, "base.json"),
      JSON.stringify({ define: { __VER__: '"v1"', __ENV__: '"prod"' } }),
    );
    writeFileSync(
      join(dir, "main.json"),
      JSON.stringify({
        extends: "./base.json",
        define: { __ENV__: '"override"', __NEW__: '"x"' },
      }),
    );
    const config = await loadConfig(join(dir, "main.json"));
    expect(config.define).toEqual({
      __VER__: '"v1"',
      __ENV__: '"override"',
      __NEW__: '"x"',
    });
  });

  test("순환 참조 감지: A extends B extends A → throw", async () => {
    reset();
    writeFileSync(join(dir, "a.json"), JSON.stringify({ extends: "./b.json", banner: "/* a */" }));
    writeFileSync(join(dir, "b.json"), JSON.stringify({ extends: "./a.json", banner: "/* b */" }));
    await expect(loadConfig(join(dir, "a.json"))).rejects.toThrow(/circular extends detected/);
  });

  test("self extends: A extends A → throw", async () => {
    reset();
    writeFileSync(join(dir, "self.json"), JSON.stringify({ extends: "./self.json" }));
    await expect(loadConfig(join(dir, "self.json"))).rejects.toThrow(/circular extends/);
  });

  test("extends 경로 부재 시 명확한 에러", async () => {
    reset();
    writeFileSync(join(dir, "main.json"), JSON.stringify({ extends: "./does-not-exist.json" }));
    await expect(loadConfig(join(dir, "main.json"))).rejects.toThrow(/config file not found/);
  });

  test("절대 경로 extends 도 동작", async () => {
    reset();
    writeFileSync(join(dir, "base.json"), JSON.stringify({ banner: "/* abs-base */" }));
    writeFileSync(join(dir, "main.json"), JSON.stringify({ extends: join(dir, "base.json") }));
    const config = await loadConfig(join(dir, "main.json"));
    expect(config.banner).toBe("/* abs-base */");
  });

  test("extends 가 mode-merge 와 함께 동작 (별도 단위 검증)", async () => {
    reset();
    writeFileSync(join(dir, "base.json"), JSON.stringify({ format: "esm", banner: "/* base */" }));
    writeFileSync(join(dir, "main.json"), JSON.stringify({ extends: "./base.json", minify: true }));
    const config = await loadConfig(join(dir, "main.json"));
    expect(config.format).toBe("esm"); // extends 에서 상속
    expect(config.banner).toBe("/* base */");
    expect(config.minify).toBe(true); // 현재 config
  });

  test("extends 가 .ts 파일도 OK", async () => {
    reset();
    writeFileSync(
      join(dir, "base.config.ts"),
      `export default { format: "esm" as const, banner: "/* TS base */" };`,
    );
    writeFileSync(
      join(dir, "main.config.json"),
      JSON.stringify({ extends: "./base.config.ts", minify: true }),
    );
    const config = await loadConfig(join(dir, "main.config.json"));
    expect(config.format).toBe("esm");
    expect(config.banner).toBe("/* TS base */");
    expect(config.minify).toBe(true);
  });
});
