// per-platform state — ios / android 별로 별도 watch handle + bundle + lazy
// sourcemap cache. RN runtime 이 첫 요청 시점에 platform 동적 spawn (initial
// build 대기), rebuild 마다 cache invalidate.

import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { WatchHandle, WatchReadyEvent, WatchRebuildEvent } from "@zts/core";

import { watchRn } from "../preset.ts";
import type { RnDevServerOptions } from "./options.ts";
import { postProcessSourceMap } from "./sourcemap.ts";

const SOURCE_MAPPING_URL_RE = /\/\/# sourceMappingURL=[^\n]*/g;

export interface PlatformState {
  readonly platform: "ios" | "android";
  readonly outputDir: string;
  readonly outputPath: string;
  handle: WatchHandle;
  bundle: string | null;
  /** rebuild 마다 invalidate. 같은 build 안에서 여러 sourcemap 요청 시 재사용. */
  sourceMapCache: string | null;
  buildError: string | null;
  fileCount: number;
  lastRebuildTime: number;
}

/** sourcemap lazy fetch + memoize. cache miss 시 handle 에서 build + postProcess. */
export function getCachedSourceMap(state: PlatformState): string | null {
  if (state.sourceMapCache) return state.sourceMapCache;
  const raw = state.handle.getBundleSourceMap();
  if (!raw) return null;
  state.sourceMapCache = postProcessSourceMap(raw);
  return state.sourceMapCache;
}

export interface PlatformStateCallbacks {
  onReady?: (state: PlatformState, event: WatchReadyEvent) => void;
  onRebuild?: (state: PlatformState, event: WatchRebuildEvent) => void;
}

/**
 * platform 별 watch + state 생성. 첫 build 는 비동기 — caller 가
 * `waitForBuild(state)` 로 대기. RN runtime 이 ios+android 동시 요청 시
 * 별도 outputDir 에 격리.
 */
export function createPlatformState(
  options: RnDevServerOptions,
  platform: "ios" | "android",
  callbacks?: PlatformStateCallbacks,
): PlatformState {
  const outputDir = mkdtempSync(join(tmpdir(), `zts-rn-${platform}-`));
  const outputPath = join(outputDir, "bundle.js");

  // bundle 의 RnBundleInput 의 rnPlatform 만 override — 다른 필드 그대로 유지.
  const platformBundle = { ...options.bundle, rnPlatform: platform };

  const state: PlatformState = {
    platform,
    outputDir,
    outputPath,
    // watchRn 의 onReady/onRebuild 콜백이 state ref 를 closure 로 capture 해야 해서
    // placeholder 후 line 아래에서 채움. self-reference 패턴 — caller 가 직접 state
    // 만들지 않으므로 초기 undefined window 누수 없음.
    handle: undefined as unknown as WatchHandle,
    bundle: null,
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: Date.now(),
  };

  state.handle = watchRn({
    ...platformBundle,
    outfile: outputPath,
    onReady(event) {
      if (event.files) state.fileCount = event.files;
      if (existsSync(outputPath)) {
        state.bundle = readFileSync(outputPath, "utf-8").replace(SOURCE_MAPPING_URL_RE, "");
      } else {
        state.buildError = "Build produced no output";
      }
      callbacks?.onReady?.(state, event);
    },
    onRebuild(event) {
      state.lastRebuildTime = Date.now();
      if (!event.success) {
        state.buildError = event.error ?? "Unknown build error";
        callbacks?.onRebuild?.(state, event);
        return;
      }
      state.buildError = null;
      // rebuild 마다 cache invalidate — 다음 요청 시 lazy getter 가 swap fetch.
      state.sourceMapCache = null;
      if (existsSync(outputPath)) {
        state.bundle = readFileSync(outputPath, "utf-8").replace(SOURCE_MAPPING_URL_RE, "");
      }
      callbacks?.onRebuild?.(state, event);
    },
  });

  return state;
}

/** initial build 또는 buildError 가 정해질 때까지 polling. dev server start 시점 1회. */
export function waitForBuild(state: PlatformState, pollIntervalMs = 50): Promise<void> {
  return new Promise((resolve) => {
    const check = () => {
      if (state.bundle !== null || state.buildError !== null) resolve();
      else setTimeout(check, pollIntervalMs);
    };
    check();
  });
}

/** 모든 platform 의 watch handle 종료 + outputDir cleanup (caller 책임). */
export interface PlatformStateRegistry {
  readonly platforms: ReadonlyMap<string, PlatformState>;
  getOrCreate(platform: "ios" | "android"): PlatformState;
  stopAll(): Promise<void>;
}

export function createPlatformStateRegistry(
  options: RnDevServerOptions,
  callbacks?: PlatformStateCallbacks,
): PlatformStateRegistry {
  const platforms = new Map<string, PlatformState>();

  return {
    platforms,
    getOrCreate(platform) {
      let state = platforms.get(platform);
      if (state) return state;
      state = createPlatformState(options, platform, callbacks);
      platforms.set(platform, state);
      return state;
    },
    async stopAll() {
      const handles = [...platforms.values()];
      platforms.clear();
      for (const s of handles) {
        try {
          s.handle.stop();
        } catch {
          /* ignore */
        }
      }
    },
  };
}
