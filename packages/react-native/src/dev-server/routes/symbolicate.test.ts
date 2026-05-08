import { describe, expect, test } from 'bun:test';
import type { ServerResponse } from 'node:http';
import { Readable } from 'node:stream';

import type { WatchHandle } from '@zntc/core';

import type { PlatformState, PlatformStateRegistry } from '../platform-state.ts';
import { handleSymbolicateRequest, isSymbolicateRoute } from './symbolicate.ts';

interface MockRes {
  statusCode?: number;
  payload?: unknown;
  writeHead(c: number): void;
  end(b: string): void;
}
function makeRes(): MockRes {
  return {
    writeHead(c) {
      this.statusCode = c;
    },
    end(b) {
      this.payload = JSON.parse(b);
    },
  };
}

function streamReq(json: string) {
  const r = new Readable({ read() {} });
  r.push(json);
  r.push(null);
  return r;
}

function makeState(bundleMap: string | null = null): PlatformState {
  return {
    platform: 'ios',
    outputDir: '/tmp',
    outputPath: '/tmp/b.js',
    handle: {
      stop() {},
      getBundleSourceMap: () => bundleMap,
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle,
    bundle: null,
    bundleStale: false,
    refreshBundle: async () => {},
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: 0,
  };
}

function fixedRegistry(state: PlatformState): PlatformStateRegistry {
  return {
    platforms: new Map([[state.platform, state]]),
    getOrCreate: () => state,
    async stopAll() {},
  };
}

describe('isSymbolicateRoute', () => {
  test('POST /symbolicate 매치', () =>
    expect(isSymbolicateRoute('/symbolicate', 'POST')).toBe(true));
  test('GET /symbolicate 미매치', () =>
    expect(isSymbolicateRoute('/symbolicate', 'GET')).toBe(false));
  test('/other 미매치', () => expect(isSymbolicateRoute('/other', 'POST')).toBe(false));
});

describe('handleSymbolicateRequest', () => {
  test('invalid JSON → 400', async () => {
    const res = makeRes();
    await handleSymbolicateRequest(
      streamReq('not json') as never,
      res as unknown as ServerResponse,
      new URL('http://x/symbolicate'),
      fixedRegistry(makeState()),
      'ios',
      '/proj',
      undefined,
    );
    expect(res.statusCode).toBe(400);
    expect(res.payload).toEqual({ error: 'Invalid JSON body' });
  });

  test('sourcemap 없음 → 200 + fallback (frame 그대로)', async () => {
    const res = makeRes();
    await handleSymbolicateRequest(
      streamReq(
        JSON.stringify({
          stack: [{ file: 'bundle.js', lineNumber: 5, column: 1, methodName: 'foo' }],
        }),
      ) as never,
      res as unknown as ServerResponse,
      new URL('http://x/symbolicate'),
      fixedRegistry(makeState(null)),
      'ios',
      '/proj',
      undefined,
    );
    expect(res.statusCode).toBe(200);
    expect(res.payload).toEqual({
      stack: [{ file: 'bundle.js', lineNumber: 5, column: 1, methodName: 'foo' }],
      codeFrame: null,
    });
  });

  test('invalid sourcemap JSON → 200 + fallback', async () => {
    const res = makeRes();
    await handleSymbolicateRequest(
      streamReq(JSON.stringify({ stack: [] })) as never,
      res as unknown as ServerResponse,
      new URL('http://x/symbolicate'),
      fixedRegistry(makeState('not a json sourcemap')),
      'ios',
      '/proj',
      undefined,
    );
    expect(res.statusCode).toBe(200);
    expect((res.payload as { stack: unknown[] }).stack).toEqual([]);
    expect((res.payload as { codeFrame: unknown }).codeFrame).toBeNull();
  });

  test('정상 sourcemap — frame 역매핑 후 200', async () => {
    const sourceMap = JSON.stringify({
      version: 3,
      sources: ['src/foo.ts'],
      names: ['bar'],
      mappings: 'AAAA',
    });
    const res = makeRes();
    await handleSymbolicateRequest(
      streamReq(
        JSON.stringify({
          stack: [{ file: 'bundle.js', lineNumber: 1, column: 0, methodName: null }],
        }),
      ) as never,
      res as unknown as ServerResponse,
      new URL('http://x/symbolicate?platform=ios'),
      fixedRegistry(makeState(sourceMap)),
      'ios',
      '/proj',
      undefined,
    );
    expect(res.statusCode).toBe(200);
    const stack = (res.payload as { stack: Array<{ file: string }> }).stack;
    expect(stack[0]?.file).toContain('foo.ts');
  });

  test('customizeFrame collapse:true → 응답에 collapse 포함', async () => {
    const sourceMap = JSON.stringify({
      version: 3,
      sources: ['src/foo.ts'],
      names: [],
      mappings: 'AAAA',
    });
    const res = makeRes();
    await handleSymbolicateRequest(
      streamReq(
        JSON.stringify({
          stack: [{ file: 'bundle.js', lineNumber: 1, column: 0 }],
        }),
      ) as never,
      res as unknown as ServerResponse,
      new URL('http://x/symbolicate'),
      fixedRegistry(makeState(sourceMap)),
      'ios',
      '/proj',
      async () => ({ collapse: true }),
    );
    const stack = (res.payload as { stack: Array<{ collapse?: boolean }> }).stack;
    expect(stack[0]?.collapse).toBe(true);
  });

  test('platform query parsing — invalid → default', async () => {
    const recorded: string[] = [];
    const registry: PlatformStateRegistry = {
      platforms: new Map(),
      getOrCreate(p) {
        recorded.push(p);
        return makeState();
      },
      async stopAll() {},
    };
    await handleSymbolicateRequest(
      streamReq(JSON.stringify({ stack: [] })) as never,
      makeRes() as unknown as ServerResponse,
      new URL('http://x/symbolicate?platform=web'),
      registry,
      'android',
      '/proj',
      undefined,
    );
    expect(recorded).toEqual(['android']);
  });
});
