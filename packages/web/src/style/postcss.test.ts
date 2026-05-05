import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  collectPostcssMessages,
  findPostcssConfig,
  isCssFile,
  isPostcssConfigFile,
  logPostcssProcessed,
  POSTCSS_CONFIG_NAMES,
} from "./postcss.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "zts-postcss-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function touch(rel: string, content = ""): string {
  const path = join(dir, rel);
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, content);
  return path;
}

describe("POSTCSS_CONFIG_NAMES", () => {
  test("zts.mjs L892-902 와 동일 순서/내용", () => {
    expect([...POSTCSS_CONFIG_NAMES]).toEqual([
      "postcss.config.mjs",
      "postcss.config.js",
      "postcss.config.cjs",
      "postcss.config.json",
      ".postcssrc",
      ".postcssrc.json",
      ".postcssrc.js",
      ".postcssrc.cjs",
      ".postcssrc.mjs",
    ]);
  });
});

describe("isCssFile", () => {
  test(".css 만 true", () => {
    expect(isCssFile("a.css")).toBe(true);
    expect(isCssFile("/abs/path/a.css")).toBe(true);
  });

  test("그 외 false", () => {
    expect(isCssFile("a.scss")).toBe(false);
    expect(isCssFile("a.module.css.map")).toBe(false);
    expect(isCssFile("a.tsx")).toBe(false);
    expect(isCssFile("")).toBe(false);
  });
});

describe("isPostcssConfigFile", () => {
  test("표준 config 파일들 true", () => {
    expect(isPostcssConfigFile("/x/postcss.config.mjs")).toBe(true);
    expect(isPostcssConfigFile("postcss.config.cjs")).toBe(true);
    expect(isPostcssConfigFile("/repo/.postcssrc")).toBe(true);
    expect(isPostcssConfigFile("/repo/.postcssrc.json")).toBe(true);
  });

  test("그 외 false", () => {
    expect(isPostcssConfigFile("postcss.config.txt")).toBe(false);
    expect(isPostcssConfigFile("postcssrc")).toBe(false);
    expect(isPostcssConfigFile("a.css")).toBe(false);
  });
});

describe("findPostcssConfig", () => {
  test("같은 디렉토리에 config 있으면 절대 path", () => {
    touch("postcss.config.js", "module.exports = {};");
    expect(findPostcssConfig(dir)).toBe(join(dir, "postcss.config.js"));
  });

  test("부모 디렉토리는 walk 안 함 (zts.mjs 동작과 일치)", () => {
    touch("postcss.config.cjs");
    mkdirSync(join(dir, "sub/deep"), { recursive: true });
    // sub/deep 에서는 못 찾음 — single dir lookup.
    expect(findPostcssConfig(join(dir, "sub/deep"))).toBe(null);
  });

  test("우선순위: postcss.config.* → .postcssrc → .postcssrc.*", () => {
    touch(".postcssrc.json");
    touch("postcss.config.js");
    // POSTCSS_CONFIG_NAMES 의 postcss.config.js 가 .postcssrc.json 보다 우선.
    expect(findPostcssConfig(dir)).toBe(join(dir, "postcss.config.js"));
  });

  test("config 없으면 null", () => {
    expect(findPostcssConfig(dir)).toBe(null);
  });
});

describe("collectPostcssMessages", () => {
  test("dependency 메시지 → deps 에 추가", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages([{ type: "dependency", file: "/a/b.css" }], deps, dirDeps);
    expect(deps.has(join("/a/b.css"))).toBe(true);
    expect(dirDeps.size).toBe(0);
  });

  test("dir-dependency 메시지 → dirDeps", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages([{ type: "dir-dependency", dir: "/a" }], deps, dirDeps);
    expect(dirDeps.has(join("/a"))).toBe(true);
  });

  test("dir-dependency 의 directory alias 도 인식", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages([{ type: "dir-dependency", directory: "/x" }], deps, dirDeps);
    expect(dirDeps.has(join("/x"))).toBe(true);
  });

  test("context-dependency → deps", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages([{ type: "context-dependency", file: "/c.css" }], deps, dirDeps);
    expect(deps.has(join("/c.css"))).toBe(true);
  });

  test("알 수 없는 type 무시", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages([{ type: "warning", file: "/a.css" }], deps, dirDeps);
    expect(deps.size).toBe(0);
    expect(dirDeps.size).toBe(0);
  });

  test("file/dir 가 string 아니면 skip", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages(
      [
        { type: "dependency", file: 123 as unknown as string },
        { type: "dir-dependency", dir: undefined },
      ],
      deps,
      dirDeps,
    );
    expect(deps.size).toBe(0);
    expect(dirDeps.size).toBe(0);
  });

  test("null/undefined 메시지도 안전 — 빈 set 반환", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages(null, deps, dirDeps);
    collectPostcssMessages(undefined, deps, dirDeps);
    expect(deps.size).toBe(0);
    expect(dirDeps.size).toBe(0);
  });

  test("여러 메시지 동시 누적 (dedup 자동)", () => {
    const deps = new Set<string>();
    const dirDeps = new Set<string>();
    collectPostcssMessages(
      [
        { type: "dependency", file: "/a.css" },
        { type: "dependency", file: "/a.css" },
        { type: "dir-dependency", dir: "/d" },
      ],
      deps,
      dirDeps,
    );
    expect(deps.size).toBe(1);
    expect(dirDeps.size).toBe(1);
  });
});

describe("logPostcssProcessed", () => {
  let originalError: typeof console.error;
  let captured: string[];

  beforeEach(() => {
    originalError = console.error;
    captured = [];
    console.error = (msg: string) => captured.push(msg);
  });

  afterEach(() => {
    console.error = originalError;
  });

  test("logLevel silent 이면 출력 없음", () => {
    logPostcssProcessed("silent", 5, "/x/postcss.config.js");
    expect(captured.length).toBe(0);
  });

  test("logLevel undefined 이면 출력", () => {
    logPostcssProcessed(undefined, 3, "/x/postcss.config.js");
    expect(captured[0]).toContain("processed 3");
    expect(captured[0]).toContain("postcss.config.js");
  });

  test("configFile null 이면 fallback 표시", () => {
    logPostcssProcessed(undefined, 1, null);
    expect(captured[0]).toContain("postcss config");
  });
});
