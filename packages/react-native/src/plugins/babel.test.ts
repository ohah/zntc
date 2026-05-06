import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  applyBabelPluginPrefix,
  detectCustomPlugins,
  isZtsNativePlugin,
  ZTS_NATIVE_PLUGIN_PATTERNS,
} from "./babel.ts";

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

describe("detectCustomPlugins — project-기준 require (#2605 audit)", () => {
  test("project node_modules 의 babel plugin 인식", () => {
    // Fixture: project 디렉토리에 자체 node_modules + custom babel plugin install.
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "fix-test" }));
    mkdirSync(join(dir, "node_modules/my-fake-plugin"), { recursive: true });
    writeFileSync(
      join(dir, "node_modules/my-fake-plugin/package.json"),
      JSON.stringify({ name: "my-fake-plugin", main: "index.js" }),
    );
    writeFileSync(
      join(dir, "node_modules/my-fake-plugin/index.js"),
      "module.exports = function fake(){ return {}; };",
    );
    writeFileSync(
      join(dir, "babel.config.js"),
      `module.exports = { plugins: ['my-fake-plugin'] };`,
    );
    // detectCustomPlugins 가 project 의 node_modules 에서 require 성공 → ZTS
    // native 외 plugin 으로 인식.
    expect(detectCustomPlugins(dir)).toBe(true);
  });

  test("babel-plugin-root-import 같은 외부 plugin — config 만 detect", () => {
    // detectCustomPlugins 는 plugin require 성공 안 해도 string name 만으로 판단.
    // require 실패 시점은 createBabelTransformer 의 ensureBabel — 그 단계에서
    // project-기준 resolve fallback 으로 처리.
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "fix-test" }));
    writeFileSync(
      join(dir, "babel.config.js"),
      `module.exports = { plugins: [['babel-plugin-root-import', { rootPathPrefix: '~/' }]] };`,
    );
    expect(detectCustomPlugins(dir)).toBe(true);
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

describe("applyBabelPluginPrefix", () => {
  test("plain name → babel-plugin-{name}", () => {
    // bare 의 babel.config.js 가 `['lodash']` 를 쓰는데 prefix 없이 resolve 하면
    // lodash 라이브러리 자체로 풀려 babel 이 reject — 핵심 회귀 케이스.
    expect(applyBabelPluginPrefix("lodash")).toBe("babel-plugin-lodash");
    expect(applyBabelPluginPrefix("root-import")).toBe("babel-plugin-root-import");
  });

  test("@babel/foo → @babel/plugin-foo", () => {
    expect(applyBabelPluginPrefix("@babel/proposal-decorators")).toBe(
      "@babel/plugin-proposal-decorators",
    );
  });

  test("@scope/foo → @scope/babel-plugin-foo", () => {
    expect(applyBabelPluginPrefix("@nativewind/preset")).toBe(
      "@nativewind/babel-plugin-preset",
    );
  });

  test("이미 prefix 가진 이름은 그대로", () => {
    expect(applyBabelPluginPrefix("babel-plugin-lodash")).toBe("babel-plugin-lodash");
    expect(applyBabelPluginPrefix("@babel/plugin-transform-flow-strip-types")).toBe(
      "@babel/plugin-transform-flow-strip-types",
    );
    expect(applyBabelPluginPrefix("@scope/babel-plugin-foo")).toBe("@scope/babel-plugin-foo");
  });

  test("절대/상대 경로 + module: prefix 는 그대로", () => {
    expect(applyBabelPluginPrefix("/abs/path/plugin.js")).toBe("/abs/path/plugin.js");
    expect(applyBabelPluginPrefix("./local-plugin")).toBe("./local-plugin");
    expect(applyBabelPluginPrefix("module:@react-native/babel-preset")).toBe(
      "module:@react-native/babel-preset",
    );
  });

  test("preset prefix 도 보존", () => {
    expect(applyBabelPluginPrefix("@babel/preset-typescript")).toBe(
      "@babel/preset-typescript",
    );
    expect(applyBabelPluginPrefix("babel-preset-expo")).toBe("babel-preset-expo");
  });
});
