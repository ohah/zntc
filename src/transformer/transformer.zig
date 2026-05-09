//! ZNTC Transformer — 핵심 변환 엔진
//!
//! 단일 AST를 append-only로 변환한다.
//!
//! 작동 원리:
//!   1. 파서 AST를 cloneForTransformer()로 복제
//!   2. 파서 노드(0..parser_node_count-1)를 읽기 전용으로 탐색
//!   3. 변환된 노드를 같은 AST 끝에 append
//!   4. string_table이 하나이므로 파서에서 만든 합성 이름도 codegen에서 읽을 수 있음
//!
//! 메모리:
//!   - ast는 트랜스포머 allocator로 복제됨 (원본 module.ast 보존)
//!   - 변환 완료 후 원본 AST는 해제 가능
//!   - source는 원본과 같은 슬라이스를 참조 (zero-copy)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const plugin_state = @import("plugin_state.zig");
const PluginState = plugin_state.PluginState;
const jsx_lowering_mod = @import("jsx_lowering.zig");
const Symbol = @import("../semantic/symbol.zig").Symbol;
const tagged_template_mod = @import("transformer/tagged_template.zig");
const flow_mod = @import("transformer/flow.zig");
const define_mod = @import("transformer/define.zig");
const namespace_mod = @import("transformer/namespace.zig");
const drop_mod = @import("transformer/drop.zig");
const type_only_mod = @import("transformer/type_only.zig");
const options_mod = @import("options.zig");
const runtime_helper_bits = @import("runtime_helper_bits.zig");
const state_mod = @import("state.zig");
pub const ast_plugin_mod = @import("ast_plugin.zig");
pub const AstTransformCtx = ast_plugin_mod.AstTransformCtx;
pub const FunctionInfo = ast_plugin_mod.FunctionInfo;
pub const AutoLabelMode = options_mod.AutoLabelMode;
pub const BindingLite = options_mod.BindingLite;
pub const DefineEntry = options_mod.DefineEntry;
pub const ModuleSpecifierMapEntry = options_mod.ModuleSpecifierMapEntry;
pub const Plugin = options_mod.Plugin;
pub const RuntimeHelpers = runtime_helper_bits.RuntimeHelpers;
pub const TransformOptions = options_mod.TransformOptions;

/// 단일 AST append-only 변환기.
///
/// 사용법:
/// ```zig
/// var t = try Transformer.init(allocator, &source_ast, .{});
/// const new_root = try t.transform();
/// // t.ast 에 변환된 AST가 들어있다
/// ```
pub const Transformer = struct {
    /// 통합 AST. 파서 노드(0..parser_node_count-1)는 읽기 전용,
    /// 트랜스포머가 추가한 노드(parser_node_count..)는 append-only.
    /// `*Ast` — Transformer 가 소유권을 가진다 (clone 경로). D1b-2 의 `initInPlace` 는
    /// 외부 소유 AST 를 borrow 하는 variant 로 같은 필드를 공유.
    ast: *Ast,

    /// 파서 노드 수. transform() 시작 시 루트 인덱스(parser_node_count - 1) 계산에 사용.
    parser_node_count: u32,

    /// ast ownership — `init` 은 owned (clone 후 transformer 가 free), `initBorrow` 는
    /// borrowed (외부 owner 가 free). deinit 분기에 사용 (#1961 후속).
    ast_ownership: AstOwnership = .owned,

    /// 설정
    options: TransformOptions,

    /// allocator (ArrayList 호출에 필요)
    allocator: std.mem.Allocator,

    /// 임시 버퍼 (리스트 변환 시 재사용)
    scratch: std.ArrayList(NodeIndex),

    /// 보류 노드 버퍼 (1→N 노드 확장용).
    /// enum/namespace 변환 시 원래 노드 앞에 삽입할 문장(예: `var Color;`)을 저장.
    /// visitExtraList가 각 자식 방문 후 이 버퍼를 드레인하여 리스트에 삽입한다.
    pending_nodes: std.ArrayList(NodeIndex),

    /// 통합 symbol_ids. 파서 노드 영역은 semantic analyzer가 채우고,
    /// 트랜스포머 노드 영역은 propagateSymbolId/copySymbolId가 채운다.
    /// 빈 슬라이스이면 symbol 전파 비활성.
    symbol_ids: std.ArrayList(?u32) = .empty,

    /// #2869 transformer 가 emit 한 runtime helper identifier_reference 노드 인덱스.
    /// resync 의 SemanticAnalyzer 가 이 marker 를 보고 user scope 와 격리된 별도
    /// `helper_scope_map` 으로 binding → user 의 동일 이름 local 선언이 helper call
    /// 을 shadow 하지 못한다. esbuild/swc 의 symbol-bound runtime helper 모델.
    /// invariant: `markRuntimeHelperRef` 호출처는 매번 새로 만든 NodeIndex 만 넣으므로
    /// 중복 entry 가 발생하지 않음 — dedupe 불필요.
    helper_ref_nodes: std.ArrayListUnmanaged(u32) = .empty,

    /// semantic analyzer의 심볼 테이블 (unused import 판별용).
    /// 비어 있으면 unused import 제거 비활성.
    symbols: []const Symbol = &.{},

    /// #1791 per-reference 기록 (`semantic/analyzer::SemanticAnalyzer.references`).
    /// import binding elision 판정은 `Symbol.reference_count` 대신 여기서 symbol 별
    /// Reference 를 돌며 **value-use 가 하나라도 있는지** 로 판단한다. 비어있으면
    /// elision 비활성 (보수적 보존). caller 가 symbols 와 함께 설정.
    references: []const @import("../semantic/symbol.zig").Reference = &.{},

    /// Full semantic을 건너뛰는 standalone transpile 경로에서 named import elision만
    /// 판단하기 위한 lightweight binding facts.
    binding_lite: ?*const BindingLite = null,

    /// ES 다운레벨링 임시 변수 카운터.
    /// `foo() ?? bar` → `(_a = foo()) != null ? _a : bar`에서 _a, _b, _c, ... 생성에 사용.
    temp_var_counter: u32 = 0,

    /// ES2022 static block: `this` → 클래스 이름 치환을 위한 컨텍스트.
    /// static block body를 visit하는 동안만 설정된다.
    /// null이면 치환 비활성, 값이 있으면 해당 Span의 이름으로 this를 치환.
    static_block_class_name: ?Span = null,

    /// static block 안에서 일반 함수(non-arrow) 깊이 추적.
    /// 0이면 static block 최상위 (this 치환 대상), >0이면 중첩 함수 안 (치환 안 함).
    /// arrow function은 this를 상속하므로 depth를 올리지 않는다.
    this_depth: u32 = 0,

    /// ES2015 arrow function this/arguments 캡처.
    /// arrow_this_depth > 0이면 현재 다운레벨링 중인 arrow function body 안에 있으므로
    /// this → _this, arguments → _arguments로 치환한다.
    /// 일반 함수 진입 시 0으로 리셋 (자체 this/arguments 바인딩).
    arrow_this_depth: u32 = 0,

    /// ES2015 new.target: 현재 함수의 종류 (new.target 변환에 사용).
    /// constructor: this.constructor, method: void 0,
    /// function_named: this instanceof Fn ? this.constructor : void 0
    new_target_ctx: NewTargetCtx = .none,

    /// ES2015 class extends: 현재 클래스의 super class 이름 Span.
    /// class body 방문 중 설정되어, super() → Parent.call(this),
    /// super.method() → Parent.prototype.method.call(this) 변환에 사용.
    current_super_class: ?Span = null,
    current_super_class_old_idx: NodeIndex = .none,
    /// 현재 super member 접근이 static class element 안에서 발생하는지 여부.
    /// static method/field/block 에서는 super base가 Parent.prototype이 아니라 Parent constructor다.
    current_super_is_static: bool = false,
    /// static field/block 처럼 `this` 표현식이 사라지는 위치에서 super receiver로 사용할 class 이름.
    current_super_static_receiver: ?Span = null,

    /// ES2015 generator: labeled break/continue를 위한 label 스택.
    /// labeled_statement 진입 시 push, 퇴장 시 pop.
    generator_label_stack: std.ArrayList(GeneratorLabelEntry) = .empty,

    /// ES2015 generator: for loop의 update label (labeled continue 대상).
    /// collectForOperations에서 update nop 추가 직전에 설정.
    generator_for_update_label: ?u32 = null,

    /// ES2015 generator: for-of 변환에서 생성한 임시 변수 span.
    /// buildGeneratorBody에서 호이스팅 변수에 추가.
    generator_temp_var_spans: std.ArrayList(token_mod.Span) = .empty,

    /// ES2015 class private fields: "#name" → "_name" 매핑.
    /// class body 방문 중 설정되어, this.#x → _x.get(this), this.#x = v → _x.set(this, v) 변환에 사용.
    current_private_fields: []const PrivateFieldMapping = &.{},

    /// ES2022 class private methods: "#name" → WeakSet + standalone function 매핑.
    /// class body 방문 중 설정되어, this.#method() → _method_fn.call(this) 변환에 사용.
    current_private_methods: []const PrivateMethodMapping = &.{},

    /// 현재 함수 스코프에서 arrow body가 this를 사용하여 var _this = this 삽입이 필요한지.
    needs_this_var: bool = false,

    /// 현재 함수 스코프에서 arrow body가 arguments를 사용하여 var _arguments = arguments 삽입이 필요한지.
    needs_arguments_var: bool = false,

    /// ES2015 class constructor에서 super() 호출 후 this → _this 별칭이 필요한지.
    /// __callSuper가 Reflect.construct를 사용하면 새 객체를 반환하므로,
    /// super() 이후의 this 참조를 _this로 교체해야 한다.
    super_call_this_alias: bool = false,

    /// for-in/for-of/for-await-of 헤더의 left(variable_declaration)를 방문 중인지.
    /// true면 let/const → var 다운레벨 시 `= void 0` init 주입을 생략.
    /// 헤더에선 루프가 매 반복 바인딩에 쓰므로 TDZ 흉내가 불필요하고,
    /// `var k = void 0` 를 hoist해 `k = void 0; for(var k in ...)` 로 뽑아내면
    /// strict mode에서 `var k` 선언 전 접근으로 ReferenceError (#1386).
    in_for_in_of_header: bool = false,

    /// 플러그인별 runtime state. 각 plugin은 자기 sub-struct만 접근.
    /// 상세 규칙은 `plugin_state.zig` 참조.
    plugins: PluginState = .{},

    /// 런타임 헬퍼 사용 추적.
    /// 각 변환이 헬퍼를 사용하면 해당 비트를 설정한다.
    /// 번들러 emitter가 이 비트맵을 읽어 필요한 헬퍼만 출력에 주입한다.
    runtime_helpers: RuntimeHelpers = .{},

    /// 런타임 헬퍼를 ES5 문법으로 출력 (arrow, rest params 제거).
    /// unsupported.arrow일 때 자동 설정.
    runtime_es5_compat: bool = false,

    /// ES2015 tagged template: 호이스팅할 _templateObject 캐싱 함수 목록.
    /// 모듈 root 방문 완료 시 program body 맨 앞에 삽입.
    tagged_template_fns: std.ArrayList(NodeIndex) = .empty,

    /// ES2015 tagged template: _templateObject 카운터 (1부터: _templateObject2, _templateObject3, ...).
    tagged_template_counter: u32 = 0,

    /// ES2015 block scoping: _loop 함수명 카운터 (_loop, _loop2, ...)
    loop_counter: u32 = 0,

    /// ES2015 block scoping 격리: 블록 내부 let/const 변수가 외부 스코프와
    /// 이름 충돌 시 리네이밍 (x → x$1). 스택으로 중첩 블록 지원.
    block_rename_stack: std.ArrayList(BlockRenameEntry) = .empty,

    /// 현재 함수 스코프에서 선언된 모든 변수 이름 (var 호이스팅 범위).
    /// 블록 진입 시 내부 let/const와 비교하여 충돌 감지에 사용.
    scope_var_names: std.ArrayList([]const u8) = .empty,

    /// block rename suffix 카운터.
    block_rename_counter: u32 = 0,

    /// JSX lowering: 사용된 import 추적 (automatic 모드에서 import문 생성용)
    jsx_import_info: jsx_lowering_mod.JsxImportInfo = .{},

    /// 소스의 줄 오프셋 테이블 (Scanner에서 전달). jsxDEV source info 계산용.
    line_offsets: []const u32 = &.{},

    /// 후행 노드 버퍼 (함수 뒤에 프로퍼티 할당문 삽입용).
    /// pending_nodes가 자식 앞에 삽입되는 것과 대칭: trailing_nodes는 자식 뒤에 삽입.
    /// visitExtraList가 각 자식 방문 후 이 버퍼를 드레인하여 리스트에 삽입한다.
    trailing_nodes: std.ArrayList(NodeIndex) = .empty,

    /// TS const enum: 선언 시 멤버 값을 미리 평가하여 보관.
    /// 후속 visitMemberExpression에서 `E.A` 형태 참조를 literal로 인라인.
    const_enums: std.ArrayList(ConstEnumDecl) = .empty,

    /// `const re = /.../;` 형태로 선언된 regex literal 추적.
    /// key=symbol_id, value=pattern 텍스트 (`/`/flags 제외 owned slice).
    /// `String.replace(re, "$<name>...")` 같은 호출에서 named group 매핑 lookup 에 사용 (#1473).
    /// const 바인딩만 추적 (let/var 는 재할당 가능).
    regex_var_map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    pub const BlockRenameEntry = state_mod.BlockRenameEntry;
    pub const GeneratorLabelEntry = state_mod.GeneratorLabelEntry;
    pub const NewTargetCtx = state_mod.NewTargetCtx;
    pub const ConstEnumValue = state_mod.ConstEnumValue;
    pub const ConstEnumMember = state_mod.ConstEnumMember;
    pub const ConstEnumDecl = state_mod.ConstEnumDecl;
    pub const PrivateFieldMapping = state_mod.PrivateFieldMapping;
    pub const PrivateMethodMapping = state_mod.PrivateMethodMapping;
    pub const AstOwnership = state_mod.AstOwnership;

    // RefreshRegistration / RefreshSignature 타입 정의는 plugin_state.zig로 이사.
    // 외부 모듈 (refresh.zig 등)에서 `Transformer.RefreshRegistration`로 접근 가능하도록 alias 제공.
    pub const RefreshRegistration = plugin_state.RefreshRegistration;
    pub const RefreshSignature = plugin_state.RefreshSignature;

    /// super 참조가 Parent.prototype.* / Parent.* 호출 형태로 lowering 되어야 하는지 판정.
    /// - `unsupported.class`: ES2015 미만 타겟이라 class 자체가 lowering 됨
    /// - `current_super_is_static`: target 이 class 를 지원해도 static field init/static block 은
    ///   IIFE/`Class.foo = …` 로 들어내져 super 가 더 이상 lexical 로 의미를 가지지 않음
    /// - `current_super_class != null`: derived class 안 (extends 가 있어 super 의미 자체가 존재)
    pub inline fn needsSuperLowering(self: *const Transformer) bool {
        return (self.options.unsupported.class or self.current_super_is_static) and self.current_super_class != null;
    }

    /// 현재 scope 의 private field 가 `WeakMap.get/set` lowering 대상인지 판정.
    /// `class` / `class_private_field` 옵션 둘 중 하나라도 켜져 있고, 현재 visit 중인
    /// class 가 private field 를 갖고 있을 때 true.
    pub inline fn hasActivePrivateFieldLowering(self: *const Transformer) bool {
        return (self.options.unsupported.class or self.options.unsupported.class_private_field) and self.current_private_fields.len > 0;
    }

    // Construction/teardown — transformer/lifecycle.zig로 위임
    const lifecycle_mod = @import("transformer/lifecycle.zig");
    pub const init = lifecycle_mod.init;
    pub const initBorrow = lifecycle_mod.initBorrow;
    pub const deinit = lifecycle_mod.deinit;
    pub const deinitExceptAst = lifecycle_mod.deinitExceptAst;
    pub const initSymbolIds = lifecycle_mod.initSymbolIds;
    pub const markRuntimeHelperRef = lifecycle_mod.markRuntimeHelperRef;
    pub const ownedHelperRefNodes = lifecycle_mod.ownedHelperRefNodes;

    // ================================================================
    // 공개 API
    // ================================================================

    /// 변환을 실행한다. 원본 AST의 마지막 노드(program)부터 시작.
    ///
    /// 반환값: 새 AST에서의 루트 NodeIndex.
    /// 변환된 AST는 self.ast에 저장된다.
    const driver_mod = @import("transformer/driver.zig");
    pub const transform = driver_mod.transform;

    // ================================================================
    // 핵심 visitor — switch 기반 (D042)
    // ================================================================

    /// 노드 하나를 방문하여 새 AST에 복사/변환/스킵한다.
    ///
    /// 반환값:
    ///   - 변환된 노드의 새 인덱스
    ///   - .none이면 이 노드를 삭제(스킵)한다는 뜻
    /// 에러 타입. ArrayList의 append/ensureCapacity가 반환하는 에러.
    /// 재귀 함수에서 Zig가 에러 셋을 추론할 수 없으므로 명시적으로 선언.
    pub const Error = std.mem.Allocator.Error;

    pub fn visitNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        if (idx.isNone()) return .none;
        const new_idx = try self.visitNodeInner(idx);
        // symbol_id 전파: 원본 node_idx → 새 node_idx
        self.propagateSymbolId(idx, new_idx);
        return new_idx;
    }

    const node_dispatch_mod = @import("transformer/node_dispatch.zig");
    const visitNodeInner = node_dispatch_mod.visitNodeInner;

    // ================================================================
    // Node/symbol/extra helpers — transformer/node_helpers.zig로 위임
    // ================================================================
    const node_helpers = @import("transformer/node_helpers.zig");
    pub const copyNodeDirect = node_helpers.copyNodeDirect;
    pub const tryRenameIdentifierLike = node_helpers.tryRenameIdentifierLike;
    pub const getClassNameSpan = node_helpers.getClassNameSpan;
    pub const propagateSymbolId = node_helpers.propagateSymbolId;
    pub const copySymbolId = node_helpers.copySymbolId;
    pub const makeIdentifierRefWithSymbol = node_helpers.makeIdentifierRefWithSymbol;
    pub const attachRootScopeSymbolByName = node_helpers.attachRootScopeSymbolByName;
    pub const visitUnaryNode = node_helpers.visitUnaryNode;
    pub const visitBinaryNode = node_helpers.visitBinaryNode;
    pub const visitUnaryExtra = node_helpers.visitUnaryExtra;
    pub const visitMemberExpression = node_helpers.visitMemberExpression;
    pub const visitTernaryNode = node_helpers.visitTernaryNode;
    pub const getSymbolIdAt = node_helpers.getSymbolIdAt;
    pub const readNodeIdx = node_helpers.readNodeIdx;
    pub const readU32 = node_helpers.readU32;
    pub const addExtraNode = node_helpers.addExtraNode;

    pub const visitTaggedTemplate = tagged_template_mod.visitTaggedTemplate;

    // ================================================================
    // Control-flow visitors — transformer/control_flow.zig로 위임
    // ================================================================
    const control_flow_mod = @import("transformer/control_flow.zig");
    pub const visitForInOfTernary = control_flow_mod.visitForInOfTernary;
    pub const tryLowerForInOfPrivateTarget = control_flow_mod.tryLowerForInOfPrivateTarget;
    pub const visitForStatement = control_flow_mod.visitForStatement;
    pub const visitSwitchStatement = control_flow_mod.visitSwitchStatement;
    pub const visitSwitchCase = control_flow_mod.visitSwitchCase;

    // ================================================================
    // List traversal / block-scope helpers — transformer/lists.zig로 위임
    // ================================================================
    const lists_mod = @import("transformer/lists.zig");
    pub const visitListNode = lists_mod.visitListNode;
    pub const visitExtraList = lists_mod.visitExtraList;
    pub const lookupBlockRename = lists_mod.lookupBlockRename;
    pub const buildUniqueName = lists_mod.buildUniqueName;
    pub const buildVarDecl = lists_mod.buildVarDecl;
    pub const hoistTempVars = lists_mod.hoistTempVars;

    // ================================================================
    // Flow syntax 변환 — transformer/flow.zig로 위임
    // ================================================================
    pub const visitFlowMatch = flow_mod.visitFlowMatch;
    pub const visitFlowComponentWrapper = flow_mod.visitFlowComponentWrapper;

    // ================================================================
    // TS expression 변환 — 타입 부분 제거, 값만 보존
    // ================================================================

    const type_expression_mod = @import("transformer/type_expression.zig");
    pub const visitTsExpression = type_expression_mod.visitTsExpression;

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    // ================================================================
    // --drop 헬퍼
    // ================================================================

    pub const shouldDropNode = drop_mod.shouldDropNode;
    pub const isConsoleCall = drop_mod.isConsoleCall;

    // ================================================================
    // define 글로벌 치환
    // ================================================================

    const function_visit_mod = @import("transformer/functions.zig");
    pub const visitBodyWorkletAware = function_visit_mod.visitBodyWorkletAware;
    pub const visitWithRefreshSuppressed = function_visit_mod.visitWithRefreshSuppressed;

    pub const tryDefineReplace = define_mod.tryDefineReplace;

    // ================================================================
    // TS / Flow enum 변환 — transformer/enum.zig로 위임
    // ================================================================
    const enum_mod = @import("transformer/enum.zig");
    pub const visitFlowEnumDeclaration = enum_mod.visitFlowEnumDeclaration;
    pub const visitEnumDeclaration = enum_mod.visitEnumDeclaration;
    pub const tryInlineConstEnumMember = enum_mod.tryInlineConstEnumMember;

    // ================================================================
    // TS namespace 변환
    // ================================================================
    pub const visitImportEqualsDeclaration = namespace_mod.visitImportEqualsDeclaration;
    pub const visitExportAssignment = namespace_mod.visitExportAssignment;
    pub const visitNamespaceDeclaration = namespace_mod.visitNamespaceDeclaration;

    // ================================================================
    // JSX 노드 변환
    // ================================================================

    const jsx_visit_mod = @import("transformer/jsx.zig");
    pub const visitJSXElement = jsx_visit_mod.visitJSXElement;
    pub const visitJSXOpeningElement = jsx_visit_mod.visitJSXOpeningElement;

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    // ================================================================
    // Declaration/function visitors — transformer/declarations.zig로 위임
    // ================================================================
    const declarations_mod = @import("transformer/declarations.zig");
    pub const visitVariableDeclaration = declarations_mod.visitVariableDeclaration;
    pub const visitVariableDeclarator = declarations_mod.visitVariableDeclarator;
    pub const visitFunction = declarations_mod.visitFunction;
    pub const lowerNewTarget = declarations_mod.lowerNewTarget;
    pub const ParamPropertyResult = declarations_mod.ParamPropertyResult;
    pub const visitParamsCollectProperties = declarations_mod.visitParamsCollectProperties;
    pub const buildParameterPropertyStatements = declarations_mod.buildParameterPropertyStatements;
    pub const insertParameterPropertyAssignmentsAfterSuper = declarations_mod.insertParameterPropertyAssignmentsAfterSuper;
    pub const insertParameterPropertyAssignments = declarations_mod.insertParameterPropertyAssignments;
    pub const insertStatementsAfterSuper = declarations_mod.insertStatementsAfterSuper;
    pub const prependStatementsToBody = declarations_mod.prependStatementsToBody;

    pub const visitArrowFunction = function_visit_mod.visitArrowFunction;

    // ================================================================
    // Class + Decorator — transformer/class_decorator.zig로 위임
    // ================================================================
    const class_deco = @import("transformer/class_decorator.zig");

    /// Stage 3 decorator lowering이 필요한 class면 실행해 결과 NodeIndex 반환, 아니면 null.
    /// `unsupported.class` 분기보다 먼저 호출해 ES5 target에서 decorator silent drop을 방지한다.
    pub fn tryTransformStage3(self: *Transformer, node: Node) Error!?NodeIndex {
        if (self.options.experimental_decorators) return null;
        const e = node.data.extra;
        const class_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);
        const has_member_decos = self.hasAnyMemberDecorators(e);
        if (class_deco_len == 0 and !has_member_decos) return null;
        return try self.transformStage3Decorators(node);
    }

    pub const visitClass = class_deco.visitClass;
    pub const visitClassWithAssignSemantics = class_deco.visitClassWithAssignSemantics;
    pub const buildStaticFieldAssignment = class_deco.buildStaticFieldAssignment;
    pub const classifyClassMember = class_deco.classifyClassMember;
    pub const classifyPropertyDefinition = class_deco.classifyPropertyDefinition;
    pub const classifyMethodDefinition = class_deco.classifyMethodDefinition;
    pub const applyFieldAssignments = class_deco.applyFieldAssignments;
    pub const ClassMemberContext = class_deco.ClassMemberContext;
    pub const FieldAssignment = class_deco.FieldAssignment;
    pub const MemberDecoratorInfo = class_deco.MemberDecoratorInfo;
    pub const visitDecoratorExpression = class_deco.visitDecoratorExpression;
    pub const collectMemberDecorators = class_deco.collectMemberDecorators;
    pub const collectParamDecorators = class_deco.collectParamDecorators;
    pub const appendParamDecorators = class_deco.appendParamDecorators;
    pub const buildDecorateParamCall = class_deco.buildDecorateParamCall;
    pub const insertFieldAssignmentsIntoConstructor = class_deco.insertFieldAssignmentsIntoConstructor;
    pub const isSuperCallStatement = class_deco.isSuperCallStatement;
    pub const buildConstructorWithFieldAssignments = class_deco.buildConstructorWithFieldAssignments;
    pub const buildThisAssignment = class_deco.buildThisAssignment;
    pub const transformExperimentalDecorators = class_deco.transformExperimentalDecorators;
    pub const buildDecorateClassMemberCall = class_deco.buildDecorateClassMemberCall;
    pub const buildDecorateClassCall = class_deco.buildDecorateClassCall;
    pub const serializeTypeAnnotation = class_deco.serializeTypeAnnotation;
    pub const buildMetadataCall = class_deco.buildMetadataCall;
    pub const buildParamTypesArray = class_deco.buildParamTypesArray;
    pub const appendMemberMetadata = class_deco.appendMemberMetadata;
    pub const appendClassMetadata = class_deco.appendClassMetadata;
    // Stage 3 (TC39) decorator
    pub const hasAnyMemberDecorators = class_deco.hasAnyMemberDecorators;
    pub const transformStage3Decorators = class_deco.transformStage3Decorators;
    pub const memberKeyToStringLiteral = class_deco.memberKeyToStringLiteral;
    pub const collectStage3Decorators = class_deco.collectStage3Decorators;
    pub const buildEsDecorateCall = class_deco.buildEsDecorateCall;
    pub const buildClassEsDecorateCall = class_deco.buildClassEsDecorateCall;
    pub const buildContextObject = class_deco.buildContextObject;
    pub const buildMetadataDecl = class_deco.buildMetadataDecl;
    pub const buildClassReassign = class_deco.buildClassReassign;
    pub const buildRunInitializersCall = class_deco.buildRunInitializersCall;
    pub const buildRunInitializersCall2 = class_deco.buildRunInitializersCall2;
    pub const buildStage3LetDeclarations = class_deco.buildStage3LetDeclarations;
    pub const makeLet = class_deco.makeLet;
    pub const makeObjProp = class_deco.makeObjProp;
    pub const buildAccessObject = class_deco.buildAccessObject;
    pub const buildFieldInitNames = class_deco.buildFieldInitNames;
    pub const buildMetadataDefineProperty = class_deco.buildMetadataDefineProperty;
    pub const buildGetterMethod = class_deco.buildGetterMethod;
    pub const buildSetterMethod = class_deco.buildSetterMethod;
    pub const extractCleanVarName = class_deco.extractCleanVarName;
    pub const appendEsDecorateStmt = class_deco.appendEsDecorateStmt;
    pub const wrapInStringLiteral = class_deco.wrapInStringLiteral;
    pub const extractTypeFromSource = class_deco.extractTypeFromSource;

    const call_visit_mod = @import("transformer/calls.zig");
    pub const visitCallExpression = call_visit_mod.visitCallExpression;

    // ================================================================
    // Regex replacement 변환 — transformer/regex.zig로 위임
    // ================================================================
    const regex_mod = @import("transformer/regex.zig");
    pub const tryRewriteReplaceNamedRefs = regex_mod.tryRewriteReplaceNamedRefs;
    pub const collectConstRegexDeclarators = regex_mod.collectConstRegexDeclarators;

    pub const visitNewExpression = call_visit_mod.visitNewExpression;

    // ================================================================
    // Class/object member visitors — transformer/members.zig로 위임
    // ================================================================
    const members_mod = @import("transformer/members.zig");
    pub const visitMethodDefinition = members_mod.visitMethodDefinition;
    pub const visitPropertyDefinition = members_mod.visitPropertyDefinition;
    pub const visitAccessorProperty = members_mod.visitAccessorProperty;
    pub const visitObjectProperty = members_mod.visitObjectProperty;
    pub const visitFormalParameter = members_mod.visitFormalParameter;

    // ================================================================
    // Import/export 변환 — transformer/import_export.zig로 위임
    // ================================================================
    const import_export_mod = @import("transformer/import_export.zig");
    pub const visitExportDefaultDeclaration = import_export_mod.visitExportDefaultDeclaration;
    pub const visitImportDeclaration = import_export_mod.visitImportDeclaration;
    pub const shouldElideImportSpecifier = import_export_mod.shouldElideImportSpecifier;
    pub const visitExportAllDeclaration = import_export_mod.visitExportAllDeclaration;
    pub const visitExportNamedDeclaration = import_export_mod.visitExportNamedDeclaration;

    // ================================================================
    // Comptime 헬퍼 — TS 타입 전용 노드 판별 (D042)
    // ================================================================

    pub const isTypeOnlyNode = type_only_mod.isTypeOnlyNode;

    // ================================================================
    // React Fast Refresh — transformer/refresh.zig로 위임
    // ================================================================
    const refresh = @import("transformer/refresh.zig");
    pub const isComponentName = refresh.isComponentName;
    pub const getFunctionName = refresh.getFunctionName;
    pub const maybeRegisterRefreshComponent = refresh.maybeRegisterRefreshComponent;
    pub const makeRefreshHandle = refresh.makeRefreshHandle;
    pub const appendRefreshRegistrations = refresh.appendRefreshRegistrations;
    pub const buildRefreshAssignment = refresh.buildRefreshAssignment;
    pub const buildRefreshVarDeclaration = refresh.buildRefreshVarDeclaration;
    pub const buildRefreshRegCall = refresh.buildRefreshRegCall;
    pub const buildRefreshSigDeclaration = refresh.buildRefreshSigDeclaration;
    pub const buildRefreshSigCall = refresh.buildRefreshSigCall;
    pub const isHookCall = refresh.isHookCall;
    pub const scanHookSignature = refresh.scanHookSignature;
    pub const findHookCallsInNode = refresh.findHookCallsInNode;
    pub const findHookCallsInNodeDepth = refresh.findHookCallsInNodeDepth;
    pub const makeSigHandle = refresh.makeSigHandle;
    pub const maybeRegisterRefreshSignature = refresh.maybeRegisterRefreshSignature;
    pub const insertSigCallAtBodyStart = refresh.insertSigCallAtBodyStart;

    // ================================================================
    // Auto-workletization helpers — transformer/auto_worklet.zig로 위임
    // ================================================================
    const auto_worklet = @import("transformer/auto_worklet.zig");
    pub const matchAutoWorkletCallee = auto_worklet.matchAutoWorkletCallee;
    pub const visitCallArgsWithAutoWorklet = auto_worklet.visitCallArgsWithAutoWorklet;

    // ================================================================
    // Plugin dispatch helper
    // ================================================================

    const plugin_dispatch_mod = @import("transformer/plugins.zig");
    pub const VisitorHookKind = plugin_dispatch_mod.VisitorHookKind;
    pub const dispatchVisitor = plugin_dispatch_mod.dispatchVisitor;
    pub const dispatchFunctionPlugins = plugin_dispatch_mod.dispatchFunctionPlugins;
};
