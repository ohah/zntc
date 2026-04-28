/**
 * zts CLI flag ↔ `BuildOptions` ↔ WASM `BundleOptionsInput` schema sync 검증.
 *
 * #2112 의 schema sync 는 `BuildOptions` ↔ `KNOWN_CONFIG_KEYS` ↔ Zig DTO 만 검증했다.
 * 다음 두 갭이 남아 있어 silent 회귀 가능:
 *  1. CLI flag (`zts.mjs`) ↔ `BuildOptions` 매핑 — 새 BuildOptions 키 추가 후 CLI flag
 *     안 만든 채 release 시 사용자가 `--xxx` 가 없어 의문스러워함
 *  2. WASM (`packages/wasm/index.ts`) `BundleOptionsInput` ↔ `BuildOptions` — WASM 이
 *     의도적으로 좁은 부분집합이라 모든 키가 일치할 필요는 없지만 **WASM 키가
 *     BuildOptions 와 같은 이름이어야** silent 의미 차이 회피
 *
 * source of truth: `BuildOptions` = `BuildOptionsCommon ∪ { platform, target, browserslist }`,
 * 그리고 `packages/shared/index.ts` 의 `TranspileOptions` (transpile 단계 키 — CLI 가 일부
 * 노출). 두 union 이 CLI flag 가 매핑될 후보 키 풀.
 *
 * `cliOnlyFlags` / `buildOptionsOnlyKeys` allowlist 로 의도적 분리는 명시적으로 추적.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const CLI_PATH = join(__dirname, "zts.mjs");
const INDEX_PATH = join(__dirname, "..", "index.ts");
const SHARED_INDEX_PATH = join(__dirname, "..", "..", "shared", "index.ts");
const WASM_INDEX_PATH = join(__dirname, "..", "..", "wasm", "index.ts");

// ─── 정적 파싱 헬퍼 ──────────────────────────────────────────

/** zts.mjs 의 `parseArgs` 함수 본문에서 모든 flag 토큰 추출. namespace prefix (`--banner:js=`) 도 포함. */
function extractCliFlags(source: string): string[] {
  const startMarker = "function parseArgs(argv) {";
  const start = source.indexOf(startMarker);
  if (start < 0) throw new Error("parseArgs not found in zts.mjs");
  let depth = 0;
  let i = start + startMarker.length - 1;
  let bodyEnd = -1;
  for (; i < source.length; i += 1) {
    const c = source[i];
    if (c === "{") depth += 1;
    else if (c === "}") {
      depth -= 1;
      if (depth === 0) {
        bodyEnd = i;
        break;
      }
    }
  }
  if (bodyEnd < 0) throw new Error("parseArgs body not balanced");
  const body = source.slice(start, bodyEnd + 1);

  const flags = new Set<string>();
  for (const m of body.matchAll(/arg === "(--[a-zA-Z][a-zA-Z0-9-]*)"/g)) flags.add(m[1]);
  for (const m of body.matchAll(/arg\.startsWith\("(--[a-zA-Z][a-zA-Z0-9-]*)="\)/g)) {
    flags.add(m[1] + "=");
  }
  for (const m of body.matchAll(/arg\.startsWith\("(--[a-zA-Z][a-zA-Z0-9-]*):"\)/g)) {
    flags.add(m[1] + ":*");
  }
  for (const m of body.matchAll(
    /arg\.startsWith\("(--[a-zA-Z][a-zA-Z0-9-]*:[a-zA-Z0-9.-]+)="\)/g,
  )) {
    flags.add(m[1] + "=");
  }
  return [...flags].sort();
}

/** 인터페이스 본문에서 필드명 추출 (`name?:` / `name:`). */
function extractInterfaceKeys(source: string, interfaceName: string): string[] {
  const re = new RegExp(`(?:export\\s+)?interface\\s+${interfaceName}\\s*\\{`);
  const match = re.exec(source);
  if (!match) throw new Error(`${interfaceName} not found`);
  const bodyStart = match.index + match[0].length;
  let depth = 1;
  let i = bodyStart;
  while (i < source.length && depth > 0) {
    const c = source[i];
    if (c === "{") depth += 1;
    else if (c === "}") depth -= 1;
    i += 1;
  }
  const body = source.slice(bodyStart, i - 1);
  const fields: string[] = [];
  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("//") || line.startsWith("*") || line.startsWith("/*")) continue;
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*\??\s*:/);
    if (m) fields.push(m[1]);
  }
  return fields;
}

/** kebab-case → camelCase. `--global-name` → `globalName`. */
function kebabToCamel(s: string): string {
  return s.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());
}

/** flag 토큰에서 BuildOptions/TranspileOptions 키 후보 도출. */
function flagToCandidateKey(flag: string): string {
  let s = flag.replace(/^--/, "").replace(/=$/, "").replace(/:\*$/, "");
  if (s.includes(":")) {
    const [head, tail] = s.split(":");
    const cleanedTail = tail.replace(/^\./, "");
    return kebabToCamel(head) + cleanedTail.charAt(0).toUpperCase() + cleanedTail.slice(1);
  }
  return kebabToCamel(s);
}

// ─── 테스트 ─────────────────────────────────────────────────

describe("CLI flag ↔ BuildOptions / TranspileOptions schema sync", () => {
  const cliSource = readFileSync(CLI_PATH, "utf8");
  const indexSource = readFileSync(INDEX_PATH, "utf8");
  const sharedSource = readFileSync(SHARED_INDEX_PATH, "utf8");

  const cliFlags = extractCliFlags(cliSource);
  // BuildOptions = BuildOptionsCommon ∪ { platform, target, browserslist } (union variants).
  const buildOptionsKeys = new Set([
    ...extractInterfaceKeys(indexSource, "BuildOptionsCommon"),
    "platform",
    "target",
    "browserslist",
  ]);
  const transpileOptionsKeys = new Set(extractInterfaceKeys(sharedSource, "TranspileOptions"));
  // CLI flag 가 매핑될 후보 키 풀 — BuildOptions + TranspileOptions.
  const knownKeys = new Set([...buildOptionsKeys, ...transpileOptionsKeys]);

  test("flag 추출 sanity — 최소 30개 + 알려진 flag 포함", () => {
    expect(cliFlags.length).toBeGreaterThanOrEqual(30);
    expect(cliFlags).toContain("--bundle");
    expect(cliFlags).toContain("--outdir");
    expect(cliFlags).toContain("--minify");
    expect(cliFlags).toContain("--global-name=");
    expect(cliFlags).toContain("--define:*"); // namespace prefix
  });

  test("BuildOptions / TranspileOptions 키 추출 sanity", () => {
    expect(buildOptionsKeys.size).toBeGreaterThanOrEqual(70);
    expect(transpileOptionsKeys.size).toBeGreaterThanOrEqual(20);
    expect(buildOptionsKeys.has("entryPoints")).toBe(true);
    expect(buildOptionsKeys.has("platform")).toBe(true); // union 변형으로 추가
    expect(transpileOptionsKeys.has("quotes")).toBe(true);
    expect(transpileOptionsKeys.has("asciiOnly")).toBe(true);
  });

  // CLI 에만 있는 flag — config-loader / dev-server / CLI flow 만의 옵션.
  // 새 CLI-only flag 추가 시 여기 등록.
  const cliOnlyFlags: ReadonlySet<string> = new Set([
    // 빌드 모드 / 명령
    "--bundle",
    "--watch",
    "--watch-json",
    "--watch-delay=",
    "--serve",
    "--open",
    "--clean",
    // 설정 / 환경
    "--config",
    "--config=",
    "--mode",
    "--mode=",
    "--workspace",
    "--workspace=",
    "--workspace-config",
    "--workspace-config=",
    "--env-dir",
    "--env-dir=",
    "--env-prefix",
    "--env-prefix=",
    "--plugin",
    "--log-level=",
    // dev server
    "--port",
    "--port=",
    "--host",
    "--host=",
    "--certfile",
    "--keyfile",
    "--proxy",
    // tsconfig — CLI 용 alias (`--project`, `--tsconfig-path` 둘 다 BuildOptions 의 `tsconfigPath` 와 매핑)
    "--project",
    // RN — CLI 만 노출
    "--rn-platform",
    "--rn-platform=",
    // jsx-dev — CLI shorthand for jsx="automatic-dev"
    "--jsx-dev",
    // drop — CLI 의 `--drop=console/debugger` 는 transpile 의 dropConsole/dropDebugger 와 매핑
    // (1:N 이라 단순 키 매칭으론 추적 어려움)
    "--drop=",
    // charset — CLI 는 `--charset=utf8/ascii` 식 enum, BuildOptions/TranspileOptions 는
    // `charsetUtf8: boolean` (1:N 매핑). zts.mjs 에서 enum→boolean 변환.
    "--charset=",
    // banner/footer — `--banner=`/`--footer=` 가 정식 (BuildOptions 와 1:1).
    // `--banner:js=`/`--footer:js=` 는 esbuild 호환 silent alias — 동일 키로 매핑.
    "--banner:js=",
    "--footer:js=",
    // out-extension — esbuild 식 namespace (`--out-extension:.js=`). BuildOptions 의
    // `outExtension: string` (단일) 와 1:N. zts.mjs 가 `.js` 만 받아 단일 string 으로 변환.
    "--out-extension:.js=",
  ]);

  // BuildOptions/TranspileOptions 에 있고 CLI 에 없는 키 (의도적). 함수형/고급 옵션.
  const buildOptionsOnlyKeys: ReadonlySet<string> = new Set([
    // 함수형 (CLI 표현 불가)
    "manualChunks",
    "plugins",
    // entry — positional argument (flag 아님)
    "entryPoints",
    "filename", // transpile 의 filename — stdin 모드일 때 의미, CLI 가 자동 결정
    // Zig/NAPI 내부 또는 자동 결정 (사용자가 거의 안 만짐)
    "allowOverwrite",
    "assetRegistry",
    "blockList",
    "collectModuleCodes",
    "configurableExports",
    "conditions",
    "devMode",
    "dropConsole", // --drop=console 로 cover
    "dropDebugger", // --drop=debugger 로 cover
    "dropLabels",
    "emitDiskSourcemap",
    "entryErrorGuard",
    "experimentalCodeCache",
    "fallback",
    "globalIdentifiers",
    "ignoreAnnotations",
    "inlineDynamicImports",
    "jsxSideEffects",
    "lineLimit",
    "nodePaths",
    "onReady",
    "onRebuild",
    "outExtension", // namespace 객체 — `--out-extension:.js=` 가 일부 cover
    "outbase",
    "packagesExternal",
    "polyfills",
    "preserveSymlinks", // CLI 에 있긴 한데 boolean 형이라 별도 — TODO 향후 통합
    "profile",
    "profileFormat",
    "profileLevel",
    "pure",
    "reactRefresh",
    "rootDir",
    "runBeforeMain",
    "scopeHoist",
    "silentConsoleErrorPatterns",
    "stopAfter", // transpile 단독 — CLI 미노출 (디버그 옵션)
    "strictExecutionOrder",
    "treeShaking",
    "tsconfigRaw",
    "verbatimModuleSyntax",
    "watch", // BuildOptions 의 watch 와 CLI --watch 는 의미 다름
    "watchExclude",
    "watchFolders",
    "watchInclude",
    "workletPluginVersion",
    "workletTransform",
    "write",
    // CLI 에 boolean 형으로 노출되어 있지만 키가 미묘하게 다름 — `--ascii-only` ↔ TranspileOptions `asciiOnly` (OK), `--charset=` ↔ BuildOptions/TranspileOptions 는 charsetUtf8 boolean 만 (1:N 매핑)
    "charsetUtf8",
    "analyze", // CLI 가 boolean flag, BuildOptions 는 boolean — 매칭되지만 alias 처리 누락 가능
    // ─── follow-up: CLI flag 추가 권장 (별도 PR) ──────────────────────
    // 이 키들은 BuildOptions/TranspileOptions 에 정의되어 있지만 CLI 가 아직 안 노출.
    // 사용자가 CLI 에서 직접 지정 못 해 tsconfig/config 경유 필요. CLI flag 추가 가치 있음.
    "browserslist", // `--browserslist=">0.5%"` — target 보다 우선
    "emitDecoratorMetadata", // `--emit-decorator-metadata` (현재는 `--experimental-decorators` 만)
    "jsxInJs", // `--jsx-in-js` — `.js` 파일에서도 JSX 파싱
    "target", // `--target=es2020` — ES 다운레벨 (현재는 tsconfig.target 만)
    "verbatimModuleSyntax", // `--verbatim-module-syntax`
  ]);

  test("CLI flag 가 BuildOptions / TranspileOptions 키와 매칭되거나 cliOnlyFlags 에 등록", () => {
    const unmapped: { flag: string; candidate: string }[] = [];
    for (const flag of cliFlags) {
      if (cliOnlyFlags.has(flag)) continue;
      const candidate = flagToCandidateKey(flag);
      if (knownKeys.has(candidate)) continue;
      unmapped.push({ flag, candidate });
    }
    if (unmapped.length > 0) {
      const list = unmapped.map((x) => `  ${x.flag} → ${x.candidate}`).join("\n");
      throw new Error(
        `[schema drift] CLI flag 가 BuildOptions/TranspileOptions 키와 매칭 안 됨:\n${list}\n` +
          `BuildOptions 에 키 추가 OR cliOnlyFlags allowlist 에 등록.`,
      );
    }
  });

  test("BuildOptions / TranspileOptions 키가 CLI flag 로 노출되거나 buildOptionsOnlyKeys 에 등록", () => {
    const cliExposedKeys = new Set<string>();
    for (const flag of cliFlags) {
      if (cliOnlyFlags.has(flag)) continue;
      const candidate = flagToCandidateKey(flag);
      if (knownKeys.has(candidate)) cliExposedKeys.add(candidate);
    }

    const missing: string[] = [];
    for (const key of knownKeys) {
      if (cliExposedKeys.has(key)) continue;
      if (buildOptionsOnlyKeys.has(key)) continue;
      missing.push(key);
    }
    if (missing.length > 0) {
      throw new Error(
        `[schema drift] BuildOptions/TranspileOptions 키가 CLI flag 로 노출 안 됨: ${missing.sort().join(", ")}\n` +
          `CLI flag 추가 (zts.mjs parseArgs) OR buildOptionsOnlyKeys allowlist 에 등록.`,
      );
    }
  });

  test("flag 명명 규칙 — 모든 CLI flag 는 lowercase + kebab + `:` namespace 만", () => {
    const bad: string[] = [];
    for (const flag of cliFlags) {
      const stripped = flag.replace(/^--/, "").replace(/[:=*]/g, "").replace(/\./g, "");
      if (!/^[a-z][a-z0-9-]*$/.test(stripped)) bad.push(flag);
    }
    expect(bad).toEqual([]);
  });
});

describe("WASM BundleOptionsInput ↔ BuildOptions / TranspileOptions schema sync", () => {
  const indexSource = readFileSync(INDEX_PATH, "utf8");
  const sharedSource = readFileSync(SHARED_INDEX_PATH, "utf8");
  const wasmSource = readFileSync(WASM_INDEX_PATH, "utf8");

  const buildOptionsKeys = new Set([
    ...extractInterfaceKeys(indexSource, "BuildOptionsCommon"),
    "platform",
    "target",
    "browserslist",
  ]);
  const transpileOptionsKeys = new Set(extractInterfaceKeys(sharedSource, "TranspileOptions"));
  const knownKeys = new Set([...buildOptionsKeys, ...transpileOptionsKeys]);
  const wasmKeys = extractInterfaceKeys(wasmSource, "BundleOptionsInput");

  test("WASM 키 추출 sanity", () => {
    expect(wasmKeys.length).toBeGreaterThanOrEqual(15);
    expect(wasmKeys).toContain("format");
    expect(wasmKeys).toContain("minify");
    expect(wasmKeys).toContain("jsxFactory");
  });

  // WASM 만의 키 — WASM 환경에서 의미 있는 옵션 (NAPI/CLI 와 무관).
  const wasmOnlyKeys: ReadonlySet<string> = new Set([
    "codeSplitting", // WASM bundler 의 별도 toggle (NAPI 는 splitting 사용 — naming 통일 follow-up)
    "unsupported", // WASM 이 직접 bitmask 받음 (target → bits 변환 회피용 escape hatch)
  ]);

  test("WASM BundleOptionsInput 의 모든 키가 BuildOptions/TranspileOptions 와 같은 이름으로 존재", () => {
    const drift: string[] = [];
    for (const key of wasmKeys) {
      if (knownKeys.has(key)) continue;
      if (wasmOnlyKeys.has(key)) continue;
      drift.push(key);
    }
    if (drift.length > 0) {
      throw new Error(
        `[schema drift] WASM BundleOptionsInput 키가 BuildOptions/TranspileOptions 에 없음: ${drift.join(", ")}\n` +
          `WASM 명명을 통일 OR wasmOnlyKeys allowlist 에 등록.`,
      );
    }
  });
});
