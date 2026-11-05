# 변환 후 semantic graph 유지 계약

[#4819](https://github.com/ohah/zntc/issues/4819), [#5954](https://github.com/ohah/zntc/issues/5954), [#6193](https://github.com/ohah/zntc/issues/6193)의 통합 구현 경계다. 과거 producer census 112개나 output consumer 10가족은 각각의 조사 분모이며 전체 문법·옵션 조합의 실행 분모로 사용하지 않는다.

## 분석과 게시

일반 standalone 및 bundler 변환은 최초 분석의 `SymbolId`와 `ScopeId`를 유지한다. 생성 binding/reference는 실제 생성자가 등록하고, 최종 출력 walk는 실제 owner와 참조 범위를 검증한다. 이름·span이 비슷한 다른 심볼을 찾아 붙이거나, 누락된 owner를 임의의 program/function scope로 대체하지 않는다.

Exact scope audit에서 생성 scope의 부모 사슬을 잇는 원본 scope는 owner가 이미 출력 AST에서 사라진 경우에도 잔존 source bridge로 취급한다. owner가 도달 가능하면 생성 owner의 AST 조상이거나, 원본 source span이 생성 owner의 span을 포함해야 한다. 서로 다른 span과 복제된 동일 span의 형제 source block 변이 20개를 모두 거부하고, loop/class lowering이 이동한 owner span으로 입증되는 non-ancestor bridge는 유지한다.

Tree-shaker import liveness와 reverse index는 `ImportBinding.local_symbol`을 사용할 때 현재 `local_symbol_node`의 semantic ID와 다시 대조한다. `resolveImportLocalSymbol`은 anchor의 identifier spelling도 captured local name과 대조하며, Unicode escape 표기만 다른 동일 식별자는 허용한다. 다른 same-kind import SID, 외부 모듈 SID, 잘못된 범위, 역할·이름 불일치 또는 없는 anchor는 해당 import를 제거할 근거로 사용하지 않으며 보수적으로 유지한다.

선택적 minify 및 bundler prepass는 AST와 semantic graph를 함께 준비하고 함께 게시한다. 실패한 후보는 원본 AST·graph·export metadata·cache에 부분 결과를 남기지 않는다. 원본 선언을 제거하는 변환은 실제 producer의 선언·참조·scope·외부 root를 포함한 retirement 증명을 남긴다. source symbol의 storage/origin을 일반적인 “삭제됨” 표시로 덮어 검사에서 제외하지 않는다.

Zig bundler AST Visitor는 기본적으로 graph 보존 계약이 없다. plain JavaScript의 제한된 prepass 조건에서 Visitor가 binding/reference/scope identity를 바꾸지 않는다고 명시하면 `.identity_preserving_visitor_edits` 경로를 사용할 수 있다. 후보 출력은 exact identity audit를 통과해야 게시된다. 적대 검증은 숫자 literal span 편집을 허용하고, reference의 출력 이름만 동명 decoy binding으로 바꾼 변조는 기존 SID와의 불일치로 후보를 거부하며 원본 AST·graph를 보존하는지 확인한다. 이 계약은 임의 subtree 재작성이나 binding/reference/scope 생성·삭제·이동을 허가하지 않으며, `onFunction` 또는 auto-worklet 훅과 조합할 수 없다.

`scope_frame_history.zig`의 초기 scope/owner와 생성·이동 기록은 graph와 같은 생명주기를 가진다. Worklet class lowerer, computed class key, enum 및 명시적 statement drop 같은 역할은 각 생성자의 실제 사건으로 증명한다. History의 copy-on-write, 해제, codec 및 새 AST domain 복원에서도 역할과 소유권을 함께 보존해야 한다. 증명은 임의의 동형 AST나 다른 graph에서 재사용할 수 없다.

### 함수·메서드 기본 매개변수의 제한 admission

Bundler retained-graph preflight는 strict 동기 일반 `function` 선언/표현식, arrow, plain object/class method, 단순 setter의 식별자 매개변수만 검사한다. 기본값은 boolean/null/number/string literal이어야 하고, 전체 매개변수 목록의 각 바인딩 SID·이름·parameter scope가 일치해야 하며, parameter scope가 실제 함수 scope의 부모여야 한다. 함수·메서드 scope subtree의 direct eval/`with`, async/generator, getter·decorator, destructuring, 비리터럴 기본값은 거부한다. MethodFlags는 `is_setter`를 허용하고, `is_static`은 실제 class body에 단 한 번 소속된 메서드에서만 허용한다. 클래스 본문의 메서드와 setter는 기존 클래스 retained-graph 조건도 별도로 통과해야 한다. Arrow에서는 cover-grammar `assignment_expression`이 해당 제한 증명을 통과한 매개변수 기본값일 때만 허용한다.

허용된 기본값 lower는 기존 parameter binding의 `SymbolId`로 읽기/쓰기 참조를 복사한다. 회귀 테스트는 bundler preflight admission과 object/class method·setter 변환 뒤 exact output audit를 함께 확인하며, 생성된 기본값 참조가 원본 parameter SID를 유지하는지 검사한다. 비리터럴·복합 패턴·async/generator·sloppy 함수·direct eval, 손상된 parameter SID·strictness·scope 연결·메서드 플래그를 적대 입력으로 거부한다. 이 조합 증거는 전체 target/plugin 조합이나 #4819/#6193 완료를 뜻하지 않는다.

Arrow의 cover-grammar 기본값은 `.assignment_expression`에서 일반 formal-parameter default로 변환된다. 이 경로도 strict synchronous arrow, 단순 parameter identifier, primitive literal default에 한해 허용한다. 전체 parameter 목록의 exact SID/name/scope와 parameter/body scope 연결을 확인하고 direct eval/`with` 및 나머지 expression/pattern은 거부한다. 회귀 테스트는 합성된 parameter read/write가 원본 arrow parameter SID를 유지하고 exact output audit를 통과하는지 확인한다.

Class constructor 기본값은 별도의 `isSimpleParamsConstructorBodyGraphSafe` 증명을 따른다. 단순 identifier 매개변수와 primitive/operator allowlist, 앞선 단순 매개변수의 exact SID reference만 허용하며, constructor body와 derived `super()` 순서도 함께 검사한다. 회귀 테스트는 base/derived constructor 및 앞선 매개변수 기본값에서 생성된 참조가 각 원본 parameter SID를 유지하는지 exact output audit로 확인한다.

클래스 계산형 accessor 키는 strict 동기 getter/setter 쌍에서 JS `StringValue`로 디코드 가능한 정적 문자열 리터럴을 허용한다. 키 이름은 파싱 시 확정되고, 표기가 달라도 디코드한 양쪽 키 값이 같아야 한다. 동적 키, 식별자 참조, 템플릿, 디코드할 수 없는 문자열, 단일 accessor, 또는 클래스 위치에서 `Object` helper가 섀도잉되는 경우는 계속 preflight에서 거부한다. ES5 번들 회귀 테스트는 생성된 key temp와 setter 기본값의 exact identity 및 Node 실행 결과를 원본과 비교한다. 이 제한은 다른 계산형 클래스 멤버나 전체 target/plugin/minify 조합으로 확장되지 않는다.

## 분석 호출 경계

### Production admission / abort 경계 (`main` `844985161`, 2026-11-05)

| 경로 | 첫 분석과 admission | 실패 결과 | 재분석 분류 |
| --- | --- | --- | --- |
| standalone `transpile` | [입력 parser AST](../src/transpile.zig)에 `SemanticAnalyzer`가 최초 graph를 만든다. 변환기가 이 graph를 편집하고 `requireStandaloneOutputNormalForm`가 output identity를 이름 결정 전에 확인한다. | 불완전한 producer identity는 output gate에서 거부한다. | `ZNTC_DEBUG_SYMBOL_COVERAGE`와 minify가 함께 켜졌을 때만 output AST를 별도 분석하는 post-minify oracle이 돈다. 그 결과는 비교/진단에만 쓰고 producer SID/ScopeId를 대체하지 않는다. |
| bundler source module | [`parseModule`](../src/bundler/graph/parse_module.zig)은 해당 입력 AST의 첫 graph를 만든다. [`runCandidate`](../src/bundler/graph/transform_prepass.zig)는 옵션·target·syntax·plugin 조건을 사전 검사한 뒤 제한된 lowerer를 실행하고, producer-owned graph를 exact output normal form으로 검사한다. | 준비된 후보에서 검사 실패는 `candidate_completed=false`로 끝나고 transaction이 후보 AST·semantic graph·module metadata를 게시하지 않는다. 입력 module snapshot은 유지된다. 명시적 증명 실패는 diagnostic과 함께 abort한다. | 같은 output AST를 재분석해 identity를 복구하는 production 경로는 없다. `resyncModuleGraphMetadataAfterAstMutation`은 import/export/module metadata를 재계산하며 `SemanticAnalyzer`를 다시 실행하지 않는다. |
| JSON source module | [`parse`](../src/bundler/graph/json_module.zig)은 JSON module AST의 최초 graph를 만든다. | 해당 module domain 안에서만 사용한다. | 다른 AST에 대한 첫 분석이지 변환 output graph 복구가 아니다. |
| AST mutation oracle | [`resyncAfterAstMutationForTest`](../src/bundler/graph/transform_prepass.zig)는 테스트 전용이며 non-test 빌드의 `compileError`로 막혀 있다. | 제품 호출은 컴파일되지 않는다. | 테스트 비교용 fresh graph다. |

Standalone의 `post_minify_analyzer`와 bundler의 test-only resync만 이 주요 source-to-output 경로에서 후행 분석을 한다. 앞의 것은 진단 oracle이고 뒤의 것은 테스트 oracle이다. 둘 다 output identity를 게시하지 않는다. 독립적으로 생성된 runtime wrapper/import/helper AST와 Worklet serialized payload는 각각 별도 AST domain이며 해당 AST의 최초 분석으로 분류한다.

### 실제 호출자와 admission 트리거

Standalone의 production 분석 모드는 [`buildTransformPlan`](../src/transpile.zig)에 의해 정해진다. `.full`은 Flow·non-TS·JSX, transform-semantic 옵션, downlevel target, 비-ESM 출력, `export =`, 비-이름형 import, runtime-sensitive syntax 및 안전하지 않은 import-shadow 형태를 포함한다. `.bindings`는 그 외 blocker가 없는 TypeScript named-import elision 경로이고, `.none`은 단순 TS type stripping 경로다. `.full` graph는 변환 후 [`requireStandaloneOutputNormalForm`](../src/transpile.zig)에서 출력 이름 결정 전에 검증한다. `canMangleWithTransformSemantic*`/`canMangleWithTransformFacts`는 source unit-test 경로에서만 참조되며 production mode selector가 아니다. 전체 함수명 검색을 production caller 조사에 포함하되 이 predicate를 실제 admission 실행으로 세지 않는다.

Bundler에는 실행 트리거와 graph-retention admission이라는 두 단계가 있다.

| 단계 | 실제 caller / 조건 | 결과 |
| --- | --- | --- |
| 실행 트리거 | cold parse의 [`parseModule`](../src/bundler/graph/parse_module.zig)와 disk-cache hit의 `tryDiskLoadHit`가 `shouldRunTransformerPrePass`를 호출하고 true일 때 `runTransformerPrePass`를 호출한다. | `shouldRun`은 transform이 필요한 module을 고를 뿐 retained graph를 승인하지 않는다. |
| `shouldRun` 조건 | JavaScript-like module, 이미 적용된 source plugin, 현재 AST에 적용 가능한 AST plugin hook, identifier minify, user-code React Refresh/style plugin import, JSX/decorator/TS namespace·enum/import-equals/export-equals flags, worklet signal, 또는 `requiresGraphPrePass` 옵션을 검사한다. | 조건이 모두 false이면 parser AST·graph를 그대로 사용한다. RN core worklet 제외와 `node_modules` plugin 적용 범위는 각 조건 안에서 결정한다. |
| candidate 준비 | `run`은 설치된 module의 prepared snapshot으로 candidate를 만들고 `runCandidate`에 넘긴다. candidate 완료, export-owner 확인, source-current 확인이 모두 성공한 뒤에만 `prepared.publish`를 호출한다. | 후보의 AST/semantic/module metadata는 한 transaction으로 게시된다. 원본 module은 publish 전까지 유지된다. |

### `runCandidate`의 bounded graph gate

`canKeepPrepassSemanticGraphPrepared`는 통과 목록 자체가 아니라 보수적 preflight다. 이후 lowerer 실행, graph edit completion, certificate completion, exact output proof까지 별도로 통과해야 한다.

| 축 | admission / output 증명 | 거부 또는 rollback |
| --- | --- | --- |
| Syntax / target | `moduleUnsupported`로 module별 target을 정규화한다. `options.unsupported`가 있는 경우 audited syntax subset, 제한된 class/loop/async/super 경로, 또는 native-noop·side-effect-entry·class·helper certificate가 source와 output에서 각각 맞아야 한다. TS/Flow/JSX/decorator/import-export 별 preflight는 AST feature flags와 실제 node 형태를 함께 확인한다. | 지원 subset을 벗어나거나 source/output 증명이 맞지 않으면 candidate가 완료되지 않는다. exact proof를 약화해 통과시키지 않는다. |
| AST plugins | 실제 AST hook이 가능한지 `shouldRun`이 거르고, retained path에서는 semantic-edit API 또는 명시적 identity-preserving visitor contract를 요구한다. output의 `with`, scope 사실이 빠진 direct `eval`, 증명할 수 없는 TLA는 별도 output 검사에서 막는다. | contract가 없으면 preflight가 닫힌다. contract 위반은 diagnostic을 내고 candidate를 abort한다. resolve/load/source/output/lifecycle hook은 분석된 AST를 직접 편집하지 않는 경로로 분류한다. |
| Minify / statement edits | identifier minify는 retained module graph를 linker까지 넘기는 실행 트리거다. `minify_syntax`는 private AST/semantic journal 안에서 적용되고 완료 receipt와 owner/ref 증명이 필요하다. label·console 삭제와 mapped-import split은 surviving reference statement coordinates와 exact graph를 다시 확인한다. | 선택적 syntax minify journal이 거부되면 직전 AST/graph snapshot을 복원하고 그 최적화만 생략한다. 이 rollback은 analyzer fallback이 아니다. 전체 candidate의 graph 증명이 실패하면 candidate transaction을 게시하지 않는다. |
| Import/export·dynamic scope | stable runtime import, supported top-level exports, mapped/TypeScript import subsets, direct-eval name lookup 사실을 source와 output에서 확인한다. statement deletion 후에는 statement owner/reference 좌표를 projection하고 tree-shaker `StmtInfo`를 같은 graph에서 다시 만든다. | 형태가 지원되지 않거나 dynamic lookup facts가 불완전하면 admission/output proof가 실패한다. |
| Graph ownership | parser owner token, source scope-history prefix, generated scope owner/provenance, retirements, helper/class/namespace owner와 module metadata를 같은 candidate transaction에서 이어 간다. `completeGenericPrepassCandidate`는 exact output normal form을 통과해야 완료 표시를 한다. | 누락·불일치·OOM은 prepared candidate를 폐기한다. `run`은 특정 diagnostic이 없으면 transaction failure를 보고하고 원본 module을 유지한다. |

`canKeepPrepassSemanticGraphPrepared`가 false이거나 후속 exact/certificate gate가 실패하는 경우의 production 동작은 output 재분석이 아니다. candidate는 `candidate_completed` 상태에 도달하지 못해 `PreparedGenericPrepass`에서 폐기된다. 일부 오류는 명시적 diagnostic을 내고, preflight 거부에는 generic transaction-failure diagnostic이 난다. [`refreshSemanticAndStmtInfoAfterAstMutation`](../src/bundler/graph/transform_prepass.zig)은 `resyncAfterAstMutationForTest` oracle 내부에서만 호출되며 non-test 빌드 compile fence가 있다.

### 그 외 production graph owner

| 경로 | actual caller | identity 처리 |
| --- | --- | --- |
| cache restore | [`tryDiskLoadHit`](../src/bundler/graph/parse_module.zig) → `materializeFromCachedAst` | cache에 같이 저장된 parse AST와 semantic graph를 복원하고 graph-facing module metadata만 재구성한다. output AST를 새로 분석하지 않는다. |
| cross-module const materialization | `TreeShaker.materializeFullPrepass`, `propagateNumericExportConstFacts`, `materializeNumericConstFactsWorklist` → [`prepareAndPublishConstFactsForIndex`](../src/bundler/tree_shaker/const_materialize.zig) | COW candidate에 exact materialized read receipt를 적용하고 semantic journal/editor로 같은 graph의 references·owners를 갱신한다. tracking이 불완전하거나 publication guard가 실패하면 candidate를 게시하지 않는다. |
| CJS Node Buffer capability fold | `TreeShaker.applyNodeBufferCapabilityFacts` → `prepareNodeBufferCapabilityPlan` → [`prepareNodeBufferCapabilityFold`](../src/bundler/graph/transform_prepass.zig) | exact removed-node/retirement proof로 retained graph candidate를 만든다. 계획·graph·publication 증명 실패 시 원본 AST를 유지해 두 runtime branch를 남기며 analyzer fallback은 없다. |
| const graph projection helper | [`resyncAfterConstMaterializationRetainingGraph`](../src/bundler/graph/transform_prepass.zig) | 현재 직접 호출은 unit-test path이며 graph API로 re-export된다. 이것을 production caller로 세지 않는다. |
| legacy Buffer graph resync helper | `resyncLegacyBufferGraphForTest` | non-test compile fence가 있는 test helper다. production Buffer fold의 거부 복구 경로가 아니다. |
| JSON source | [`parse`](../src/bundler/graph/json_module.zig) | JSON AST domain의 최초 분석이다. |

이 caller/decision 목록은 실제 함수 호출 경계를 모두 식별하지만 syntax × target × plugin × minify의 가능한 모든 cross-product가 실행되었다는 뜻은 아니다. 각 bounded 조합의 실행 분모와 hostile validation은 해당 구현 PR의 증거로 따로 기록한다.

이 caller/decision 목록은 current production boundary의 code review map이다. 모든 syntax × target × plugin × minify 조합의 실행 증거는 아니며, 각 bounded feature의 hostile inputs와 compileable mutations는 해당 PR 기록에서 별도로 센다.

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
