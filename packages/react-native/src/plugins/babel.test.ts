import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { detectCustomPlugins, isZtsNativePlugin, ZTS_NATIVE_PLUGIN_PATTERNS } from "./babel.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "zts-rn-babel-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("isZtsNativePlugin", () => {
  test("ZTS native list 의 plugin 모두 true", () => {
    for (const pattern of ZTS_NATIVE_PLUGIN_PATTERNS) {
      expect(isZtsNativePlugin(pattern)).toBe(true);
    }
  });

  test("substring 매칭 — `transform-typescript` → true (full path 도 매치)", () => {
    expect(isZtsNativePlugin("@babel/plugin-transform-typescript")).toBe(true);
    expect(isZtsNativePlugin("/abs/path/to/react-native-reanimated/plugin")).toBe(true);
  });

  test("native list 외 — false", () => {
    expect(isZtsNativePlugin("nativewind/babel")).toBe(false);
    expect(isZtsNativePlugin("babel-plugin-styled-components")).toBe(false);
    expect(isZtsNativePlugin("")).toBe(false);
  });

  test("핵심 RN preset / Reanimated / Worklets / TS strip 모두 cover", () => {
    expect(isZtsNativePlugin("@react-native/babel-preset")).toBe(true);
    expect(isZtsNativePlugin("react-native-reanimated/plugin")).toBe(true);
    expect(isZtsNativePlugin("react-native-worklets")).toBe(true);
    expect(isZtsNativePlugin("transform-flow-strip-types")).toBe(true);
  });
});

describe("detectCustomPlugins", () => {
  test("babel.config.js 미존재 — false", () => {
    expect(detectCustomPlugins(dir)).toBe(false);
  });

  test("babel.config.js 존재 + plugins 0 — false", () => {
    writeFileSync(join(dir, "babel.config.js"), "module.exports = {};");
    expect(detectCustomPlugins(dir)).toBe(false);
  });

  test("babel.config.js 존재 + plugins 가 ZTS native 만 — false", () => {
    writeFileSync(
      join(dir, "babel.config.js"),
      `module.exports = { plugins: ['react-native-reanimated/plugin', '@react-native/babel-preset'] };`,
    );
    expect(detectCustomPlugins(dir)).toBe(false);
  });

  test("babel.config.js + plugins 에 native 외 1개 — true", () => {
    writeFileSync(
      join(dir, "babel.config.js"),
      `module.exports = { plugins: ['react-native-reanimated/plugin', 'nativewind/babel'] };`,
    );
    expect(detectCustomPlugins(dir)).toBe(true);
  });

  test("plugin tuple `[name, options]` 도 인식", () => {
    writeFileSync(
      join(dir, "babel.config.js"),
      `module.exports = { plugins: [['nativewind/babel', { mode: 'transform' }]] };`,
    );
    expect(detectCustomPlugins(dir)).toBe(true);
  });

  test("require throw 시 — false (조용히 skip)", () => {
    writeFileSync(join(dir, "babel.config.js"), "throw new Error('boom');");
    expect(detectCustomPlugins(dir)).toBe(false);
  });

  test("config.plugins 가 undefined — false (default 빈 배열)", () => {
    writeFileSync(join(dir, "babel.config.js"), "module.exports = { presets: ['x'] };");
    expect(detectCustomPlugins(dir)).toBe(false);
  });

  test("plugin 의 type 이 string/array 외 — skip", () => {
    writeFileSync(
      join(dir, "babel.config.js"),
      `module.exports = { plugins: [42, null, { name: 'foo' }] };`,
    );
    expect(detectCustomPlugins(dir)).toBe(false);
  });
});

describe("ZTS_NATIVE_PLUGIN_PATTERNS", () => {
  test("count >= 15 (sanity)", () => {
    expect(ZTS_NATIVE_PLUGIN_PATTERNS.length).toBeGreaterThanOrEqual(15);
  });

  test("중복 없음", () => {
    const set = new Set(ZTS_NATIVE_PLUGIN_PATTERNS);
    expect(set.size).toBe(ZTS_NATIVE_PLUGIN_PATTERNS.length);
  });
});
