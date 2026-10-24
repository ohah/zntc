# SymbolId 최종 이름 출력 소비자 인벤토리

이 문서는 [#6181](https://github.com/ohah/zntc/issues/6181)의 source-backed 출력 감사를 현재 main에 맞춰 갱신한 결과다. 기준 main은 PR [#6202](https://github.com/ohah/zntc/pull/6202)이 병합된 `26e005cf1`이다. PR [#6189](https://github.com/ohah/zntc/pull/6189)(`3204f0c2`)가 CJS/IIFE code-splitting identity 검증을 추가했고, PR [#6192](https://github.com/ohah/zntc/pull/6192)(`21e349c6`)가 Stage 3 decorator × native private minify mismatch를 수정했다. #6202 병합 뒤 main CI run [40004005839](https://github.com/ohah/zntc/actions/runs/40004005839)은 진행 중이다.

## 범위와 판정

- standalone transform/codegen, bundler scope-hoist/preserve-modules, ESM/CJS/wrapped writer, code splitting, helper preamble, namespace/enum, JSX preserve, private name 경계를 살폈다.
- bundler `Format`은 ESM/CJS/IIFE/UMD/AMD다. preserve-modules는 ESM/CJS를 조사했고, IIFE/UMD/AMD 조합은 저장소가 명시적으로 지원하지 않는 경계다 (`src/bundler/types.zig`, `src/bundler/bundler_test/splitting_dev.zig`).
- 분모는 아래 표의 **10개 출력 소비자 가족**이다. 이는 AST binding constructor 전체나 모든 resolver 호출 수와 다른 분모다.
- 현재 기준 main에서 확인된 실제 `SymbolId → 최종 이름 → 출력` 불일치는 **0건**이다. 이는 이 문서의 지원 경로 조사 범위에 한정되며 전체 producer 경로가 끝났다는 뜻은 아니다.
- #6186은 code-splitting linker rename → emitted chunk output과 CJS entry-export writer의 연결 검증을 추가했다. #6187은 JSX preserve casing을 수정하고 minify, collision, no-minify, one-character, nested Phase B, multi-entry provider export 회귀를 추가했다. #6189는 CJS/IIFE의 emitted provider-local ↔ consumer-import/body identity 연결을 확인하고, #6192는 private-name 출력 mismatch를 수정했다. 별도 회귀 gate는 alias·re-export·reserved key·nested shadow·동명 provider를 포함한 적대 입력 10개를 CJS/IIFE 양쪽에서 검사한다.

## 이름 선택 공통 경로

| 경로 | Identity → 이름 선택 | 출력 소비자와 기본 경계 |
| --- | --- | --- |
| standalone | [`buildStandaloneLateOutputNameOverrides`](../src/transpile.zig#L1215)가 늦게 이름을 고를 synthetic symbol에 대해 exact `SymbolId`별 override를 만든다. [`Codegen.sourceSymbolId`](../src/codegen/codegen.zig#L429)와 [`finalSymbolName`](../src/codegen/codegen.zig#L441)이 그 ID와 override를 읽는다. | [`node_dispatch.emitNode`](../src/codegen/node_dispatch.zig#L195)가 선언·참조·assignment target·JSX identifier를 출력한다. 이름 변경이 없으면 source-backed 노드는 원문 span을 보존한다. |
| bundler | [`resolvePostGraphOutputHintNames`](../src/bundler/linker.zig#L1046)가 semantic graph에서 허용된 generated output hint를 exact `(ModuleIndex, SymbolId)`로 등록한다. [`getCanonicalByRef`](../src/bundler/linker.zig#L4966)와 `rename_table`이 canonical spelling을 제공하고, metadata가 AST의 `symbol_ids`와 rename을 codegen에 전달한다. | codegen은 같은 `finalSymbolName` 소비자를 사용한다. semantic ownership을 요구하는 namespace/enum 경로는 identity가 없거나 모호하면 오류로 종료한다. |
| ESM factory wrapper 및 출력 밖 AST 노드 | [`resolveNodeName`](../src/bundler/emitter.zig#L2903)는 NodeIndex의 `symbol_ids`에서 exact ID를 찾아 linker rename을 적용한다. 늦게 방출하는 TLA wait는 [`resolveTlaPromiseName`](../src/bundler/emitter.zig#L1725)에서 저장된 binding node, `SymbolId`, `ScopeId`를 검증한다. | wrapper hoisted `var`/함수/class/namespace/enum 이름과 TLA promise 이름을 writer에 전달한다. rename이 없는 경우에만 원문 이름을 쓴다. |

## 출력 소비자별 인벤토리

| 소비자 | Producer identity → 최종 spelling → writer | Fallback / 종료 조건 | 검증 근거 |
| --- | --- | --- | --- |
| 일반 lexical identifier와 binding | AST node의 `symbol_ids` → `Codegen.finalSymbolName` (linker rename, transform override, generated hint/name 순) → [`node_dispatch.emitNode`](../src/codegen/node_dispatch.zig#L195) | 선택된 이름이 없으면 source span. semantic graph가 필요한 output owner는 source-name 재검색을 하지 않고 실패한다. unresolved global은 lexical binding `SymbolId`가 없으며 원문/global 경로를 유지한다. | `src/codegen/codegen_test/basic.zig`의 SID override·rename 테스트, `src/transpile.zig`의 #4819 standalone late-name 계열 |
| Object shorthand와 assignment target | shorthand value의 exact ID → 동일한 final spelling → [`emitObjectProperty`](../src/codegen/expressions.zig#L516) | key는 public property 계약이므로 원문 유지. value 이름이 바뀌면 longhand로 펼친다. assignment target 자리에서는 값 전용 peephole/constant inline이 유효하지 않으면 원문 span을 유지한다. | `src/codegen/codegen_test/basic.zig` shorthand/property 출력 테스트; 구현의 치환 목록과 `identifierEmitsSubstituted`가 대응 |
| Import/export specifier | import local 및 export local의 exact ID → `finalSymbolName` → [`emitSpecifierWithRename` / `emitExportSpecifier`](../src/codegen/modules.zig#L251) | imported/exported 이름은 remote property/public API key이므로 원문 유지. local 이름만 변경하고 필요하면 `as`를 쓴다. CJS wrapper free `exports`/`module`은 별도 wrapper identity 경로다. | `src/codegen/codegen_test/basic.zig`; ESM/CJS module writer 테스트; #6174/#6176/#6178/#6180 반영 |
| Entry export와 CJS/ESM/wrapped writer | local `ExportBinding`의 `SymbolRef` → `getCanonicalByRef`/`FinalExportEntry.binding_symbol` → [`buildFinalExports`](../src/bundler/linker/metadata.zig#L1799), [`emitEsmEntryExports`](../src/bundler/emitter/entry_exports.zig#L56), [`emitWrappedEntryExports`](../src/bundler/emitter/entry_exports.zig#L84), [`emitCjsEntryExports`](../src/bundler/emitter/entry_exports.zig#L125) | public export key는 원문 계약. re-export, namespace, CJS interop 표현식은 local binding ID가 없는 경계이며 별도 canonical/interop 경로로 구분한다. | #6186 병합 테스트 `src/bundler/bundler_test/cjs_esm.zig`: `#6181 CJS writer uses linker-final local names for colliding re-exports`; entry writer unit tests in `src/bundler/emitter/entry_exports.zig` |
| Code-splitting chunk export/import | provider local binding의 exact `SymbolRef` → linker canonical local; cross-chunk 계약은 `(owner module, public export)`에서 계산한 global name → [`resolveOwnerLocal`](../src/bundler/emitter/chunks.zig#L482) 및 chunk import/export writer | ESM/CJS/IIFE splitting은 지원된다. namespace re-export와 interop에는 materialized binding/interop 경로가 있다. 유효한 local spelling을 얻지 못하는 CJS reserved-word re-export는 기존 export-key fallback에 도달할 수 있으며, 이는 plain local identifier로 표현할 수 없는 writer 경계이지 확인된 SID 이름 불일치는 아니다. | #6186은 ESM provider declaration↔consumer import를 emitted output까지 연결한다. `splitting_dev.zig`의 CJS/IIFE splitting 테스트는 format wiring을 검사하나 minified provider-local↔consumer-import identity 연결까지 단언하지 않는다. 과거 reserved-local 제약은 [#4117](https://github.com/ohah/zntc/pull/4117) 참고 |
| preserve-modules CJS live export | 재할당 export binding의 exact semantic SID → metadata가 해당 SID를 `exports.<public>` 저장소 이름으로 rename → declaration은 [`bindings.zig`](../src/codegen/bindings.zig#L216), 이후 read/write는 일반 identifier writer | public key는 export contract. named export mode에서만 storage rename을 사용하고, const/class/function 및 `none`/`default_` output mode는 이 경로에서 제외한다. preserve-modules + IIFE/UMD/AMD는 명시된 non-goal이다. | `tests/integration/tests/preserve-modules-cjs-live-binding.test.ts`는 minify on/off 순환 live binding과 emitted `exports.A` declaration/read 계약을 실행 검증한다; 게이트는 `src/bundler/linker/metadata.zig#L1484`, emitter/codegen 동일 게이트는 `src/bundler/emitter.zig#L2165` 및 `#L2564` |
| Runtime helper와 output-owned generated local | helper/generated binding을 만들 때 보유한 ID → standalone late override 또는 linker `output_name_hint`/canonical rename → helper preamble, import, generated reference writer | direct eval/with가 spelling을 관찰할 수 있거나 owner scope가 불명확하면 충돌 검사 후 early spelling을 선택한다. bundler helper import와 call reference는 exact ID를 공유하며, 서로 다른 provider/importer ID를 같은 이름이라고 추정하지 않는다. | `src/transpile.zig`의 #4819 helper preamble/final-name 테스트, `tests/integration/tests/linked-jsx-helper-name.test.ts`, linker metadata helper rename handoff |
| Namespace/enum IIFE | namespace declaration 및 generated parameter의 exact IDs → `finalSymbolName` → [`type_runtime`](../src/codegen/type_runtime.zig#L385) namespace/enum parameter, member reference writer | semantic owner map이 주어졌으면 missing/ambiguous SID는 오류. owner map이 없는 저수준 codegen caller만 제한된 text fallback을 쓴다. namespace member/export property 이름은 원문 key다. | `src/codegen/codegen_test/basic.zig`의 fail-closed/low-level fallback 계열; `src/transpile.zig`의 #4819 namespace/enum late-name 계열 |
| JSX preserve tag | component root `jsx_identifier`의 exact ID → 일반 `finalSymbolName`/linker rename → `node_dispatch.emitNode`; member tail과 attribute는 property spelling | lowercase intrinsic name은 binding reference가 아니다. preserve JSX에서 component root의 대문자 casing은 최종 출력까지 유지해야 한다. #6185 결함은 #6187로 수정되어 main에 병합됐다. | 기존 `#4470`은 preserve/deconflict만 검사. #6187은 minify, collision, no-minify, one-character, nested Phase B 및 multi-entry provider export를 검사한다. 서로 다른 10개 변이와 multi-entry reconciliation 호출 제거 변이가 전용 테스트에서 실패했다. |
| Private name과 private lowering helper | native `#private` 이름은 lexical `SymbolId` 대신 class별 private-name map으로 일괄 변환; downlevel/private-field helper local은 생성 시 exact `SymbolId` | nested class는 독립 map으로 재귀 처리한다. direct eval class는 보수적으로 skip하고, 수집/적용 OOM은 해당 spelling의 모든 occurrence를 원문으로 유지해 불일치 rename을 피한다. Bundler는 emitted root에서 도달 가능한 class만 처리한다. Stage 3 decorator의 `context.name` 원문은 보존한다. legacy `emitDecoratorMetadata`는 private-name key를 만들지 않는다. #6191 mismatch는 PR #6192에서 수정되어 main에 병합됐다. | `src/codegen/private_mangler.zig`와 `private_mangler_test.zig`; `tests/integration/tests/decorator-private-accessor-5669.test.ts`; legacy metadata + native private 실행 재현; `src/transformer/private_field_temp_identity_semantic_test.zig`의 generated temp ID 테스트 |

## Fallback과 잔여 경계

- **원문 source span**: exact ID가 없거나 ID에 대해 새 spelling을 선택하지 않은 source-backed 토큰의 안정적 출력. 이름을 텍스트로 다시 찾아 다른 binding을 고르지 않는다.
- **Dynamic scope**: `with`/직접 eval을 포함하는 scope chain에서는 늦은 이름 선택을 막는다. static eval 문자열은 후보 이름 예약에 반영한다. early spelling은 identity 누락으로 세지 않는다.
- **Semantic-less / low-level codegen**: 일부 unit-level namespace/enum caller는 owner map 없이 호출될 수 있다. production semantic path는 owner map을 제공하고 missing SID를 거부한다.
- **Property/public contract**: object key, imported/exported property, public export spelling, JSX member/attribute leaf는 lexical binding 이름 소비자가 아니므로 원문을 유지한다.
- **Linker-generated runtime names**: preamble/global/helper symbol은 normal parsed AST binding이 아닐 수 있지만 linker identity table 또는 producer-owned semantic ID로 연결한다. unresolved external/global 이름은 deliberate no-binding 경계다.
- **Private names**: class-local name domain으로 별도 처리한다. 클래스 소유 경계와 all-or-none rewrite가 보장된다. Stage 3 decorator metadata의 관찰 가능한 `context.name` 문자열은 source spelling을 유지한다. Legacy `emitDecoratorMetadata`는 type metadata만 emit하고 private-name 문자열을 만들지 않으며, native private 필드와 함께 minify한 출력을 실행 확인했다. Stage 3 decorator × private-name mismatch는 #6192에서 수정되어 merge 뒤 main CI가 성공했다.
- **preserve-modules 포맷**: ESM/CJS는 지원되고 CJS storage rename은 exact SID를 사용한다. preserve-modules + IIFE/UMD/AMD는 저장소에서 의도적 non-goal로 거부한다.
- **Code-splitting 포맷**: ESM/CJS/IIFE는 지원되고 UMD/AMD는 아직 거부된다. #6186은 ESM에서 SID→final local→cross-chunk emitted import/export를 연결했고, #6189는 CJS/IIFE 두 포맷에서 provider local→consumer import/body 연결을 emitted output으로 확인한다. [`splitting_mangle.zig`](../src/bundler/bundler_test/splitting_mangle.zig#L385)의 추가 gate는 10개 서로 다른 입력 그래프를 두 포맷으로 빌드해 같은 연결을 대조한다.
- **Code-splitting reserved CJS re-export**: `resolveOwnerLocal`이 안전한 local identifier를 못 찾으면 export key로 fallback한다. 이는 #4819 identity mismatch로 분류하지 않았고, 지원/출력 제한 여부는 별도 bundler 이슈로 다뤄야 한다.

## 2026-10-25 metadata self-rename의 exact ID 소비

`buildMetadataForAst`의 module self-rename 루프는 scope-map iterator가 이미 가진
`SymbolId`로 `RenameTable`을 직접 조회한다. 이름을 `getCanonicalName`에 넘겨
같은 ID를 다시 찾는 왕복은 제거했다. 원본 AST 테스트용 `buildMetadata`에도
같은 처리를 적용했다. dev metadata builder의 변경은 아니다.

서로 다른 입력 10개에서 top-level ID, 동명 nested decoy, 무관한 이웃 binding과
미해결 global 경계를 검사한다. 두 소비자 각각의 잘못된 조회 ID·저장 ID·출력
spelling을 주입한 컴파일 가능한 변이 10개가 검출됐다. 정상 scope-map에서는
기존 코드와 동작이 같았으므로 이 변경을 제품 mismatch 수정이나 원복 변이
검출로 주장하지 않는다. 캐시 간 이름 복원, runtime helper ID 복구와 변환 후
재분석은 별도 잔여다.

## 결론

현재 source survey는 위 10개 consumer family를 연결했다. 기준 main `26e005cf1`에서 조사한 범위의 확인된 실제 mismatch는 0건이다. #6186/#6187/#6189의 emitted-output 연결과 JSX 보정, #6192의 private-name 보정 및 #6202의 숫자 상수 post-pass graph 보존이 main에 반영됐다. 새 10입력 gate는 CJS/IIFE 각 출력에서 provider 선언·export local·consumer import local·실제 본문 참조를 함께 검사한다. 이 문서는 출력 소비자 감사 결과만 기록한다. #5954의 최종 종료 여부는 전체 producer/fallback crosswalk와 별도 same-graph 작업 #6193의 경계를 대조한 뒤 결정한다.
