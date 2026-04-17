# Flow 지원 전략

Flow 타입 스트리핑 설계 + 결정 기록 (방식 A 채택, 2026-03-30/31 구현 완료).

## 목표
React Native 앱 번들링 (Metro 대체). RN 코어 + 서드파티 라이브러리 전체가 Flow로 작성되어 있으므로 Flow 타입 스트리핑이 필수.

## Flow 현황 (2024-2025)
- Meta 내부에서 계속 투자 중 — Facebook/Instagram/WhatsApp 전체가 Flow
- Hermes 엔진이 Flow를 네이티브로 실행 (트랜스파일 불필요)
- 최근 추가된 구문: `component` 선언 (2023), `hook` 선언 (2023), `match` 표현식 (2024)
- RN 새 아키텍처 (Fabric/TurboModules) codegen이 Flow 타입에서 네이티브 인터페이스 생성
- **결론: Flow는 죽지 않았고 스펙이 계속 확장 중 → 전체 스펙 지원이 필요할 수 있음**

## Metro 소스 분석 결과 (520개 JS 파일, 450개 @flow)
```
TIER 1 (필수 — 수천 회 사용):
  타입 어노테이션 (: Type), ?Type (2,094회), 제네릭 <T> (3,176회),
  union |, +prop (covariant, 870회), export type (736회),
  type alias (515회), import type (497회), declare (932회)

TIER 2 (중간 — 수십 회):
  opaque type (12회), interface (19회), /*:: */ 주석 타입 (26회)

TIER 3 (미사용 또는 극히 드뭄):
  component 선언 (0회), hook 선언 (0회), {| exact |} (소스에서 0회),
  $ReadOnly 등 유틸리티 (소스에서 0회), : mixed (3회), : * (1회)
```

## 선택지 비교
```
┌─────────────────────┬──────────┬──────────┬──────────────────────────┐
│ 방식                 │ 초기 비용 │ 유지보수  │ 특징                      │
├─────────────────────┼──────────┼──────────┼──────────────────────────┤
│ A. ZTS 파서에 직접   │ 1-2주    │ 높음     │ 외부 의존성 0, WASM 그대로 │
│    Flow 구문 추가    │ (TIER1만)│ (스펙 변경│ comptime 분기로 모드 추가  │
│    (Hermes cpp 참고) │ 2-3주    │  시 직접  │ 128개 C++ 파일 불필요      │
│                     │ (전체)   │  수정)   │                          │
├─────────────────────┼──────────┼──────────┼──────────────────────────┤
│ B. Hermes C++ 파서를 │ 2-3주    │ 낮음     │ Flow 100% 커버            │
│    Zig build로 링크  │          │ (Hermes  │ C++ 128개 파일 빌드 필요   │
│    (@cImport C ABI)  │          │  업데이트 │ 크로스 컴파일 복잡         │
│                     │          │  만)     │ 바이너리 +5MB             │
│                     │          │          │ WASM 빌드 시 C++ 체인 필요 │
├─────────────────────┼──────────┼──────────┼──────────────────────────┤
│ C. hermes-parser     │ 2-3주    │ 낮음     │ Flow 100% 커버            │
│    WASM를 wasm3      │          │ (npm     │ wasm3 C 라이브러리 링크    │
│    런타임으로 실행    │          │  업데이트 │ 바이너리 AST 역직렬화 필요 │
│                     │          │  만)     │ 네이티브보다 느림          │
│                     │          │          │ Emscripten 인터페이스 호환 │
└─────────────────────┴──────────┴──────────┴──────────────────────────┘
```

## 핵심 트레이드오프
- **A (직접 구현)**: 초기 가장 빠르지만, Flow 스펙이 계속 확장되면 유지보수 부담 누적
- **B (Hermes C++ 링크)**: Meta가 스펙을 유지보수하지만, C++ 빌드 시스템 통합이 복잡
- **C (WASM 런타임)**: B와 비슷하지만 성능 오버헤드 + Emscripten 인터페이스 해석 필요
- Zig는 C/C++을 `build.zig`로 직접 컴파일 가능 → B 방식에서 CMake 불필요

## Hermes C++ 파서 의존성 (B 방식 시 필요한 파일)
```
lib/Parser/     9개 cpp  — 파서 본체 (Flow/JSX/TS 포함)
lib/AST/       11개 cpp  — AST 노드 정의
lib/Support/   31개 cpp  — 유틸리티
lib/ADT/        1개 cpp  — 자료구조
Platform/Unicode/ 6개 cpp — 유니코드
external/llvh/ 70개 cpp  — LLVM 포크 (SmallVector 등)
합계:         128개 C++ 파일
```

## ✅ 결정 완료 (2026-03-30 ~ 2026-03-31)

**방식 A (직접 구현) 채택.** flow.zig 독립 파싱 체인, flow_ 접두사 AST 태그.

### 구현 완료 항목
- [x] `is_flow` 인프라: @flow pragma 감지, .js.flow 확장자, --flow CLI
- [x] 기본 타입: string, number, boolean, bool, mixed, empty, ?Type, union, intersection, generics, T[]
- [x] type alias, opaque type (supertype constraint 포함)
- [x] interface (extends 지원)
- [x] declare (class/function/var/module/module.exports/export)
- [x] import type, import typeof, export type
- [x] as TypeCast, (expr: Type) TypeCast
- [x] {| |} exact object type
- [x] %checks predicate
- [x] /*:: */ 블록 flow comment, /*: */ 인라인 flow comment
- [x] Metro 410/410 @flow 파일 파싱+스트리핑 성공
- [x] --resolve-extensions, --main-fields (RN 플랫폼 확장자 해석)

### 미구현 (Metro 미사용, 필요 시 추가)
- [ ] component 선언 (Flow 2023)
- [ ] hook 선언 (Flow 2023)
- [ ] match 표현식 (Flow 2024)
