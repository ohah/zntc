// Metro resolver.resolveRequest → ZNTC onResolve 어댑팅. Metro 시그니처
// `(context, moduleName, platform)` 그대로 호출. 위임 시 sentinel throw 로 ZNTC
// 기본 해석기 fallthrough (Metro 의 `context.resolveRequest()` 호출과 동등).

import { createRequire } from 'node:module';
import { dirname, isAbsolute, resolve } from 'node:path';

import type { ZntcPlugin } from '@zntc/core';

import type { CustomResolver, MetroPlatform } from '../metro-resolver-types.ts';

/** ZNTC 기본 해석기로 위임 위해 사용자 resolver 가 던지는 sentinel error message. */
const DELEGATE_TO_DEFAULT_SENTINEL = '__ZNTC_RN_DELEGATE_TO_DEFAULT__';
const nodeRequire = createRequire(import.meta.url);

export interface MetroResolveRequestOptions {
  resolveRequest: CustomResolver;
  platform: MetroPlatform;
}

function resolveFallbackRequest(moduleName: string, originModulePath: string): string {
  if (isAbsolute(moduleName)) return moduleName;

  const baseDir = originModulePath ? dirname(originModulePath) : process.cwd();
  if (moduleName.startsWith('.')) return resolve(baseDir, moduleName);

  return nodeRequire.resolve(moduleName, { paths: [baseDir] });
}

export function createMetroResolveRequestPlugin(opts: MetroResolveRequestOptions): ZntcPlugin {
  const { resolveRequest, platform } = opts;
  // Metro 호환: web platform 시 null 전달 (RN 외 platform 의 resolver 우회).
  const metroPlatform = platform === 'web' ? null : platform;

  return {
    name: 'zntc:react-native:metro-resolve-request',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        // Default resolver 위임 함수 — 원래 요청 그대로면 ZNTC 기본 해석기로
        // fallthrough, 사용자가 specifier 를 바꾸면 그 바뀐 값으로 해석한다.
        const fallbackResolver: CustomResolver = (_context, moduleName) => {
          if (moduleName !== args.path) {
            return {
              type: 'sourceFile',
              filePath: resolveFallbackRequest(moduleName, args.importer ?? ''),
            };
          }

          throw new Error(DELEGATE_TO_DEFAULT_SENTINEL);
        };
        try {
          const result = resolveRequest(
            {
              originModulePath: args.importer ?? '',
              platform: metroPlatform,
              resolveRequest: fallbackResolver,
            },
            args.path,
            metroPlatform,
          );
          if (result.type === 'sourceFile') return { path: result.filePath };
          if (result.type === 'assetFiles') return { path: result.filePaths[0] ?? args.path };
          // Metro `{ type: 'empty' }` → ZNTC `disabled` flag (빈 모듈로 처리 —
          // ZNTC 가 자동으로 module.exports = {} 출력, 별도 onLoad 불필요).
          if (result.type === 'empty') return { disabled: true };
        } catch (err: unknown) {
          if ((err as Error).message === DELEGATE_TO_DEFAULT_SENTINEL) return null;
          throw err;
        }
        return null;
      });
    },
  };
}
