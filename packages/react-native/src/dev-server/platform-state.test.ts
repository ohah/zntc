import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import type { WatchHandle } from '@zntc/core';

import { buildRnDevServerOptions } from './options.ts';
import {
  createBundleRefresher,
  createPlatformStateRegistry,
  getCachedSourceMap,
  type PlatformState,
  waitForBuild,
} from './platform-state.ts';

let dir: string;
let entryPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-rn-platform-'));
  mkdirSync(join(dir, 'src'), { recursive: true });
  entryPath = join(dir, 'src/index.ts');
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
    platform: 'ios',
    outputDir: '/tmp/x',
    outputPath: '/tmp/x/bundle.js',
    handle,
    bundle: null,
    bundleStale: false,
    refreshBundle: async () => {},
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: 0,
    ...overrides,
  };
}

describe('createBundleRefresher — in-flight staleness generation guard (Finding #26)', () => {
  function makeHarness() {
    let stale = false;
    let buildCount = 0;
    const resolvers: Array<() => void> = [];
    const refresher = createBundleRefresher({
      // bundle 은 항상 존재 가정 — staleness 만으로 refresh 여부 결정.
      isFresh: () => !stale,
      build: () => {
        buildCount += 1;
        return new Promise<void>((resolve) => resolvers.push(resolve));
      },
      setStale: () => {
        stale = true;
      },
      clearStale: () => {
        stale = false;
      },
    });
    return {
      refresher,
      isStale: () => stale,
      buildCount: () => buildCount,
      finishBuild: (i: number) => resolvers[i]?.(),
    };
  }

  test('in-flight build 중 markStale 재호출 시 완료가 stale 을 clear 하지 않음', async () => {
    const h = makeHarness();
    // 1. 첫 staleness + refresh → build #1 in-flight
    h.refresher.markStale();
    expect(h.isStale()).toBe(true);
    const p1 = h.refresher.refresh();
    expect(h.buildCount()).toBe(1);

    // 2. in-flight 중 두 번째 staleness 신호 (generation bump)
    h.refresher.markStale();

    // 3. build #1 완료 → 새 staleness 가 있었으므로 stale 유지(다음 요청 rebuild). 마스킹 금지.
    h.finishBuild(0);
    await p1;
    expect(h.isStale()).toBe(true);
  });

  test('in-flight 중 markStale 없으면 완료가 stale 을 정상 clear', async () => {
    const h = makeHarness();
    h.refresher.markStale();
    const p1 = h.refresher.refresh();
    h.finishBuild(0);
    await p1;
    expect(h.isStale()).toBe(false);
  });

  test('in-flight refresh 는 coalesce — 동시 refresh 가 build 를 중복 트리거하지 않음', async () => {
    const h = makeHarness();
    h.refresher.markStale();
    const a = h.refresher.refresh();
    const b = h.refresher.refresh();
    expect(h.buildCount()).toBe(1);
    h.finishBuild(0);
    await Promise.all([a, b]);
  });

  test('이미 신선하면 build 스킵', () => {
    const h = makeHarness();
    void h.refresher.refresh();
    expect(h.buildCount()).toBe(0);
  });
});

describe('getCachedSourceMap', () => {
  test('cache 미존재 + handle 결과 → postProcess 반영', () => {
    const handle = {
      stop() {},
      getBundleSourceMap: () => JSON.stringify({ version: 3, sources: ['/node_modules/x/y.js'] }),
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle;
    const state: PlatformState = {
      platform: 'ios',
      outputDir: '/tmp',
      outputPath: '/tmp/b.js',
      handle,
      bundle: null,
      bundleStale: false,
      refreshBundle: async () => {},
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

  test('handle 이 null 반환 → null', () => {
    const handle = {
      stop() {},
      getBundleSourceMap: () => null,
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle;
    const state: PlatformState = {
      platform: 'ios',
      outputDir: '/tmp',
      outputPath: '/tmp/b.js',
      handle,
      bundle: null,
      bundleStale: false,
      refreshBundle: async () => {},
      sourceMapCache: null,
      buildError: null,
      fileCount: 1,
      lastRebuildTime: 0,
    };
    expect(getCachedSourceMap(state)).toBeNull();
  });

  test('이미 cached 값 있으면 handle 호출 안 함', () => {
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
      platform: 'ios',
      outputDir: '/tmp',
      outputPath: '/tmp/b.js',
      handle,
      bundle: null,
      bundleStale: false,
      refreshBundle: async () => {},
      sourceMapCache: '{"v":3}',
      buildError: null,
      fileCount: 1,
      lastRebuildTime: 0,
    };
    expect(getCachedSourceMap(state)).toBe('{"v":3}');
    expect(called).toBe(0);
  });
});

describe('waitForBuild', () => {
  test('bundle 가 set 되면 resolve', async () => {
    const state = fakeState();
    setTimeout(() => {
      state.bundle = 'code;';
    }, 10);
    await waitForBuild(state, 5);
    expect(state.bundle).toBe('code;');
  });

  test('buildError 가 set 되면 resolve', async () => {
    const state = fakeState();
    setTimeout(() => {
      state.buildError = 'boom';
    }, 10);
    await waitForBuild(state, 5);
    expect(state.buildError).toBe('boom');
  });

  test('이미 bundle 이 set 이면 즉시 resolve', async () => {
    const state = fakeState({ bundle: 'code;' });
    await waitForBuild(state, 5);
    expect(state.bundle).toBe('code;');
  });
});

describe('createPlatformStateRegistry — 캐싱', () => {
  test('같은 platform 두 번 요청 시 같은 instance 반환 (cache)', () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const recordedReady: string[] = [];
    const registry = createPlatformStateRegistry(opts, {
      onReady(s) {
        recordedReady.push(s.platform);
      },
    });
    try {
      const a = registry.getOrCreate('ios');
      const b = registry.getOrCreate('ios');
      expect(a).toBe(b);
      expect(registry.platforms.size).toBe(1);
    } finally {
      void registry.stopAll();
    }
  });

  test('ios + android 분리 — 각자 별 instance', () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const registry = createPlatformStateRegistry(opts);
    try {
      const ios = registry.getOrCreate('ios');
      const android = registry.getOrCreate('android');
      expect(ios.platform).toBe('ios');
      expect(android.platform).toBe('android');
      expect(ios).not.toBe(android);
      expect(registry.platforms.size).toBe(2);
    } finally {
      void registry.stopAll();
    }
  });

  test('stopAll → registry 비움', async () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const registry = createPlatformStateRegistry(opts);
    registry.getOrCreate('ios');
    expect(registry.platforms.size).toBe(1);
    await registry.stopAll();
    expect(registry.platforms.size).toBe(0);
  });

  test('multi-platform — ios + android 동시 spawn 후 각자 별 watch handle (Finding #9)', async () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const registry = createPlatformStateRegistry(opts);
    try {
      const ios = registry.getOrCreate('ios');
      const android = registry.getOrCreate('android');
      // 첫 build 둘 다 대기 (동시).
      await Promise.all([waitForBuild(ios), waitForBuild(android)]);
      expect(ios.bundle !== null || ios.buildError !== null).toBe(true);
      expect(android.bundle !== null || android.buildError !== null).toBe(true);
      expect(ios.outputDir).not.toBe(android.outputDir);
    } finally {
      await registry.stopAll();
    }
  });
});

describe('createPlatformState — onReady/onRebuild 콜백 (Finding #7)', () => {
  test('dev HMR rebuild 는 풀 bundle state 를 stale 로 표시하고 필요 시 재생성', async () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      state: PlatformState;
      event: { updates?: Array<{ id: string; code: string }>; graphChanged?: boolean };
    }>();
    const registry = createPlatformStateRegistry(opts, {
      onRebuild(state, event) {
        if (event.updates && event.updates.length > 0) {
          rebuildDone({ state, event });
        }
      },
    });
    try {
      const ios = registry.getOrCreate('ios');
      await waitForBuild(ios);
      const initial = ios.bundle;
      expect(initial).toContain('hi');

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(entryPath, 'console.log("second");\n');

      const { state, event } = await rebuildP;
      expect(event.graphChanged).toBeFalsy();
      expect(state.bundleStale).toBe(true);
      expect(state.bundle).toBe(initial);

      await state.refreshBundle();
      expect(state.bundleStale).toBe(false);
      expect(state.bundle).toContain('second');
    } finally {
      await registry.stopAll();
    }
  }, 10000);

  test('dev graphChanged 는 reload callback 전 풀 bundle 을 갱신', async () => {
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      state: PlatformState;
      event: { success: boolean; graphChanged?: boolean };
    }>();
    const registry = createPlatformStateRegistry(opts, {
      onRebuild(state, event) {
        if (event.graphChanged || !event.success) {
          rebuildDone({ state, event });
        }
      },
    });
    try {
      const ios = registry.getOrCreate('ios');
      await waitForBuild(ios);

      writeFileSync(join(dir, 'src/util.ts'), 'export const value = "graph-second";\n');
      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(entryPath, 'import { value } from "./util";\nconsole.log(value);\n');

      const { state, event } = await rebuildP;
      expect(event.success).toBe(true);
      expect(event.graphChanged).toBe(true);
      expect(state.bundleStale).toBe(false);
      expect(state.bundle).toContain('graph-second');
    } finally {
      await registry.stopAll();
    }
  }, 10000);

  test('stopAll 시 watch handle 의 stop 이 throw 해도 silent', async () => {
    // platform-state.ts 의 stopAll try/catch 분기 검증. handle.stop 이 throw 하면
    // 다른 platform 의 cleanup 이 영향 받지 않아야 함.
    const opts = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
    });
    const registry = createPlatformStateRegistry(opts);
    const ios = registry.getOrCreate('ios');
    // handle.stop 을 throw 로 monkey-patch.
    (ios.handle as unknown as { stop: () => void }).stop = () => {
      throw new Error('simulated stop fail');
    };
    await expect(registry.stopAll()).resolves.toBeUndefined();
    expect(registry.platforms.size).toBe(0);
  });
});
