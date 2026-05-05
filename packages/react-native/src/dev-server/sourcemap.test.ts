import { describe, expect, test } from "bun:test";

import { postProcessSourceMap } from "./sourcemap.ts";

describe("postProcessSourceMap", () => {
  test("invalid JSON → rawJson 그대로", () => {
    expect(postProcessSourceMap("not json")).toBe("not json");
  });

  test("version != 3 → 그대로", () => {
    const v2 = JSON.stringify({ version: 2, sources: ["a.js"] });
    expect(postProcessSourceMap(v2)).toBe(v2);
  });

  test("sources 없음 → 그대로", () => {
    const noSources = JSON.stringify({ version: 3 });
    expect(postProcessSourceMap(noSources)).toBe(noSources);
  });

  test("node_modules sources → x_google_ignoreList 추가", () => {
    const input = JSON.stringify({
      version: 3,
      sources: ["src/app.ts", "/node_modules/react/index.js", "src/util.ts"],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1]);
  });

  test("기존 x_google_ignoreList 보존 + node_modules 추가 (sort + dedup)", () => {
    const input = JSON.stringify({
      version: 3,
      sources: ["polyfill.js", "src/app.ts", "/node_modules/react/index.js"],
      x_google_ignoreList: [0],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0, 2]);
  });

  test("중복 인덱스 dedup", () => {
    const input = JSON.stringify({
      version: 3,
      sources: ["/node_modules/x/y.js"],
      x_google_ignoreList: [0],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0]);
  });

  test("non-string source 항목 무시", () => {
    const input = JSON.stringify({
      version: 3,
      sources: ["src/app.ts", 42, "/node_modules/foo/index.js"],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([2]);
  });

  test("ignored 항목 0 → x_google_ignoreList 추가 안 함", () => {
    const input = JSON.stringify({ version: 3, sources: ["src/app.ts"] });
    const out = JSON.parse(postProcessSourceMap(input));
    expect("x_google_ignoreList" in out).toBe(false);
  });
});
