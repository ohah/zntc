// metro-resolver-types 는 type-only 정의. 실행 코드 0 — runtime 검증할 게 없음.
// 단위 테스트는 type narrowing / discriminated union round-trip 만 (TS 가
// strict mode 에서 reject 하면 fail).

import { describe, expect, test } from 'bun:test';

import type {
  CustomResolver,
  MetroPlatform,
  Resolution,
  ResolutionContext,
} from './metro-resolver-types.ts';

describe('Resolution union', () => {
  test('sourceFile 분기 — filePath 필수', () => {
    const r: Resolution = { type: 'sourceFile', filePath: '/abs/foo.ts' };
    expect(r.type).toBe('sourceFile');
    if (r.type === 'sourceFile') {
      expect(r.filePath).toBe('/abs/foo.ts');
    }
  });

  test('assetFiles 분기 — filePaths readonly array', () => {
    const r: Resolution = {
      type: 'assetFiles',
      filePaths: ['/abs/foo@1x.png', '/abs/foo@2x.png'],
    };
    expect(r.type).toBe('assetFiles');
    if (r.type === 'assetFiles') {
      expect(r.filePaths.length).toBe(2);
    }
  });

  test('empty 분기 — type 만', () => {
    const r: Resolution = { type: 'empty' };
    expect(r.type).toBe('empty');
  });
});

describe('MetroPlatform 타입', () => {
  test('ios / android / web 만 허용 (compile-time)', () => {
    const ios: MetroPlatform = 'ios';
    const android: MetroPlatform = 'android';
    const web: MetroPlatform = 'web';
    expect([ios, android, web]).toEqual(['ios', 'android', 'web']);
  });
});

describe('CustomResolver / ResolutionContext', () => {
  test('sample resolver 가 ResolutionContext + moduleName + platform 받아 Resolution 반환', () => {
    const sampleResolver: CustomResolver = (context, moduleName, platform) => {
      if (moduleName === 'polyfilled') {
        return { type: 'empty' };
      }
      if (moduleName.endsWith('.png')) {
        return { type: 'assetFiles', filePaths: [`/abs/${moduleName}`] };
      }
      // default 위임 — 무한 재귀 방지 위해 자기 자신 제외 후 호출.
      return context.resolveRequest(context, moduleName, platform);
    };
    const defaultResolver: CustomResolver = (_ctx, moduleName) => ({
      type: 'sourceFile',
      filePath: `/default/${moduleName}.ts`,
    });
    const ctx: ResolutionContext = {
      originModulePath: '/abs/origin.ts',
      platform: 'ios',
      resolveRequest: defaultResolver,
    };
    expect(sampleResolver(ctx, 'polyfilled', 'ios')).toEqual({ type: 'empty' });
    expect(sampleResolver(ctx, 'logo.png', 'ios')).toEqual({
      type: 'assetFiles',
      filePaths: ['/abs/logo.png'],
    });
    expect(sampleResolver(ctx, 'react', 'ios')).toEqual({
      type: 'sourceFile',
      filePath: '/default/react.ts',
    });
  });

  test('ResolutionContext.platform null 허용 (default 분기)', () => {
    const ctx: ResolutionContext = {
      originModulePath: '/x',
      platform: null,
      resolveRequest: (_c, m) => ({ type: 'sourceFile', filePath: m }),
    };
    expect(ctx.platform).toBeNull();
  });
});
