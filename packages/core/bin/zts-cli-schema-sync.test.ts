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

import { FLAG_REGISTRY, flagsOf } from "./cli-flags.mjs";
import { NAPI_INTERNAL_ONLY_KEYS } from "../src/schema-allowlists.ts";

const CLI_PATH = join(__dirname, "zts.mjs");
const INDEX_PATH = join(__dirname, "..", "index.ts");
const SHARED_INDEX_PATH = join(__dirname, "..", "..", "shared", "index.ts");
const WASM_INDEX_PATH = join(__dirname, "..", "..", "wasm", "index.ts");

// ─── 정적 파싱 헬퍼 ──────────────────────────────────────────

/**
 * `bodyStart` (여는 `{` 다음 위치) 에서 시작해 brace-balanced 본문을 잘라낸다.
 * 닫는 `}` 직전까지의 슬라이스를 반환. balance 안 맞으면 throw.
 */
function extractBracedBody(source: string, bodyStart: number, errorContext: string): string {
  let depth = 1;
  let i = bodyStart;
  while (i < source.length && depth > 0) {
    const c = source[i];
    if (c === "{") depth += 1;
    else if (c === "}") depth -= 1;
    i += 1;
  }
  if (depth !== 0) throw new Error(`${errorContext} not balanced`);
  return source.slice(bodyStart, i - 1);
}

/** body 의 한 줄 단위 키 패턴 추출. 주석/빈 줄 skip. matcher 가 [name] 캡처 그룹 1을 반환. */
function extractKeysByLine(body: string, matcher: RegExp): string[] {
  const keys: string[] = [];
  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("//") || line.startsWith("*") || line.startsWith("/*")) continue;
    const m = line.match(matcher);
    if (m) keys.push(m[1]);
  }
  return keys;
}

/**
 * zts.mjs 의 `parseArgs` 함수 안 `opts = { ... }` 객체 리터럴에서 키 추출.
 * `mergeConfigIntoOpts` 의 `opts[key] === undefined` 머지 조건이 정상 작동하려면
 * SCALAR/BOOL/ARRAY_KEYS 의 모든 키가 default 객체에 등록되어 있어야 한다.
 */
function extractOptsDefaultKeys(source: string): string[] {
  const startMarker = "const opts = {";
  const start = source.indexOf(startMarker, source.indexOf("function parseArgs(argv)"));
  if (start < 0) throw new Error("opts default object not found in parseArgs");
  const body = extractBracedBody(source, start + startMarker.length, "opts default");
  return extractKeysByLine(body, /^([a-zA-Z_][a-zA-Z0-9_]*)\s*:/);
}

/** zts.mjs 의 `mergeConfigIntoOpts` 안 SCALAR_KEYS / BOOL_KEYS / ARRAY_KEYS 리스트의 키 집합 추출. */
function extractMergeKeyLists(source: string): {
  scalar: string[];
  bool: string[];
  array: string[];
} {
  const extractList = (label: string): string[] => {
    const idx = source.indexOf(`const ${label} = [`);
    if (idx < 0) throw new Error(`${label} not found`);
    const closeIdx = source.indexOf("];", idx);
    const body = source.slice(idx, closeIdx);
    return [...body.matchAll(/"([a-zA-Z_][a-zA-Z0-9_]*)"/g)].map((m) => m[1]);
  };
  return {
    scalar: extractList("SCALAR_KEYS"),
    bool: extractList("BOOL_KEYS"),
    array: extractList("ARRAY_KEYS"),
  };
}

/**
 * 모든 CLI flag 토큰 추출.
 *
 * registry-driven flag 는 import 한 `FLAG_REGISTRY` 의 spec 들을 직접 순회 (formatter 의
 * multi-line reformat 으로 인한 정적 파서 회귀 회피). legacy if-chain (특수 형식 — `--serve`,
 * `--host`, `--proxy`) 은 zts.mjs source 에서 정규식 추출.
 */
function extractCliFlags(source: string): string[] {
  const flags = new Set<string>();

  // ─── (1) FLAG_REGISTRY (직접 import) ───────────────────────────────────────
  for (const spec of FLAG_REGISTRY as readonly any[]) {
    const formsDefault = ["equal", "pair"];
    const forms: string[] =
      spec.forms ??
      (spec.kind === "string" || spec.kind === "int" || spec.kind === "array" || spec.kind === "csv"
        ? formsDefault
        : []);
    const allFlags = flagsOf(spec) as string[];

    for (const f of allFlags) {
      switch (spec.kind) {
        case "bool":
          flags.add(f);
          break;
        case "string-default":
          flags.add(f);
          if (f.length > 2) flags.add(f + "=");
          break;
        case "ns-array":
        case "key-value":
          flags.add(f + ":*");
          break;
        case "ns-string":
        case "enum-bool":
        case "string-bool":
          flags.add(f + "=");
          break;
        default:
          // string / int / csv / array — single-letter short alias 는 equal-form 미지원.
          if (forms.includes("equal") && f.length > 2) flags.add(f + "=");
          if (forms.includes("pair")) flags.add(f);
      }
    }
  }

  // ─── (2) parseArgs 본문 안의 legacy if-chain (특수 형식 — serve/host/proxy) ──
  const startMarker = "function parseArgs(argv) {";
  const start = source.indexOf(startMarker);
  if (start < 0) throw new Error("parseArgs not found in zts.mjs");
  const body = extractBracedBody(source, start + startMarker.length, "parseArgs body");

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
  const body = extractBracedBody(source, match.index + match[0].length, interfaceName);
  return extractKeysByLine(body, /^([a-zA-Z_][a-zA-Z0-9_]*)\s*\??\s*:/);
}

/**
 * 인터페이스 본문에서 `name → coarse-type` 매핑 추출. 정확한 타입이 아니라 silent type drift
 * 감지용 (`outdir: string` 이 `string[]` 으로 바뀌면 잡힘). 분류:
 *  - `boolean` → "boolean"
 *  - `Array<...>` / `Foo[]` / `(...)[]` → "array"
 *  - `Record<...>` / `{ ... }` → "object"
 *  - `(...) => ...` → "function"
 *  - 그 외 (string, "foo" | "bar", number 등) → "string"
 */
function extractTypeMap(source: string, interfaceName: string): Map<string, string> {
  const re = new RegExp(`(?:export\\s+)?interface\\s+${interfaceName}\\s*\\{`);
  const match = re.exec(source);
  if (!match) throw new Error(`${interfaceName} not found`);
  const body = extractBracedBody(source, match.index + match[0].length, interfaceName);
  const out = new Map<string, string>();
  // 한 줄 단위 파싱 — 다중 줄 type 은 첫 줄만 보고 coarse 분류 (대부분 충분).
  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("//") || line.startsWith("*") || line.startsWith("/*")) continue;
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*\??\s*:\s*(.+?);?\s*$/);
    if (!m) continue;
    const name = m[1];
    const type = m[2].trim();
    out.set(name, classifyType(type));
  }
  return out;
}

function classifyType(type: string): string {
  // Function: `(args) => ...`
  if (/^\(.*\)\s*=>/.test(type)) return "function";
  // Array: `Foo[]` / `Array<...>` / `(...)[]`
  if (/\[\]\s*$/.test(type) || /^Array\s*</.test(type) || /^ReadonlyArray\s*</.test(type))
    return "array";
  // Object: `Record<...>` / `{ ... }`
  if (/^Record\s*</.test(type) || type.startsWith("{")) return "object";
  // Boolean
  if (type === "boolean") return "boolean";
  if (type === "number") return "number";
  // 그 외 (string, "foo" | "bar", string union 등)
  return "string";
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
    "--help",
    "--bundle",
    "--watch",
    "--watch-json",
    "--watch-delay=",
    "--serve",
    "--no-splitting",
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
    "--base",
    "--base=",
    "--entry-html",
    "--entry-html=",
    "--public-dir",
    "--public-dir=",
    "--spa-fallback",
    "--spa-fallback=",
    "--plugin",
    "--log-level=",
    // dev server
    "--port",
    "--port=",
    "--host",
    "--host=",
    "--strict-port",
    "--certfile",
    "--keyfile",
    "--proxy",
    // tsconfig — CLI 용 alias (`--project`, `--tsconfig-path` 둘 다 BuildOptions 의 `tsconfigPath` 와 매핑)
    "--project",
    "--project=",
    // tsconfig raw — CLI 입력 어댑터. `loadTsConfig` 가 풀어 jsx/target/decorators 등 다른
    // 옵션으로 변환해 NAPI 로 보냄. BuildOptions 표면에는 없음 (Zig 측 jsx tsconfig 통합 후 노출 검토).
    "--tsconfig-raw=",
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
    // packages — CLI 는 esbuild 호환 `--packages=external` enum 형태, BuildOptions 는
    // `packagesExternal: boolean`.
    "--packages=",
    // banner/footer — `--banner=`/`--footer=` 가 정식 (BuildOptions 와 1:1).
    // `--banner:js=`/`--footer:js=` 는 esbuild 호환 silent alias — 동일 키로 매핑.
    "--banner:js=",
    "--footer:js=",
    // out-extension — esbuild 식 namespace (`--out-extension:.js=`). BuildOptions 의
    // `outExtension: string` (단일) 와 1:N. zts.mjs 가 `.js` 만 받아 단일 string 으로 변환.
    "--out-extension:.js=",
  ]);

  // BuildOptions/TranspileOptions 에 있고 CLI 에 없는 키 (의도적). 함수형/고급 옵션.
  // 공통 NAPI internal 키는 `NAPI_INTERNAL_ONLY_KEYS` (schema-allowlists.ts) 재사용 — 새 internal
  // 키 추가 시 그곳 1곳에만 등록하면 typo-suggest 와 cli-schema-sync 모두 자동 통과.
  const buildOptionsOnlyKeys: ReadonlySet<string> = new Set([
    ...NAPI_INTERNAL_ONLY_KEYS,
    // 함수형 / 중첩 객체 (CLI 표현 불가)
    "compiler", // compiler.styledComponents / compiler.emotion — 중첩 객체, CLI 미노출
    "manualChunks",
    "plugins",
    "server", // server.port / server.host 는 개별 CLI flag 와 config-only nested 객체 양쪽 지원
    // entry — positional argument (flag 아님)
    "entryPoints",
    "filename", // transpile 의 filename — stdin 모드일 때 의미, CLI 가 자동 결정
    // 1:N 매핑으로 CLI 가 cover (cliOnlyFlags 의 namespace 형 flag 가 받음)
    "conditions",
    "dropConsole", // --drop=console 로 cover
    "dropDebugger", // --drop=debugger 로 cover
    "dropLabels",
    "ignoreAnnotations",
    "inlineDynamicImports",
    "jsxSideEffects",
    "outExtension", // namespace 객체 — `--out-extension:.js=` 가 일부 cover
    "outbase",
    "stopAfter", // transpile 단독 — CLI 미노출 (디버그 옵션)
    "treeShaking",
    "watch", // BuildOptions 의 watch 와 CLI --watch 는 의미 다름
    // CLI 가 enum→boolean 변환 (`--charset=utf8` → charsetUtf8: true)
    "charsetUtf8",
    "analyze", // CLI 가 boolean flag, BuildOptions 는 boolean — 매칭되지만 alias 처리 누락 가능
  ]);

  test("CLI flag 가 BuildOptions / TranspileOptions 키와 매칭되거나 cliOnlyFlags 에 등록", () => {
    const unmapped: { flag: string; candidate: string }[] = [];
    for (const flag of cliFlags) {
      // single-letter short alias (`-o`, `-p`, `-w`) — canonical `--` flag 의 alias 라
      // 별도 키 매핑 불필요. matchFlagFromRegistry 가 canonical 과 같은 target 으로 매핑.
      if (/^-[a-z]$/.test(flag)) continue;
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
      if (/^-[a-z]$/.test(flag)) continue;
      if (cliOnlyFlags.has(flag)) continue;
      const candidate = flagToCandidateKey(flag);
      if (knownKeys.has(candidate)) cliExposedKeys.add(candidate);
    }
    // spec.target 이 flag 이름과 다른 경우도 노출 키로 인정 (예: `--sourcemap=mode` 의
    // target=sourcemapMode + extra={sourcemap:true} — spec 한 개가 두 BuildOptions 키를 set).
    for (const spec of FLAG_REGISTRY as readonly {
      target?: string;
      extra?: Record<string, unknown>;
    }[]) {
      if (spec.target && knownKeys.has(spec.target)) cliExposedKeys.add(spec.target);
      if (spec.extra) {
        for (const k of Object.keys(spec.extra)) {
          if (knownKeys.has(k)) cliExposedKeys.add(k);
        }
      }
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
      // single-letter short flag (`-o`, `-p`, `-w`) 는 별도 형식.
      if (/^-[a-z]$/.test(flag)) continue;
      const stripped = flag.replace(/^--/, "").replace(/[:=*]/g, "").replace(/\./g, "");
      if (!/^[a-z][a-z0-9-]*$/.test(stripped)) bad.push(flag);
    }
    expect(bad).toEqual([]);
  });

  // SCALAR_KEYS / BOOL_KEYS / ARRAY_KEYS 의 모든 키가 parseArgs `opts` default 객체에 등록돼 있어야
  // `mergeConfigIntoOpts` 의 머지 조건 (`opts[key] === undefined`) 가 정상 작동.
  // 회귀 패턴: outdir/outfile null → undefined (#2135), outbase 누락 (이번 fix). 자동 감지.
  test("mergeConfigIntoOpts 의 SCALAR_KEYS / BOOL_KEYS / ARRAY_KEYS 가 모두 opts default 에 존재", () => {
    const optsKeys = new Set(extractOptsDefaultKeys(cliSource));
    const lists = extractMergeKeyLists(cliSource);
    const missing: string[] = [];
    for (const k of [...lists.scalar, ...lists.bool, ...lists.array]) {
      if (!optsKeys.has(k)) missing.push(k);
    }
    if (missing.length > 0) {
      throw new Error(
        `[schema drift] SCALAR/BOOL/ARRAY_KEYS 에는 있지만 parseArgs opts default 에 없음: ${missing.join(", ")}\n` +
          `parseArgs 의 opts 객체에 default 추가 (보통 \`undefined\` / \`false\` / \`[]\`).`,
      );
    }
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

// 핵심 키 ~12개의 coarse type (string|boolean|object|array|function) 이 BuildOptions /
// TranspileOptions / WASM 사이에서 일치하는지 검증 — silent type drift 차단.
// 회귀 시나리오: `outdir: string` 이 누군가 `string[]` 으로 바꾸거나, `define: object` 가 `array`
// 로 바뀌는 등 — 키 이름은 그대로 매칭되지만 의미 깨짐.
describe("schema sync — 핵심 키 coarse type drift 검증", () => {
  const indexSource = readFileSync(INDEX_PATH, "utf8");
  const sharedSource = readFileSync(SHARED_INDEX_PATH, "utf8");
  const wasmSource = readFileSync(WASM_INDEX_PATH, "utf8");

  const buildOptionsTypes = extractTypeMap(indexSource, "BuildOptionsCommon");
  const transpileOptionsTypes = extractTypeMap(sharedSource, "TranspileOptions");
  const wasmTypes = extractTypeMap(wasmSource, "BundleOptionsInput");

  // 핵심 키 + 기대 coarse type. 의도적 정의 — drift 시 여기까지 같이 갱신해야 함.
  const CORE_TYPES: ReadonlyArray<readonly [string, string]> = [
    ["entryPoints", "array"],
    ["outdir", "string"],
    ["outfile", "string"],
    ["format", "string"],
    ["platform", "string"],
    ["target", "string"],
    ["minify", "boolean"],
    ["sourcemap", "boolean"],
    ["external", "array"],
    ["define", "object"],
    ["alias", "object"],
    ["loader", "object"],
    ["jsxFactory", "string"],
    ["jsx", "string"],
  ];

  test("BuildOptionsCommon 의 핵심 키 type 이 기대값과 일치", () => {
    const mismatched: string[] = [];
    for (const [key, expected] of CORE_TYPES) {
      const actual = buildOptionsTypes.get(key);
      if (actual === undefined) continue; // BuildOptionsCommon 에 없는 키 (예: target — union variant) 는 skip
      if (actual !== expected)
        mismatched.push(`${key}: BuildOptionsCommon='${actual}' expected='${expected}'`);
    }
    expect(mismatched).toEqual([]);
  });

  // TranspileOptions 는 NAPI 경계 형식이라 일부 키가 BuildOptions 와 다른 표현을 가짐.
  // 의도적 차이는 allowlist 에 등록 (key → transpile 측 expected type).
  const TRANSPILE_TYPE_OVERRIDES: ReadonlyMap<string, string> = new Map([
    // BuildOptions 는 Record<string, string> 객체, TranspileOptions 는 NAPI 가 받는 array
    // (`{ key, value }` pair 의 배열). 의도적.
    ["define", "array"],
  ]);

  test("TranspileOptions 의 핵심 키 type 이 기대값과 일치 (TRANSPILE 식 override 반영)", () => {
    const mismatched: string[] = [];
    for (const [key, expected] of CORE_TYPES) {
      const actual = transpileOptionsTypes.get(key);
      if (actual === undefined) continue;
      const target = TRANSPILE_TYPE_OVERRIDES.get(key) ?? expected;
      if (actual !== target)
        mismatched.push(`${key}: TranspileOptions='${actual}' expected='${target}'`);
    }
    expect(mismatched).toEqual([]);
  });

  test("WASM BundleOptionsInput 의 공통 키 type 이 BuildOptions/TranspileOptions 와 일치", () => {
    // WASM 은 부분 집합이라 누락 키는 skip — 존재하는 키의 type 만 비교.
    const drift: string[] = [];
    for (const [key, wasmType] of wasmTypes) {
      const buildType = buildOptionsTypes.get(key);
      const transpileType = transpileOptionsTypes.get(key);
      const refType = buildType ?? transpileType;
      if (!refType) continue; // wasmOnly (e.g. unsupported, codeSplitting)
      if (wasmType !== refType) {
        drift.push(`${key}: WASM='${wasmType}' BuildOptions/TranspileOptions='${refType}'`);
      }
    }
    if (drift.length > 0) {
      throw new Error(`[type drift] WASM 과 NAPI 의 키 type 불일치:\n  ${drift.join("\n  ")}`);
    }
  });
});
