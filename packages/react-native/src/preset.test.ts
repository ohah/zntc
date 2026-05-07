import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import type { ZntcPlugin } from '@zntc/core';

import { buildRnBundleOptions, type RnBundleInput } from './preset.ts';
import { RN_GLOBAL_IDENTIFIERS } from './rn-constants.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-rn-preset-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function baseInput(overrides: Partial<RnBundleInput> = {}): RnBundleInput {
  return {
    entry: 'src/index.ts',
    projectRoot: dir,
    rnPlatform: 'ios',
    dev: false,
    ...overrides,
  };
}

describe('buildRnBundleOptions — 기본 RN preset 필드', () => {
  test('entry 가 absolute path 로 정규화', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.entryPoints).toEqual([join(dir, 'src/index.ts')]);
  });

  test("platform = 'react-native'", () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.platform).toBe('react-native');
  });

  test('RN-specific 자동 활성 필드 (target/flow/jsxInJs/configurableExports/strictExecutionOrder/workletTransform/codegenTransform)', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.target).toBe('es5');
    expect(opts.flow).toBe(true);
    expect(opts.jsxInJs).toBe(true);
    expect(opts.configurableExports).toBe(true);
    expect(opts.strictExecutionOrder).toBe(true);
    expect(opts.workletTransform).toBe(true);
    expect(opts.codegenTransform).toBe(true);
  });

  test('emitDiskSourcemap — dev 시 false, prod 시 true', () => {
    expect(buildRnBundleOptions(baseInput({ dev: true })).emitDiskSourcemap).toBe(false);
    expect(buildRnBundleOptions(baseInput({ dev: false })).emitDiskSourcemap).toBe(true);
  });

  test('globalIdentifiers — RN_GLOBAL_IDENTIFIERS 의 snapshot', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.globalIdentifiers).toEqual([...RN_GLOBAL_IDENTIFIERS]);
  });

  test('mainFields — react-native / browser / module / main', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.mainFields).toEqual(['react-native', 'browser', 'module', 'main']);
  });
});

describe('buildRnBundleOptions — platform 분기 (resolveExtensions)', () => {
  test('iOS — `.ios.*` 가 prefix', () => {
    const opts = buildRnBundleOptions(baseInput({ rnPlatform: 'ios' }));
    expect(opts.resolveExtensions?.[0]).toBe('.ios.ts');
    expect(opts.resolveExtensions?.[1]).toBe('.ios.tsx');
    expect(opts.resolveExtensions).toContain('.native.ts');
    expect(opts.resolveExtensions).toContain('.ts');
  });

  test('Android — `.android.*` 가 prefix', () => {
    const opts = buildRnBundleOptions(baseInput({ rnPlatform: 'android' }));
    expect(opts.resolveExtensions?.[0]).toBe('.android.ts');
    expect(opts.resolveExtensions?.[1]).toBe('.android.tsx');
    expect(opts.resolveExtensions).toContain('.native.ts');
  });
});

describe('buildRnBundleOptions — define / banner / footer / polyfills', () => {
  test('define — __DEV__ + process.env.NODE_ENV + Expo Router env + EXPO_OS', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: true, rnPlatform: 'android' }));
    expect(opts.define?.__DEV__).toBe('true');
    expect(opts.define?.['process.env.NODE_ENV']).toBe('"development"');
    // EXPO_ROUTER_APP_ROOT 는 projectRoot 의 `app/` 절대 경로 — `_ctx.{ios,android,web}.js`
    // 가 node_modules 안에 있어 importer 기준 상대 경로면 ctx 매치 0 → "Welcome to Expo"
    // fallback 화면 트리거됨.
    expect(opts.define?.['process.env.EXPO_ROUTER_APP_ROOT']).toBe(
      JSON.stringify(join(dir, 'app')),
    );
    expect(opts.define?.['process.env.EXPO_OS']).toBe('"android"');
    expect(opts.define?.global).toBe('__ZNTC_RN_GLOBAL__');
  });

  test('define — prod 시 NODE_ENV=production', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: false }));
    expect(opts.define?.__DEV__).toBe('false');
    expect(opts.define?.['process.env.NODE_ENV']).toBe('"production"');
  });

  test('banner — RN prelude 4 핵심 라인 포함 (top-level globalThis assignment 없음 — iOS 26.4 회피)', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: true }));
    expect(opts.banner).toContain('__BUNDLE_START_TIME__');
    expect(opts.banner).toContain('__DEV__=true');
    expect(opts.banner).toContain('__ZNTC_RN_GLOBAL__');
    // __ZNTC_RN_BUNDLER__ 는 footer 의 IIFE 안에서 set — banner 에 직접 두면 iOS 26.4+
    // Hermes 가 spec global lazy registration trigger.
    expect(opts.banner).not.toContain('globalThis.__ZNTC_RN_BUNDLER__');
    expect(opts.banner).not.toContain('__BUNGAE_');
  });

  test('bannerExtras — RN prelude 끝에 append', () => {
    const opts = buildRnBundleOptions(
      baseInput({ bannerExtras: 'globalThis.__APP_VERSION__="1.0";' }),
    );
    expect(opts.banner).toContain('__APP_VERSION__');
    expect(opts.banner?.endsWith('globalThis.__APP_VERSION__="1.0";')).toBe(true);
  });

  test('dev=true — footer 에 IIFE-wrapped __ZNTC_RN_BUNDLER__ flag + DevLoadingView hide 포함', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: true }));
    // top-level globalThis assignment 회피 — IIFE 안에서 set
    expect(opts.footer).toContain('__ZNTC_RN_BUNDLER__');
    expect(opts.footer).toMatch(/\(function\(g\)\{g\.__ZNTC_RN_BUNDLER__/);
    expect(opts.footer).toContain('DevLoadingView.hide');
  });

  test('dev=false — footer 에 IIFE-wrapped __ZNTC_RN_BUNDLER__ flag (DevLoadingView 없음)', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: false }));
    // prod 도 IIFE flag 는 emit (iOS 26.4 spec global trigger 회피 + identifier 표식 유지)
    expect(opts.footer).toContain('__ZNTC_RN_BUNDLER__');
    expect(opts.footer).toMatch(/\(function\(g\)\{g\.__ZNTC_RN_BUNDLER__/);
    // dev-only 는 부재
    expect(opts.footer).not.toContain('DevLoadingView.hide');
  });

  test('polyfills — resolveRnPolyfills miss 시 미정의 (caller 가 default 빈 배열)', () => {
    const opts = buildRnBundleOptions(baseInput());
    // Fixture 에 RN 미설치 — polyfills 없음
    expect(opts.polyfills).toBeUndefined();
  });

  test('extra.polyfills — 사용자 추가 polyfill 이 projectRoot 기준 절대화 + preset 결과에 추가', () => {
    const opts = buildRnBundleOptions(
      baseInput({ extra: { polyfills: ['./shims/myPolyfill.js'] } }),
    );
    expect(opts.polyfills).toEqual([join(dir, 'shims/myPolyfill.js')]);
  });

  test('extra.polyfills — 절대 경로 그대로 보존', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { polyfills: ['/abs/some/poly.js'] } }));
    expect(opts.polyfills).toEqual(['/abs/some/poly.js']);
  });

  test('extra.polyfills — 빈 배열은 polyfills 미정의 (preset 의 RN polyfill 도 미설치 fixture)', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { polyfills: [] } }));
    expect(opts.polyfills).toBeUndefined();
  });

  test('extra.extraVars — banner 에 `var <key>=<JSON.stringify(value)>` inject', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        extra: {
          extraVars: { __APP_VERSION__: '1.2.3', __FEATURE_X__: true, __COUNT__: 42 },
        },
      }),
    );
    expect(opts.banner).toContain('var __APP_VERSION__="1.2.3";');
    expect(opts.banner).toContain('var __FEATURE_X__=true;');
    expect(opts.banner).toContain('var __COUNT__=42;');
  });

  test('extra.extraVars — prelude reserved 식별자 5종 모두 skip (Hermes 재선언 SyntaxError 방지)', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        extra: {
          extraVars: {
            __DEV__: false,
            global: 'x',
            process: 'y',
            __BUNDLE_START_TIME__: 0,
            __ZNTC_RN_GLOBAL__: 'z',
            __OK__: 1,
          },
        },
      }),
    );
    // baseline (extraVars 없는 옵션) 의 var declaration count 그대로 — extraVars
    // 가 reserved 식별자를 재선언하지 않는지 정확히 검증.
    const baseline = buildRnBundleOptions(baseInput()).banner!;
    for (const id of [
      '__DEV__',
      'global',
      'process',
      '__BUNDLE_START_TIME__',
      '__ZNTC_RN_GLOBAL__',
    ]) {
      const re = new RegExp(`var ${id}=`, 'g');
      expect((opts.banner?.match(re) ?? []).length).toBe((baseline.match(re) ?? []).length);
    }
    expect(opts.banner).toContain('var __OK__=1;');
  });

  test('extra.extraVars — 빈 객체 → banner 가 baseline 과 동일', () => {
    const baseline = buildRnBundleOptions(baseInput()).banner!;
    const opts = buildRnBundleOptions(baseInput({ extra: { extraVars: {} } }));
    expect(opts.banner).toBe(baseline);
  });

  test('extra.extraVars — bannerExtras 와 함께 사용 시 extraVars 가 먼저, bannerExtras 가 뒤', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        bannerExtras: 'globalThis.__LATE__=1;',
        extra: { extraVars: { __EARLY__: 1 } },
      }),
    );
    const earlyIdx = opts.banner!.indexOf('__EARLY__');
    const lateIdx = opts.banner!.indexOf('__LATE__');
    expect(earlyIdx).toBeGreaterThan(0);
    expect(lateIdx).toBeGreaterThan(earlyIdx);
  });

  test('runBeforeMain — InitializeCore 미해결 시 미정의', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.runBeforeMain).toBeUndefined();
  });

  test('extra.prelude — 사용자 prelude 가 projectRoot 기준 절대화 + runBeforeMain 에 append', () => {
    const opts = buildRnBundleOptions(
      baseInput({ extra: { prelude: ['./shims/extra-prelude.js'] } }),
    );
    expect(opts.runBeforeMain).toEqual([join(dir, 'shims/extra-prelude.js')]);
  });

  test('extra.prelude — 절대 경로 그대로 보존 + 다중 항목 순서 보존', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        extra: { prelude: ['/abs/early.js', './relative-late.js'] },
      }),
    );
    expect(opts.runBeforeMain).toEqual(['/abs/early.js', join(dir, 'relative-late.js')]);
  });

  test('extra.prelude — 빈 배열은 runBeforeMain 미정의 (preset 의 InitializeCore 도 미설치 fixture)', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { prelude: [] } }));
    expect(opts.runBeforeMain).toBeUndefined();
  });

  test('extra.inlineSourceMap=true — sourcemapMode=inline (#2605 audit P1)', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { inlineSourceMap: true } }));
    expect(opts.sourcemapMode).toBe('inline');
  });

  test('extra.inlineSourceMap=false 또는 미지정 — sourcemapMode 미설정', () => {
    const a = buildRnBundleOptions(baseInput({ extra: { inlineSourceMap: false } }));
    expect(a.sourcemapMode).toBeUndefined();
    const b = buildRnBundleOptions(baseInput({ extra: {} }));
    expect(b.sourcemapMode).toBeUndefined();
  });

  test('extra.sourceRoot — Metro sourcemapSourcesRoot 호환', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { sourceRoot: '/abs/proj' } }));
    expect(opts.sourceRoot).toBe('/abs/proj');
  });

  test('extra.sourceRoot 미지정 — preset.sourceRoot 미설정', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.sourceRoot).toBeUndefined();
  });

  test('extra.silentConsoleErrorPatterns — Metro server.silentConsoleErrorPatterns 호환', () => {
    const patterns = ['^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$'];
    const opts = buildRnBundleOptions(
      baseInput({ extra: { silentConsoleErrorPatterns: patterns } }),
    );
    expect(opts.silentConsoleErrorPatterns).toEqual(patterns);
  });

  test('extra.silentConsoleErrorPatterns — 빈 배열 또는 미지정 시 미설정', () => {
    const a = buildRnBundleOptions(baseInput({ extra: { silentConsoleErrorPatterns: [] } }));
    expect(a.silentConsoleErrorPatterns).toBeUndefined();
    const b = buildRnBundleOptions(baseInput());
    expect(b.silentConsoleErrorPatterns).toBeUndefined();
  });
});

describe('buildRnBundleOptions — dev mode 분기 (jsx / devMode / reactRefresh / collectModuleCodes)', () => {
  test('dev=true — jsx=automatic-dev / devMode / reactRefresh / collectModuleCodes 모두 활성', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: true }));
    expect(opts.jsx).toBe('automatic-dev');
    expect(opts.devMode).toBe(true);
    expect(opts.reactRefresh).toBe(true);
    expect(opts.collectModuleCodes).toBe(true);
  });

  test('dev=false — jsx 미정의 (NAPI default), devMode/reactRefresh/collectModuleCodes 미설정', () => {
    const opts = buildRnBundleOptions(baseInput({ dev: false }));
    expect(opts.jsx).toBeUndefined();
    expect(opts.devMode).toBeUndefined();
    expect(opts.reactRefresh).toBeUndefined();
    expect(opts.collectModuleCodes).toBeUndefined();
  });
});

describe('buildRnBundleOptions — plugins (asset/optional-babel/require-context/[+metro-resolve])', () => {
  test('기본 2 plugin (asset/require-context)', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.plugins?.length).toBe(2);
    const names = opts.plugins?.map((p) => p.name);
    expect(names).toEqual(['zntc:react-native:runtime', 'zntc:react-native:require-context']);
  });

  test('native 외 inline babel plugin 지정 시 babel plugin 추가', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        extra: {
          babel: { plugins: ['nativewind/babel'] },
        },
      }),
    );
    expect(opts.plugins?.map((p) => p.name)).toEqual([
      'zntc:react-native:runtime',
      'zntc:react-native:babel-transform',
      'zntc:react-native:require-context',
    ]);
  });

  test('extra.metroResolveRequest 지정 시 3 plugin (metro-resolve-request 추가)', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        extra: {
          metroResolveRequest: () => ({ type: 'empty' }),
        },
      }),
    );
    expect(opts.plugins?.length).toBe(3);
    expect(opts.plugins?.[2]?.name).toBe('zntc:react-native:metro-resolve-request');
  });

  test('extra.additionalPlugins → plugins 끝에 append', () => {
    const userPlugin: ZntcPlugin = { name: 'user:custom', setup() {} };
    const opts = buildRnBundleOptions(
      baseInput({
        extra: {
          additionalPlugins: [userPlugin],
        },
      }),
    );
    expect(opts.plugins?.length).toBe(3);
    expect(opts.plugins?.[2]).toBe(userPlugin);
  });
});

describe('buildRnBundleOptions — extra (watchFolders / blockList / fallback)', () => {
  test('watchFolders — 지정 시 absolute path 로 정규화', () => {
    const opts = buildRnBundleOptions(
      baseInput({ extra: { watchFolders: ['./shared', '/abs/other'] } }),
    );
    expect(opts.watchFolders).toEqual([join(dir, 'shared'), '/abs/other']);
  });

  test('blockList — 빈 배열은 미설정', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { blockList: [] } }));
    expect(opts.blockList).toBeUndefined();
  });

  test('blockList — 지정 시 그대로', () => {
    const re = /\.test\.ts$/;
    const opts = buildRnBundleOptions(baseInput({ extra: { blockList: [re, 'string-pat'] } }));
    expect(opts.blockList).toEqual([re, 'string-pat']);
  });

  test('fallback — 빈 객체는 미설정', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { fallback: {} } }));
    expect(opts.fallback).toBeUndefined();
  });

  test('fallback — 지정 시 그대로', () => {
    const opts = buildRnBundleOptions(
      baseInput({ extra: { fallback: { crypto: '/abs/crypto-shim', fs: false } } }),
    );
    expect(opts.fallback).toEqual({ crypto: '/abs/crypto-shim', fs: false });
  });
});

describe('buildRnBundleOptions — loader / alias', () => {
  test("loader — assetExts 마다 'file'", () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.loader?.['.png']).toBe('file');
    expect(opts.loader?.['.jpg']).toBe('file');
    expect(opts.loader?.['.svg']).toBe('file');
  });

  test('loader — Metro 호환 default 폰트/이미지 확장자 모두 등록 (#2605 audit)', () => {
    const opts = buildRnBundleOptions(baseInput());
    // 폰트 — RN 흔한 use case (.woff/.woff2)
    expect(opts.loader?.['.woff']).toBe('file');
    expect(opts.loader?.['.woff2']).toBe('file');
    // 이미지 — bmp/ico/avif 추가
    expect(opts.loader?.['.bmp']).toBe('file');
    expect(opts.loader?.['.ico']).toBe('file');
    expect(opts.loader?.['.avif']).toBe('file');
    // 비디오 — webm/mov
    expect(opts.loader?.['.webm']).toBe('file');
    expect(opts.loader?.['.mov']).toBe('file');
    // 오디오 — aac/wav
    expect(opts.loader?.['.aac']).toBe('file');
    expect(opts.loader?.['.wav']).toBe('file');
    // 문서 — yaml/yml
    expect(opts.loader?.['.yaml']).toBe('file');
    expect(opts.loader?.['.yml']).toBe('file');
  });

  test('loader — assetExts override 적용', () => {
    const opts = buildRnBundleOptions(baseInput({ extra: { assetExts: ['.webp', '.woff2'] } }));
    expect(Object.keys(opts.loader ?? {}).sort()).toEqual(['.webp', '.woff2']);
  });

  test('alias — 빈 객체 (asset registry self-cycle 회피, comment 참조)', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.alias).toEqual({});
  });
});

describe('buildRnBundleOptions — override (deep merge)', () => {
  test('define — preset 위에 user override 합쳐짐 (deep merge)', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        override: { define: { __MY_FLAG__: '"on"' } },
      }),
    );
    expect(opts.define?.__DEV__).toBeDefined();
    expect(opts.define?.__MY_FLAG__).toBe('"on"');
  });

  test('plugins — override 가 array 라 replace (deep merge 안 함)', () => {
    const customPlugins: ZntcPlugin[] = [{ name: 'user:only', setup() {} }];
    const opts = buildRnBundleOptions(
      baseInput({
        override: { plugins: customPlugins },
      }),
    );
    expect(opts.plugins).toBe(customPlugins);
  });

  test('primitive override — replace', () => {
    const opts = buildRnBundleOptions(baseInput({ override: { minify: true, target: 'es2020' } }));
    expect(opts.minify).toBe(true);
    expect(opts.target).toBe('es2020');
  });

  test('override 의 nested object — deep merge', () => {
    const opts = buildRnBundleOptions(
      baseInput({
        override: {
          loader: { '.graphql': 'text' },
        },
      }),
    );
    expect(opts.loader?.['.png']).toBe('file');
    expect(opts.loader?.['.graphql']).toBe('text');
  });
});

describe('buildRnBundleOptions — workletPluginVersion', () => {
  test('input override 우선', () => {
    const opts = buildRnBundleOptions(baseInput({ workletPluginVersion: '0.1.2' }));
    expect(opts.workletPluginVersion).toBe('0.1.2');
  });

  test('react-native-worklets 미설치 시 미정의', () => {
    const opts = buildRnBundleOptions(baseInput());
    expect(opts.workletPluginVersion).toBeUndefined();
  });
});

describe('buildRnBundleOptions — sourcemap / minify', () => {
  test('sourcemap default — dev 따라감', () => {
    expect(buildRnBundleOptions(baseInput({ dev: true })).sourcemap).toBe(true);
    expect(buildRnBundleOptions(baseInput({ dev: false })).sourcemap).toBe(false);
  });

  test('sourcemap explicit override', () => {
    expect(buildRnBundleOptions(baseInput({ dev: false, sourcemap: true })).sourcemap).toBe(true);
  });

  test('minify default = false', () => {
    expect(buildRnBundleOptions(baseInput()).minify).toBe(false);
  });

  test('minify explicit', () => {
    expect(buildRnBundleOptions(baseInput({ minify: true })).minify).toBe(true);
  });
});
