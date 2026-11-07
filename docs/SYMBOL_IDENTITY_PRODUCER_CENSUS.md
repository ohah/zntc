# SymbolId producer census: bounded AST binding constructors

이 문서는 [#5980](https://github.com/ohah/zntc/issues/5980)의 bounded AST binding-constructor 색인이다. Callsite별 생성 시점, owner `ScopeId`, exact `SymbolId` handoff, final-name consumer와 fallback은 [SYMBOL_IDENTITY_PRODUCER_AUDIT.md](./SYMBOL_IDENTITY_PRODUCER_AUDIT.md)에 있다. 112개라는 색인 수는 누락 ID 수가 아니다.

## 기준과 계수

- 기준 커밋: `7346fc2cb48980257f9fc5a8625dc627eb7f0768` (`origin/main`, PR #6122 병합 후).
- 색인 분모: call expression 112곳, 70개 색인 함수, 35개 파일. 실제 production caller가 있는 expression은 111곳, 함수는 69개다. `es2015_for_of.zig::makeVarDeclFromSpan`은 호출자가 없는 helper 안의 call이다.
- 기존 다섯 constructor 계열은 색인상 110곳이며, 도달 가능한 production expression은 109곳이다. 색인 분포는 `makeSyntheticBinding` 50(도달 49), `makeExactSyntheticBinding` 26, `makeExactSyntheticBindingFromSpan` 20, `createSyntheticTempBinding` 10, `makeUsingBinding` 4다.
- 별도 exact-identity helper `createSyntheticTempBindingWithIdentity`: 도달 가능한 production callsite 2곳.
- 색인은 아래 여섯 helper의 source call expression을 기록한다. 이 분모에는 위의 호출 없는 helper expression 하나가 포함된다. Constructor 정의, helper 내부 위임, 전용 test 파일, inline `test {}` 및 테스트에서만 부르는 `checkGeneratorAssignmentBindingIdentity`와 `checkGeneratorHoistProducerUsesExactBindingHandle`는 제외한다.

## Source index

각 줄은 호출 파일과 enclosing 함수별 callsite를 나열한다. 이 단계에서는 callsite의 심볼 소유권 완료 여부를 판정하지 않는다. 함수 이름을 선택한 뒤 각 함수의 생성 시점, owner `ScopeId`, final-name consumer, standalone/bundler/minify mode, fallback을 추적한다.

| 파일 | 함수와 constructor callsite |
| --- | --- |
| [`src/transformer/es2015_arrow.zig`](../src/transformer/es2015_arrow.zig) | `wrapNativeParameterArrow`: `makeExactSyntheticBinding` L509 |
| [`src/transformer/es2015_block_scoping.zig`](../src/transformer/es2015_block_scoping.zig) | `buildControlFlowCheck`: `makeExactSyntheticBinding` L1469<br>`buildLoopClosureWithFlow`: `makeExactSyntheticBindingFromSpan` L829 |
| [`src/transformer/es2015_class.zig`](../src/transformer/es2015_class.zig) | `beginClassSelfWrite`: `makeExactSyntheticBinding` L110<br>`emitClassSelfWriteTarget`: `makeExactSyntheticBinding` L141,165<br>`lowerClassDeclaration`: `makeExactSyntheticBinding` L397; `makeExactSyntheticBindingFromSpan` L255,339<br>`lowerClassExpression`: `makeExactSyntheticBinding` L890; `makeExactSyntheticBindingFromSpan` L717,842 |
| [`src/transformer/es2015_class/constructors.zig`](../src/transformer/es2015_class/constructors.zig) | `buildFunctionFromConstructor`: `makeExactSyntheticBinding` L60 |
| [`src/transformer/es2015_class/derived_constructors.zig`](../src/transformer/es2015_class/derived_constructors.zig) | `buildDefaultSuperConstructor`: `makeExactSyntheticBinding` L571 |
| [`src/transformer/es2015_class/members.zig`](../src/transformer/es2015_class/members.zig) | `classifyComputedAccessorProperty`: `makeExactSyntheticBindingFromSpan` L733<br>`setupPrivateFieldMappings`: `makeExactSyntheticBinding` L302,322 |
| [`src/transformer/es2015_class/super_props.zig`](../src/transformer/es2015_class/super_props.zig) | `beginSuperTemp`: `createSyntheticTempBinding` L39; `createSyntheticTempBindingWithIdentity` L38; `makeExactSyntheticBindingFromSpan` L42 |
| [`src/transformer/es2015_destructuring.zig`](../src/transformer/es2015_destructuring.zig) | `makeDestructuringTempBinding`: `makeSyntheticBinding` L55 |
| [`src/transformer/es2015_for_of.zig`](../src/transformer/es2015_for_of.zig) | `makeVarDeclFromSpan`: `makeSyntheticBinding` L574 (production caller 없음)<br>`rewriteForIn`: `createSyntheticTempBinding` L374,375,376,377<br>`rewriteForOf`: `makeExactSyntheticBinding` L264; `makeExactSyntheticBindingFromSpan` L204; `makeSyntheticBinding` L122,142,162,186 |
| [`src/transformer/es2015_generator.zig`](../src/transformer/es2015_generator.zig) | `buildHoistedVarDecl`: `createSyntheticTempBindingWithIdentity` L666; `makeExactSyntheticBindingFromSpan` L674<br>`makeGeneratorStateBinding`: `makeExactSyntheticBindingFromSpan` L3219 |
| [`src/transformer/es2015_params.zig`](../src/transformer/es2015_params.zig) | `buildDestructuringDefault`: `makeSyntheticBinding` L496,515<br>`buildDestructuringParam`: `makeSyntheticBinding` L555,573<br>`buildRestPatternParam`: `makeSyntheticBinding` L702,720<br>`call`: `makeSyntheticBinding` L309 |
| [`src/transformer/es2018_for_await.zig`](../src/transformer/es2018_for_await.zig) | `rewriteForAwait`: `createSyntheticTempBinding` L122,123,128,129; `makeExactSyntheticBinding` L118 |
| [`src/transformer/es2019.zig`](../src/transformer/es2019.zig) | `lowerOptionalCatchBinding`: `makeSyntheticBinding` L67 |
| [`src/transformer/es2022.zig`](../src/transformer/es2022.zig) | `buildNewConstructor`: `makeSyntheticBinding` L852<br>`lowerPrivateMembers`: `makeExactSyntheticBinding` L497 |
| [`src/transformer/es2022_tla.zig`](../src/transformer/es2022_tla.zig) | `lowerProgram`: `makeSyntheticBinding` L729<br>`moveDefaultExport`: `makeSyntheticBinding` L485 |
| [`src/transformer/es2025_using.zig`](../src/transformer/es2025_using.zig) | `buildCatchClause`: `makeUsingBinding` L537<br>`normalizeForOfUsingHead`: `makeSyntheticBinding` L373<br>`rewriteUsingStatements`: `makeSyntheticBinding` L299; `makeUsingBinding` L209,210,211 |
| [`src/transformer/es_helpers.zig`](../src/transformer/es_helpers.zig) | `buildCapturedFunctionAssignment`: `makeExactSyntheticBindingFromSpan` L1293<br>`buildForOfLoopVarAssign`: `createSyntheticTempBinding` L2989<br>`buildNewTargetCapture`: `makeExactSyntheticBinding` L3510<br>`buildStandaloneFunc`: `makeSyntheticBinding` L3658,3705<br>`buildStaticPrivateFieldDescriptor`: `makeSyntheticBinding` L135<br>`buildStaticPrivateMethodDescriptor`: `makeSyntheticBinding` L194<br>`capturePrivateClassSelf`: `makeExactSyntheticBindingFromSpan` L441,446<br>`memoizeComputedKey`: `makeSyntheticBinding` L1149<br>`reservePrivateMethodFunctionSymbols`: `makeExactSyntheticBinding` L249,257<br>`reservePrivateMethodWeakSetSymbols`: `makeExactSyntheticBinding` L225 |
| [`src/transformer/object_super.zig`](../src/transformer/object_super.zig) | `wrapWithHome`: `makeExactSyntheticBindingFromSpan` L287,302,323 |
| [`src/transformer/parameter_environment.zig`](../src/transformer/parameter_environment.zig) | `nameFunctionExpression`: `makeExactSyntheticBinding` L874 |
| [`src/transformer/plugins/worklet_plugin.zig`](../src/transformer/plugins/worklet_plugin.zig) | `buildClassFactoryAssignment`: `makeExactSyntheticBindingFromSpan` L1118<br>`buildClassFactoryBody`: `makeSyntheticBinding` L1034,1035<br>`buildFactoryBody`: `makeExactSyntheticBindingFromSpan` L368 |
| [`src/transformer/transformer/class_decorator.zig`](../src/transformer/transformer/class_decorator.zig) | `visitClassWithAssignSemanticsInner`: `makeExactSyntheticBindingFromSpan` L553; `makeSyntheticBinding` L280,416 |
| [`src/transformer/transformer/class_member_helpers.zig`](../src/transformer/transformer/class_member_helpers.zig) | `buildSuperSpreadArgsShell`: `makeSyntheticBinding` L757 |
| [`src/transformer/transformer/class_visit.zig`](../src/transformer/transformer/class_visit.zig) | `visitClass`: `makeSyntheticBinding` L84,98,179<br>`wrapClassExprInIIFE`: `makeSyntheticBinding` L676 |
| [`src/transformer/transformer/control_flow.zig`](../src/transformer/transformer/control_flow.zig) | `tryLowerForInOfPrivateTarget`: `makeSyntheticBinding` L477 |
| [`src/transformer/transformer/declarations.zig`](../src/transformer/transformer/declarations.zig) | `nameAnonymousConstClass`: `makeSyntheticBinding` L686 |
| [`src/transformer/transformer/emotion.zig`](../src/transformer/transformer/emotion.zig) | `ensureCssPropAlias`: `makeExactSyntheticBinding` L383 |
| [`src/transformer/transformer/flow.zig`](../src/transformer/transformer/flow.zig) | `visitFlowMatch`: `makeSyntheticBinding` L338 |
| [`src/transformer/transformer/lists.zig`](../src/transformer/transformer/lists.zig) | `buildVarDecl`: `makeSyntheticBinding` L200<br>`hoistTempVarsWithScope`: `makeSyntheticBinding` L384,386 |
| [`src/transformer/transformer/refresh.zig`](../src/transformer/transformer/refresh.zig) | `appendRefreshRegistration`: `makeExactSyntheticBinding` L138<br>`maybeRegisterRefreshSignature`: `makeExactSyntheticBinding` L593 |
| [`semantic_edit.zig` at `7346fc2` L4340](https://github.com/ohah/zntc/blob/7346fc2cb48980257f9fc5a8625dc627eb7f0768/src/transformer/transformer/semantic_edit.zig#L4340) | `splitParameterBodyVarBinding`: `makeExactSyntheticBinding` |
| [`src/transformer/transformer/stage3_decorator_helpers.zig`](../src/transformer/transformer/stage3_decorator_helpers.zig) | `buildAccessObject`: `makeSyntheticBinding` L496,544,599,601<br>`buildMetadataDecl`: `makeExactSyntheticBindingFromSpan` L726<br>`buildSetterMethodWithHandles`: `makeSyntheticBinding` L1102<br>`makeLetWithBinding`: `makeSyntheticBinding` L942<br>`makeLetWithExactBinding`: `makeExactSyntheticBinding` L950 |
| [`src/transformer/transformer/stage3_decorator_transform.zig`](../src/transformer/transformer/stage3_decorator_transform.zig) | `valueParam`: `makeSyntheticBinding` L1717 |
| [`src/transformer/transformer/styled_components.zig`](../src/transformer/transformer/styled_components.zig) | `forwardTemplateInterpolations`: `makeSyntheticBinding` L1431<br>`maybeExtractCssProp`: `makeSyntheticBinding` L1778,1813 |
| [`src/transformer/transformer/tagged_template.zig`](../src/transformer/transformer/tagged_template.zig) | `lowerTaggedTemplate`: `makeExactSyntheticBinding` L236 |
| [`src/transformer/transformer/worklet.zig`](../src/transformer/transformer/worklet.zig) | `buildClosureDestructuring`: `makeExactSyntheticBinding` L1069<br>`generateInitCode`: `makeSyntheticBinding` L976 |

## 분모 밖에 남겨 둔 producer/consumer 경계

이 분모는 AST binding-constructor call expression만 센다. Reference-only temp reservation과 plugin/linker-owned output binding은 별도 경계다. `worklet.zig`의 두 serialized-payload binding call은 색인에 포함하지만 별도 semantic graph를 사용한다. Semantic-less/graphless fallback은 각 callsite 행에 분리 기록하며, 그 경계 자체를 누락 ID로 세지 않는다. 다른 producer family와 resolver/local re-search 범위는 #5952, #5954, #5956, #6003, #6004의 현 상태에 따라 별도로 추적한다.

## Identity audit 결과

[상세 감사표](./SYMBOL_IDENTITY_PRODUCER_AUDIT.md)에서 112/112 callsite를 생성 시점, owner, consumer, output mode, fallback 기준으로 분류했다. Production caller가 있는 111개 경로에서 semantic graph를 사용하는 지원 경로의 누락 exact `SymbolId` handoff는 0이다. 한 call은 호출자가 없는 helper expression이다. 이 결과는 전체 final-name 통합이나 #4819 완료를 뜻하지 않으며, name/span/scope 재검색과 resolver·collision 경계는 별도 이슈에 남아 있다.

## Current main delta (2026-10-22; `c5b0c956c`)

위 source index와 112/112 행별 표는 기준 커밋 `7346fc2cb`의 snapshot이다. 기준을 현재 `main`으로 옮기며 바뀐 constructor callsite는 한 건 제거되고 한 건 추가되어 분모는 **112곳, 70개 함수, 35개 파일**로 유지된다. 실제 production caller가 있는 callsite는 **111곳, 69개 함수**다.

- 다섯 constructor 계열의 현재 분포: `makeSyntheticBinding` 50, `makeExactSyntheticBinding` 26, `makeExactSyntheticBindingFromSpan` 21, `createSyntheticTempBinding` 9, `makeUsingBinding` 4. 별도 `createSyntheticTempBindingWithIdentity`는 production callsite 2곳이다.
- `es2015_class/super_props.zig::beginSuperTemp`의 기존 `createSyntheticTempBinding` 호출은 없어졌다. 현재 semantic 경로는 producer `SymbolId`를 확보한 뒤 `createSyntheticTempBindingWithIdentity`를 사용한다.
- `object_super.zig::wrapWithHome`에는 `_args` alias parameter를 만드는 `makeExactSyntheticBindingFromSpan` callsite가 추가됐다. 이 binding과 alias references는 wrapper parameter `ScopeId` 및 exact `SymbolId`를 공유한다. Alias는 native parameter list가 dynamic lookup 때문에 유지될 때만 생성되고, current final-name marker는 `_obj` home parameter에만 붙는다. 따라서 `_args`의 조기 spelling은 이 dynamic-scope 경계에 남으며 누락된 `SymbolId` handoff로 세지 않는다.
- `semantic_edit.zig`의 `splitParameterBodyVarBinding` 호출은 census snapshot `7346fc2`에서 L4340이고, 현재 main `ec7b100d`에서는 L4595다 ([현재 main source](https://github.com/ohah/zntc/blob/ec7b100d2eef3e9a07c16d9389a00a2dfcde594d/src/transformer/transformer/semantic_edit.zig#L4595)). 위 census 행은 snapshot 커밋에 고정해 source-line drift를 분리한다.

이 delta도 bounded AST constructor 분모만 갱신한다. 전체 producer 누락 수나 #4819 완료 여부를 뜻하지 않는다.

## Post-census producer addition (2026-10-25)

The historical 112-callsite index above remains a snapshot of its stated base. `src/transformer/static_class_capture.zig::ensureCapture` adds one reachable `makeExactSyntheticBindingFromSpan` callsite for immutable moved-static-initializer captures. Its exact SID/owner, declaration/reference handoff, dynamic-environment boundary, and late output-name consumer are documented in the [producer audit delta](./SYMBOL_IDENTITY_PRODUCER_AUDIT.md#static-initializer-immutable-capture-delta-2026-10-25). This is an explicit addition to the bounded inventory, not evidence that every output-graph producer has been migrated.

## Current source census (2026-11-06; a33381d4)

The source index and the 112-row identity review above remain snapshots of their stated base. The current-main constructor inventory is now pinned by the [audit script](../scripts/audit-symbol-identity-producer-census.mjs).

| Measure | Historical base 7346fc2 | Current main a33381d4 |
| --- | ---: | ---: |
| Constructor call expressions | 112 | 138 |
| Source files | 35 | 45 |
| Enclosing functions | 70 | 89 |
| Reachable production callsites | 111 | 137 |
| Constructor helper with no production caller | 1 | 1 |

Current callsite totals are makeSyntheticBinding 52, makeExactSyntheticBinding 42, makeExactSyntheticBindingFromSpan 29, createSyntheticTempBinding 9, makeUsingBinding 4, and createSyntheticTempBindingWithIdentity 2. The one unreachable expression remains es2015_for_of.zig::makeVarDeclFromSpan; its current location is L706.

The pinned SHA-256 fingerprint is 246344339d6250038c5dc248cd41d3fdeaebe9b265dcdc7e77dd6e68ebccddb8. The current total is a source inventory, not a count of missing symbols. Compared with the historical 112-site base, the source has 37 added production expressions and 11 removed expressions, for a net increase of 26. Some rows moved between enclosing functions during refactors; the pinned fingerprint covers normalized call expressions and their source function so ordinary additions or removals cannot hide behind equal totals.

The scanner excludes constructor definitions and their internal delegation, _test.zig files, inline test { } bodies, and three test-only helper functions. native_constructor_function_cells.zig::runControl is the additional helper discovered during this refresh; it is called only from that file's inline test. The scanner self-test checks nested test blocks, comments and strings, helper delegation, test-only helpers, an added producer call, a removed producer call, and an unclassified helper.

The exact new and retired function-level census entries since the historical base are:

| Source function | Callsite delta |
| --- | --- |
| class_strict_context.zig::visitInitializer | +1 makeExactSyntheticBinding |
| es2015_arrow.zig::prepareNativeParameterArrow / wrapNativeParameterArrow | +1 / -1 makeExactSyntheticBinding (identity creation moved before wrapper visitation) |
| es2015_block_scoping.zig::annexCatch | +2 makeExactSyntheticBinding |
| es2015_block_scoping.zig::annexEmptyCompletion | +1 makeExactSyntheticBinding |
| es2015_block_scoping.zig::annexSetter | +2 makeExactSyntheticBinding |
| es2015_block_scoping.zig::lowerExtractedNativeAnnexB | +1 makeExactSyntheticBinding |
| es2015_class/private_fields.zig::PrivateFields.init | +1 makeExactSyntheticBinding |
| es2015_class/super_props.zig::beginSuperTemp | -1 createSyntheticTempBinding |
| es2015_generator.zig::registeredClassAssignment | +1 makeExactSyntheticBindingFromSpan |
| es2015_params.zig::lowerParamsImpl | +2 makeExactSyntheticBindingFromSpan |
| es2025_using.zig::rewriteUsingStatements / rewriteUsingStatementsWithOwner | -3/+3 makeUsingBinding, -1/+1 makeSyntheticBinding (owner-aware refactor) |
| es_helpers.zig::buildWeakCollectionDecl | +1 makeExactSyntheticBinding |
| loop_await_driver.zig::slot, build | +1 each makeExactSyntheticBinding |
| native_constructor_function_cells.zig::prepareImpl | +1 makeExactSyntheticBindingFromSpan |
| native_constructor_guard.zig::binding | +1 makeExactSyntheticBinding |
| native_parameter_cells.zig::normalize | +2 makeSyntheticBinding |
| object_super.zig::wrapWithHome / wrapWithHomeAndPrefixRoots | -3/+4 makeExactSyntheticBindingFromSpan |
| retained_class_keys.zig::prepareLoopBody, maybeWrap | +1 makeExactSyntheticBinding; +1 each exact and exact-from-span in maybeWrap |
| retained_field_arrow.zig::prepareOwnedArrow | +2 makeExactSyntheticBinding |
| static_class_capture.zig::ensureCapture | +1 makeExactSyntheticBindingFromSpan |
| transformer/class_member_helpers.zig::buildSuperSpreadArgsShell / buildSuperSpreadArgsShellInScope | -1/+1 makeSyntheticBinding (scope-aware refactor) |
| transformer/driver.zig::appendImplicitArgumentsBodyCopy | +1 makeExactSyntheticBindingFromSpan |
| transformer/semantic_edit.zig::ensureAnnexBVariableStorage | +1 makeExactSyntheticBindingFromSpan |
| transformer/tagged_template.zig::lowerTaggedTemplate / lowerTaggedTemplateImpl | -1/+1 makeExactSyntheticBinding (implementation split) |

This refresh pins callsite inventory only. The 37 added expressions now have a row-by-row owner, exact SID handoff, final-name consumer, and fallback review in the [current-main delta audit](./SYMBOL_IDENTITY_PRODUCER_DELTA_AUDIT.md); that review found no missing exact-ID handoff among those rows on supported semantic-graph paths. This bounded result does not classify other producer families or close the broader retained-graph/output-consumer matrix. Keep #4819 and #6193 open.


## Outside-census identity domains (2026-11-07)

The historical 138 transformer constructor expressions (140 after the native
module-using delta below) and 41 `SyntheticKind` roles are
bounded inventories. They do not enumerate every independent parsed program or
foreign-module callsite. These additions are separate domains, not new rows
silently absorbed into that constructor count:

| Domain / handoff                                              | Actual authority and final consumer                                                                                                                                                                                                                                                    | Validation boundary                                                                                                                                                                                                                                |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Compiler-owned output program (`compiler_output_program.zig`) | `Program.create` owns a copy of compiler-generated facade/callback source, its fresh Parser AST, one first Analyzer, and a fresh output-domain owner. Actual function parameter child edges select binding/SID/scope/function-owner handles; one SID name table feeds `Codegen`.       | `validate`, exact literal-role binding, cold/warm owners, allocation-failure tests; `audit-semantic-reanalysis-boundaries.mjs` separately pins this first-analysis role. It never permits reanalysis of a transformed user module.                 |
| Public facade / dynamic callback artifact                     | `makePublicEntryFacadeOutput` and `rewriteDynamicImports` are the two actual `Program.create` callers. `emit` emits a complete independent file; `emitValue` emits a typed callback value. Native-helper/provider paths bind exact string-node roles rather than identifier spellings. | `OutputFile.compiler_output_program` and `compiler_output_snippets` own these arenas until output destruction. Carrier destruction and error cleanup are part of the contract. No independent program is cached as a user module's semantic graph. |
| PM dynamic namespace callsite                                 | `pm_dynamic_namespace.lower` uses the existing source AST/editor and an actual helper module owner/export SID via `Builder.importedWithOwner`. The import record retains exact helper read/SID/scope and provider namespace/init owners.                                               | `validate` precedes chunk emission; the normal name selector consumes the attached source reference. This is a typed cross-module source callsite, not another first Analyzer domain. Cold/warm owner relocation must be tested independently.     |
| Worklet clone → class-key IIFE                                | The initial source external origin stays immutable. An actual Worklet Creator ties exact source/target owner, leaf, and execution frames; the following class-key transfer proves that clone's reserved IIFE and completed body.                                                       | Existing clone/cache/COW/OOM hostile tests and the paired computed-key composition tests exercise these separate transitions. A detached Node VM executes the serialized payload with its actual `__closure`; this is not an RN/JSI/UI test.       |

The old external 123-gateway ledger is pinned to `08bb86d99`; it must not be
presented as an exhaustive current count without adding these concrete gateways
and re-running its extractor on the final integrated source. Source classification,
source-audit self-mutations, native runtime tests, public API/cache matrices, and
implementation mutation campaigns remain separate evidence. In particular, a
bounded Worklet cohort cannot certify unexecuted PM or independent-program cache
paths, and no source inventory alone closes #4819/#6193.

The independent program's one SID name table also reserves all actual analyzed
scope-map bindings and unresolved global reads before selecting names. These are
spelling reservations only: physical parameter edges still select the SymbolId.
The existing unique-name allocator handles collisions, including escaped names;
direct-eval/with scopes retain their actual source parameter names. A fresh name
such as `__zntcArtifact0` must never capture an existing free read of that name.


## Native module using boundary delta (2026-11-07)

The synchronous module-disposal change on base `2798bb50735f680c5313bfb0dd089ee57a8a5fd7`
adds exactly two production constructor expressions in
`src/transformer/es2025_using.zig::rewriteNativeModuleUsing`. The bounded current
inventory is **140 expressions, 90 functions, 45 files** (139 reachable production
expressions and the same one historical unreachable expression). Its fingerprint
is `d7283ab0073c53213c0f571b1cde149a9611032f3e8e9015761627fdcdb1ddb7`.
The script's base-plus-feature revision string is a source label, not a claim
that the unmodified base commit contains these expressions.

| Exact producer | Binding authority and final consumer |
| --- | --- |
| `makeExactSyntheticBindingFromSpan` for the acquisition guard | A fresh private binding declared by `declareSyntheticInScope` as `variable_const` in the actual program scope. Its exact SID is attached to references reading the original resource value and to the end-block reference; the linker/name planner consumes these same handles. Native `using` registers the guard only after the initializer and original dispose-method lookup succeed. |
| `makeExactSyntheticBinding` for the end-block guard | A distinct private binding declared in the constructor-owned generated block scope. Its initializer references the acquisition guard's exact SID from that scope; native block exit invokes the same idempotent per-resource guard. It is not a second acquisition or a name-based identity recovery. |

The original source binding is reused as a lexical `const` with its source SID;
its constructor-owned declaration payload carries lexical preservation through
actual visitor copies. Imports, exports, other lexical declarations, and class
self bindings retain their existing roles. The graph prepass admits this demand
from actual top-level synchronous `using` statements and publishes only through
the existing retained-graph output checks; it adds no Analyzer or reanalysis.
Programs with top-level `await using` retain the previous path. Ordinary TLA is
not itself an async-disposal request. The native helper captures disposal/call
intrinsics at its own initialization; this does not certify host-mutated or
late-loaded helper primordial environments. The two new constructor rows do not
expand the separate output-program/Worklet domains or claim whole-epic closure.
