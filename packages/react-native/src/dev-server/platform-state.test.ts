import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { WatchHandle } from "@zts/core";

import { buildRnDevServerOptions } from "./options.ts";
import {
  createPlatformStateRegistry,
  getCachedSourceMap,
  type PlatformState,
  waitForBuild,
} from "./platform-state.ts";

let dir: string;
let entryPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "zts-rn-platform-"));
  mkdirSync(join(dir, "src"), { recursive: true });
  entryPath = join(dir, "src/index.ts");
  writeFileSync(entryPath, 'console.log("hi");\n');
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function fakeState(overrides: Partial<PlatformState> = {}): PlatformState {
  const handle = {
    stop() {},
    getBundleSourceMap: () => null,
    getHmrSourceMap: () => null,
  } as unknown as WatchHandle;
  return {
    platform: "ios",
    outputDir: "/tmp/x",
    outputPath: "/tmp/x/bundle.js",
    handle,
    bundle: null,
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: 0,
    ...overrides,
  };
}

describe("getCachedSourceMap", () => {
  test("cache 미존재 + handle 결과 → postProcess 반영", () => {
    const handle = {
      stop() {},
      getBundleSourceMap: () => JSON.stringify({ version: 3, sources: ["/node_modules/x/y.js"] }),
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle;
    const state: PlatformState = {
      platform: "ios",
      outputDir: "/tmp",
      outputPath: "/tmp/b.js",
      handle,
      bundle: null,
      sourceMapCache: null,
      buildError: null,
      fileCount: 1,
      lastRebuildTime: 0,
    };
    const json = getCachedSourceMap(state);
    const parsed = JSON.parse(json!);
    expect(parsed.x_google_ignoreList).toEqual([0]);
    // 두 번째 호출은 cache 값
    expect(getCachedSourceMap(state)).toBe(json);
  });

  test("handle 이 null 반환 → null", () => {
    const handle = {
      stop() {},
      getBundleSourceMap: () => null,
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle;
    const state: PlatformState = {
      platform: "ios",
      outputDir: "/tmp",
      outputPath: "/tmp/b.js",
      handle,
      bundle: null,
      sourceMapCache: null,
      buildError: null,
      fileCount: 1,
      lastRebuildTime: 0,
    };
    expect(getCachedSourceMap(state)).toBeNull();
  });

  test("이미 cached 값 있으면 handle 호출 안 함", () => {
    let called = 0;
    const handle = {
      stop() {},
      getBundleSourceMap: () => {
        called++;
        return null;
      },
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle;
    const state: PlatformState = {
      platform: "ios",
      outputDir: "/tmp",
      outputPath: "/tmp/b.js",
      handle,
      bundle: null,
      sourceMapCache: '{"v":3}',
      buildError: null,
      fileCount: 1,
      lastRebuildTime: 0,
    };
    expect(getCachedSourceMap(state)).toBe('{"v":3}');
    expect(called).toBe(0);
  });
});

describe("waitForBuild", () => {
  test("bundle 가 set 되면 resolve", async () => {
    const state = fakeState();
    setTimeout(() => {
      state.bundle = "code;";
    }, 10);
    await waitForBuild(state, 5);
    expect(state.bundle).toBe("code;");
  });

  test("buildError 가 set 되면 resolve", async () => {
    const state = fakeState();
    setTimeout(() => {
      state.buildError = "boom";
    }, 10);
    await waitForBuild(state, 5);
    expect(state.buildError).toBe("boom");
  });

  test("이미 bundle 이 set 이면 즉시 resolve", async () => {
    const state = fakeState({ bundle: "code;" });
    await waitForBuild(state, 5);
    expect(state.bundle).toBe("code;");
  });
});

describe("createPlatformStateRegistry — 캐싱", () => {
  test("같은 platform 두 번 요청 시 같은 instance 반환 (cache)", () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: "ios", dev: true },
    });
    const recordedReady: string[] = [];
    const registry = createPlatformStateRegistry(opts, {
      onReady(s) {
        recordedReady.push(s.platform);
      },
    });
    try {
      const a = registry.getOrCreate("ios");
      const b = registry.getOrCreate("ios");
      expect(a).toBe(b);
      expect(registry.platforms.size).toBe(1);
    } finally {
      void registry.stopAll();
    }
  });

  test("ios + android 분리 — 각자 별 instance", () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: "ios", dev: true },
    });
    const registry = createPlatformStateRegistry(opts);
    try {
      const ios = registry.getOrCreate("ios");
      const android = registry.getOrCreate("android");
      expect(ios.platform).toBe("ios");
      expect(android.platform).toBe("android");
      expect(ios).not.toBe(android);
      expect(registry.platforms.size).toBe(2);
    } finally {
      void registry.stopAll();
    }
  });

  test("stopAll → registry 비움", async () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: "ios", dev: true },
    });
    const registry = createPlatformStateRegistry(opts);
    registry.getOrCreate("ios");
    expect(registry.platforms.size).toBe(1);
    await registry.stopAll();
    expect(registry.platforms.size).toBe(0);
  });
});
