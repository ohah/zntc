import { describe, expect, test } from 'bun:test';

import type { RnBundleInput } from '../preset.ts';
import {
  buildRnDevServerOptions,
  type RnDevServerOptions,
  type RnDevServerOptionsInput,
} from './options.ts';

const BUNDLE: RnBundleInput = {
  entry: '/proj/src/index.ts',
  projectRoot: '/proj',
  rnPlatform: 'ios',
  dev: true,
};

function input(
  overrides: Partial<Omit<RnDevServerOptions, 'bundle'>> = {},
): RnDevServerOptionsInput {
  return { bundle: BUNDLE, ...overrides };
}

describe('buildRnDevServerOptions — Metro 호환 default', () => {
  test('port=8081, host=localhost (Metro 기본)', () => {
    const opts = buildRnDevServerOptions(input());
    expect(opts.port).toBe(8081);
    expect(opts.host).toBe('localhost');
  });

  test('terminalActions = true (default)', () => {
    expect(buildRnDevServerOptions(input()).terminalActions).toBe(true);
  });

  test('hmr = true (default)', () => {
    expect(buildRnDevServerOptions(input()).hmr).toBe(true);
  });

  test('symbolicator = undefined (customizeFrame 미지정)', () => {
    expect(buildRnDevServerOptions(input()).symbolicator).toBeUndefined();
  });

  test('bundle reference 그대로 보존 (caller 가 RnBundleInput 책임)', () => {
    expect(buildRnDevServerOptions(input()).bundle).toBe(BUNDLE);
  });
});

describe('buildRnDevServerOptions — override', () => {
  test('port=9000 / host=0.0.0.0 override', () => {
    const opts = buildRnDevServerOptions(input({ port: 9000, host: '0.0.0.0' }));
    expect(opts.port).toBe(9000);
    expect(opts.host).toBe('0.0.0.0');
  });

  test('terminalActions=false override', () => {
    expect(buildRnDevServerOptions(input({ terminalActions: false })).terminalActions).toBe(false);
  });

  test('hmr=false override', () => {
    expect(buildRnDevServerOptions(input({ hmr: false })).hmr).toBe(false);
  });
});

describe('buildRnDevServerOptions — hooks pass-through', () => {
  test('enhanceMiddleware reference 보존', () => {
    const fn: RnDevServerOptions['enhanceMiddleware'] = (mw) => mw;
    expect(buildRnDevServerOptions(input({ enhanceMiddleware: fn })).enhanceMiddleware).toBe(fn);
  });

  test('enhanceMiddleware 미지정 시 undefined', () => {
    expect(buildRnDevServerOptions(input()).enhanceMiddleware).toBeUndefined();
  });

  test('rewriteRequestUrl reference 보존', () => {
    const fn = (url: string) => url + '?ok';
    expect(buildRnDevServerOptions(input({ rewriteRequestUrl: fn })).rewriteRequestUrl).toBe(fn);
  });

  test('symbolicator.customizeFrame 지정 시 객체 생성', () => {
    const fn = async () => ({ collapse: true });
    const opts = buildRnDevServerOptions(input({ symbolicator: { customizeFrame: fn } }));
    expect(opts.symbolicator).toEqual({ customizeFrame: fn });
  });

  test('symbolicator 빈 객체 (customizeFrame 미지정) → undefined 로 정규화', () => {
    expect(buildRnDevServerOptions(input({ symbolicator: {} })).symbolicator).toBeUndefined();
  });
});
