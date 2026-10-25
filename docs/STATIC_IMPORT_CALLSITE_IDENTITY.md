# 단일 출력 CJS static import의 실제 호출과 저장 binding

이 경로는 wrapped ESM 소비자(`wrap_kind == .esm`)가 CJS 모듈에서 가져오는 bare/named/default/namespace import를 같은 source-order AST plan으로 전환한다. #4819/#5954/#6193 전체 완료를 뜻하지 않는다.

## 실제 실행 경계

기존 named import 문자열 rename은 `require_dep().call()`로 strict 함수의 receiver를 바꾸고, dependency 실행을 최초 binding read까지 미뤘다. 첫 actual-caller 경로는 `(0, require_dep()["call"])`와 실제 dependency initializer를 만들어 native `1 [true,42]`를 회복했다.

이후 bare/default/namespace를 raw prefix에 남긴 모듈은 실행 순서를 함께 결정할 수 없어 admission에서 제외했다. 이번 ordered 경로는 세 종류도 실제 AST로 전환해 source statement 순서대로 초기화한다. 이전 mixed 24셀(default/namespace/bare × A→B/B→A × plain/min, consumer body effect 유무)을 그대로 유지하며 모두 native와 대조한다. 이전 no-body 6개 및 body-effect 12개 실패를 분모에서 삭제하지 않고 회복 여부를 검사한다.

## Source anchor와 local identity

- parser가 static/side-effect/re-export record를 만들 때 실제 module-source string literal의 `NodeIndex`를 `source_node`에 기록한다. parser_metadata는 이를 graph에 그대로 전달하고 AST scanner도 현재 source 노드에서 직접 같은 필드를 생성한다.
- import declaration이 재생성돼도 리프 identity는 보존된다. 실제 literal clone이 있으면 syntax scanner가 새 anchor를 기록하고 `mergeImportRecords`는 기존 dependency resolution과 현재 AST anchor를 명시적으로 결합한다. 작은/큰 fan-out 두 merge 경로를 검사한다. dynamic `call_node`의 original-expression provenance 계약은 변경하지 않는다.
- bare import는 source literal NodeIndex로 record를 선택한다. spelling/span/cached local SID로 source binding을 재선택하지 않는다. missing/out-of-range/wrong-kind/duplicate anchor는 명시적으로 실패한다.
- named non-default read는 original/current local binding anchor의 SID로 선택하고, 원래 Reference의 ScopeId에서 require/member/callee AST를 만든다. 기존 Reference는 일괄 제거한다.
- default/namespace는 기존 source SID와 Module Scope를 유지하며 실제 var binding/declarator/initializer를 생성한다. kind/decl_flags를 physical storage에 맞게 전환하고 declaration Reference를 새 binding node에 reanchor한다. 기존 read/export Reference의 SID는 바꾸지 않는다.
- `ImportBinding.local_role.materialized_var`와 현재 binding node를 생성 시 보존한다. 공통 exact helper는 role에 맞는 kind와 node shape를 검증하며, 새 role에는 semantic-less name fallback이 없다. 기존 original-import low-level 계약은 유지한다. local-syntax export는 barrel 분류와 무관하게 실제 local reference node를 보존하여 storage와 동일한 SID handoff를 검증한다. 기존 namespace/export 출력 경로 전체의 이름 복구 제거를 뜻하지 않는다.

## 실행과 이름의 소유권

`runtime_callsite_builder.zig`는 실제 local import SID/declaration/reference와 foreign role/SID/owner handle을 생성한다. 배열 확장은 amortized capacity를 유지한다. require/toESM 최종 이름은 이미 선택한 exact foreign SID의 rename 결과이며 이름 검색으로 ID를 복구하지 않는다.

compiler import는 binding-only edge로 `callsite_lowered=true`를 가진다. strict-order/async-cone metadata가 별도 raw initializer를 추가하지 않는다. source record도 변환 완료를 표시하므로 기존 raw preamble/storage/expression rename은 동시에 제거된다. default interop의 기존 direct-require 최적화도 유지해 Proxy prototype trap 같은 새 관찰 효과를 추가하지 않는다.

source directive prologue는 custom/strict 노드의 원래 순서로 먼저 유지하며 initializer와 compiler import는 그 뒤에 둔다. program owner는 새 root로 명시 이관하고 editor finish 결과와 transform-cache ID 배열을 동일 snapshot으로 갱신한다. generic 출력 walk로 scope를 고치거나 새 semantic analysis를 추가하지 않는다.

## 검증과 남은 경계

parser/scanner 직접 생성, 실제 literal clone, 1/70개 record merge, AST codec 재구성, unicode/specifier rewrite의 current anchor를 검사한다. storage source 10개는 기존 SID·Scope·decl anchor와 actual AST owner walk를 독립 대조한다. malformed/poisoned state 10개는 cached SID/spelling/span/record order 오염과 null/range/kind/duplicate anchor를 포함한다. 실제 source 10개 × ES5/ES2017 × ESM/CJS/IIFE × plain/fullmin 행렬도 native와 대조한다. 최종 full/NAPI/compiled mutation 수치는 PR에 기록한다.

ImportRecord와 local-role은 graph-facing memory state이며 module codec wire에 포함되지 않는다. AST cache 복원 후 scanner가 anchor를 재구성한다. compiler-import consumer는 기존 process-owner cache eviction을 유지하므로 owner-linked persistent warm reuse나 warm parse 0을 완료했다고 주장하지 않는다.

아래 경계는 여전히 별도 필수 잔여다.

- inlineRequires/Metro의 lazy policy, wrapped ESM target 및 guarded source prefix, re-export source execution, source-phase/defer/attribute import, split/preserve/HMR은 기존 admission을 유지한다. 일부 unsupported use가 raw에 남으면 module 전체의 mixed-order gate도 유지한다.
- moduleSpecifierMap의 original default-spec binding 생성은 기존 `hasMappedImportToSplit` reanalysis gate를 유지한다. rewrite control은 current anchor 전달만 증명하며 same-owner SID birth 완료로 세지 않는다.
- foreign CJS/ESM raw wrapper와 raw export getter의 실제 closure Scope/Reference는 이 단계로 제거되지 않는다.
- 명시 directive 없는 ESM wrapper implicit-strict 두 칸은 native `["strict",42]`, 이전/현재 `["sloppy",42]`의 기존 debt다.
- 실제 TLA 4개(별도 CJS 2개 정상 control) 및 기존 DCE 5개 실패는 통과 수에 섞지 않는다.
