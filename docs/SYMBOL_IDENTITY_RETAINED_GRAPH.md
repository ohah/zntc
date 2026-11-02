# 변환 후 semantic graph 유지 계약

[#4819](https://github.com/ohah/zntc/issues/4819), [#5954](https://github.com/ohah/zntc/issues/5954), [#6193](https://github.com/ohah/zntc/issues/6193)의 통합 구현 경계다. 과거 producer census 112개나 output consumer 10가족은 각각의 조사 분모이며 전체 문법·옵션 조합의 실행 분모로 사용하지 않는다.

## 분석과 게시

일반 standalone 및 bundler 변환은 최초 분석의 `SymbolId`와 `ScopeId`를 유지한다. 생성 binding/reference는 실제 생성자가 등록하고, 최종 출력 walk는 실제 owner와 참조 범위를 검증한다. 이름·span이 비슷한 다른 심볼을 찾아 붙이거나, 누락된 owner를 임의의 program/function scope로 대체하지 않는다.

Exact scope audit에서 생성 scope의 부모 사슬을 잇는 원본 scope는 owner가 이미 출력 AST에서 사라진 경우에도 잔존 source bridge로 취급한다. owner가 도달 가능하면 생성 owner의 AST 조상이거나, 원본 source span이 생성 owner의 span을 포함해야 한다. 서로 다른 span과 복제된 동일 span의 형제 source block 변이 20개를 모두 거부하고, loop/class lowering이 이동한 owner span으로 입증되는 non-ancestor bridge는 유지한다.

Tree-shaker import liveness와 reverse index는 `ImportBinding.local_symbol`을 사용할 때 현재 `local_symbol_node`의 semantic ID와 다시 대조한다. `resolveImportLocalSymbol`은 anchor의 identifier spelling도 captured local name과 대조하며, Unicode escape 표기만 다른 동일 식별자는 허용한다. 다른 same-kind import SID, 외부 모듈 SID, 잘못된 범위, 역할·이름 불일치 또는 없는 anchor는 해당 import를 제거할 근거로 사용하지 않으며 보수적으로 유지한다.

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

## Linker 이름-keyed canonical assignment 경계

변환 후 재분석을 제거했다는 것은 production의 모든 문자열→SID lookup이 사라졌다는 뜻이 아니다. naming pass의 최초 deconflict 시점에는 retained semantic graph가 이미 존재한다. `forEachTopLevelOwnerName`가 module-scope row에서 얻은 SID는 source와 synthetic output owner 모두 `NameOwner`를 거쳐 `assignSymbolCanonical`까지 전달한다. scope가 없는 synthetic이나 wrapper scope의 generated symbol도 scope-map row와 spelling을 검증한 뒤 exact SID를 유지한다. 적대 테스트는 owner 수집 뒤 map을 같은 이름의 decoy SID로 바꿔도 canonical write가 원래 owner에만 가는지 확인한다.

이름이 있는 local `export default`는 module-scope row 유무와 관계없이 export scanner가 exact local SID를 제공해야 한다. SID가 없으면 owner 수집이 실패한다. root-map row가 exact export SID와 다른 유효한 동명 SID를 가리켜도 실패한다. 오래되었거나 유효하지 않은 map row는 exact export witness가 있을 때만 복구한다. `TopLevelOwnerIdentity`는 SID를 필수로 가지며 canonical assignment는 `NameOwner`에 저장된 SID에만 쓴다. SID가 없는 owner가 write sink에 도달하면 실패한다. cross-chunk 점유 marker는 semantic SID가 없으므로, 충돌 상대가 없고 이름이 예약어인 경우에도 rename assignment에서 제외한다. canonical name 조회도 `SymbolID`를 직접 사용하며 production 경로에는 spelling에서 SID를 찾는 fallback이 없다.

ES5 block-scoping lowering이 module 밖 공유 scope로 올리는 block `let`/`const`/`class`/function도 별도 owner 입력이다. `forEachHoistedBlockOwner`는 scope-map row를 후보로만 보고, SID 범위·source spelling·선언 `scope_id`가 해당 block scope와 일치하는지 root-shadow 및 kind 필터보다 먼저 확인한다. 따라서 범위 밖 SID, 다른 이름/다른 scope SID, alias row, root-shadow 뒤에 숨긴 손상 row는 조용히 누락되거나 다른 owner로 등록되지 않고 실패한다. 10가지 hostile map 변이와 정상 cross-module owner 수집이 이를 검증한다. 같은 검증기는 runtime/wrapper shadow 처럼 이름으로 소비자 binding을 찾아 canonical SID를 쓰는 `renameConsumerScopeBindings`와 generated explicit-global shadow pass에도 적용한다. 동명 root 행을 nested SID로 바꾼 두 hostile fixture는 오귀속 전에 실패하고 rename table이 비어 있음을 확인한다.

Compiler-generated callsite read shadow는 foreign target의 exact identity를 검증한 뒤 target 출력 이름으로 소비자 scope chain을 찾는다. 여기서도 map row는 후보일 뿐이며, rename 전에 해당 scope의 SID 범위·선언 scope·spelling을 확인한다. 적대 fixture는 `value` 행을 다른 유효한 root SID인 `ns`로 바꿔 baseline에서 잘못된 `ns` rename을 재현하고, 수정 후에는 `InvalidCallsiteReference`로 거부되며 rename table이 비어 있음을 확인한다.

Namespace access 재분석도 import SID를 소비하므로 `SymbolRef`와 scanner AST anchor가 함께 있으면 서로 일치해야 한다. `SymbolRef`가 없으면 retained anchor에서 SID를 얻고, anchor까지 없는 저수준 caller만 root scope-map fallback을 사용한다. 그 fallback도 spelling·scope·binding kind를 검증하며 실패하면 namespace 사용 집합을 전체 보존 경로로 돌린다. 적대 fixture는 invalid ref와 poisoned `ns → decoy0` 행에서 `wrong0`가 사용 집합에 섞이는 baseline 오류를 검출하고, 수정 후에는 anchor 복구와 anchorless fallback의 정상/poisoned 경우를 모두 확인한다.

CJS runtime-helper factory-root shadow 판정도 scope-map SID를 사용해 preserved import에 local alias가 필요한지 결정한다. 행이 있으면 scope·spelling을 검증하고, 행이 없거나 root map이 비면 실제 root symbol spelling을 확인한다. 손상된 행은 “충돌 없음”으로 오판하지 않고 가능한 shadow로 처리해 emitter가 사용 가능한 alias를 고르게 한다. 적대 fixture는 실제 root helper-name binding의 map row를 nested decoy SID로 바꾸거나 row를 제거했을 때 baseline에서 shadow가 누락되는 경우를 재현한다.

resolveNestedShadowForModule은 target rename을 실제 local ExportBinding SID가 있을 때만 수행한다. 일반 ESM re-export는 leaf export로 canonicalize된다. CJS runtime property는 lexical owner가 아니므로 건너뛰고, namespace 같은 nonlocal export alias는 consumer의 exact nested SID를 rename한다. 적대 입력 `export * as math`와 동명 private `const math`, nested parameter를 둔 테스트는 수정 전 private SID 오귀속을 검출하고 수정 후 private SID 보존·consumer SID rename과 Node 원본/번들 출력 `42` 일치를 확인한다.

lazy-only computeRenamesForModules의 nonlocal fallback은 제거했다. Scanner가 등록한 local ExportBinding만 exact SymbolId에 할당하고, re-export alias는 그 모듈의 lexical binding이 아니므로 건너뛴다. cross-chunk namespace output은 typed output owner가 이름을 받는다. 적대 입력 export * as math와 같은 파일의 const math, 그리고 math unresolved global로 alias를 math$1로 바꾸는 실제 ChunkGraph 테스트는 수정 전 private math SID가 잘못 rename되는 것을 재현하고 수정 후 rename이 없음을 확인한다. 이 수정도 전체 변환 재분석 제거 또는 남은 linker lookup의 전면 제거를 뜻하지 않는다.
