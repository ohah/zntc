# SymbolId resolver and collision caller census

This is the live semantic-name caller census for [#6003](https://github.com/ohah/zntc/issues/6003), based on `origin/main` `999b67c8ee61b94773769eb4709c790ad0fc144c` (2026-10-22). It complements the bounded AST binding-constructor index in [SYMBOL_IDENTITY_PRODUCER_CENSUS.md](./SYMBOL_IDENTITY_PRODUCER_CENSUS.md). Resolver call count is not a missing-producer count; the two inventories have different denominators.

## Final spelling consumers

- [`Codegen.finalSymbolName`](../src/codegen/codegen.zig#L441) resolves a name from an exact `SymbolId`.
- Standalone late names are collected by [`buildStandaloneLateOutputNameOverrides`](../src/transpile.zig#L1212). It accepts only bindings registered for late output naming; dynamic scopes keep an early spelling.
- Bundler output hints are finalized by [`resolvePostGraphOutputHintNames`](../src/bundler/linker.zig#L3044), then the linker renames the exact graph symbol.
- Graphless and semantic-less paths have no `SymbolId`; they choose an early spelling and keep collision checks. They are not missing identity handoffs on the semantic path.

## Semantic resolver callers

| Caller family | Live caller files and functions | Identity passed to output | Mode and boundary |
| --- | --- | --- | --- |
| Class lowering and class self names | [`es2015_class.zig`](../src/transformer/es2015_class.zig): `classSuperParameterName`, `beginClassSelfWrite`, `emitClassSelfWriteTarget`, `lowerClassDeclaration`, `lowerClassExpression` | `_super`, class-self aliases, setter parameters, and anonymous-class bindings are declared in the generated IIFE or nearest var owner; references use those exact IDs and scopes. | Safe standalone names can be late; bundler names use the semantic graph. Plain resolver branches at the class-super callsites are graphless fallbacks. |
| `_newTarget` capture | [`buildFunctionFromConstructor`](../src/transformer/es2015_class/constructors.zig#L58), [`buildDefaultSuperConstructor`](../src/transformer/es2015_class/derived_constructors.zig#L569), [`wrapNativeParameterArrow`](../src/transformer/es2015_arrow.zig#L505), [`visitNodeInner`](../src/transformer/transformer/node_dispatch.zig#L875) | Constructor or arrow owner is fixed before declaration; capture records and generated references keep the same parameter/binding ID. | Late standalone or graph names where safe; graphless arrow fallback keeps its preselected spelling. |
| Derived-constructor `args` | [`es2022.zig`](../src/transformer/es2022.zig), [`class_member_helpers.zig`](../src/transformer/transformer/class_member_helpers.zig) | The generated constructor parameter and `super(...args)` reference share one exact ID at the constructor scope. | Early eval-aware spelling; graphless path has no ID. |
| JSX and Emotion runtime names | [`makeJsxRuntimeRef`](../src/transformer/jsx_lowering.zig#L168), [`ensureCssPropAlias`](../src/transformer/transformer/emotion.zig#L379) | JSX helper references/imports retain the helper or import ID. Emotion's CSS alias is declared in program scope and its generated read uses that ID. | Safe standalone or graph names; eval-sensitive branches choose early names. Resolver branches without semantic graph are graphless. |
| Styled-components, Refresh, and Flow helpers | [`resolveStyledInjectName`](../src/transformer/transformer/styled_components.zig#L1637), [`maybeExtractCssProp`](../src/transformer/transformer/styled_components.zig#L1766), [`resolveRefreshHandleName`](../src/transformer/transformer/refresh.zig#L168), [`visitFlowComponentWrapper`](../src/transformer/transformer/flow.zig#L525) | Tracked imports, Refresh registrations, and Flow helper references preserve the binding ID from declaration through generated reads. | Standalone late naming is limited to registered bindings; bundler graph paths keep exact IDs. Plain resolver fallbacks are semantic-less. |
| Stage 3 decorators | [`prepareStage3OutputName`](../src/transformer/transformer/stage3_decorator_transform.zig#L35), [`transformStage3Decorators`](../src/transformer/transformer/stage3_decorator_transform.zig#L183) | A staging name is selected before the generated wrapper is known; once the owner is established, the exact helper binding and references are registered in that scope. | Standalone or graph late naming when safe; dynamic scopes use early eval-aware names. Graphless transform has no SID handoff. |
| Generator state and tagged-template cache | [`generatorStateNameSpan`](../src/transformer/es2015_generator.zig#L3246), [`lowerTaggedTemplate`](../src/transformer/transformer/tagged_template.zig#L141) | `_state`, cache function, and cache data use exact callback/program/outer-scope IDs. Generated call and reference nodes retain those IDs. | Generator state uses early eval-aware or standalone late names. Tagged-template graph hints are attached to exact IDs; graphless paths keep early spellings. |
| Extracted loop and control-flow names | [`buildLoopClosureWithFlow`](../src/transformer/es2015_block_scoping.zig#L694), [`buildControlFlowCheck`](../src/transformer/es2015_block_scoping.zig#L1465), [`buildUniqueName`](../src/transformer/transformer/lists.zig#L175), [`buildUniqueNameAvoidingDynamicEval`](../src/transformer/transformer/lists.zig#L190) | `_loop` and `_ret` bindings are created at the emitted loop/function owner; deferred state-machine references carry the producer ID to the callback binder. | Standalone late names only where scope lookup is safe; other paths use eval-aware early names. |
| Object-super and for-of step helpers | [`uniqueHomeCaptureName`](../src/transformer/object_super.zig#L312), [`uniqueStepName`](../src/transformer/es2015_for_of.zig#L504) | Home parameters and loop step bindings are attached to their generated function or loop owner and references share the exact ID. | Graph and standalone late hints are exact-ID based. Early paths check direct-eval visibility and source collisions. |
| Worklet factory names | [`chooseFactoryLocalName`](../src/transformer/plugins/worklet_plugin.zig#L513), [`buildClassFactoryAssignment`](../src/transformer/plugins/worklet_plugin.zig#L1148) | Graph-backed factory binding and return reference are created in `wrapper_scope`; output hint uses that binding's exact ID. | Graph path finalizes by ID. Graphless naming checks module-wide eval visibility and has no semantic ID. Detached serialized payload identity remains #6002. |
| Anonymous-class export fallback | [`visitExportDefaultDeclaration`](../src/transformer/transformer/import_export.zig#L59) | `_Class` resolver is reached only when there is no semantic producer-map entry. The semantic path requires that entry and fails closed if it is absent. | Intentional spelling fallback for graphless transforms; not a semantic SID gap. |

The grouped list is exhaustive for live production calls to `resolveSyntheticName*`, `resolveScopedSyntheticOutputName`, `resolveGeneratedName*`, and their direct identity-aware wrappers. Tests and helper definitions are excluded. A fallback row means the caller deliberately lacks a semantic graph; it does not imply an unresolved semantic caller.

## Collision and temp allocators

The shared [`makeTempVarSpan`](../src/transformer/es_helpers.zig) allocator is used by these production caller groups:

| Caller group | Files |
| --- | --- |
| Destructuring | [`es2015_destructuring.zig`](../src/transformer/es2015_destructuring.zig) |
| Parameter temps | [`es2015_params.zig`](../src/transformer/es2015_params.zig) |
| Generator state-machine temps | [`es2015_generator.zig`](../src/transformer/es2015_generator.zig) |
| For-of, for-in, and for-await temps | [`es2015_for_of.zig`](../src/transformer/es2015_for_of.zig), [`es2018_for_await.zig`](../src/transformer/es2018_for_await.zig) |
| Class, decorator, and object-super helpers | [`es2015_class/super_props.zig`](../src/transformer/es2015_class/super_props.zig), [`class_visit.zig`](../src/transformer/transformer/class_visit.zig), [`class_decorator.zig`](../src/transformer/transformer/class_decorator.zig), [`object_super.zig`](../src/transformer/object_super.zig) |
| Other transforms | [`es2020.zig`](../src/transformer/es2020.zig), [`es2022_tla.zig`](../src/transformer/es2022_tla.zig), [`control_flow.zig`](../src/transformer/transformer/control_flow.zig), [`flow.zig`](../src/transformer/transformer/flow.zig) |

The allocator skips source/private/unresolved-name conflicts and statically known direct-eval names, then records the producer identity with its slot. Standalone and bundler late naming preserve that ID; graphless callers keep the chosen spelling. The optional-catch caller of `collidesWithUserSymbol` is [`es2019.zig`](../src/transformer/es2019.zig); the common temp allocator also uses it internally.

Additional unique-name paths audited:

- `es2025_using.zig::allocNames`, `uniqueSynthName`, and `uniqueSourceName` choose the using disposal temps, for-of using head, and default-export facade.
- `es2015_for_of.zig::uniqueForInNames` chooses generator state-machine key/index temps. `uniqueStepName` uses the dynamic-eval-aware builder and then checks source collisions.
- `object_super.zig` home capture and wrapper-parameter names use the dynamic-eval-aware builder and source-name check.
- `es2022_tla.zig::moveDefaultExport` chooses the facade binding moved after a top-level await.
- `synthetic_taken` reserves standalone final names for generated symbols in [`transpile.zig`](../src/transpile.zig#L1251).

## Direct-eval name finding

Raw source-name scans miss identifiers that are visible through a statically known direct-eval string but appear escaped in source, for example `eval('typeof \\u005fstack')`. This census led to eval-aware collision checks for all three `using` name allocators, generator `for-in` key/index names, and the top-level-await default-export facade. Scoped callers check their current owner scope; scope-less fallbacks check all dynamic-eval scopes. The helper conservatively scans decoded string literals and statically computable concatenations/templates, so a matching token in an unrelated string can skip a candidate but cannot make a generated binding visible to eval by mistake.

Regression coverage includes escaped and decoded Unicode/hex identifiers, single/double-quoted literals, concatenation, parentheses, templates and interpolation, split string pieces, constant string variables, generated for-of using heads, using export facades, generator for-in temps, and a moved TLA default export. See `#6003` tests in [`es2025_using.zig`](../src/transformer/es2025_using.zig), [`es2015_for_of.zig`](../src/transformer/es2015_for_of.zig), [`es2022_tla.zig`](../src/transformer/es2022_tla.zig), and [`transpile.zig`](../src/transpile.zig).

## Scope exclusions and completion status

- Worklet detached serialized AST binding is #6002.
- The producer denominator and missing-producer count are #5980.
- Semantic reanalysis and `captureRenamesToPending` are #5955.
- Name/span recovery after temp production is #6004.

All live semantic resolver caller families were classified at this baseline. This caller audit does not establish that every #4819 producer is complete, remove semantic reanalysis, or complete the A-plan migration.
