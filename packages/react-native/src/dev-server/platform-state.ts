// per-platform state — ios / android 별로 별도 watch handle + bundle + lazy
// sourcemap cache. RN runtime 이 첫 요청 시점에 platform 동적 spawn (initial
// build 대기), rebuild 마다 cache invalidate.

import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import type { WatchHandle, WatchReadyEvent, WatchRebuildEvent } from '@zntc/core';

import { bundleRn, watchRn } from '../preset.ts';
import type { RnDevServerOptions } from './options.ts';
import { postProcessSourceMap } from './sourcemap.ts';

const SOURCE_MAPPING_URL_RE = /\/\/# sourceMappingURL=[^\n]*/g;

export interface PlatformState {
  readonly platform: 'ios' | 'android';
  readonly outputDir: string;
  readonly outputPath: string;
  handle: WatchHandle;
  bundle: string | null;
  bundleStale: boolean;
  refreshBundle: () => Promise<void>;
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
  if (process.env.ZNTC_DEBUG_TERMINAL === '1') {
    process.stderr.write(
      `[zntc:rn-dev:debug] getBundleSourceMap[${state.platform}]: ${raw ? `len=${raw.length}` : 'null'}\n`,
    );
  }
  if (!raw) return null;
  state.sourceMapCache = postProcessSourceMap(raw);
  return state.sourceMapCache;
}

export interface PlatformStateCallbacks {
  onReady?: (state: PlatformState, event: WatchReadyEvent) => void;
  onRebuild?: (state: PlatformState, event: WatchRebuildEvent) => void;
}

function getBundleText(result: Awaited<ReturnType<typeof bundleRn>>): string {
  const jsFile =
    result.outputFiles.find((file) => file.path.endsWith('.js')) ?? result.outputFiles[0];
  if (!jsFile) throw new Error('Build produced no output');
  return jsFile.text.replace(SOURCE_MAPPING_URL_RE, '');
}

function getBundleSourceMapText(result: Awaited<ReturnType<typeof bundleRn>>): string | null {
  return result.outputFiles.find((file) => file.path.endsWith('.map'))?.text ?? null;
}

export interface BundleRefresher {
  /** stale 신호 — generation 을 bump 해 in-flight build 가 이 변경을 마스킹하지 못하게 한다. */
  markStale(): void;
  /** stale 이면 build, in-flight 면 coalesce. */
  refresh(): Promise<void>;
}

/**
 * in-flight build coalescing + generation guard. `build` 는 시작 시점 소스를 빌드하므로,
 * 진행 중 `markStale()` 이 또 불리면(파일 재변경) 그 build 완료가 stale 을 clear 하면 안 된다
 * (더 새로운 변경을 마스킹 → stale bundle 제공). generation 으로 가드: build 시작 시 generation
 * 을 캡처, 완료 시 generation 이 그대로일 때만 `clearStale`. 새 staleness 가 들어왔으면 stale 을
 * 유지해 다음 `refresh()` 가 최신 소스로 rebuild 한다. `bundleRn`/state 의존을 콜백으로 주입해
 * race-safety 로직만 결정적으로 유닛 테스트할 수 있게 분리.
 */
export function createBundleRefresher(deps: {
  /** 이미 신선(!bundleStale && bundle≠null)하면 build 스킵. */
  isFresh: () => boolean;
  /** bundleRn + state.bundle/buildError 갱신. 내부 try/catch 라 reject 하지 않음. */
  build: () => Promise<void>;
  /** stale=true. */
  setStale: () => void;
  /** stale=false. */
  clearStale: () => void;
}): BundleRefresher {
  let inFlight: Promise<void> | null = null;
  let generation = 0;

  function markStale(): void {
    deps.setStale();
    generation += 1;
  }

  function refresh(): Promise<void> {
    if (deps.isFresh()) return Promise.resolve();
    if (inFlight) return inFlight;
    const startGen = generation;
    inFlight = deps
      .build()
      .then(() => {
        // build 시작 후 새 staleness(markStale)가 없었을 때만 clear. 들어왔다면 그 변경은
        // 이 build 결과에 없으므로 stale 유지 → 다음 refresh 가 최신 소스로 rebuild.
        if (generation === startGen) deps.clearStale();
      })
      .finally(() => {
        inFlight = null;
      });
    return inFlight;
  }

  return { markStale, refresh };
}

/**
 * platform 별 watch + state 생성. 첫 build 는 비동기 — caller 가
 * `waitForBuild(state)` 로 대기. RN runtime 이 ios+android 동시 요청 시
 * 별도 outputDir 에 격리.
 */
export function createPlatformState(
  options: RnDevServerOptions,
  platform: 'ios' | 'android',
  callbacks?: PlatformStateCallbacks,
): PlatformState {
  const outputDir = mkdtempSync(join(tmpdir(), `zntc-rn-${platform}-`));
  const outputPath = join(outputDir, 'bundle.js');

  // bundle 의 RnBundleInput 의 rnPlatform 만 override — 다른 필드 그대로 유지.
  const platformBundle = { ...options.bundle, rnPlatform: platform };
  // build 끝까지 채워짐 — refreshBundle/onRebuild 콜백(모두 lazy)에서만 참조.
  let refresher: BundleRefresher;

  const state: PlatformState = {
    platform,
    outputDir,
    outputPath,
    // watchRn 의 onReady/onRebuild 콜백이 state ref 를 closure 로 capture 해야 해서
    // placeholder 후 line 아래에서 채움. self-reference 패턴 — caller 가 직접 state
    // 만들지 않으므로 초기 undefined window 누수 없음.
    handle: undefined as unknown as WatchHandle,
    bundle: null,
    bundleStale: false,
    refreshBundle: () => refresher.refresh(),
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: Date.now(),
  };

  refresher = createBundleRefresher({
    isFresh: () => !state.bundleStale && state.bundle !== null,
    build: () =>
      bundleRn(platformBundle)
        .then((result) => {
          state.bundle = getBundleText(result);
          const sourceMap = getBundleSourceMapText(result);
          state.sourceMapCache = sourceMap ? postProcessSourceMap(sourceMap) : null;
          state.buildError = null;
        })
        .catch((err) => {
          state.bundle = null;
          state.buildError = err instanceof Error ? err.message : String(err);
        }),
    setStale: () => {
      state.bundleStale = true;
    },
    clearStale: () => {
      state.bundleStale = false;
    },
  });

  if (process.env.ZNTC_DEBUG_TERMINAL === '1') {
    process.stderr.write(
      `[zntc:rn-dev:debug] watchRn[${platform}] sourcemap=${platformBundle.sourcemap} dev=${platformBundle.dev} outfile=${outputPath}\n`,
    );
  }
  state.handle = watchRn({
    ...platformBundle,
    outfile: outputPath,
    onReady(event) {
      if (event.files) state.fileCount = event.files;
      if (existsSync(outputPath)) {
        state.bundle = readFileSync(outputPath, 'utf-8').replace(SOURCE_MAPPING_URL_RE, '');
        // 초기 build 1회 — 어떤 refresh 보다 먼저라 in-flight 가 없다. generation 가드 불필요(직접 clear).
        state.bundleStale = false;
      } else {
        state.buildError = 'Build produced no output';
      }
      callbacks?.onReady?.(state, event);
    },
    onRebuild(event) {
      state.lastRebuildTime = Date.now();
      if (!event.success) {
        state.buildError = event.error ?? 'Unknown build error';
        callbacks?.onRebuild?.(state, event);
        return;
      }
      state.buildError = null;
      // rebuild 마다 cache invalidate — 다음 요청 시 lazy getter 가 swap fetch.
      state.sourceMapCache = null;
      if (platformBundle.dev) {
        if (event.graphChanged) {
          refresher.markStale();
          return state.refreshBundle().then(() => {
            if (state.buildError) {
              callbacks?.onRebuild?.(state, {
                ...event,
                success: false,
                error: state.buildError,
              });
              return;
            }
            callbacks?.onRebuild?.(state, event);
          });
        }
        if (event.updates && event.updates.length > 0) {
          refresher.markStale();
        }
        callbacks?.onRebuild?.(state, event);
        return;
      }
      // non-dev 경로: 위 `if (platformBundle.dev)` 가 false 라 markStale/refresh 가 호출되지
      // 않는다 → in-flight refresher build 가 없어 generation 가드 불필요(직접 clear). dev in-flight
      // race 는 dev 분기 안에서만 refresher 로 처리.
      if (existsSync(outputPath)) {
        state.bundle = readFileSync(outputPath, 'utf-8').replace(SOURCE_MAPPING_URL_RE, '');
        state.bundleStale = false;
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
  getOrCreate(platform: 'ios' | 'android'): PlatformState;
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
