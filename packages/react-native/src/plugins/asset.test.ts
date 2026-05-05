import { describe, expect, test } from "bun:test";

import { ZTS_HMR_CLIENT_CODE } from "../runtime-loader.ts";
import { createAssetPlugin } from "./asset.ts";
import type { PluginConfig } from "./types.ts";

interface OnLoadHandler {
  (args: { path: string }): Promise<{ contents?: string } | null> | { contents?: string } | null;
}

interface CapturedHandler {
  filter: RegExp;
  handler: OnLoadHandler;
}

function captureHandlers(config: PluginConfig): CapturedHandler[] {
  const plugin = createAssetPlugin(config);
  const captured: CapturedHandler[] = [];
  const fakeBuild = {
    onLoad(filter: { filter: RegExp }, handler: OnLoadHandler) {
      captured.push({ filter: filter.filter, handler });
    },
    onResolve() {},
    onResolveContext() {},
    onTransform() {},
  };
  plugin.setup(fakeBuild as never);
  return captured;
}

describe("createAssetPlugin", () => {
  const baseConfig: PluginConfig = {
    projectRoot: "/abs/project",
    assetExts: ["png", "jpg"],
    rnPlatform: "ios",
    sourceExts: [".ts", ".tsx", ".js", ".jsx"],
  };

  test("HMRClient.js path → ZTS HMR runtime code 반환 (onLoad)", () => {
    const handlers = captureHandlers(baseConfig);
    expect(handlers.length).toBe(1); // HMRClient.js 만 (sourceExts 에 RN-specific 확장자 0)
    const hmrHandler = handlers[0]!;
    expect(hmrHandler.filter.test("/abs/Libraries/Utilities/HMRClient.js")).toBe(true);
    expect(hmrHandler.filter.test("/abs/foo.ts")).toBe(false);

    const result = hmrHandler.handler({ path: "/abs/Libraries/Utilities/HMRClient.js" });
    expect(result).toEqual({ contents: ZTS_HMR_CLIENT_CODE });
  });

  test("babelTransformerPath 미지정 — HMRClient.js handler 만 등록 (custom transformer 없음)", () => {
    const handlers = captureHandlers(baseConfig);
    expect(handlers.length).toBe(1);
  });

  test("babelTransformerPath 지정 + customExts 0 — HMRClient.js handler 만", () => {
    // sourceExts 가 모두 표준 JS/TS — customExts 빈 string → 등록 skip
    const handlers = captureHandlers({
      ...baseConfig,
      babelTransformerPath: "react-native-svg-transformer",
    });
    expect(handlers.length).toBe(1);
  });

  test("babelTransformerPath + customExts (.svg) — 두 번째 onLoad 등록", () => {
    const handlers = captureHandlers({
      ...baseConfig,
      sourceExts: [".ts", ".tsx", ".js", ".jsx", ".svg"],
      babelTransformerPath: "react-native-svg-transformer",
    });
    expect(handlers.length).toBe(2);
    const customHandler = handlers[1]!;
    expect(customHandler.filter.test("/abs/icon.svg")).toBe(true);
    expect(customHandler.filter.test("/abs/foo.ts")).toBe(false);
  });

  test("customExts 패턴 — JS/TS/JSON 표준 확장자 제외", () => {
    const handlers = captureHandlers({
      ...baseConfig,
      sourceExts: [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json", ".svg", ".graphql"],
      babelTransformerPath: "any-transformer",
    });
    const customHandler = handlers[1]!;
    expect(customHandler.filter.test("/abs/x.svg")).toBe(true);
    expect(customHandler.filter.test("/abs/x.graphql")).toBe(true);
    expect(customHandler.filter.test("/abs/x.ts")).toBe(false);
    expect(customHandler.filter.test("/abs/x.json")).toBe(false);
    expect(customHandler.filter.test("/abs/x.mjs")).toBe(false);
  });

  test("plugin name 은 zts:react-native:runtime", () => {
    const plugin = createAssetPlugin(baseConfig);
    expect(plugin.name).toBe("zts:react-native:runtime");
  });
});
