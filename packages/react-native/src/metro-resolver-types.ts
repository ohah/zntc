// Metro 호환 resolver type. createMetroResolveRequestPlugin (PR #5) 의 caller
// 가 사용자 resolveRequest 를 그대로 받아 ZNTC `onResolve` hook 으로 어댑팅.
//
// `metro-resolver` 의 full type 을 직접 import 하지 않는 이유 — metro-resolver
// 는 optionalDependencies, lazy require. 정의만 ZNTC 측에 두면 type-level 호환
// 검증 가능 + 패키지 미설치 시 declaration 누락 회피.

/**
 * Metro RN runtime platform 식별자. core 의 `Platform` (build target —
 * "browser" / "node" / "neutral" / "react-native") 와 namespace 충돌 회피
 * 위해 `Metro` prefix. `web` 은 caller 가 RN-on-web 시나리오에서 사용 가능.
 */
export type MetroPlatform = 'ios' | 'android' | 'web';

/** Metro `resolveRequest` 의 반환 타입 — Metro 표준 호환. */
export type Resolution =
  | { type: 'sourceFile'; filePath: string }
  | { type: 'assetFiles'; filePaths: readonly string[] }
  | { type: 'empty' };

/**
 * Metro `resolveRequest` 의 첫 번째 인자 (context). Metro 의 ResolutionContext
 * 를 단순화 — `originModulePath`, `platform`, default resolver fallback 만.
 *
 * `context.resolveRequest(context, moduleName, platform)` 호출하면 default
 * resolver 로 위임 (Metro 동작과 동일). 무한 재귀 방지를 위해 호출 시 자기
 * 자신은 제외됨.
 */
export interface ResolutionContext {
  /** 요청한 모듈의 absolute path. */
  originModulePath: string;
  /** 현재 빌드 플랫폼. ios/android 또는 null (default). */
  platform: string | null;
  /** Default resolver — 무한 재귀 방지 시 자기 자신 제외 후 호출. */
  resolveRequest: CustomResolver;
}

/**
 * 사용자 resolveRequest 함수 시그니처 (Metro 호환).
 * - `context.resolveRequest(context, moduleName, platform)` 로 default 위임 가능.
 * - 결과로 Resolution 반환 또는 throw — throw 시 caller (createMetroResolveRequestPlugin)
 *   가 sentinel `__ZNTC_RN_DELEGATE_TO_DEFAULT__` 를 잡아 default resolver fallthrough.
 */
export type CustomResolver = (
  context: ResolutionContext,
  moduleName: string,
  platform: string | null,
) => Resolution;
