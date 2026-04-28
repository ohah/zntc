/**
 * Schema sync 테스트 공통 allowlist — `BuildOptionsCommon` 에 정의되어 있지만 사용자가 직접
 * 명시할 일 없는 **NAPI/internal/번들러-전용** 옵션 집합.
 *
 * 사용처:
 *  - `packages/core/src/typo-suggest.test.ts`: `KNOWN_CONFIG_KEYS` 미포함 정당화 (사용자가
 *    `zts.config.*` 에 적을 일 없으므로 typo 검출 대상 아님)
 *  - `packages/core/bin/zts-cli-schema-sync.test.ts`: CLI flag 미노출 정당화
 *
 * Zig DTO sync (`src/transpile_options_dto_test.zig:ts_buildoptions_only_allowlist`) 는 별
 * 언어라 별도 유지 — 새 internal 키 추가 시 양쪽 모두 갱신 필요. (TypeScript Compiler API
 * 도입 + codegen 으로 single source 화는 ROI 낮아 보류, future work.)
 *
 * 새 internal 키 추가 시 여기 1곳에만 등록 → 두 TS 테스트 모두 자동 통과. 각 테스트의 추가
 * allowlist (테스트만의 특수 케이스) 는 그대로 유지.
 */
export const NAPI_INTERNAL_ONLY_KEYS = [
  "allowOverwrite",
  "assetRegistry",
  "blockList",
  "collectModuleCodes",
  "configurableExports",
  "devMode",
  "emitDiskSourcemap",
  "entryErrorGuard",
  "experimentalCodeCache",
  "fallback",
  "globalIdentifiers",
  "nodePaths",
  "onReady",
  "onRebuild",
  "polyfills",
  "preserveSymlinks",
  "profile",
  "profileFormat",
  "profileLevel",
  "reactRefresh",
  "rootDir",
  "runBeforeMain",
  "scopeHoist",
  "silentConsoleErrorPatterns",
  "strictExecutionOrder",
  "tsconfigRaw",
  "watchExclude",
  "watchFolders",
  "watchInclude",
  "workletPluginVersion",
  "workletTransform",
  "write",
] as const;
