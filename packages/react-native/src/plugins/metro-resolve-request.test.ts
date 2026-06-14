import { describe, expect, test } from 'bun:test';

import type { CustomResolver } from '../metro-resolver-types.ts';
import { createMetroResolveRequestPlugin } from './metro-resolve-request.ts';

interface OnResolveHandler {
  (args: { path: string; importer?: string }): { path?: string; disabled?: boolean } | null;
}

function captureHandler(opts: {
  resolveRequest: CustomResolver;
  platform: 'ios' | 'android' | 'web';
}): OnResolveHandler {
  const plugin = createMetroResolveRequestPlugin(opts);
  let captured: OnResolveHandler | null = null;
  const fakeBuild = {
    onResolve(_filter: { filter: RegExp }, handler: OnResolveHandler) {
      captured = handler;
    },
    onResolveContext() {},
    onLoad() {},
    onTransform() {},
  };
  plugin.setup(fakeBuild as never);
  if (!captured) throw new Error('handler not registered');
  return captured;
}

describe('createMetroResolveRequestPlugin', () => {
  test('Resolution.sourceFile → `{ path }`', () => {
    const resolver: CustomResolver = (_ctx, name) => ({
      type: 'sourceFile',
      filePath: `/abs/${name}.ts`,
    });
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(handler({ path: 'react', importer: '/abs/origin.ts' })).toEqual({
      path: '/abs/react.ts',
    });
  });

  test('Resolution.assetFiles → 첫 element path', () => {
    const resolver: CustomResolver = () => ({
      type: 'assetFiles',
      filePaths: ['/abs/a@2x.png', '/abs/a@3x.png'],
    });
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(handler({ path: './a.png', importer: '/abs/origin.ts' })).toEqual({
      path: '/abs/a@2x.png',
    });
  });

  test('Resolution.assetFiles 빈 배열 → null (기본 해석기 위임, bare specifier 누출 금지)', () => {
    const resolver: CustomResolver = () => ({ type: 'assetFiles', filePaths: [] });
    const handler = captureHandler({ resolveRequest: resolver, platform: 'android' });
    // 빈 filePaths 는 해석 실패 — 원래 specifier(./missing.png)를 경로로 반환하면 안 됨.
    expect(handler({ path: './missing.png', importer: '/abs/x' })).toBeNull();
  });

  test('Resolution.empty → `{ disabled: true }`', () => {
    const resolver: CustomResolver = () => ({ type: 'empty' });
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(handler({ path: 'polyfilled', importer: '/abs/x' })).toEqual({ disabled: true });
  });

  test('default resolver 위임 (sentinel throw) → null (ZNTC fallthrough)', () => {
    const resolver: CustomResolver = (ctx, name, platform) =>
      ctx.resolveRequest(ctx, name, platform);
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(handler({ path: 'react', importer: '/abs/x' })).toBeNull();
  });

  test('default resolver 위임 중 absolute specifier 로 교체하면 해당 path 반환', () => {
    const resolver: CustomResolver = (ctx, _name, platform) =>
      ctx.resolveRequest(ctx, '/abs/redux-saga-effects.cjs.js', platform);
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(handler({ path: 'redux-saga/effects', importer: '/abs/origin.ts' })).toEqual({
      path: '/abs/redux-saga-effects.cjs.js',
    });
  });

  test('custom resolver 의 일반 throw 는 propagate', () => {
    const resolver: CustomResolver = () => {
      throw new Error('custom-error');
    };
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(() => handler({ path: 'x', importer: '/abs/y' })).toThrow('custom-error');
  });

  test('platform=web → resolver 에 null 전달 (RN 외 platform 우회)', () => {
    let receivedPlatform: string | null | undefined = 'uninitialized';
    const resolver: CustomResolver = (_ctx, _name, platform) => {
      receivedPlatform = platform;
      return { type: 'empty' };
    };
    const handler = captureHandler({ resolveRequest: resolver, platform: 'web' });
    handler({ path: 'x', importer: '/abs/y' });
    expect(receivedPlatform).toBeNull();
  });

  test('importer 없으면 originModulePath 빈 string', () => {
    let receivedOrigin: string | null = null;
    const resolver: CustomResolver = (ctx, _name, _platform) => {
      receivedOrigin = ctx.originModulePath;
      return { type: 'empty' };
    };
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    handler({ path: 'x' });
    expect(receivedOrigin).toBe('');
  });

  test("Metro 'context.resolveRequest' 호출 — fallback 함수가 sentinel throw", () => {
    let fallbackCalled = false;
    const resolver: CustomResolver = (ctx, name, platform) => {
      // 사용자 resolver 가 default 위임 — fallback 호출.
      try {
        ctx.resolveRequest(ctx, name, platform);
      } catch (_err) {
        fallbackCalled = true;
        throw _err; // sentinel propagate
      }
      return { type: 'empty' };
    };
    const handler = captureHandler({ resolveRequest: resolver, platform: 'ios' });
    expect(handler({ path: 'x', importer: '/abs/y' })).toBeNull();
    expect(fallbackCalled).toBe(true);
  });
});
