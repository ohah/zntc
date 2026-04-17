# Known Issues

스모크 테스트 + 브라우저 E2E에서 발견된 이슈 목록.

## 번들러 런타임 에러 (scope hoisting)

### ~~zod~~ ✅ #313 | ~~rxjs~~ ✅ #313 | ~~vue~~ ✅ #314 | ~~supabase~~ ✅ #314

## ~~CLI 기능 부재~~ ✅ `--define` PR #312

## ~~메모리 누수~~ ✅ `package_json.zig` PR #313

## ~~브라우저 호환성~~ ✅

- ~~글로벌 충돌 (effect)~~ ✅ #317 + #321 (IIFE 기본 래핑 + isReservedName 확장)
- ~~import.meta polyfill~~ ✅ #317
- ~~auto define process.env.NODE_ENV~~ ✅ #317
- ~~Node 서브패스 external~~ ✅ #319
- ~~cheerio (__copyProps var→let)~~ ✅ #319
- ~~Node 빌트인 빈 모듈 대체~~ ✅ #321
- ~~package.json browser 필드~~ ✅ #321

## ~~파서 버그~~ ✅

- ~~JS destructuring default~~ ✅ #320 (false/true/null이 identifier로 파싱)
- ~~regex 검증 에러~~ ✅ #318 (검증 스킵, esbuild 동일)

## ~~구조적 개선~~ ✅ PR #322

### ~~barrel re-export `.local` 오분류~~ ✅
- binding_scanner에서 import binding HashMap 조회로 barrel re-export를 `.re_export`로 정확 분류 (Rolldown 방식)
- namespace barrel re-export(`import * as z; export { z }`)는 `.local` 유지 (linker가 별도 처리)
- linker workaround 제거, resolveExportChain 단순화

### ~~ESM external import 처리~~ ✅
- ImportRecord에 `is_external` 플래그 추가 (resolve 실패와 external 구분)
- ESM 번들에서도 esbuild와 동일하게 `require()` preamble 사용 (import 구문 없이 Node CJS 파싱)

### ~~ESM→CJS `export *` 지원~~ ✅ PR #314

## 미해결

### zx — CJS 래핑 모듈 내부 require()가 ESM+`type:module` 환경에서 동작 안 함
- **증상**: `ReferenceError: require is not defined in ES module scope`
- **원인**: `package.json`에 `"type": "module"`이 있으면 Node가 ESM으로 파싱하여 `require()` 미정의
- **현재 동작**: `type: module` 없으면 Node가 CJS로 파싱 → require() 동작 (esbuild 동일)
- **해결 방향**: `type: module` 환경 지원 시 `createRequire(import.meta.url)` shim 주입 필요

### remeda — pipe 함수 인자 수 검증 에러
- **증상**: `Error: Wrong number of arguments` — remeda의 pipe()가 인자 수 검증 실패
- **원인**: tree-shaking 또는 scope hoisting에서 함수 래핑이 깨짐 (esbuild는 정상)

### 스모크 테스트 제외 패키지 (ZTS 문제 아님)
- **cookie**: v1.0+에서 default export 제거. esbuild/rolldown도 동일 실패. ZTS만 성공
- **yargs**: 내부 `createRequire(import.meta.url)` 사용 → esbuild 번들에서도 동일 실패. ZTS는 `format: cjs`로 우회

