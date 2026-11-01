# 변환 후 semantic graph 유지 계약

[#4819](https://github.com/ohah/zntc/issues/4819), [#5954](https://github.com/ohah/zntc/issues/5954), [#6193](https://github.com/ohah/zntc/issues/6193)의 통합 구현 경계다. 과거 producer census 112개나 output consumer 10가족은 각각의 조사 분모이며 전체 문법·옵션 조합의 실행 분모로 사용하지 않는다.

## 분석과 게시

일반 standalone 및 bundler 변환은 최초 분석의 `SymbolId`와 `ScopeId`를 유지한다. 생성 binding/reference는 실제 생성자가 등록하고, 최종 출력 walk는 실제 owner와 참조 범위를 검증한다. 이름·span이 비슷한 다른 심볼을 찾아 붙이거나, 누락된 owner를 임의의 program/function scope로 대체하지 않는다.

선택적 minify 및 bundler prepass는 AST와 semantic graph를 함께 준비하고 함께 게시한다. 실패한 후보는 원본 AST·graph·export metadata·cache에 부분 결과를 남기지 않는다. 원본 선언을 제거하는 변환은 실제 producer의 선언·참조·scope·외부 root를 포함한 retirement 증명을 남긴다. source symbol의 storage/origin을 일반적인 “삭제됨” 표시로 덮어 검사에서 제외하지 않는다.

`scope_frame_history.zig`의 초기 scope/owner와 생성·이동 기록은 graph와 같은 생명주기를 가진다. Worklet class lowerer, computed class key, enum 및 명시적 statement drop 같은 역할은 각 생성자의 실제 사건으로 증명한다. History의 copy-on-write, 해제, codec 및 새 AST domain 복원에서도 역할과 소유권을 함께 보존해야 한다. 증명은 임의의 동형 AST나 다른 graph에서 재사용할 수 없다.

## 분석 호출 경계

| 호출 | 역할 | 유지 이유 / 종료 조건 |
| --- | --- | --- |
| standalone source, graph source parse, JSON module | 각 입력 domain의 첫 분석 | 아직 graph가 없는 입력의 최초 identity 생성이다. 같은 입력의 transform 후 복구 분석이 아니다. |
| runtime dynamic-import, entry-provider, entry invocation, interop AST | 생성한 독립 program의 첫 분석 | 서로 다른 AST domain을 source graph로 위장하지 않는다. |
| Worklet `__initData.code` payload | 직렬화할 독립 program의 첫 분석 | outer source graph를 대체하지 않는다. outer graph의 clone/lowerer 역할은 별도 기록한다. |
| `ZNTC_DEBUG_SYMBOL_COVERAGE` + minify 진단 oracle | 독립 후행 검증 | 출력 identity를 다시 게시하지 않는 진단이다. “후행 analyzer 호출 전부 0”으로 표현하지 않는다. |
| `resyncAfterAstMutationForTest` 및 legacy rename oracle | 테스트 전용 비교 | 제품 호출은 `!builtin.is_test` compile error로 금지한다. 테스트가 더 이상 비교를 필요로 하지 않을 때 제거할 수 있다. |
| semantic-less / graphless low-level API | 명시적 identity 없는 호환 경계 | retained semantic 지원 경로의 누락을 이 경계로 보내 숨기지 않는다. 호출자 계약을 바꿔 실제 producer identity를 제공하기 전까지 별도로 유지한다. |

## 출력 이름과 별도 allocator

일반 lexical 출력은 exact source/producer SID에서 codegen의 final-name 소비자까지 연결한다. canonical rename이 없다는 것은 이름을 바꾸지 않았다는 뜻이며 identity 검증 생략 허가가 아니다. external import writer는 실제 import node·module·SID를 검증한 뒤 원래 spelling 또는 canonical 이름을 사용한다. graphless helper의 명시적 local-name 호환은 분석된 helper와 구분한다.

Namespace preamble처럼 source AST에 선언이 없는 출력 binding은 `codegen_output_domain.zig`의 실제 module owner와 output symbol을 사용한다. source SEM에 가짜 default export 선언/SID나 Scope0을 넣지 않는다. public export 이름, property key, runtime protocol 문자열은 lexical binding 이름과 다른 계약이다. chunk writer는 binding spelling과 module-export StringValue를 구분한다.

`resolveSyntheticName`, temp allocator 및 eval-aware 예약은 그래프가 없는 API와 dynamic scope의 관측 가능한 spelling을 보호하는 역할도 가진다. semantic 경로에서는 생성자 SID·output scope와 최종 이름 소비자가 authority다. 이 예약 코드를 제거하려면 해당 호출자의 graphless 호환 또는 eval/with 관측 계약을 대체해야 하며, 함수 이름이 남아 있다는 사실만으로 name-to-SID 복구가 남았다고 판단하지 않는다.

## 동적 범위와 target 제한

`with`나 opaque direct eval이 생성 capture/helper를 관측할 수 있는 경우, 기존 typed 정책은 원래 native 문법을 유지하며 target 제한을 경고하거나 표현 불가능한 변환을 오류로 거부한다. object computed accessor, lexical arrow, private class capture, class initializer 및 exponentiation의 메시지는 `transformer/options.zig`에 정의한다. 이 입력을 모두 ES5로 낮췄다고 보고하지 않는다. helper를 실제로 낮출 수 있는 bounded 경로는 등록된 helper identity와 source lookup 증명을 요구한다.

## 검증 기록의 구분

집중 native 시험, 전체 native 시험, 같은 HEAD의 CLI/NAPI 실제 출력, cache cold/warm, 적대 입력, 컴파일 가능한 구현 변이, 정상 Git hook, PR merge 및 merged-main 확인은 서로 다른 근거다. 최종 PR에는 실제 실행 결과와 HEAD를 기록한다. 이 문서의 구조 설명만으로 전체 검사 통과나 이슈 완료를 주장하지 않는다. CI는 사용자가 비활성화를 지시한 기간에는 켜지 않으며 로컬 검증 결과를 CI 결과로 표기하지 않는다.
