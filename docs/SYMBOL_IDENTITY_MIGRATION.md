# #4819 심볼 identity 전환과 보정 경로 제거

[에픽 #4819](https://github.com/ohah/zntc/issues/4819)의 목표는 사용자 변수와 생성 변수가 변환 중 같은 identity를 유지하고, 출력 직전에 이름을 확정하는 것이다. 이 문서는 현재 보정 경로를 제거할 조건과 다음 작업 단위를 기록한다. 새로운 AST나 별도 심볼 시스템을 도입하는 계획은 아니다.

생성자 표의 조사 기준은 2026-10-04의 `6ca87b46`이며, 이후 구현 상태는 아래 작업 순서에 기록한다. 아래 표는 확인한 주요 이름 생성자 계열이며, 모든 호출 지점과 문법·옵션 조합의 전수 목록은 아니다. private-field/decorator/class-self, Flow 및 plugin/worklet/refresh/emotion/styled-components의 생성 경로 전수조사는 남아 있다. 원본 AST를 보존해야 하는 bundler/cache/HMR의 메모리 소유권은 [기존 ownership RFC](./RFC_TRANSFORMER_OWN_AST.md)와 구분한다. AST 복사 제거와 의미 분석 재실행 제거는 다른 작업이다.

## 생성과 출력의 계약

- 심볼 기반 변환 경로에서 binding을 만들 때 `SymbolId`와 소유 `ScopeId`를 함께 정한다. 같은 변수의 reference는 그 handle을 받아 연결한다. 속성 이름, label, 미해결 외부 이름은 binding과 구분한다.
- 생성 함수의 소유 스코프를 나중에 만들 수밖에 없는 경우, 정확한 binding/reference 노드와 예정된 owner를 가진 보류 handle을 전달한다. 소유권이 결정된 뒤 이름을 다시 검색해 변수를 고르는 경로는 제거 대상으로 기록한다.
- AST 이동·복사는 identity를 유지하고 reference scope, 선언, 읽기/쓰기 및 문장별 사용 정보를 함께 갱신한다. 이동 전후 parent가 달라질 수 있으므로 source scope와 출력 scope를 구분해 검증한다.
- `flags.declare` 행의 `scope_id`는 그 심볼의 선언 대상 scope를 기록한다. 값 참조 행의 사용 위치 scope와 구분하며, 선언 심볼이 그 scope의 자식에서도 보인다는 사실만으로 잘못된 선언 소유권을 허용하지 않는다.
- 최종 이름 결정은 비-minify 출력도 포함한다. 미해결 전역, direct `eval`/`with`, export/property 이름, 외부 runtime 계약을 먼저 보존·예약하고 모든 내부 이름 소비자가 같은 결과를 사용한다.
- 출력 별칭과 원본 함수·클래스의 `.name`은 별도 계약이다. alias 예약은 Unicode escape를 해석한 identifier StringValue로 비교하고, 이름 복원은 정확한 초기화 식 노드와 선언 SID에 연결한다. 같은 선언의 이름을 변환기와 codegen이 중복 복원하지 않는다.
- 의도적인 분석 생략 또는 저수준 Transformer의 `semantic_edit_enabled=false` 경로는 적용 범위를 별도로 기록한다. 해당 경로의 `null`을 심볼 기반 경로에서 누락을 허용하는 근거로 사용하지 않는다.

## 이름 생성자와 남은 경계

`SID`는 `SymbolId`를 뜻한다. 표의 경로들은 모듈 소유자를 가리키며 행 번호에 의존하지 않는다.

| 생성자 계열                                                | 현재 identity와 소비자                                                                                                                                                                                                                                                                                                  | 제거하거나 통합할 경계                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 일반 temp·구조분해·매개변수 temp                           | [es_helpers](../src/transformer/es_helpers.zig), [es2015_params](../src/transformer/es2015_params.zig)의 binding과 tracked reference. [semantic_edit](../src/transformer/transformer/semantic_edit.zig)의 `createSyntheticTempBinding`은 알려진 scope에서 SID를 등록한다.                                               | 문자열만 받는 생성자와 별도 등록 호출의 조합, 등록 누락을 뒤에서 복구하는 fallback. 생성 시 등록을 제거한 mutation이 후처리로 복구되지 않아야 한다.                                                                                                                                                                                                     |
| lexical capture `_this`·`arguments`·`new.target`           | [semantic_edit](../src/transformer/transformer/semantic_edit.zig)의 capture frame/origin 기록과 정확한 binding SID를 출력 reference에 연결한다.                                                                                                                                                                         | 출력 scope에서 이름으로 다시 선택하는 보정. parameter 평가환경, derived constructor, 중첩 함수로 이동한 참조까지 handle로 연결한 뒤 해당 검색을 제거한다.                                                                                                                                                                                               |
| class `_super`·추출된 `_loop`·generator state·wrapper temp | [block scoping](../src/transformer/es2015_block_scoping.zig), [semantic_edit](../src/transformer/transformer/semantic_edit.zig)에 generated function scope와 deferred state 노드가 등록된다. [private_fields](../src/transformer/es2015_class/private_fields.zig)는 wrapper의 `_super` parameter SID에 참조를 연결한다. | `completeGeneratedStateSymbols`와 `trackGeneratedLocalSymbols`, `_super` wrapper 순회 중 이름/span 기반 연결. 원본 superclass SID와 생성 parameter SID를 구분하고 owner 및 정확한 노드·SID를 전달한 계열부터 제거한다. 정당한 deferred insertion 자체를 삭제 대상으로 취급하지 않는다.                                                                  |
| runtime helper import·단일 파일 preamble                   | [semantic_edit](../src/transformer/transformer/semantic_edit.zig)의 helper import/preamble SID와 pending reference. [transpile](../src/transpile.zig)이 helper 본문을 출력한다.                                                                                                                                         | helper 별칭 문자열로 묶는 pending chain과 출력 이후 alias 치환. import와 inline 경로의 선언·호출·본문 소비자가 같은 최종 이름을 사용해야 한다.                                                                                                                                                                                                          |
| namespace·enum IIFE parameter                              | [analyzer](../src/semantic/analyzer.zig)의 parameter SID/namespace owner, [namespace transform](../src/transformer/transformer/namespace.zig)의 member AST, [type_runtime](../src/codegen/type_runtime.zig)의 IIFE 출력.                                                                                                | 이름 사전 선택과 codegen prefix/member 치환 fallback. 병합·중첩 namespace, enum self/member 참조와 분석만 수행하는 출력 경로를 이관한 뒤 제거한다.                                                                                                                                                                                                      |
| JSX runtime import                                         | [jsx_runtime_imports](../src/transformer/jsx_runtime_imports.zig)가 local binding을 만들고 helper SID에 연결한다.                                                                                                                                                                                                       | runtime helper와 공유하는 별칭/보류 참조 경계. standalone·bundle 및 automatic/development/classic 경계를 구분한다.                                                                                                                                                                                                                                      |
| CJS wrapper parameter·runtime factory                      | [emitter](../src/bundler/emitter.zig)의 `allocCjsWrapperParamNames`, [linker](../src/bundler/linker.zig)의 runtime factory 별칭을 wrapper와 codegen이 사용한다. 내부 parameter는 독립 SID가 없고 factory는 raw preamble로 출력된다. 외부 `require_x`/`exports_x`/`init_x`의 synthetic SID와는 다르다.                   | emitter/linker의 별도 문자열 allocator와 전체 이름 충돌 검색. wrapper scope 및 모든 본문 참조가 최종 이름 결정에 참여한 뒤 제거한다.                                                                                                                                                                                                                    |
| linker default export·모듈 간 rename                       | [analyzer](../src/semantic/analyzer.zig)의 anonymous default facade SID, [linker](../src/bundler/linker.zig)의 rename table과 [transform_prepass](../src/bundler/graph/transform_prepass.zig)의 선언/facade NodeIndex 기반 old/new SID 연결.                                                                            | [binding_scanner](../src/bundler/binding_scanner.zig)의 `scope.get("_default")` 재사용/추가 생성, linker의 `_default` 충돌 처리와 `captureRenamesToPending` handoff. handoff 자체는 현재 이름·위치 추측으로 이관하는 구현이 아니지만, 재분석이 SID를 다시 만들기 때문에 필요하다. facade SID를 선언·참조까지 전달하고 재분석을 제거한 뒤 각각 삭제한다. |

## 보정 경로별 제거 조건

| 제거 대상                                               | 제거 전에 필요한 증거                                                                                                                                                        |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 생성 후 이름/span/scope 검색                            | 해당 생성자 binding/reference가 생성 또는 명시적 owner 확정 시점에 같은 SID를 가진다. 생성 시 등록을 끊으면 테스트가 실패하며, 보정 코드를 제거한 정상 구현은 통과한다.      |
| `canRetainGraphForAuditedSyntaxSubset`의 해당 문법 조건 | 그 변환이 AST와 semantic 정보를 함께 갱신하고, 함께 실행되는 helper·plugin·minify 변환도 해당 계약을 지킨다. 허용 조건만 바꿔 통과한 테스트는 제거 근거가 아니다.            |
| 재분석과 rename handoff                                 | 모든 적용 경로에서 SID, reference/statement 사용 정보, import/export, tree shaking 및 cache 재사용 정보가 변환 후에도 유효하다. 재분석 경로를 실제로 제거한 상태로 검증한다. |
| codegen 이름 치환·별도 allocator                        | 선언과 모든 참조가 심볼 또는 명시적인 외부 이름 계약으로 출력된다. 비-minify, identifier-minify, 전체 minify와 bundle/code splitting에서도 충돌·shadowing이 없다.            |
| `resolveSyntheticName`·`collidesWithUserSymbol`         | 위 생성자 이관과 최종 이름 결정이 끝나고, 미해결 전역 및 동적 스코프 예약을 포함한 실행 회귀가 통과한다. 검사기부터 삭제하지 않는다.                                         |

## 합의한 작업 순서

1. **source scope-parent 검사 연결 완료:** [PR #5057](https://github.com/ohah/zntc/pull/5057)에서 source AST의 owner/parent 검사와 CLI 호출을 연결했다. source parent 오류와 namespace/Flow의 기존 owner 표현 차이를 구분한다. 변환 후 출력 scope 검사를 대체하지 않으며, 전체 심볼 전환 완료를 뜻하지 않는다.
2. **매개변수·본문 binding 정적 분리:** [parameter_environment](../src/transformer/parameter_environment.zig)가 기본값·계산된 구조분해 key의 외부 참조와 충돌하는 본문 `var`·함수·`let`·`const`·클래스 선언을 기존 rename table에 연결한다. analyzer가 같은 SID로 합친 비단순 매개변수와 본문 `var`도, 매개변수 초기화 식에서 그 binding을 참조할 때 별도 SID로 나눈다. parameter reference를 새 SID로 옮기고, 매개변수 초기화가 끝난 뒤 본문 `var`에 초기값을 복사한다. closure가 가진 매개변수 값과 본문 변수를 분리하며, 계산된 key·구조분해 shorthand, parameter TDZ, 원본 함수 이름, 별칭 충돌을 실행과 exact graph로 검사한다. 이는 ES5 정적 변환 경로의 제한된 분리이며, 전체 parameter/body scope model을 구현한 것은 아니다.
3. **구조분해 매개변수 temp 생성 시 SID/scope 소유 강제:** [PR #5059](https://github.com/ohah/zntc/pull/5059)에서 ES5 parameter lowering이 활성 함수 scope에 temp를 생성하고 즉시 SID와 exact span map을 기록하도록 한다. semantic editing을 사용하지 않는 저수준 Transformer 경로는 no-op으로 유지하고, owner node가 아직 붙지 않은 예약 생성 함수 scope도 허용한다. 네 곳의 사후 재등록 fallback을 제거하고 직접 identity 검사와 standalone/bundle 실행 비교를 추가한다.
4. 이후 위 표의 한 생성자 계열씩 생성부터 최종 출력까지 이관한다. 각 PR에는 바뀐 지원 범위, 삭제한 보정 코드, 남은 호출 지점, 음성 대조 및 실제 실행 결과를 기록한다. 이 문서의 항목도 같은 PR에서 갱신한다.

### 매개변수 수정 후 남은 경계

- 본문 lexical 선언 자체의 ES5 TDZ 보존은 남아 있다. 예를 들어 `let x = 4`보다 앞에서 본문의 `x`를 읽으면 원본은 `ReferenceError`지만 현재 출력은 `undefined`를 읽을 수 있다. 매개변수가 외부 `x`를 읽도록 고친 것과 본문 TDZ 구현 완료를 구분한다.
- direct `eval`/`with`가 있는 동적 스코프는 정적 rename 대상에서 제외한다. source의 중복 함수 선언·TypeScript overload가 남기는 과거 심볼 행과 일부 재분석 진단도 별도 정리 대상이다. 실제 AST binding이 없는 행을 이번 rename으로 새 synthetic binding으로 만들지는 않는다.
- 이름 복원은 기존 `__name` helper를 사용한다. helper는 모듈 본문 실행 전에 내장 property-definition 함수를 보관하며, 모듈 시작 시 표준 intrinsic을 가정한다. standalone 출력은 hashbang·directive 뒤에서 helper를 writer로 출력해 실행 모드와 소스맵 위치를 유지한다.
- 생성자 전수 이관, 통합된 최종 이름 결정과 재분석 제거는 아직 완료하지 않았다. 구조분해 매개변수 생성 계약은 이 문서의 세 번째 작업 범위이며, 나머지 생성자 계열의 소유권 완성을 뜻하지 않는다.

## 검증과 완료 보고

- 구조 검사는 AST, SID, reference, scope owner/map의 일관성을 검사한다. `clean=1`만으로 원본 프로그램과 같은 의미라고 판정하지 않는다.
- 실행 검사는 원본을 실행 가능한 엔진에서 실행한 결과와 변환 출력을 비교한다. shadowing, closure, 평가 순서·횟수, 읽기/쓰기, direct `eval` 및 외부 이름 충돌을 포함한다.
- 적용된 변경에 따라 standalone/bundle, native/downlevel target, 기본 출력/identifier-minify/전체 minify를 비교한다. code splitting, JSX, helper, plugin/cache 경계는 해당 생성자를 이관할 때 포함한다.
- mutation은 생성 시 등록·reference 연결·scope 관계·검사 호출을 끊었을 때 실패하는지 확인한다. `retained`/`reanalyzed` 선택만 틀리게 만드는 mutation은 경계 정책 검사이며 런타임 의미 보존 증거와 구분한다.
- 테스트 함수 수, assertion 수, fixture × target 실행 수와 남은 구현 경계 수를 서로 환산하지 않는다. 각 작업은 실제로 삭제한 보정 경로와 아직 남은 범위로 보고한다.
- 이 문서 작성이나 일부 생성자의 이관만으로 #4819를 닫지 않는다. 최종 이름 결정과 재분석 제거를 포함한 에픽 종료 조건은 계속 유효하다.
