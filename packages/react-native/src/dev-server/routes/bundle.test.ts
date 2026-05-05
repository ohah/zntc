import { describe, expect, test } from 'bun:test';
import type { IncomingMessage, ServerResponse } from 'node:http';

import type { WatchHandle } from '@zts/core';

import type { PlatformState, PlatformStateRegistry } from '../platform-state.ts';
import {
  handleBundleRequest,
  handleHmrMapRequest,
  handleMapRequest,
  isBundleRoute,
  isHmrMapRoute,
  isMapRoute,
} from './bundle.ts';

interface MockRes {
  statusCode?: number;
  headers?: Record<string, unknown>;
  chunks: string[];
  ended: boolean;
  writeHead(c: number, h?: Record<string, unknown>): void;
  write(s: string): void;
  end(s?: string): void;
}
function makeRes(): MockRes {
  return {
    chunks: [],
    ended: false,
    writeHead(c, h) {
      this.statusCode = c;
      if (h) this.headers = h;
    },
    write(s) {
      this.chunks.push(s);
    },
    end(s) {
      if (s) this.chunks.push(s);
      this.ended = true;
    },
  };
}

function makeReq(host = 'x:8081', accept?: string): IncomingMessage {
  return {
    headers: { host, ...(accept ? { accept } : {}) },
  } as unknown as IncomingMessage;
}

function fakeHandle(
  opts: {
    bundleMap?: string | null;
    hmrMaps?: Record<string, string>;
  } = {},
): WatchHandle {
  return {
    stop() {},
    getBundleSourceMap: () => opts.bundleMap ?? null,
    getHmrSourceMap: (id: string) => opts.hmrMaps?.[id] ?? null,
  } as unknown as WatchHandle;
}

function makeState(overrides: Partial<PlatformState> = {}): PlatformState {
  return {
    platform: 'ios',
    outputDir: '/tmp',
    outputPath: '/tmp/b.js',
    handle: fakeHandle(),
    bundle: null,
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: 0,
    ...overrides,
  };
}

function fixedRegistry(state: PlatformState): PlatformStateRegistry {
  const map = new Map<string, PlatformState>([[state.platform, state]]);
  return {
    platforms: map,
    getOrCreate: () => state,
    async stopAll() {
      map.clear();
    },
  };
}

describe('isBundleRoute / isMapRoute / isHmrMapRoute', () => {
  test('/index.bundle / .bundle.js / .map / .bundle.map 매치', () => {
    expect(isBundleRoute('/index.bundle')).toBe(true);
    expect(isBundleRoute('/index.bundle.js')).toBe(true);
    expect(isMapRoute('/index.map')).toBe(true);
    expect(isMapRoute('/index.bundle.map')).toBe(true);
  });

  test('/__zts_hmr_map/<id>', () => {
    expect(isHmrMapRoute('/__zts_hmr_map/foo')).toBe(true);
    expect(isHmrMapRoute('/foo')).toBe(false);
  });
});

describe('handleBundleRequest', () => {
  test('buildError → 200 + throw new Error JS', async () => {
    const state = makeState({ buildError: 'syntax error' });
    const registry = fixedRegistry(state);
    const res = makeRes();
    await handleBundleRequest(
      makeReq() as never,
      res as unknown as ServerResponse,
      new URL('http://x/index.bundle?platform=ios'),
      registry,
      'ios',
      '/proj',
      8081,
    );
    expect(res.statusCode).toBe(200);
    expect(res.chunks.join('')).toContain('throw new Error');
    expect(res.chunks.join('')).toContain('syntax error');
  });

  test('bundle === null + buildError === null + already-set bundle 없음 → 503', async () => {
    // buildError 도 bundle 도 둘 다 null 이면 waitForBuild polling 으로 빠짐 — 즉시
    // 503 검증을 위해 두 번째 path: bundle 이 한 번도 없는 상태에서 setTimeout 으로
    // buildError 를 null 인 채로 남기는 것은 무한 polling 이라 실용적이지 않음.
    // 대신 bundle 이 빈 문자열 인 케이스를 검증.
    const state = makeState({ bundle: '' });
    const registry = fixedRegistry(state);
    const res = makeRes();
    await handleBundleRequest(
      makeReq() as never,
      res as unknown as ServerResponse,
      new URL('http://x/index.bundle'),
      registry,
      'ios',
      '/proj',
      8081,
    );
    expect(res.statusCode).toBe(503);
  });

  test('정상 bundle — plain (sourceMappingURL + sourceURL 주입)', async () => {
    const state = makeState({ bundle: 'console.log(1);' });
    const registry = fixedRegistry(state);
    const res = makeRes();
    await handleBundleRequest(
      makeReq('x:8081') as never,
      res as unknown as ServerResponse,
      new URL('http://x:8081/index.bundle?platform=ios&dev=true'),
      registry,
      'ios',
      '/proj',
      8081,
    );
    expect(res.statusCode).toBe(200);
    expect(res.headers!['Content-Type']).toBe('application/javascript; charset=UTF-8');
    expect(res.headers!['X-React-Native-Project-Root']).toBe('/proj');
    const body = res.chunks.join('');
    expect(body).toContain('console.log(1);');
    expect(body).toContain('//# sourceMappingURL=http://x:8081/index.map?platform=ios&dev=true');
    expect(body).toContain('//# sourceURL=');
  });

  test('multipart/mixed accept → progress + bundle chunks', async () => {
    const state = makeState({ bundle: 'code;', fileCount: 3 });
    const registry = fixedRegistry(state);
    const res = makeRes();
    await handleBundleRequest(
      makeReq('x:8081', 'multipart/mixed') as never,
      res as unknown as ServerResponse,
      new URL('http://x:8081/index.bundle?platform=ios'),
      registry,
      'ios',
      '/proj',
      8081,
    );
    expect(res.statusCode).toBe(200);
    expect(res.headers!['Content-Type'] as string).toContain('multipart/mixed');
    const all = res.chunks.join('');
    expect(all).toContain('{"done":3,"total":3}');
    expect(all).toContain('X-Metro-Files-Changed-Count: 3');
    expect(all).toContain('X-Metro-Delta-ID:');
    expect(all).toContain('code;');
  });

  test('platform=android query → registry getOrCreate 호출', async () => {
    const state = makeState({ platform: 'android', bundle: 'x' });
    const map = new Map<string, PlatformState>();
    const recordedRequests: string[] = [];
    const registry: PlatformStateRegistry = {
      platforms: map,
      getOrCreate(p) {
        recordedRequests.push(p);
        map.set(p, state);
        return state;
      },
      async stopAll() {},
    };
    const res = makeRes();
    await handleBundleRequest(
      makeReq() as never,
      res as unknown as ServerResponse,
      new URL('http://x/index.bundle?platform=android'),
      registry,
      'ios',
      '/proj',
      8081,
    );
    expect(recordedRequests).toEqual(['android']);
  });

  test('platform 미지정 → defaultPlatform', async () => {
    const state = makeState({ bundle: 'x' });
    const recorded: string[] = [];
    const registry: PlatformStateRegistry = {
      platforms: new Map(),
      getOrCreate(p) {
        recorded.push(p);
        return state;
      },
      async stopAll() {},
    };
    await handleBundleRequest(
      makeReq() as never,
      makeRes() as unknown as ServerResponse,
      new URL('http://x/index.bundle'),
      registry,
      'android',
      '/proj',
      8081,
    );
    expect(recorded).toEqual(['android']);
  });

  test('platform query 가 invalid → defaultPlatform', async () => {
    const state = makeState({ bundle: 'x' });
    const recorded: string[] = [];
    const registry: PlatformStateRegistry = {
      platforms: new Map(),
      getOrCreate(p) {
        recorded.push(p);
        return state;
      },
      async stopAll() {},
    };
    await handleBundleRequest(
      makeReq() as never,
      makeRes() as unknown as ServerResponse,
      new URL('http://x/index.bundle?platform=web'),
      registry,
      'ios',
      '/proj',
      8081,
    );
    expect(recorded).toEqual(['ios']);
  });
});

describe('handleMapRequest', () => {
  test('cached source map → 200 + JSON', () => {
    const state = makeState({
      handle: fakeHandle({
        bundleMap: JSON.stringify({ version: 3, sources: ['a.js'] }),
      }),
    });
    const registry = fixedRegistry(state);
    const res = makeRes();
    handleMapRequest(
      {} as never,
      res as unknown as ServerResponse,
      new URL('http://x/index.map?platform=ios'),
      registry,
      'ios',
    );
    expect(res.statusCode).toBe(200);
    expect(res.headers!['Content-Type']).toBe('application/json');
    expect(JSON.parse(res.chunks.join('')).version).toBe(3);
  });

  test('source map 없음 → 404', () => {
    const state = makeState();
    const registry = fixedRegistry(state);
    const res = makeRes();
    handleMapRequest(
      {} as never,
      res as unknown as ServerResponse,
      new URL('http://x/index.map'),
      registry,
      'ios',
    );
    expect(res.statusCode).toBe(404);
  });
});

describe('handleHmrMapRequest', () => {
  test('module 매치 → 200 + JSON', () => {
    const state = makeState({
      handle: fakeHandle({ hmrMaps: { 'src/x.ts': '{"v":3,"id":"x"}' } }),
    });
    const registry = fixedRegistry(state);
    const res = makeRes();
    handleHmrMapRequest(
      {} as never,
      res as unknown as ServerResponse,
      new URL('http://x/__zts_hmr_map/src%2Fx.ts?platform=ios'),
      registry,
      'ios',
    );
    expect(res.statusCode).toBe(200);
    expect(res.chunks.join('')).toContain('"id":"x"');
  });

  test('module 미매치 → 404', () => {
    const state = makeState();
    const registry = fixedRegistry(state);
    const res = makeRes();
    handleHmrMapRequest(
      {} as never,
      res as unknown as ServerResponse,
      new URL('http://x/__zts_hmr_map/missing'),
      registry,
      'ios',
    );
    expect(res.statusCode).toBe(404);
  });
});
