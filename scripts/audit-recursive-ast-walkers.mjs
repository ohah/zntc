#!/usr/bin/env node
// 재귀 AST walker durability audit (#4123).
//
// 배경: `a + b + c + … (수천 항)` 같은 깊은 좌결합 트리를 AST visitor 가 재귀로 내려가면
// 스택 오버플로우(#4123). 대책으로 핫패스/공통 walker 를 `ast_walk.walkPreorderIterative`
// (명시 스택 반복 순회)로 전환했다. 문제는 **새 walker 가 또 재귀로 children() 을 돌면 버그가
// 조용히 재유입**된다는 것. 이 audit 이 그 tripwire 다.
//
// 규칙: src/ 안의 모든 `ast_walk.children()` 호출처(주석/정의 제외)는 아래 ALLOWLIST 의
// 한 분류에 *명시적으로* (file::fn 키로) 등록돼야 한다. 등록 안 된 신규 호출처가 있으면 CI 실패.
// iterative_safe / one_level 항목은 함수 본문에 직접 자기 재귀 호출이 다시 들어와도 CI 실패한다.
//   - iterative_safe   : 명시 스택/큐/collector 또는 sanctioned 헬퍼(walkPreorderIterative).
//                        깊이 무관 안전.
//   - one_level        : 재귀 없이 직계 자식만 1단계 순회(flat). 깊이 무관 안전.
//   - bounded_recursive: explicit numeric depth cap; conservative limit result, reviewed per edge.
//   - recursive_tracked: 아직 재귀라 깊은 체인서 overflow 가능. #4123 PR-2c 에서 반복화 예정.
//                        (전환되면 children() 대신 walkPreorderIterative 를 써 이 목록에서 빠짐.)
//
// 신규 walker 작성자에게: 서브트리를 재귀 순회해야 하면 **반드시 walkPreorderIterative** 를
// 써라(또는 명시 스택). 직계 1단계만 보면 one_level 로, 깊이 가드(cap)가 있으면 그 함수에
// 가드 주석을 달고 iterative_safe 로 등록하라.
//
// 한계(정직히): 이 audit 은 `ast_walk.children()` 기반 일반 순회만 본다. binary/unary 노드의
// left/right 를 *직접* 재귀(visitBinaryNode/emitBinary 식 rebuild/emit)하는 특수 패턴, 그리고
// depth-cap 이 달린 direct-recursion evaluator(purity/import_scanner 등)는 이 audit 밖이다 —
// 전자는 좌-스파인 평탄화(#4123 PR-1), 후자는 자체 depth guard 로 안전. 키를 file::fn 으로 둬
// 동명 walker 우회를 막고, fn 선언이 여러 줄로 쪼개져도(`fn name(\n …)`) 잡도록 한다.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve, relative } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const srcRoot = join(root, 'src');

// "<relpath>::<fn>" → { class, note }. class ∈ {iterative_safe, one_level, bounded_recursive, recursive_tracked}.
// 파일 경로로 스코프해 동명 walker 가 분류를 상속하는 false-negative 를 차단.
const ALLOWLIST = {
  'src/transformer/ast_plugin.zig::registerInjectedFunctionScopes': {
    class: 'iterative_safe',
    note: 'explicit Work stack carries insertion ScopeId; visited node ids prevent repeated or cyclic descent',
  },
  'src/semantic/class_key_evaluation.zig::completeIife': {
    class: 'iterative_safe',
    note: 'explicit node stack and reachable set prove memo membership in the actual completed IIFE body',
  },
  'src/bundler/lowered_tla_publication.zig::hasSuspension': {
    class: 'iterative_safe',
    note: 'explicit work stack and visited set over the selected owned initializer; source function boundaries are skipped',
  },
  'src/transformer/loop_dynamic_capture.zig::initializedBefore': {
    class: 'one_level',
    note: 'source-parent chain proof plus one-level statement-list ordering',
  },
  'src/transformer/loop_dynamic_capture.zig::checkLoop': {
    class: 'iterative_safe',
    note: 'explicit source worklist and iterative reachable collector; no recursive AST descent',
  },
  'src/transformer/loop_dynamic_capture.zig::preflight': {
    class: 'iterative_safe',
    note: 'explicit source-owner stack records scope and actual enclosing lowering mode',
  },
  'src/transformer/generator_native_lexical.zig::publishSameCaseClasses': {
    class: 'iterative_safe',
    note: 'explicit heap Work stack selects actual retained class declarations without recursive descent',
  },
  'src/transformer/generator_native_lexical.zig::classCases': {
    class: 'iterative_safe',
    note: 'explicit heap Work stack tracks actual generated state-case ownership without recursive descent',
  },
  // Exact main1f417 audit: actual function bodies reviewed; inline tests tracked separately.
  'src/bundler/graph/transform_prepass.zig::methodSuperUsesOnlyBodyOrSyncArrowChain': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/bundler/graph/transform_prepass.zig::reachableDirectEvalCallsHaveScopeFacts': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/bundler/self_namespace_ast.zig::source': {
    class: 'one_level',
    note: 'flat direct-child edge scan over reachable from the iterative reachable-node collector',
  },
  'src/bundler/self_namespace_ast.zig::foreignSource': {
    class: 'one_level',
    note: 'flat direct-child edge scan over reachable from the iterative reachable-node collector',
  },
  'src/bundler/static_import_callsite.zig::lower': {
    class: 'one_level',
    note: 'flat direct-child edge scan over live from the iterative reachable-node collector',
  },
  'src/bundler/tree_shaker/cjs_patterns.zig::nodeBufferCapabilityValuesAreStable': {
    class: 'iterative_safe',
    note: 'explicit pending/stack heap worklist enqueues children without recursive descent',
  },
  'src/bundler/tree_shaker/cjs_patterns.zig::fallbackFunctionGraphIsStable': {
    class: 'one_level',
    note: 'flat direct-child edge scan over reachable_nodes from the iterative reachable-node collector',
  },
  'src/semantic/scope_frame_history.zig::captureComputedAwaitSources': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/semantic/scope_frame_history.zig::captureInitializers': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/semantic/source_drop_registry.zig::validatesEdge': {
    class: 'one_level',
    note: 'direct-child iterator checks stored edge ordinal and payload without descendant traversal',
  },
  'src/semantic/source_drop_registry.zig::validatesEdges': {
    class: 'one_level',
    note: 'direct-child iterator checks stored edge ordinal and payload without descendant traversal',
  },
  'src/semantic/source_drop_registry.zig::validatesStatement': {
    class: 'one_level',
    note: 'direct-child iteration builds parent edges over an already collected node list without recursive descent',
  },
  'src/semantic/statement_coordinates.zig::collect': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/class_initializer_publication.zig::parents': {
    class: 'one_level',
    note: 'flat direct-child edge scan over nodes from the iterative reachable-node collector',
  },
  'src/transformer/class_strict_context.zig::moveInitializerScopes': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/class_strict_context.zig::moveSourceReferencesIntoFactory': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/computed_object_helper_authority.zig::validate': {
    class: 'one_level',
    note: 'flat direct-child edge scan over nodes from the iterative reachable-node collector',
  },
  'src/transformer/deferred_super_class_lowering.zig::inspectConstructor': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/drop_statement_retirement.zig::capture': {
    class: 'one_level',
    note: 'direct-child iteration builds parent edges over an already collected node list without recursive descent',
  },
  'src/transformer/drop_statement_retirement.zig::detachLiveUses': {
    class: 'one_level',
    note: 'flat direct-child parent-map construction over live.keyIterator; ancestor lookup has node-count fuel',
  },
  'src/transformer/erased_const_enum_handoff.zig::detachErasedUses': {
    class: 'one_level',
    note: 'flat direct-child parent-map construction over live.keyIterator; ancestor lookup has node-count fuel',
  },
  'src/transformer/es2015_arrow.zig::lexicalCapturesInWith': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_arrow.zig::hasLexicalSuperArrowMode': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_arrow.zig::findLexicalParameterCaptureNode': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_block_scoping.zig::bindExtractedBodyVarStorage': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_block_scoping.zig::prepareExtractedGeneratorBody': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_block_scoping.zig::lowerExtractedNativeAnnexB': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_class/members.zig::classifyMembers': {
    class: 'iterative_safe',
    note: 'explicit enum_stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_class/methods.zig::sourceRootHasDynamicEnvironment': {
    class: 'bounded_recursive',
    boundedContract: {
      parameter: 'depth',
      type: 'usize',
      limit: 256,
      increment: 1,
      recursiveEdges: 2,
    },
    note: 'depth starts at zero, both recursive edges increment it, and depth > 256 returns conservative unsafe true',
  },
  'src/transformer/es2015_for_of.zig::bindingHeadSuspends': {
    class: 'iterative_safe',
    note: 'explicit pending heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_for_of.zig::moveLoopHead': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_generator.zig::movePrivateCaseBindingsAndReferences': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_generator.zig::moveCaseReferences': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2015_generator.zig::appendAnnexBVariableStorage': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2022_tla.zig::moveWrappedReferenceScopes': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es2025_using.zig::moveUsingRegionToScope': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es_helpers.zig::privateFactorySourceHasUnsafeEval': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/es_helpers.zig::relocatePrivateReferences': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/initializer_clone.zig::bindPendingCaptures': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/initializer_clone.zig::cloneImpl': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/legacy_assignment_field_certificate.zig::complete': {
    class: 'one_level',
    note: 'flat direct-child edge scan over nodes from the iterative reachable-node collector',
  },
  'src/transformer/legacy_static_field_block_certificate.zig::complete': {
    class: 'one_level',
    note: 'flat direct-child edge scan over nodes from the iterative reachable-node collector',
  },
  'src/transformer/loop_await_driver.zig::enqueueSourceChildren': {
    class: 'one_level',
    note: 'one-level child collection appends to the caller-owned stack consumed by iterative driver loops',
  },
  'src/transformer/minify.zig::initializerLexicalReadsInitialized': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/minify.zig::mergeDeclsPreserving': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_arrow_statement_publication.zig::localOwner': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_constructor_body_scope.zig::prepare': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_constructor_guard.zig::instrumentSourceTries': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_constructor_timing.zig::hasDeferredSuper': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_derived_this.zig::needsCellInScope': {
    class: 'iterative_safe',
    note: 'explicit worklist heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_noop_graph.zig::shape': {
    class: 'iterative_safe',
    note: 'explicit todo heap worklist enqueues children without recursive descent',
  },
  'src/transformer/native_noop_graph.zig::recordFunctionFormals': {
    class: 'one_level',
    note: 'paired old_children/new_children iterators compare only direct formal-parameter edges',
  },
  'src/transformer/native_private_field_certificate.zig::build': {
    class: 'one_level',
    note: 'flat direct-child edge scan over nodes from the iterative reachable-node collector',
  },
  'src/transformer/object_super.zig::findHomeObjectParentScope': {
    class: 'iterative_safe',
    note: 'explicit queue heap worklist enqueues children without recursive descent',
  },
  'src/transformer/optional_nullish_composition.zig::init': {
    class: 'one_level',
    note: 'flat direct-child edge scan over nodes from the iterative reachable-node collector',
  },
  'src/transformer/retained_class_keys.zig::singleEvaluationOwner': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/retained_class_keys.zig::prepareLoopBody': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/retained_field_arrow.zig::collect': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/sideeffect_entry_graph.zig::shape': {
    class: 'iterative_safe',
    note: 'explicit todo heap worklist enqueues children without recursive descent',
  },
  'src/transformer/static_class_capture.zig::noteArrowDynamicEval': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/symbol_coverage.zig::validateNodeScopeProvenance': {
    class: 'one_level',
    note: 'flat direct-child edge scan over reachable from the iterative reachable-node collector',
  },
  'src/transformer/symbol_coverage.zig::hasExactReachableScopeOwnership': {
    class: 'one_level',
    note: 'builds parent edges from direct children of the caller-provided iterative reachable-node list',
  },
  'src/transformer/symbol_coverage.zig::hasExactReachableReferenceResolution': {
    class: 'one_level',
    note: 'builds parent edges from direct children of the caller-provided iterative reachable-node list',
  },
  'src/transformer/symbol_coverage.zig::nestedEnumAuditFixture': {
    class: 'one_level',
    note: 'flat direct-child edge scan over source_nodes/nodes from the iterative reachable-node collector',
  },
  'src/transformer/transformer/declarations.zig::hasDeferredNativeSuper': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/declarations.zig::placeNativeInitializer': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/declarations.zig::insertLoweredSuperInitializers': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/declarations.zig::insertNativeSuperInitializers': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/legacy_decorator_helpers.zig::moveDecoratorExpression': {
    class: 'iterative_safe',
    note: 'explicit pending heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/semantic_edit.zig::bindOutputScopesAndReferencesChecked': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/semantic_edit.zig::retargetDeferredGeneratorForInBodyReferences': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/semantic_edit.zig::bindDeferredGeneratorForInBodyReferences': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/transformer/semantic_edit.zig::retireErasedImportBindings': {
    class: 'one_level',
    note: 'flat direct-child parent-map construction over live.keyIterator; ancestor lookup has node-count fuel',
  },
  'src/transformer/transformer/semantic_edit.zig::moveStaticBlockSourceReferences': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/virtual_helper_provider_certificate.zig::nearestOwner': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/worklet_class_clone.zig::publishChecked': {
    class: 'iterative_safe',
    note: 'explicit pending heap worklist enqueues children without recursive descent',
  },
  'src/transpile.zig::reserveStandaloneExplicitGlobalShadows': {
    class: 'iterative_safe',
    note: 'explicit stack heap worklist enqueues children without recursive descent',
  },
  'src/transformer/async_parameter_var_cells.zig::hasBodyCellDeclaration': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack; actual var binding leaves and typed FDI roles select rewrite demand; nested function/class boundaries excluded',
  },
  'src/transformer/async_parameter_var_cells.zig::moveBodyReferences': {
    class: 'iterative_safe',
    note: 'explicit Work stack under the actual generated function edge; nested function/class boundaries are excluded',
  },
  'src/transformer/async_parameter_var_cells.zig::normalize': {
    class: 'iterative_safe',
    note: 'explicit Work stack carrying lexical scope; nested function/class boundaries are excluded',
  },
  // --- sanctioned 헬퍼 / 명시 스택·큐·collector (깊이 무관 안전) ---
  'src/parser/ast_walk.zig::walkPreorderIterative': {
    class: 'iterative_safe',
    note: 'the sanctioned iterative helper',
  },
  'src/parser/ast_walk.zig::collectChildrenInto': {
    class: 'iterative_safe',
    note: 'sanctioned child-collection entry point for iterative worklists (#4123 PR-2c)',
  },
  'src/bundler/stmt_info.zig::mapReachableNodesToStmts': {
    class: 'iterative_safe',
    note: 'explicit node stack per top-level statement; each node visited once (#5446)',
  },
  'src/bundler/emitter/dead_store.zig::stmtBreaksFlow': {
    class: 'iterative_safe',
    note: '명시 스택(worklist)으로 서브트리 순회 — 두 store 사이 statement 가 바깥 흐름을 끊는지 판정 (#4503). 재귀 없음.',
  },
  'src/bundler/linker.zig::resolveExplicitGlobalShadowsInModule': {
    class: 'iterative_safe',
    note: 'NodeIndex work stack expands each AST node once; children() is only used to enqueue direct children.',
  },
  'src/parser/ast_walk.zig::collectReachableNodeIndicesFrom': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + visited bitmap; collectReachableNodeIndices delegates here, and child-buffer entries are pushed in reverse preorder',
  },
  'src/transformer/minify.zig::markReachableNodes': { class: 'iterative_safe', note: 'BFS queue' },
  'src/transformer/es2015_arrow.zig::findLexicalNewTargetSpan': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + seen set; lexical new.target search skips non-arrow function/class boundaries',
  },
  'src/transformer/es2015_arrow.zig::lexicalCaptures': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack + seen set; method/field lexical boundaries are pushed without recursive descent',
  },
  'src/transformer/es2015_arrow.zig::hasLexicalSuperArrow': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack + seen set; nested arrow capture scans are themselves iterative',
  },
  'src/transformer/es2015_block_scoping.zig::collectChildIndices': {
    class: 'iterative_safe',
    note: 'one-level collector feeding caller stack',
  },
  'src/transformer/transformer/worklet.zig::collectAllIdentifiers': {
    class: 'iterative_safe',
    note: 'explicit stack (worklet)',
  },
  'src/transformer/transformer/worklet.zig::collectNewExpressionCallees': {
    class: 'iterative_safe',
    note: 'explicit stack (worklet)',
  },
  'src/transformer/ast_plugin.zig::collectInjectedReferenceNodeIndices': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack + visited bitmap skips static member property names while retaining receiver references',
  },
  'src/transformer/transformer/worklet.zig::walkBodyForClosureAnalysis': {
    class: 'iterative_safe',
    note: 'heap-backed ClosureScopeFrame array; frame.nodes worklist handles ordinary descent; nested function/arrow/method pushes a frame and finished child references merge into the parent without native recursion',
  },
  'src/bundler/tree_shaker/const_materialize.zig::anyReachableNode': {
    class: 'iterative_safe',
    note: 'numeric_dfs_stack',
  },
  'src/semantic/reference_walk.zig::collectReferences': {
    class: 'iterative_safe',
    note: 'explicit Edge stack and states map; heritage modes stop at nested execution boundaries',
  },
  'src/transformer/es2015_class.zig::recordExpressionHeritage': {
    class: 'iterative_safe',
    note: 'owners NodeIndex worklist and seen map stop at function/class owners; separate heritage-reference collector preserves call arguments',
  },
  'src/transformer/heritage_dynamic_scope.zig::potentialEval': {
    class: 'iterative_safe',
    note: 'NodeIndex stack scans parser expression edges and skips nested function/class execution',
  },
  'src/transformer/heritage_dynamic_scope.zig::preflight': {
    class: 'iterative_safe',
    note: 'Work stack carries final/source strictness separately; class heritage and body enqueue distinct contexts without native recursion',
  },
  'src/transformer/es2015_class/members.zig::moveInstanceInitScopes': {
    class: 'iterative_safe',
    note: 'explicit node stack for field initializer scope transfer',
  },
  'src/transformer/es2015_class/private_fields.zig::trackPrivateMethodSymbols': {
    class: 'iterative_safe',
    note: 'scoped Work stack + seen set; collected helper bindings/references are attached in flat follow-up loops',
  },
  'src/transformer/es_helpers.zig::capturePrivateClassSelf': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack + seen set scans exact class-self references and direct eval without recursion',
  },
  'src/transformer/es_helpers.zig::privateMethodNeedsClassSelfCapture': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack + seen set classifies source references and private names before lowering; nested classes are skipped without recursion',
  },
  'src/transformer/es2015_class/private_fields.zig::trackGeneratedParameterSymbols': {
    class: 'iterative_safe',
    note: 'scoped Work stack + seen set; parameter references are registered without recursively visiting children',
  },
  'src/transformer/es2017.zig::moveAsyncGeneratorBodyScopes': {
    class: 'iterative_safe',
    note: 'explicit node stack for async generator scope transfer',
  },
  'src/transformer/minify.zig::mergeDecls': {
    class: 'iterative_safe',
    note: 'explicit node stack before adjacent declaration merge',
  },
  'src/transformer/object_super.zig::homeObjectParentScope': {
    class: 'iterative_safe',
    note: 'cursor-driven NodeIndex queue + seen set; scope ownership is a map lookup',
  },
  'src/transformer/object_super.zig::valuesFunctionContextUse': {
    class: 'iterative_safe',
    note: 'parent-tagged work stack + seen set scans values/computed keys and skips nested function bodies',
  },
  'src/transformer/object_super.zig::valuesHaveDynamicLookup': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + seen set scans value expressions/computed keys and skips nested function bodies',
  },
  'src/transformer/object_super.zig::collectLexicalArgumentsReferences': {
    class: 'iterative_safe',
    note: 'parent-tagged NodeIndex stack + seen set collects lexical arguments references',
  },
  'src/transformer/object_super.zig::collectHomeArgumentsAliasReferences': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + seen set collects rewritten alias references without recursion',
  },
  'src/transformer/object_super.zig::trackHoistedHomeReferences': {
    class: 'iterative_safe',
    note: 'cursor-driven scoped Work queue + seen set; children are enqueued while exact home references are recorded',
  },
  'src/transformer/object_super.zig::bindWrappedHomeParameter': {
    class: 'iterative_safe',
    note: 'cursor-driven scoped worklist + seen set; wrapper scope/reference updates do not recurse through the AST',
  },
  'src/transformer/object_super.zig::scanMethodSuper': {
    class: 'iterative_safe',
    note: 'explicit work stack tracks async-arrow context while crossing class keys and method boundaries',
  },
  'src/transformer/transformer/enum.zig::refersToPriorMember': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack scans initializer descendants; static member access descends only into its receiver',
  },
  'src/transformer/options.zig::hasLoweredArrowCapture': {
    class: 'iterative_safe',
    note: 'explicit stack + (node, arrow-context) seen set; function/method/field boundaries are queued explicitly',
  },
  'src/transformer/minify.zig::build': {
    class: 'iterative_safe',
    note: 'explicit node stack + visited bitmap builds statement-owner and parent maps',
  },
  'src/codegen/statements.zig::discriminantReadsLoweredName': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack scans discriminant descendants and returns on an exact lowered-name match',
  },
  'src/bundler/graph/transform_prepass.zig::methodSuperUsesOnlyDirectMethodBody': {
    class: 'iterative_safe',
    note: 'explicit work stack tracks nested-function boundaries while scanning method parameters/body',
  },
  'src/bundler/graph/transform_prepass.zig::methodSuperUsesOnlyArrowScopes': {
    class: 'iterative_safe',
    note: 'explicit scoped work stack tracks arrow depth/owner and validates parameter/body nodes',
  },
  'src/bundler/graph/transform_prepass.zig::isRetainableDirectSuperPropertyAccess': {
    class: 'iterative_safe',
    note: 'pending NodeIndex stack + seen set validates the property subtree without recursion',
  },
  'src/bundler/graph/transform_prepass.zig::collectRetainedPreflightParents': {
    class: 'iterative_safe',
    note: 'explicit enter/exit DFS stack records parent edges and detects cycles',
  },
  'src/bundler/graph/transform_prepass.zig::collectMinifiedStatementContexts': {
    class: 'iterative_safe',
    note: 'explicit statement-context stack enqueues direct children; repeated nodes are checked for consistent context without recursion',
  },
  'src/bundler/graph/transform_prepass.zig::es5AsyncArrowLexicalCaptures': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack collects lexical captures while respecting function boundaries',
  },
  'src/bundler/graph/transform_prepass.zig::methodSuperUsesInAsyncArrowScopesOrDirectBody': {
    class: 'iterative_safe',
    note: 'explicit scoped work stack tracks method-body and async-arrow context',
  },
  'src/bundler/tree_shaker/cjs_patterns.zig::appendSubtreeNodes': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack + seen bitset appends each reachable node once',
  },
  'src/bundler/emitter/esm_wrap.zig::collectNestedVarDecls': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack skips function/class boundaries and collects module-scope var declarations',
  },
  'src/transformer/output_scope_test_utils.zig::buildParentMap': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + reachable set; direct parent edges are recorded before children are pushed',
  },
  'src/transformer/symbol_coverage.zig::checkExactImpl': {
    class: 'iterative_safe',
    note: 'reachable_stack + reachable_nodes set; ambiguous-parent scope checks use a bounded parent-chain loop',
  },
  'src/transformer/symbol_coverage.zig::countCyclicAstEdges': {
    class: 'iterative_safe',
    note: 'VisitFrame entry/exit stack + visiting/visited state map; children are pushed onto the stack and seen nodes are not expanded, so back-edge detection does not recurse',
  },
  'src/transformer/symbol_coverage.zig::collectFlowMatchPatternDeclarations': {
    class: 'iterative_safe',
    note: 'explicit NodeIndex stack traverses Flow match pattern containers; each handled child is enqueued without recursive descent',
  },
  'src/transformer/transformer/control_flow.zig::findBindingWithSymbol': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + seen set searches captured-loop bindings by SymbolId',
  },
  'src/transformer/transformer/control_flow.zig::rebindLoopStorageReferences': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + seen set; rebindOutputReference updates semantic records without descending into children',
  },
  'src/transformer/transformer/semantic_edit.zig::bindGeneratedState': {
    class: 'iterative_safe',
    note: 'explicit node stack for generated state references',
  },
  'src/transformer/transformer/semantic_edit.zig::bindOutputScopesAndReferences': {
    class: 'iterative_safe',
    note: 'OutputScopeWork stack + seen set; later binding/reference passes use collected lists and the iterative local-symbol walker',
  },
  'src/transformer/transformer/semantic_edit.zig::collectGeneratedNodeTraces': {
    class: 'iterative_safe',
    note: 'GeneratedNodeVisit stack + visited (node, scope) keys; reference flags are computed one edge at a time',
  },
  'src/transformer/transformer/semantic_edit.zig::collectGeneratedLoopNodes': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + nodes set; appendGeneratedLoopExtraList only pushes decorator/enum/Flow children onto that stack',
  },
  'src/transformer/transformer/semantic_edit.zig::registerGeneratedFunctionScopes': {
    class: 'iterative_safe',
    note: 'scoped Work stack + seen set; generated scope creation only updates semantic tables',
  },
  'src/transformer/transformer/semantic_edit.zig::completeGeneratedStateSymbols': {
    class: 'iterative_safe',
    note: 'scoped Work stack + seen set; deferred-state and generated-local follow-up walks each use explicit stacks',
  },
  'src/transformer/transformer/semantic_edit.zig::bindDeferredGeneratedStateSymbols': {
    class: 'iterative_safe',
    note: 'per-callback NodeIndex stack + visited set; pending reference membership only selects symbols to attach',
  },
  'src/transformer/transformer/semantic_edit.zig::trackGeneratedLocalSymbols': {
    class: 'iterative_safe',
    note: 'scoped Work stack + seen set; collected binding/reference loops use bounded scope-ancestry lookups',
  },
  'src/transformer/transformer/semantic_edit.zig::reparentGeneratedBodyScopes': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + live set; liveScopeOwners and reparentLiveSourceScopes iterate maps and bounded scope chains',
  },
  'src/transformer/transformer/semantic_edit.zig::reparentMovedStaticInitializerScopes': {
    class: 'iterative_safe',
    note: 'NodeIndex stack + seen set visits each initializer node once; scope-parent checks and reparenting do not recurse',
  },
  'src/transformer/transformer/semantic_edit.zig::moveGeneratedFunctionBodyBindings': {
    class: 'iterative_safe',
    note: 'work_stack + seen set records exact source binding nodes for later scope relocation',
  },
  'src/transformer/transformer/semantic_edit.zig::bindGeneratedFunctionTemps': {
    class: 'iterative_safe',
    note: 'explicit node stack for generated function temps',
  },

  // --- 직계 1단계만 (재귀 없음) ---
  'src/bundler/runtime_polyfills.zig::markSkippedIdentifiers': {
    class: 'one_level',
    note: 'import/export specifiers only, flat outer loop',
  },
  'src/bundler/constant_facts.zig::markMinifySensitiveIdentifierRefs': {
    class: 'one_level',
    note: 'one level, flat outer for',
  },
  'src/bundler/graph/transform_prepass.zig::hasDirectSpreadElement': {
    class: 'one_level',
    note: 'only checks direct child tags for spread_element; caller loops over an iteratively collected reachable-node list',
  },
  'src/bundler/graph/transform_prepass.zig::isRetainableAssignmentTarget': {
    class: 'iterative_safe',
    note: 'NodeIndex worklist + visited set checks every descendant without recursion',
  },

  // --- recursive_tracked: 없음 ---
  // #4123 PR-2c 에서 마지막 6개 재귀 walker(walkFunctionVarBindingPatterns / scanChildrenForUnsupportedBindingLiteShadow /
  // markBindingLiteValueUses / rewriteAwaitToYieldAwait / visitTypeContextNode / hasRawPrivateSyntax)를 전부 반복화했다.
  // 이들은 이제 children() 을 직접 호출하지 않고 `ast_walk.collectChildrenInto`(또는 walkPreorderIterative)를 경유하므로
  // 이 audit 의 children() 호출처 목록에서 사라진다 → recursive_tracked=0. 새 재귀 walker 가 children() 을 직접 돌면
  // 미분류 violation 으로 다시 잡힌다.
};

function listZigFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...listZigFiles(p));
    else if (entry.endsWith('.zig')) out.push(p);
  }
  return out;
}

// Function-body scan used to catch a listed iterative walker being changed back
// into direct recursion. Ignore Zig line comments and quoted/multiline strings
// so braces and function-name text inside them cannot affect the scan.
function stripZigCode(line) {
  if (line.trimStart().startsWith('\\\\')) return ''; // multiline string line
  let out = '';
  let quote = null;
  let escaped = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote !== null) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '/' && line[i + 1] === '/') break;
    out += ch;
  }
  return out;
}

// Closed-world tripwire for the single reviewed bounded recursive walker.
// This deliberately validates its exact initial guard, not arbitrary Zig proofs.
function boundedContractValid(source, name, contract) {
  const code = source.split('\n').map(stripZigCode).join('\n');
  const declaration = new RegExp(`\\bfn\\s+${name}\\s*\\(`).exec(code);
  if (!declaration) return false;
  // Only decrement for a matching closing delimiter.
  const endOf = (start, open, close) => {
    let depth = 0;
    for (let i = start; i < code.length; i++) {
      if (code[i] === open) depth++;
      else if (code[i] === close) {
        depth--;
        if (depth === 0) return i;
      }
    }
    return -1;
  };
  const parameterStart = code.indexOf('(', declaration.index);
  const parameterEnd = endOf(parameterStart, '(', ')');
  if (
    parameterEnd < 0 ||
    !new RegExp(`\\b${contract.parameter}\\s*:\\s*${contract.type}\\b`).test(
      code.slice(parameterStart, parameterEnd),
    )
  )
    return false;
  const bodyStart = code.indexOf('{', parameterEnd);
  const bodyEnd = endOf(bodyStart, '{', '}');
  if (bodyStart < 0 || bodyEnd < 0) return false;
  const compact = (text) => text.replace(/\s+/g, '');
  const guard = `if(index.isNone()or@backingInt(index)>=ast.nodes.items.lenor${contract.parameter}>${contract.limit})returntrue;`;
  if (!compact(code.slice(bodyStart + 1, bodyEnd)).startsWith(guard)) return false;
  let edges = 0;
  const calls = new RegExp(`\\b${name}\\s*\\(`, 'g');
  calls.lastIndex = bodyStart + 1;
  for (let call; (call = calls.exec(code)) && call.index < bodyEnd; ) {
    const start = code.indexOf('(', call.index);
    const end = endOf(start, '(', ')');
    if (end < 0 || end > bodyEnd) return false;
    let nesting = 0;
    let last = start + 1;
    for (let i = start + 1; i < end; i++) {
      if ('([{'.includes(code[i])) nesting++;
      else if (')]}'.includes(code[i])) nesting--;
      else if (code[i] === ',' && nesting === 0) last = i + 1;
    }
    if (compact(code.slice(last, end)) !== `${contract.parameter}+${contract.increment}`)
      return false;
    edges++;
  }
  return edges === contract.recursiveEdges;
}

// Track lexical bodies, rather than inheriting the last textual fn into a test.
// Each brace has its own frame, so nested struct methods restore the outer owner.
function scanZig(source) {
  const sites = [];
  const recursive = [];
  const frames = [];
  let pending = null;
  let parens = 0;
  const lines = source.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const code = stripZigCode(lines[i]);
    const tokens =
      /\bfn\s+([A-Za-z_][A-Za-z0-9_]*)|\btest\b|[{}();]|\bchildren\s*\(|\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
    for (const match of code.matchAll(tokens)) {
      const token = match[0];
      if (match[1]) {
        pending = { kind: 'fn', name: match[1], parens };
        continue;
      }
      if (token === 'test') {
        pending = { kind: 'test', name: `test@${i + 1}`, parens };
        continue;
      }
      if (token === '{') {
        const typeBrace = /\b(?:error|struct|enum|union)\s*$/.test(code.slice(0, match.index));
        const owner = pending && parens === pending.parens && !typeBrace ? pending : null;
        frames.push(owner);
        if (owner) pending = null;
        continue;
      }
      if (token === '}') {
        frames.pop();
        continue;
      }
      if (token === ';') {
        pending = null;
        continue;
      }
      if (token === '(') {
        parens++;
        continue;
      }
      if (token === ')') {
        parens--;
        continue;
      }
      const fn = frames.findLast((frame) => frame?.kind === 'fn');
      const test = frames.findLast((frame) => frame?.kind === 'test');
      if (/^children\s*\(/.test(token) && pending?.name !== 'children') {
        sites.push({ line: i + 1, fn: fn?.name ?? '<file-scope>', test: test?.name ?? null });
      }
      if (
        match[2] &&
        fn &&
        !test &&
        match[2] === fn.name &&
        (code[match.index - 1] !== '.' || /\b(?:self|Self)\.$/.test(code.slice(0, match.index)))
      )
        recursive.push({ line: i + 1, fn: fn.name });
      // A call token includes its opening parenthesis.
      if (token.endsWith('(')) parens++;
    }
  }
  return { sites, recursive };
}

if (process.argv.includes('--self-test')) {
  const check = (condition, message) => {
    if (!condition) throw new Error(message);
  };
  const sample = scanZig(`fn before() void {}
test "test" { var it = walk.children(t, n); }
fn outer(
 x: T,
) void { const S = struct { fn inner() void { var it = walk.children(t,n); inner(); } }; var it = walk.children(t,n); outer(); }
// children(t,n)
const text = "fn fake() { children(t,n); }";`);
  check(sample.sites.length === 3, 'comments and strings must not create sites');
  check(
    sample.sites[0].test === 'test@2' && sample.sites[0].fn === '<file-scope>',
    'inline test must not inherit before',
  );
  check(
    sample.sites[1].fn === 'inner' && sample.sites[2].fn === 'outer',
    'innermost function ownership must restore outer',
  );
  check(
    sample.recursive.map((x) => x.fn).join() === 'inner,outer',
    'nested direct recursion must be detected',
  );
  const qualified = scanZig(
    'fn capture() void { Owner.capture(); self.capture(); }\nfn children() void {}',
  );
  check(
    qualified.recursive.length === 1,
    'distinct helper qualifier is not self recursion; self call is',
  );
  check(qualified.sites.length === 0, 'children declaration is not a call');
  const bounded = `fn bounded(ast: T, index: N, depth: usize) bool {
    if (index.isNone() or @backingInt(index) >= ast.nodes.items.len or depth > 256) return true;
    if (bounded(ast, child, depth + 1)) return true;
    return bounded(ast, other(child), depth + 1);
  }`;
  const contract = {
    parameter: 'depth',
    type: 'usize',
    limit: 256,
    increment: 1,
    recursiveEdges: 2,
  };
  check(boundedContractValid(bounded, 'bounded', contract), 'reviewed bounded contract must pass');
  check(
    !boundedContractValid(bounded.replace(' or depth > 256', ''), 'bounded', contract),
    'removed guard must fail',
  );
  check(
    !boundedContractValid(bounded.replace('depth + 1', 'depth'), 'bounded', contract),
    'non-incrementing recursive edge must fail',
  );
  console.log('walker scanner self-test PASS');
  process.exit(0);
}

const callSites = [];
const testSites = [];
const directRecursiveSites = [];
const boundedViolations = [];
for (const file of listZigFiles(srcRoot)) {
  if (file.endsWith('_test.zig')) continue;
  const rel = relative(root, file).split('\\').join('/');
  const source = readFileSync(file, 'utf8');
  const scan = scanZig(source);
  for (const [key, entry] of Object.entries(ALLOWLIST)) {
    if (entry.class !== 'bounded_recursive' || !key.startsWith(`${rel}::`)) continue;
    if (
      !entry.boundedContract ||
      !boundedContractValid(source, key.slice(rel.length + 2), entry.boundedContract)
    )
      boundedViolations.push(key);
  }
  for (const site of scan.sites) {
    const value = { ...site, key: `${rel}::${site.fn}`, file: rel };
    if (site.test) testSites.push(value);
    else callSites.push(value);
  }
  for (const site of scan.recursive) {
    const entry = ALLOWLIST[`${rel}::${site.fn}`];
    if (
      entry &&
      entry.class !== 'recursive_tracked' &&
      entry.class !== 'bounded_recursive' &&
      !entry.allowDirectRecursion
    )
      directRecursiveSites.push({ ...site, file: rel });
  }
}
console.log(
  `inline test context: ${testSites.length} children() sites (excluded from production registration)`,
);
for (const site of testSites) console.log(`  ${site.file}:${site.line} ${site.test} fn ${site.fn}`);

const violations = [];
const byClass = { iterative_safe: 0, one_level: 0, recursive_tracked: 0, bounded_recursive: 0 };
const matchedKeys = new Set();
for (const site of callSites) {
  const entry = ALLOWLIST[site.key];
  if (!entry) {
    violations.push(site);
  } else {
    byClass[entry.class]++;
    matchedKeys.add(site.key);
  }
}

console.log(`recursive-ast-walker audit: ${callSites.length} children() 호출처 검사`);
console.log(
  `  iterative_safe=${byClass.iterative_safe}  one_level=${byClass.one_level}  bounded_recursive=${byClass.bounded_recursive}  recursive_tracked=${byClass.recursive_tracked}`,
);

if (directRecursiveSites.length > 0) {
  console.error('\n❌ iterative_safe / one_level walker 의 직접 자기 재귀 호출:');
  for (const v of directRecursiveSites) console.error(`  ${v.file}:${v.line}  fn ${v.fn}`);
  console.error('명시 스택/큐 순회를 유지하거나 recursive_tracked 로 분류하세요.');
}

if (boundedViolations.length > 0)
  console.error(`Bounded recursion contract rejected: ${boundedViolations.join(', ')}`);
if (violations.length > 0 || directRecursiveSites.length > 0 || boundedViolations.length > 0) {
  console.error('\n❌ 분류되지 않은 ast_walk.children() 호출처:');
  for (const v of violations) console.error(`  ${v.file}:${v.line}  fn ${v.fn}`);
  console.error(
    '\n새 AST 서브트리 순회는 깊은 좌결합 체인(#4123)에서 스택 오버플로우를 일으킬 수 있습니다.\n' +
      '- 재귀 순회면 `ast_walk.walkPreorderIterative` 로 쓰세요(명시 스택).\n' +
      '- 직계 1단계만 보면, 또는 깊이 가드가 있으면, scripts/audit-recursive-ast-walkers.mjs 의\n' +
      '  ALLOWLIST 에 `<relpath>::<fn>` 키로 분류(class)+근거(note)와 함께 등록하세요.',
  );
  process.exit(1);
}

// stale(매칭 0) ALLOWLIST 항목 알림 — PR-2c 전환으로 children() 미사용이 된 항목 정리용(실패 아님).
const stale = Object.keys(ALLOWLIST).filter((k) => !matchedKeys.has(k));
if (stale.length > 0) {
  console.log(`\n  ℹ️ 매칭 0 인 ALLOWLIST 항목(전환 완료/이동 — 정리 가능):`);
  for (const k of stale) console.log(`     ${k}`);
}

// 아직 재귀인 walker 가시화 — green CI 가 "재귀 walker 없음"으로 오인되지 않도록(실패 아님).
if (byClass.recursive_tracked > 0) {
  console.log(
    `\n  ⚠️ recursive_tracked ${byClass.recursive_tracked}개 — 깊은 체인서 여전히 overflow 가능(#4123 PR-2c 대기). green=전환완료 아님.`,
  );
} else {
  console.log(
    '  recursive_tracked 0 (bounded recursion and explicit legacy exceptions are reported separately)',
  );
}

for (const key of matchedKeys) {
  const entry = ALLOWLIST[key];
  if (entry.class === 'bounded_recursive' || entry.allowDirectRecursion)
    console.log(`  recursion contract ${key}: ${entry.note}`);
}

console.log('✅ 모든 children() 호출처가 분류됨 (신규 재귀 walker 재유입 차단).');
