// Metro resolver.resolveRequest → ZTS onResolve 어댑팅. Metro 시그니처
// `(context, moduleName, platform)` 그대로 호출. 위임 시 sentinel throw 로 ZTS
// 기본 해석기 fallthrough (Metro 의 `context.resolveRequest()` 호출과 동등).

import type { ZtsPlugin } from '@zts/core';

import type { CustomResolver, MetroPlatform } from '../metro-resolver-types.ts';

/** ZTS 기본 해석기로 위임 위해 사용자 resolver 가 던지는 sentinel error message. */
const DELEGATE_TO_DEFAULT_SENTINEL = '__ZTS_RN_DELEGATE_TO_DEFAULT__';

export interface MetroResolveRequestOptions {
  resolveRequest: CustomResolver;
  platform: MetroPlatform;
}

export function createMetroResolveRequestPlugin(opts: MetroResolveRequestOptions): ZtsPlugin {
  const { resolveRequest, platform } = opts;
  // Metro 호환: web platform 시 null 전달 (RN 외 platform 의 resolver 우회).
  const metroPlatform = platform === 'web' ? null : platform;

  return {
    name: 'zts:react-native:metro-resolve-request',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        // Default resolver 위임 함수 — Metro 의 `context.resolveRequest()` 동등.
        // throw 시 ZTS 가 catch 후 기본 해석 진행 (return null 과 동일 효과).
        const fallbackResolver = (): never => {
          throw new Error(DELEGATE_TO_DEFAULT_SENTINEL);
        };
        try {
          const result = resolveRequest(
            {
              originModulePath: args.importer ?? '',
              platform: metroPlatform,
              resolveRequest: fallbackResolver as never,
            },
            args.path,
            metroPlatform,
          );
          if (result.type === 'sourceFile') return { path: result.filePath };
          if (result.type === 'assetFiles') return { path: result.filePaths[0] ?? args.path };
          // Metro `{ type: 'empty' }` → ZTS `disabled` flag (빈 모듈로 처리 —
          // ZTS 가 자동으로 module.exports = {} 출력, 별도 onLoad 불필요).
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
