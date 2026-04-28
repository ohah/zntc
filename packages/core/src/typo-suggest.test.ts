import { describe, expect, test } from "bun:test";

import { KNOWN_CONFIG_KEYS, suggestKey, warnUnknownKeys } from "./typo-suggest.ts";

describe("suggestKey", () => {
  test("정확히 일치하는 known 키 — 본인 반환 (거리 0)", () => {
    expect(suggestKey("format", ["format", "platform"])).toBe("format");
  });

  test("거리 1: 단일 글자 typo", () => {
    expect(suggestKey("formatt", ["format", "platform"])).toBe("format");
    expect(suggestKey("forat", ["format", "platform"])).toBe("format");
  });

  test("거리 2: 두 글자 typo (긴 키)", () => {
    expect(suggestKey("entryPointts", ["entryPoints", "outdir"])).toBe("entryPoints");
  });

  test("threshold 초과: null 반환", () => {
    expect(suggestKey("xxx", ["format", "platform"])).toBeNull();
  });

  test("known 비어있으면 null", () => {
    expect(suggestKey("anything", [])).toBeNull();
  });

  test("unknown 빈 문자열은 null", () => {
    expect(suggestKey("", ["format"])).toBeNull();
  });

  test("다중 매치: 가장 가까운 거리 우선", () => {
    // 'forma' vs 'format' (1) and 'forman' (1) → tie. alphabetical.
    expect(suggestKey("forma", ["format", "forman"])).toBe("forman");
  });

  test("매우 짧은 키 (3자 이하): 거리 1 까지만", () => {
    // "abc" vs "abx" 거리 1 → OK
    expect(suggestKey("abc", ["abx"])).toBe("abx");
    // "abc" vs "xyz" 거리 3 → null (threshold 1 로 자동 조정)
    expect(suggestKey("abc", ["xyz"])).toBeNull();
  });

  test("실제 BuildOptions 키 typo 시나리오", () => {
    // "outdri" → "outdir"
    expect(suggestKey("outdri", KNOWN_CONFIG_KEYS)).toBe("outdir");
    // "minfy" → "minify"
    expect(suggestKey("minfy", KNOWN_CONFIG_KEYS)).toBe("minify");
    // "sourcemaps" → "sourcemap"
    expect(suggestKey("sourcemaps", KNOWN_CONFIG_KEYS)).toBe("sourcemap");
    // "platfrom" → "platform"
    expect(suggestKey("platfrom", KNOWN_CONFIG_KEYS)).toBe("platform");
  });

  test("완전히 다른 단어는 제안 안 함", () => {
    expect(suggestKey("kubernetes", KNOWN_CONFIG_KEYS)).toBeNull();
  });
});

describe("warnUnknownKeys", () => {
  test("known 키만 있으면 결과 빈 배열", () => {
    const result = warnUnknownKeys({ format: "esm", minify: true }, ["format", "minify"], {
      silent: true,
    });
    expect(result).toEqual([]);
  });

  test("unknown 키 + 제안 동봉", () => {
    const result = warnUnknownKeys({ formatt: "esm", outdri: "./dist" }, ["format", "outdir"], {
      silent: true,
    });
    expect(result).toEqual([
      { unknown: "formatt", suggestion: "format" },
      { unknown: "outdri", suggestion: "outdir" },
    ]);
  });

  test("제안 없는 unknown 키는 suggestion=null", () => {
    const result = warnUnknownKeys({ kubernetes: 1 }, KNOWN_CONFIG_KEYS, { silent: true });
    expect(result).toEqual([{ unknown: "kubernetes", suggestion: null }]);
  });

  test("config 일부가 known, 일부가 unknown", () => {
    const result = warnUnknownKeys(
      { format: "esm", outdri: "./dist", banner: "/* */" },
      KNOWN_CONFIG_KEYS,
      { silent: true },
    );
    expect(result).toHaveLength(1);
    expect(result[0]).toEqual({ unknown: "outdri", suggestion: "outdir" });
  });

  test("실제 콘솔 출력 (silent=false 기본) — sourceLabel 포함", () => {
    const original = console.warn;
    const calls: string[] = [];
    console.warn = (msg: string) => calls.push(msg);
    try {
      warnUnknownKeys({ formatt: "esm" }, ["format"], { sourceLabel: "zts.config.ts" });
    } finally {
      console.warn = original;
    }
    expect(calls.length).toBe(1);
    expect(calls[0]).toContain("formatt");
    expect(calls[0]).toContain("zts.config.ts");
    expect(calls[0]).toContain("did you mean 'format'");
  });
});

describe("KNOWN_CONFIG_KEYS", () => {
  test("주요 BuildOptions 키 모두 등록", () => {
    const required = [
      "entryPoints",
      "format",
      "minify",
      "sourcemap",
      "external",
      "alias",
      "define",
      "loader",
      "plugins",
      "extends",
      "tsconfigPath",
    ];
    for (const k of required) {
      expect(KNOWN_CONFIG_KEYS).toContain(k);
    }
  });

  test("중복 키 없음", () => {
    const unique = new Set(KNOWN_CONFIG_KEYS);
    expect(unique.size).toBe(KNOWN_CONFIG_KEYS.length);
  });

  // ─── #2112 schema sync — `BuildOptionsCommon` 필드와 동기화 검증 ─────────────
  test("BuildOptionsCommon 의 모든 필드가 KNOWN_CONFIG_KEYS 에 포함됨", () => {
    // packages/core/index.ts 의 `interface BuildOptionsCommon { ... }` 본문 파싱.
    // typo-suggest 의 KNOWN_CONFIG_KEYS 가 BuildOptions 와 drift 시 false negative
    // (사용자 typo 가 unknown 으로 분류되어 도움 없는 경고만 출력) 가 발생하므로
    // CI 에서 자동 감지.
    const fs = require("node:fs") as typeof import("node:fs");
    const path = require("node:path") as typeof import("node:path");
    const indexTsPath = path.join(__dirname, "..", "index.ts");
    const source = fs.readFileSync(indexTsPath, "utf8");

    // `interface BuildOptionsCommon {` ... `\n}` 본문 추출.
    const marker = "interface BuildOptionsCommon {";
    const start = source.indexOf(marker);
    expect(start).toBeGreaterThan(0);
    const bodyStart = start + marker.length;
    let depth = 1;
    let i = bodyStart;
    while (i < source.length && depth > 0) {
      const c = source[i];
      if (c === "{") depth += 1;
      else if (c === "}") depth -= 1;
      i += 1;
    }
    const body = source.slice(bodyStart, i - 1);

    // 각 줄에서 필드명 추출 — `name?:` 또는 `name:`.
    const fields: string[] = [];
    for (const rawLine of body.split("\n")) {
      const line = rawLine.trim();
      if (!line || line.startsWith("//") || line.startsWith("*") || line.startsWith("/*")) continue;
      const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*\??\s*:/);
      if (m) fields.push(m[1]);
    }
    expect(fields.length).toBeGreaterThan(20);

    const knownSet = new Set(KNOWN_CONFIG_KEYS);
    // typo-suggest 가 BuildOptions 와 drift 한 키만 보고. 의도적으로 KNOWN 에서 빠진 키는
    // BUILD_OPTIONS_NOT_IN_KNOWN allowlist 에 등록.
    const intentionallyMissing: ReadonlySet<string> = new Set([
      // BuildOptions / NAPI 만 노출 — 사용자가 zts.config.* 에 직접 명시할 일 없음.
      "allowOverwrite",
      "analyze",
      "blockList",
      "collectModuleCodes",
      "configurableExports",
      "devMode",
      "emitDiskSourcemap",
      "entryErrorGuard",
      "fallback",
      "globalIdentifiers",
      "nodePaths",
      "onReady",
      "onRebuild",
      "outExtension",
      "polyfills",
      "preserveSymlinks",
      "profile",
      "profileFormat",
      "profileLevel",
      "reactRefresh",
      "rootDir",
      "runBeforeMain",
      "silentConsoleErrorPatterns",
      "scopeHoist",
      "strictExecutionOrder",
      "watchExclude",
      "watchFolders",
      "watchInclude",
      "workletPluginVersion",
      "workletTransform",
      "experimentalCodeCache",
      "assetRegistry",
      "globalIdentifiers",
      "tsconfigRaw",
      "watch",
      "write",
    ]);

    const missing: string[] = [];
    for (const f of fields) {
      if (knownSet.has(f)) continue;
      if (intentionallyMissing.has(f)) continue;
      missing.push(f);
    }
    if (missing.length > 0) {
      throw new Error(
        `[schema drift] BuildOptionsCommon fields missing from KNOWN_CONFIG_KEYS: ${missing.join(", ")}\n` +
          `Add to KNOWN_CONFIG_KEYS (typo-suggest.ts) or to intentionallyMissing in this test.`,
      );
    }
  });
});
