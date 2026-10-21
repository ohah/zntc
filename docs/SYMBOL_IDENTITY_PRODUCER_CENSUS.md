# SymbolId producer census: bounded AST binding constructors

이 문서는 [#5980](https://github.com/ohah/zntc/issues/5980)의 source census를 위한 bounded AST binding constructor 호출 위치 색인이다. 이 색인은 빠진 `SymbolId` 수가 아니다. 경로별 identity/owner/최종 이름 소비자 분류는 별도 [#6120](https://github.com/ohah/zntc/issues/6120)에서 진행한다.

## 기준과 계수

- 기준 커밋: `230d0eaa2df06583d10dbe0ce5b5c17b151b2863` (`origin/main`, PR #6119 병합 후).
- 분모: production callsite 112곳, 70개 함수, 35개 파일.
- 기존 다섯 constructor 계열: 110곳. `makeSyntheticBinding` 50, `makeExactSyntheticBinding` 26, `makeExactSyntheticBindingFromSpan` 20, `createSyntheticTempBinding` 10, `makeUsingBinding` 4.
- 별도 exact-identity helper `createSyntheticTempBindingWithIdentity`: production callsite 2곳.
- 세는 항목은 아래 여섯 helper의 실제 production call expression이다. 생성자 정의와 helper 내부 위임은 중복 계산하지 않는다. 전용 test 파일, inline `test` block, 테스트에서만 부르는 `checkGeneratorAssignmentBindingIdentity`와 `checkGeneratorHoistProducerUsesExactBindingHandle`도 제외한다.

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
| [`src/transformer/es2015_for_of.zig`](../src/transformer/es2015_for_of.zig) | `makeVarDeclFromSpan`: `makeSyntheticBinding` L574<br>`rewriteForIn`: `createSyntheticTempBinding` L374,375,376,377<br>`rewriteForOf`: `makeExactSyntheticBinding` L264; `makeExactSyntheticBindingFromSpan` L204; `makeSyntheticBinding` L122,142,162,186 |
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
| [`src/transformer/transformer/semantic_edit.zig`](../src/transformer/transformer/semantic_edit.zig) | `splitParameterBodyVarBinding`: `makeExactSyntheticBinding` L4312 |
| [`src/transformer/transformer/stage3_decorator_helpers.zig`](../src/transformer/transformer/stage3_decorator_helpers.zig) | `buildAccessObject`: `makeSyntheticBinding` L496,544,599,601<br>`buildMetadataDecl`: `makeExactSyntheticBindingFromSpan` L726<br>`buildSetterMethodWithHandles`: `makeSyntheticBinding` L1102<br>`makeLetWithBinding`: `makeSyntheticBinding` L942<br>`makeLetWithExactBinding`: `makeExactSyntheticBinding` L950 |
| [`src/transformer/transformer/stage3_decorator_transform.zig`](../src/transformer/transformer/stage3_decorator_transform.zig) | `valueParam`: `makeSyntheticBinding` L1717 |
| [`src/transformer/transformer/styled_components.zig`](../src/transformer/transformer/styled_components.zig) | `forwardTemplateInterpolations`: `makeSyntheticBinding` L1431<br>`maybeExtractCssProp`: `makeSyntheticBinding` L1778,1813 |
| [`src/transformer/transformer/tagged_template.zig`](../src/transformer/transformer/tagged_template.zig) | `lowerTaggedTemplate`: `makeExactSyntheticBinding` L236 |
| [`src/transformer/transformer/worklet.zig`](../src/transformer/transformer/worklet.zig) | `buildClosureDestructuring`: `makeExactSyntheticBinding` L1069<br>`generateInitCode`: `makeSyntheticBinding` L976 |

## 분모 밖에 남겨 둔 producer/consumer 경계

이 112곳은 AST binding constructor 호출만 센다. reference-only temp reservation, plugin/linker가 소유하는 output binding, detached Worklet `__initData.code`, semantic-less/graphless lowering은 이 분모에 넣지 않았다. 이 경계는 `docs/SYMBOL_IDENTITY_MIGRATION.md`와 #5952, #5955, #6002, #6003, #6004 등 각각의 열린 issue에서 별도로 추적한다. 분모 밖이라는 이유만으로 완료 처리하지 않는다.

## 아직 확정하지 않은 결과

현재 확인된 것은 호출 위치의 분모뿐이다. 이 표에서 owner/ID handoff와 final-name consumer를 모두 대조하고 기존 child issue 및 의도된 fallback과 중복 제거하기 전에는 미완료 producer의 정확한 수를 산출할 수 없다. [#6120](https://github.com/ohah/zntc/issues/6120)에서 각 source-index 행을 identity family와 follow-up issue에 연결하고 미분류 행을 0으로 만든다.
