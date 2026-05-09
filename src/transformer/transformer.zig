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
const Tag = Node.Tag;
const Data = Node.Data;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const module_parser = @import("../parser/module.zig");
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const plugin_state = @import("plugin_state.zig");
const PluginState = plugin_state.PluginState;
const es2016 = @import("es2016.zig");
const es2018 = @import("es2018.zig");
const es2017_mod = @import("es2017.zig");
const es2019 = @import("es2019.zig");
const es2020 = @import("es2020.zig");
const es2021 = @import("es2021.zig");
const es2022 = @import("es2022.zig");
const es2015_template = @import("es2015_template.zig");
const es2015_shorthand = @import("es2015_shorthand.zig");
const es2015_computed = @import("es2015_computed.zig");
const es2015_object_methods = @import("es2015_object_methods.zig");
const es2015_spread = @import("es2015_spread.zig");
const es2015_arrow = @import("es2015_arrow.zig");
const es2015_for_of = @import("es2015_for_of.zig");
const es2018_for_await = @import("es2018_for_await.zig");
const es2015_destructuring = @import("es2015_destructuring.zig");
const es2015_block_scoping = @import("es2015_block_scoping.zig");
const es2015_class = @import("es2015_class.zig");
const es2015_generator = @import("es2015_generator.zig");
const es2025_using = @import("es2025_using.zig");
const regex_lower = @import("regex_lower.zig");
const unicode_escape_lower = @import("unicode_escape_lower.zig");
const es2022_tla = @import("es2022_tla.zig");
const jsx_lowering_mod = @import("jsx_lowering.zig");
const es_helpers = @import("es_helpers.zig");
const Symbol = @import("../semantic/symbol.zig").Symbol;
const worklet_mod = @import("transformer/worklet.zig");
const styled_components_mod = @import("transformer/styled_components.zig");
const emotion_mod = @import("transformer/emotion.zig");
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

    // RefreshRegistration / RefreshSignature 타입 정의는 plugin_state.zig로 이사.
    // 외부 모듈 (refresh.zig 등)에서 `Transformer.RefreshRegistration`로 접근 가능하도록 alias 제공.
    pub const RefreshRegistration = plugin_state.RefreshRegistration;
    pub const RefreshSignature = plugin_state.RefreshSignature;

    /// 파서 AST 를 transformer 가 별도 cell 에 복제 후 transform — 원본 보존 모드.
    /// 일반적인 single-shot transpile / emit 단계의 first-time transform 진입점.
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

    pub fn init(allocator: std.mem.Allocator, source_ast: *const Ast, options: TransformOptions) Error!Transformer {
        var opts = options;
        if (opts.experimental_decorators) opts.use_define_for_class_fields = false;

        const ast_ptr = try allocator.create(Ast);
        errdefer allocator.destroy(ast_ptr);
        ast_ptr.* = try Ast.cloneForTransformer(source_ast, allocator);
        // D1 (RFC #1672): parser/transformer 영역 경계 스냅샷.
        ast_ptr.transform_boundary = @intCast(ast_ptr.nodes.items.len);

        return finishInit(allocator, ast_ptr, opts, .owned);
    }

    /// 이미 transform 된 ast 를 borrow — `cloneForTransformer` skip (#1961 PR 1d).
    /// graph parse 단계의 transformer pre-pass 가 in-place 로 transform 한 ast 를
    /// emit 단계 transformer 가 그대로 사용. transform() 은 `ast.transformed_root`
    /// cache hit 분기로 즉시 cached root 반환 → 수백 KB AST 의 전량 memcpy 회피.
    /// `ast` 는 caller 가 owner — transformer.deinit 은 ast 를 건드리지 않는다.
    /// `*const Ast` 받음 — transform() cache hit 분기는 ast mutation 없음. 단, ast 필드는
    /// `*Ast` 라 내부적으로 `@constCast` (caller 가 mut 의도면 별도 borrow 함수 미래에).
    pub fn initBorrow(allocator: std.mem.Allocator, ast: *const Ast, options: TransformOptions) Error!Transformer {
        var opts = options;
        if (opts.experimental_decorators) opts.use_define_for_class_fields = false;
        return finishInit(allocator, @constCast(ast), opts, .borrowed);
    }

    const AstOwnership = state_mod.AstOwnership;

    fn finishInit(
        allocator: std.mem.Allocator,
        ast_ptr: *Ast,
        opts: TransformOptions,
        ownership: AstOwnership,
    ) Error!Transformer {
        const parser_count: u32 = switch (ownership) {
            .owned => @intCast(ast_ptr.nodes.items.len),
            .borrowed => ast_ptr.transform_boundary orelse @intCast(ast_ptr.nodes.items.len),
        };
        var self: Transformer = .{
            .ast = ast_ptr,
            .parser_node_count = parser_count,
            .options = opts,
            .allocator = allocator,
            .scratch = .empty,
            .pending_nodes = .empty,
            .ast_ownership = ownership,
        };
        if (opts.unsupported.arrow) self.runtime_es5_compat = true;
        return self;
    }

    pub fn deinit(self: *Transformer) void {
        // borrow 모드는 외부 owner (보통 module.parse_arena) 가 ast 를 free.
        if (self.ast_ownership == .owned) {
            self.ast.deinit();
            self.allocator.destroy(self.ast);
        }
        self.deinitExceptAst();
    }

    /// AST를 제외한 모든 리소스를 해제한다.
    /// 테스트에서 AST를 별도로 관리할 때 사용. `.ast` 는 `*Ast` 이므로 호출자가
    /// `ast.deinit()` + `allocator.destroy(ast)` 둘 다 책임.
    pub fn deinitExceptAst(self: *Transformer) void {
        self.scratch.deinit(self.allocator);
        self.pending_nodes.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
        self.helper_ref_nodes.deinit(self.allocator);
        self.plugins.refresh.registrations.deinit(self.allocator);
        for (self.plugins.refresh.signatures.items) |s| self.allocator.free(s.signature);
        self.plugins.refresh.signatures.deinit(self.allocator);
        self.plugins.emotion.scope_stack.deinit(self.allocator);
        if (self.plugins.emotion.newline_offsets) |*list| list.deinit(self.allocator);
        self.plugins.styled_components.css_prop_pending_decls.deinit(self.allocator);
        // collision 발생 시 mangled name 은 heap-owned. owned flag 로 free 판정 (Zig 의
        // string-literal pooling 이 implementation-defined 이라 ptr 비교 fragile).
        const sc = &self.plugins.styled_components;
        if (sc.css_prop_inject_name_owned) self.allocator.free(sc.css_prop_inject_name);
        self.trailing_nodes.deinit(self.allocator);
        self.generator_label_stack.deinit(self.allocator);
        self.generator_temp_var_spans.deinit(self.allocator);
        self.tagged_template_fns.deinit(self.allocator);
        for (self.block_rename_stack.items) |entry| self.allocator.free(entry.new_name);
        self.block_rename_stack.deinit(self.allocator);
        self.scope_var_names.deinit(self.allocator);
        for (self.const_enums.items) |decl| {
            self.allocator.free(decl.name);
            for (decl.members) |m| {
                self.allocator.free(m.name);
                if (m.value == .string) self.allocator.free(m.value.string);
            }
            self.allocator.free(decl.members);
        }
        self.const_enums.deinit(self.allocator);
        {
            var it = self.regex_var_map.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
            self.regex_var_map.deinit(self.allocator);
        }
    }

    /// semantic analyzer의 symbol_ids를 통합 배열로 복사한다.
    /// 파서 노드 영역(0..parser_node_count-1)에 symbol_id를 채운다.
    pub fn initSymbolIds(self: *Transformer, analyzer_symbol_ids: []const ?u32) Error!void {
        try self.symbol_ids.appendSlice(self.allocator, analyzer_symbol_ids);
    }

    /// #2869 helper marker 등록. caller 는 새로 만든 NodeIndex 를 넘긴다.
    pub fn markRuntimeHelperRef(self: *Transformer, idx: NodeIndex) Error!void {
        try self.helper_ref_nodes.append(self.allocator, @intFromEnum(idx));
    }

    /// #2869 marker 를 caller 소유 sorted slice 로 transfer. resync analyzer 가
    /// binary search 로 사용. `alloc` 은 cache lifetime (parse_arena) 의 allocator.
    pub fn ownedHelperRefNodes(self: *Transformer, alloc: std.mem.Allocator) Error![]u32 {
        const items = self.helper_ref_nodes.items;
        if (items.len == 0) return &.{};
        const out = try alloc.dupe(u32, items);
        std.mem.sort(u32, out, {}, std.sort.asc(u32));
        return out;
    }

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

    fn visitNodeInner(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);

        // --------------------------------------------------------
        // 1단계: TS 타입 전용 노드는 통째로 삭제
        // --------------------------------------------------------
        if (self.options.strip_types and isTypeOnlyNode(node.tag)) {
            return .none;
        }

        // --------------------------------------------------------
        // 2단계: --drop 처리
        // --------------------------------------------------------
        if (self.shouldDropNode(node)) return .none;

        // --------------------------------------------------------
        // 3단계: define 글로벌 치환
        // --------------------------------------------------------
        // worklet body 내부에서는 억제: UI 런타임은 bundler prelude의 polyfill 심볼을 모름.
        if (self.options.define.len > 0 and self.plugins.worklet.body_depth == 0) {
            if (self.tryDefineReplace(node)) |new_node| {
                return try new_node;
            }
        }

        // --------------------------------------------------------
        // 4단계: 태그별 분기 (switch 기반 visitor)
        // --------------------------------------------------------
        return switch (node.tag) {
            // === TS expressions: 타입 부분만 제거, 값 보존 ===
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            .flow_as_expression,
            .flow_type_cast_expression,
            => self.visitTsExpression(idx),

            .flow_match_expression => self.visitFlowMatch(node),

            // Flow component with ref → function Name_withRef + const Name = React.forwardRef(...)
            .flow_component_wrapper => self.visitFlowComponentWrapper(node),

            // === 리스트 노드: 자식을 하나씩 방문하며 복사 ===
            .program => {
                // Plugin visitor 훅 선취권 (file-level worklet directive 등)
                if (try self.dispatchVisitor(.on_program, idx)) |replacement| return replacement;
                // ES2022 top-level await 다운레벨링: 미지원 타겟에서 async IIFE 로 wrap. (#1384)
                if (self.options.unsupported.top_level_await) {
                    if (try es2022_tla.lowerProgram(Transformer, self, node)) |wrapped| {
                        return wrapped;
                    }
                }
                const result = try self.visitListNode(idx);
                // styled-components cssProp transform 으로 추출된 module-level decl 들을
                // program body 끝에 hoist. trailing_nodes 가 nearest list (declarator list 등)
                // 에 들어가는 케이스 회피.
                const pending = &self.plugins.styled_components.css_prop_pending_decls;
                if (pending.items.len > 0) {
                    const result_node = self.ast.getNode(result);
                    const old_list = result_node.data.list;
                    const top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(top);
                    for (self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len]) |raw| {
                        try self.scratch.append(self.allocator, @as(NodeIndex, @enumFromInt(raw)));
                    }
                    for (pending.items) |decl_idx| {
                        try self.scratch.append(self.allocator, decl_idx);
                    }
                    const new_list = try self.ast.addNodeList(self.scratch.items[top..]);
                    pending.clearRetainingCapacity();
                    return self.ast.addNode(.{
                        .tag = .program,
                        .span = result_node.span,
                        .data = .{ .list = new_list },
                    });
                }
                return result;
            },
            .block_statement,
            .sequence_expression,
            .class_body,
            .formal_parameters,
            .function_body,
            => self.visitListNode(idx),

            // JSX — fragment는 .list, element/opening_element는 .extra
            .jsx_fragment => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXFragment(self, node);
                }
                return self.visitListNode(idx);
            },

            .template_literal => {
                if (self.options.unsupported.template_literal) {
                    return es2015_template.ES2015Template(Transformer).lowerTemplateLiteral(self, node);
                }
                // no-substitution template (data.none == 0)은 리프 노드 — visitListNode으로 처리하면
                // data.list = {start: X, len: 0}이 되어 codegen의 data.none == 0 체크가 깨짐
                if (node.data.none == 0) return self.copyNodeDirect(idx);
                return self.visitListNode(idx);
            },

            // array_expression: spread(ES2015) 다운레벨링
            .array_expression => {
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadInArray(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadArray(self, node);
                    }
                }
                return self.visitListNode(idx);
            },

            // object_expression: spread(ES2018) / method shorthand / computed property(ES2015) 다운레벨링
            .object_expression => {
                // Plugin visitor 훅 — 기본 방문 전 선취권 (null 반환 시 default 진행)
                if (try self.dispatchVisitor(.on_object_expression, idx)) |replacement| return replacement;
                if (self.options.unsupported.object_spread) {
                    if (es2018.ES2018(Transformer).hasSpreadProperty(self, node)) {
                        return es2018.ES2018(Transformer).lowerObjectSpread(self, node);
                    }
                }
                // method shorthand → { key: function() {} } 를 먼저 처리.
                // function_expression 내부 async/generator lowering까지 visitNode 경로로 수행한 뒤,
                // computed key가 남아 있으면 아래 ES2015Computed가 후속 처리한다.
                if (self.options.unsupported.object_extensions) {
                    if (es2015_object_methods.ES2015ObjectMethods(Transformer).hasObjectMethod(self, node)) {
                        const lowered = try es2015_object_methods.ES2015ObjectMethods(Transformer).lowerObjectMethods(self, node);
                        const lowered_node = self.ast.getNode(lowered);
                        if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, lowered_node)) {
                            return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, lowered_node);
                        }
                        return lowered;
                    }
                }
                if (self.options.unsupported.object_extensions) {
                    if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, node)) {
                        return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, node);
                    }
                }
                return self.visitListNode(idx);
            },

            // JSX element/opening_element: .extra 형식 (tag, attrs, children)
            .jsx_element => {
                // `<ClassNames>{({css}) => ...}</ClassNames>` 진입 시 destructured `css`
                // 의 local 이름을 scope frame 에 push — render-prop 함수 안의
                // tagged_template_expression 이 visit 될 때 인식되도록.
                const pushed_emotion_scope = try emotion_mod.maybeEnterClassNamesScope(self, node);
                defer if (pushed_emotion_scope) emotion_mod.exitClassNamesScope(self);

                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXElement(self, node);
                }
                return self.visitJSXElement(node);
            },
            .jsx_opening_element => self.visitJSXOpeningElement(node),

            // === 단항 노드: 자식 1개 재귀 방문 ===
            .expression_statement => {
                // emotion `injectGlobal\`...\`;` 같은 expression-statement form 에 sourceMap
                // 적용. autoLabel 은 var 이름이 없어 미적용 — sourceMap 만 부여.
                if (self.options.emotion and self.options.emotion_source_map) {
                    const new_idx = try self.visitUnaryNode(idx);
                    return emotion_mod.maybeTransformExpressionStatement(self, new_idx);
                }
                return self.visitUnaryNode(idx);
            },
            .return_statement,
            .throw_statement,
            .spread_element,
            => self.visitUnaryNode(idx),
            .parenthesized_expression => {
                // (expr as T) → expr: TS expression이면 괄호 불필요
                const inner = node.data.unary.operand;
                if (!inner.isNone()) {
                    const inner_tag = self.ast.getNode(inner).tag;
                    if (inner_tag == .ts_as_expression or
                        inner_tag == .ts_satisfies_expression or
                        inner_tag == .ts_non_null_expression or
                        inner_tag == .ts_type_assertion or
                        inner_tag == .flow_as_expression or
                        inner_tag == .flow_type_cast_expression)
                    {
                        return self.visitNode(inner);
                    }
                }
                return self.visitUnaryNode(idx);
            },
            .await_expression => {
                if (self.options.unsupported.async_await) {
                    return es2017_mod.ES2017(Transformer).lowerAwaitExpression(self, node);
                }
                return self.visitUnaryNode(idx);
            },
            .yield_expression,
            .rest_element,
            .decorator,
            => self.visitUnaryNode(idx),
            // JSX
            .jsx_spread_attribute,
            .jsx_expression_container,
            => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXExpressionContainer(self, node);
                }
                return self.visitUnaryNode(idx);
            },
            .jsx_spread_child,
            .chain_expression,
            .computed_property_key,
            .break_statement,
            .continue_statement,
            .static_block,
            => self.visitUnaryNode(idx),

            // === 이항 노드: 자식 2개 재귀 방문 ===
            .binary_expression,
            .logical_expression,
            => {
                // ES 다운레벨링: ** → Math.pow (target < es2016)
                if (self.options.unsupported.exponentiation and node.tag == .binary_expression) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .star2) {
                        return es2016.ES2016(Transformer).lowerExponentiation(self, node);
                    }
                }
                // ES 다운레벨링: ?? → ternary
                if (self.options.unsupported.nullish_coalescing and node.tag == .logical_expression) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .question2) {
                        return es2020.ES2020(Transformer).lowerNullishCoalescing(self, node);
                    }
                }
                // ES2022 Ergonomic Brand Checks: #x in obj → _x.has(obj) 등
                // private mapping이 설정돼 있을 때만 변환 (class 다운레벨 경로가 활성화된 경우).
                if (node.tag == .binary_expression and
                    (self.current_private_fields.len > 0 or self.current_private_methods.len > 0))
                {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .kw_in) {
                        if (es2015_class.ES2015Class(Transformer).lowerPrivateIn(self, node)) |result| {
                            return result;
                        }
                    }
                }
                return self.visitBinaryNode(idx);
            },
            .assignment_expression => {
                // ES2015: super.x = v / super.x += v / super.x ||= v 는
                // Parent.prototype.x 직접 접근이 아니라 receiver(this)를 보존하는 get/set
                // 헬퍼로 먼저 lowering한다. 이후 generic logical/compound lowering으로 넘기면
                // helper call에 대입하는 잘못된 target이 생성된다.
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).lowerSuperPropertyAssignment(self, node)) |result| {
                        return result;
                    }
                }
                // Private field 좌변은 모든 assignment 연산자(=, +=, ??=, ||=, &&= ...)를
                // lowerPrivateFieldSet 단일 경로에서 처리 — es2021/es2016 등은 좌변에
                // `(a = b)` 패턴을 만들어 get()/helper call에 대입하게 되므로 먼저 가로챈다.
                // (esbuild의 lowerAssign이나 SWC/Babel plugin 순서와 동일한 선점 패턴.)
                if (self.hasActivePrivateFieldLowering()) {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.ast.getNode(left_idx);
                        if (left_node.tag == .private_field_expression) {
                            if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldSet(self, node)) |result| {
                                return result;
                            }
                        }
                    }
                }
                // ES 다운레벨링: **= → a = Math.pow(a, b) (es2016)
                if (self.options.unsupported.exponentiation) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .star2_eq) {
                        return es2016.ES2016(Transformer).lowerExponentiationAssignment(self, node);
                    }
                }
                // ES 다운레벨링: ??=, ||=, &&= (es2021)
                if (self.options.unsupported.logical_assignment) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .question2_eq) {
                        return es2021.ES2021(Transformer).lowerNullishAssignment(self, node);
                    } else if (op == .pipe2_eq) {
                        return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .pipe2);
                    } else if (op == .amp2_eq) {
                        return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .amp2);
                    }
                }
                // ES2015: assignment destructuring → sequence expression.
                // destructuring 자체가 지원되더라도 target에 private field가 있으면 강제 lowering —
                // 일반 visit 경로가 `this.#x` 를 `_x.get(this)` 로 만들어 invalid assignment target이 됨 (#1485).
                {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.ast.getNode(left_idx);
                        if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                            const has_private = self.current_private_fields.len > 0 and
                                es2015_class.ES2015Class(Transformer).destructuringTargetHasPrivateField(self, left_idx);
                            if (self.options.unsupported.destructuring or has_private) {
                                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignment(self, node);
                            }
                        }
                    }
                }
                // styled-components: `Component = styled.div\`...\`` 도 wrap 대상.
                // visitBinaryNode 결과의 right 가 styled tagged template 이면 LHS identifier
                // 이름을 displayName 으로 사용해 wrap. =, +=, ||= 등 모든 연산자에서 동작
                // (의미상 = 만 styled component 할당이지만 가드 추가 비용 vs 자연스러운 케이스
                // 커버 trade-off — 비-= 연산자 + tagged template 조합은 거의 없음).
                if (self.options.styled_components and self.plugins.styled_components.default_binding != null) {
                    const new_idx = try self.visitBinaryNode(idx);
                    return styled_components_mod.maybeWrapAssignment(self, new_idx);
                }
                return self.visitBinaryNode(idx);
            },
            .while_statement,
            .do_while_statement,
            .with_statement,
            // JSX
            .jsx_attribute,
            .jsx_namespaced_name,
            .jsx_member_expression,
            // ES2024: import(x, opts) — binary { left=arg, right=options }
            .import_expression,
            => self.visitBinaryNode(idx),

            // === member expression: extra = [object, property, flags] ===
            .static_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super.method → Parent.prototype.method
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).isSuperMember(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMember(self, node);
                    }
                }
                return self.visitMemberExpression(node);
            },
            .private_field_expression => {
                // 순서 중요: `?.` 를 먼저 ternary 로 풀어야 한다. 아래의 lowerPrivateMethodGet /
                // lowerPrivateFieldGet 이 만든 `_x.get(this)` 호출이 `?.` short-circuit 안에 들어가면
                // base 가 null/undefined 일 때도 evaluate 되어 spec 위반이다.
                // class_private_field 가 lowering 대상이면 target 이 ES2020+ 라도 chain 자체를
                // 미리 풀어야 같은 회피가 가능 — `unsupported.optional_chaining` 만으로는 부족.
                if (self.options.unsupported.optional_chaining or self.hasActivePrivateFieldLowering()) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2022: this.#method → _method_fn.bind(this) (참조만, 호출 아닌 경우)
                if (self.current_private_methods.len > 0) {
                    if (es2022.ES2022(Transformer).lowerPrivateMethodGet(self, node)) |result| {
                        return result;
                    }
                }
                // ES2015/ES2022: this.#x → _x.get(this)
                if (self.hasActivePrivateFieldLowering()) {
                    if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldGet(self, node)) |result| {
                        return result;
                    }
                }
                return self.visitMemberExpression(node);
            },
            .computed_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super["prop"] → Parent.prototype["prop"]
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).isSuperComputedMember(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperComputedMember(self, node);
                    }
                }
                return self.visitMemberExpression(node);
            },

            // === unary/update expression: extra = [operand, operator_and_flags] ===
            .unary_expression,
            .update_expression,
            => self.visitUnaryExtra(node),

            // === 삼항 노드: 자식 3개 재귀 방문 ===
            .if_statement, .conditional_expression, .for_in_statement => {
                if (node.tag == .for_in_statement and self.current_private_fields.len > 0) {
                    if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
                }
                if (self.options.unsupported.destructuring) {
                    // for (var [i,j,k] in obj) → for (var _ref in obj) { var i=_ref[0],...; body }
                    const left = node.data.ternary.a;
                    if (!left.isNone()) {
                        const left_node = self.ast.getNode(left);
                        if (left_node.tag == .variable_declaration and
                            es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, left_node))
                        {
                            return es2015_destructuring.ES2015Destructuring(Transformer).lowerForInDestructuring(self, node);
                        }
                    }
                }
                return self.visitForInOfTernary(node);
            },
            .try_statement,
            => self.visitTernaryNode(node),
            .for_await_of_statement => {
                // for-await 키워드는 ES2018. ES2018 미만 타겟에서는 async function 자체를
                // 보존하더라도 for-await 구문만 __asyncValues + while 로 제거해야 한다.
                if (self.options.unsupported.needsForAwaitOfDownlevel()) {
                    return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOf(self, node);
                }
                return self.visitForInOfTernary(node);
            },
            .for_of_statement => {
                // private field target은 그대로 두면 `for (_x.get(this) of arr)` → invalid.
                // 임시 binding + body prefix assignment 패턴으로 변환 (#1491).
                if (self.current_private_fields.len > 0) {
                    if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
                }
                if (self.options.unsupported.for_of) {
                    return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatement(self, node);
                }
                return self.visitForInOfTernary(node);
            },
            .labeled_statement => {
                // for-of/for-await-of를 block으로 lowering할 때, label이 block에 남으면
                // 바디의 `continue LABEL` 이 iteration statement를 못 찾는다.
                // label을 lowered inner while/for_statement에 직접 부여해 이를 회피.
                const child_idx = node.data.binary.right;
                if (!child_idx.isNone()) {
                    const child = self.ast.getNode(child_idx);
                    if (self.options.unsupported.needsForAwaitOfDownlevel() and child.tag == .for_await_of_statement) {
                        const new_label = try self.visitNode(node.data.binary.left);
                        return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOfLabeled(self, child, new_label);
                    }
                    if (self.options.unsupported.for_of and child.tag == .for_of_statement) {
                        const new_label = try self.visitNode(node.data.binary.left);
                        return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatementLabeled(self, child, new_label);
                    }
                }
                return self.visitBinaryNode(idx);
            },

            // === extra 기반 노드: 별도 처리 ===
            .variable_declaration => self.visitVariableDeclaration(node),
            .variable_declarator => self.visitVariableDeclarator(node),
            .function_declaration,
            .function_expression,
            => {
                const e = node.data.extra;
                const flags = self.readU32(e, ast_mod.FunctionExtra.flags);
                if (self.options.unsupported.async_await and (flags & ast_mod.FunctionFlags.is_async) != 0) {
                    // async generator (`async function*`) → __asyncGenerator wrapper. (#1911)
                    if ((flags & ast_mod.FunctionFlags.is_generator) != 0) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncGeneratorToStateMachine(self, node);
                    }
                    // async + generator 둘 다 unsupported → 직접 state machine 생성
                    if (self.options.unsupported.generator) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncToStateMachine(self, node);
                    }
                    return es2017_mod.ES2017(Transformer).lowerAsyncFunction(self, node);
                }
                if (self.options.unsupported.generator and (flags & ast_mod.FunctionFlags.is_generator) != 0) {
                    return es2015_generator.ES2015Generator(Transformer).lowerGeneratorFunction(self, node);
                }
                return self.visitFunction(node);
            },
            .function,
            => self.visitFunction(node),
            .arrow_function_expression => {
                if (self.options.unsupported.async_await) {
                    const extras = self.ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 < extras.len and (extras[e + 2] & ast_mod.ArrowFlags.is_async) != 0) {
                        // async + generator 둘 다 unsupported → 직접 state machine 생성
                        if (self.options.unsupported.generator) {
                            return es2017_mod.ES2017(Transformer).lowerAsyncArrowToStateMachine(self, node);
                        }
                        return es2017_mod.ES2017(Transformer).lowerAsyncArrow(self, node);
                    }
                }
                if (self.options.unsupported.arrow) {
                    return es2015_arrow.ES2015Arrow(Transformer).lowerArrowFunction(self, node);
                }
                return self.visitArrowFunction(node);
            },
            .class_declaration => {
                const replacement_idx = try self.dispatchVisitor(.on_class_declaration, idx);
                const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
                // Stage 3 decorator는 unsupported.class 분기보다 먼저 돌려야 한다 — 반대면 decorator가 silent drop.
                // 이름 있는 class_declaration은 Stage 3 내부에서 outer_var_decl을 pending_nodes로 hoist하고
                // `.none`을 반환하므로, export_named/default declaration이 이름을 감지해 `export { X };` 또는
                // `export default X;` 형태로 분리한다 (#1538). 익명/class_expression은 iife_call을 직접 반환해
                // 아래 visitNode 재방문이 arrow/let/static block을 ES5로 마저 다운레벨링한다.
                if (try self.tryTransformStage3(target_node)) |stage3_result| {
                    if (self.options.unsupported.class) return self.visitNode(stage3_result);
                    return stage3_result;
                }
                if (self.options.unsupported.class) {
                    return es2015_class.ES2015Class(Transformer).lowerClassDeclaration(self, target_node);
                }
                if (replacement_idx) |r| return r;
                return self.visitClass(node);
            },
            .class_expression => {
                const replacement_idx = try self.dispatchVisitor(.on_class_expression, idx);
                const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
                if (try self.tryTransformStage3(target_node)) |stage3_result| {
                    if (self.options.unsupported.class) return self.visitNode(stage3_result);
                    return stage3_result;
                }
                if (self.options.unsupported.class) {
                    return es2015_class.ES2015Class(Transformer).lowerClassExpression(self, target_node);
                }
                if (replacement_idx) |r| return r;
                return self.visitClass(node);
            },
            .for_statement => self.visitForStatement(node),
            .switch_statement => self.visitSwitchStatement(node),
            .switch_case => self.visitSwitchCase(node),
            .call_expression => {
                // ES2022: this.#method(args) → _method_fn.call(this, args)
                if (self.current_private_methods.len > 0) {
                    if (es2022.ES2022(Transformer).lowerPrivateMethodCall(self, node)) |result| {
                        return result;
                    }
                }
                // ES 다운레벨링: ?.() → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super(args) → Parent.call(this, args)
                // ES2015: super.method(args) → Parent.prototype.method.call(this, args)
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).isSuperCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperCall(self, node);
                    }
                    if (es2015_class.ES2015Class(Transformer).isSuperMethodCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMethodCall(self, node);
                    }
                    if (es2015_class.ES2015Class(Transformer).isSuperComputedMethodCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperComputedMethodCall(self, node);
                    }
                }
                // Plugin visitor 훅 — web-check 치환 등
                if (try self.dispatchVisitor(.on_call_expression, idx)) |replacement| return replacement;
                // ES2015: spread in call → .apply()
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadCall(self, node);
                    }
                }
                return self.visitCallExpression(node);
            },
            .new_expression => {
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadNew(self, node);
                    }
                }
                return self.visitNewExpression(node);
            },
            .tagged_template_expression => self.visitTaggedTemplate(node),
            .method_definition => self.visitMethodDefinition(node),
            .property_definition => self.visitPropertyDefinition(node),
            .object_property => self.visitObjectProperty(node),
            .formal_parameter => self.visitFormalParameter(node),
            .import_declaration => self.visitImportDeclaration(node),
            .export_named_declaration => self.visitExportNamedDeclaration(node),
            .export_default_declaration => self.visitExportDefaultDeclaration(node),
            .export_all_declaration => self.visitExportAllDeclaration(node),
            .catch_clause => {
                if (self.options.unsupported.optional_catch_binding) {
                    return es2019.ES2019(Transformer).lowerOptionalCatchBinding(self, node);
                }
                return self.visitBinaryNode(idx);
            },
            .binding_property,
            .assignment_pattern,
            => self.visitBinaryNode(idx),
            .accessor_property => self.visitAccessorProperty(node),

            // === 리프 노드: 그대로 복사 (자식 없음) ===
            // this_expression: static block 안에서 클래스 이름으로 치환 가능
            .this_expression => {
                // ES2022 static block 다운레벨링 중이고, 일반 함수 안이 아니면 치환
                if (self.static_block_class_name) |class_span| {
                    if (self.this_depth == 0) {
                        return self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = class_span,
                            .data = .{ .string_ref = class_span },
                        });
                    }
                }
                // ES2015 arrow this 캡처: arrow body 안의 this → _this
                if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                    self.needs_this_var = true;
                    return es_helpers.makeIdentifierRef(self, "_this");
                }
                // ES2015 class super() 후 this → _this
                if (self.super_call_this_alias) {
                    const helper = try es_helpers.makeRuntimeHelperRef(self, "__assertThisInitialized");
                    const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
                    self.runtime_helpers.derived_constructor = true;
                    return es_helpers.makeCallExpr(self, helper, &.{this_ref}, node.span);
                }
                return self.copyNodeDirect(idx);
            },

            // meta_property: new.target / import.meta
            .meta_property => {
                // new.target (data.none == 1) 다운레벨링
                if (node.data.none == 1 and self.options.unsupported.new_target) {
                    return self.lowerNewTarget(node.span);
                }
                return self.copyNodeDirect(idx);
            },

            .boolean_literal,
            .null_literal,
            .numeric_literal,
            .bigint_literal,
            => self.copyNodeDirect(idx),
            .string_literal => blk: {
                if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(idx);
                const raw = self.ast.getText(node.span);
                // raw는 따옴표를 포함. content 만 변환 후 다시 조립.
                if (raw.len < 2) break :blk self.copyNodeDirect(idx);
                const quote = raw[0];
                if (quote != '"' and quote != '\'') break :blk self.copyNodeDirect(idx);
                const content = raw[1 .. raw.len - 1];
                const lowered = (try unicode_escape_lower.lowerContent(self.allocator, content)) orelse break :blk self.copyNodeDirect(idx);
                defer self.allocator.free(lowered);
                const new_raw = try std.fmt.allocPrint(self.allocator, "{c}{s}{c}", .{ quote, lowered, quote });
                defer self.allocator.free(new_raw);
                const new_span = try self.ast.addString(new_raw);
                break :blk try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = new_span,
                    .data = .{ .string_ref = new_span },
                });
            },
            .regexp_literal => blk: {
                const u = self.options.unsupported;
                if (!(u.regex_dotall or u.regex_named_groups or u.regex_sticky or u.unicode_brace_escape)) {
                    break :blk self.copyNodeDirect(idx);
                }
                const raw = self.ast.getText(node.span);
                const result = try regex_lower.lower(self.allocator, raw, .{ .unsupported = u });
                const new_text = result.text orelse break :blk self.copyNodeDirect(idx);
                defer self.allocator.free(new_text);
                const new_span = try self.ast.addString(new_text);
                break :blk try self.ast.addNode(.{
                    .tag = .regexp_literal,
                    .span = new_span,
                    .data = .{ .string_ref = new_span },
                });
            },
            .identifier_reference => {
                // ES2015 arrow arguments 캡처: arrow body 안의 arguments → _arguments
                if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                    const text = self.ast.getText(node.data.string_ref);
                    if (std.mem.eql(u8, text, "arguments")) {
                        self.needs_arguments_var = true;
                        const args_span = try self.ast.addString("_arguments");
                        const new_idx = try self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = args_span,
                            .data = .{ .string_ref = args_span },
                        });
                        self.propagateSymbolId(idx, new_idx);
                        return new_idx;
                    }
                }
                if (try self.tryRenameIdentifierLike(idx, .identifier_reference)) |i| return i;
                return self.copyNodeDirect(idx);
            },
            .binding_identifier => {
                if (try self.tryRenameIdentifierLike(idx, .binding_identifier)) |i| return i;
                return self.copyNodeDirect(idx);
            },
            .assignment_target_identifier => {
                if (try self.tryRenameIdentifierLike(idx, .assignment_target_identifier)) |i| return i;
                return self.copyNodeDirect(idx);
            },
            .template_element => blk: {
                if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(idx);
                const raw = self.ast.getText(node.span);
                const lowered = (try unicode_escape_lower.lowerContent(self.allocator, raw)) orelse break :blk self.copyNodeDirect(idx);
                defer self.allocator.free(lowered);
                const new_span = try self.ast.addString(lowered);
                break :blk try self.ast.addNode(.{
                    .tag = .template_element,
                    .span = new_span,
                    .data = node.data,
                });
            },
            .private_identifier,
            .empty_statement,
            .debugger_statement,
            .directive,
            .hashbang,
            .super_expression,
            .elision,
            .jsx_empty_expression,
            .jsx_identifier,
            .jsx_closing_element,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            => self.copyNodeDirect(idx),

            // JSX leaf — jsx_text는 별도 처리 (jsx_transform 시 lowerJSXText)
            .jsx_text => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXText(self, node);
                }
                return self.copyNodeDirect(idx);
            },

            // === import/export specifiers ===
            // #1791 Phase D: inline `type` modifier (SPEC_FLAG_TYPE_ONLY) 또는 named specifier 의
            // value-ref 0 (type 위치에서만 사용) 이면 elide. visitExtraList 가 `.none` 을
            // 필터링. default/namespace 는 JSX pragma 등 implicit value use 위험이 커
            // `shouldElideImportSpecifier` 에서 이미 false 를 반환하므로 elision 비활성.
            .import_specifier => blk: {
                if ((node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) break :blk NodeIndex.none;
                if (self.shouldElideImportSpecifier(idx, node)) break :blk NodeIndex.none;
                break :blk self.visitBinaryNode(idx);
            },
            .export_specifier => if ((node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) .none else self.visitBinaryNode(idx),
            // default/namespace specifier는 string_ref(span) 복사 — 자식 노드 없음
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            => self.copyNodeDirect(idx),

            // === Pattern 노드: 자식 재귀 방문 ===
            .array_pattern,
            .object_pattern,
            .array_assignment_target,
            .object_assignment_target,
            => self.visitListNode(idx),

            .binding_rest_element,
            .assignment_target_rest,
            => self.visitUnaryNode(idx),
            .assignment_target_with_default,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => self.visitBinaryNode(idx),
            // assignment_target_identifier: string_ref → 변환 불필요 (identifier와 동일)

            // === TS enum/namespace: 런타임 코드 생성 (codegen에서 IIFE 출력) ===
            .ts_enum_declaration => self.visitEnumDeclaration(node),
            .ts_enum_member => self.visitBinaryNode(idx),
            .ts_enum_body => self.visitListNode(idx),
            // === Flow enum (#2401): codegen 에서 Object.freeze({...}) 출력. members 의
            // init expression 만 visit 필요 (다른 변환 영향 없음).
            .flow_enum_declaration => self.visitFlowEnumDeclaration(node),
            .flow_enum_member => self.visitBinaryNode(idx),
            .ts_module_declaration => self.visitNamespaceDeclaration(node),
            .ts_module_block => self.visitListNode(idx),

            // import x = require('y') → const x = require('y')
            .ts_import_equals_declaration => self.visitImportEqualsDeclaration(node),

            // export = expr → module.exports = expr;
            .ts_export_assignment => self.visitExportAssignment(node),

            // === 나머지: invalid + TS 타입 전용 노드 ===
            // TS 타입 노드는 isTypeOnlyNode 검사(위)에서 이미 .none으로 반환됨.
            // 여기 도달하면 strip_types=false인 경우 → 그대로 복사.
            .invalid => .none,
            else => self.copyNodeDirect(idx),
        };
    }

    // ================================================================
    // Node/symbol/extra helpers — transformer/node_helpers.zig로 위임
    // ================================================================
    const node_helpers = @import("transformer/node_helpers.zig");
    pub const copyNodeDirect = node_helpers.copyNodeDirect;
    const tryRenameIdentifierLike = node_helpers.tryRenameIdentifierLike;
    pub const getClassNameSpan = node_helpers.getClassNameSpan;
    pub const propagateSymbolId = node_helpers.propagateSymbolId;
    pub const copySymbolId = node_helpers.copySymbolId;
    pub const makeIdentifierRefWithSymbol = node_helpers.makeIdentifierRefWithSymbol;
    pub const attachRootScopeSymbolByName = node_helpers.attachRootScopeSymbolByName;
    const visitUnaryNode = node_helpers.visitUnaryNode;
    const visitBinaryNode = node_helpers.visitBinaryNode;
    const visitUnaryExtra = node_helpers.visitUnaryExtra;
    pub const visitMemberExpression = node_helpers.visitMemberExpression;
    const visitTernaryNode = node_helpers.visitTernaryNode;
    pub const getSymbolIdAt = node_helpers.getSymbolIdAt;
    pub const readNodeIdx = node_helpers.readNodeIdx;
    pub const readU32 = node_helpers.readU32;
    pub const addExtraNode = node_helpers.addExtraNode;

    pub const visitTaggedTemplate = tagged_template_mod.visitTaggedTemplate;

    // ================================================================
    // Control-flow visitors — transformer/control_flow.zig로 위임
    // ================================================================
    const control_flow_mod = @import("transformer/control_flow.zig");
    const visitForInOfTernary = control_flow_mod.visitForInOfTernary;
    const tryLowerForInOfPrivateTarget = control_flow_mod.tryLowerForInOfPrivateTarget;
    const visitForStatement = control_flow_mod.visitForStatement;
    const visitSwitchStatement = control_flow_mod.visitSwitchStatement;
    const visitSwitchCase = control_flow_mod.visitSwitchCase;

    // ================================================================
    // List traversal / block-scope helpers — transformer/lists.zig로 위임
    // ================================================================
    const lists_mod = @import("transformer/lists.zig");
    const visitListNode = lists_mod.visitListNode;
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

    /// TS expression (as/satisfies/!/type assertion/instantiation)에서
    /// 값 부분만 추출한다.
    ///
    /// 예: `x as number` → `x` (operand만 반환)
    /// 예: `x!` → `x` (non-null assertion 제거)
    /// 예: `<number>x` → `x` (type assertion 제거)
    fn visitTsExpression(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);
        if (!self.options.strip_types) {
            return self.copyNodeDirect(idx);
        }
        const operand = node.data.unary.operand;
        // ts_type_assertion: <T>(expr) → expr (괄호 불필요)
        // angle-bracket 타입 어설션에서 operand가 parenthesized_expression이면
        // 괄호를 벗겨서 내부 expression만 반환한다.
        // 단, comma sequence는 괄호가 필요하므로 유지한다.
        if (node.tag == .ts_type_assertion and !operand.isNone()) {
            const op_node = self.ast.getNode(operand);
            if (op_node.tag == .parenthesized_expression and !op_node.data.unary.operand.isNone()) {
                const inner = self.ast.getNode(op_node.data.unary.operand);
                if (inner.tag != .sequence_expression) {
                    return self.visitNode(op_node.data.unary.operand);
                }
            }
        }
        // 모든 TS expression은 unary로, operand가 값 부분
        return self.visitNode(operand);
    }

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

    /// 함수 body가 worklet이 될 예정이면 `plugins.worklet.body_depth`를 올린 상태로 body를 방문한다.
    /// 반환된 body 내부에서는 `--define` 치환이 억제되어 UI 런타임에서도 심볼이 안전하게 유지된다.
    pub fn visitBodyWorkletAware(self: *Transformer, body_idx: NodeIndex) Error!NodeIndex {
        const is_worklet = self.plugins.worklet.auto_next or
            worklet_mod.isWorkletDirectiveGeneric(self, body_idx, "worklet");
        if (is_worklet) self.plugins.worklet.body_depth += 1;
        defer if (is_worklet) {
            self.plugins.worklet.body_depth -= 1;
        };
        return self.visitNode(body_idx);
    }

    /// Fast Refresh 등록이 억제된 scope 안에서 node를 visit한다.
    /// IIFE 내부 factory처럼 최상위 바인딩이 아닌 함수 선언에 대해
    /// `_cN = <name>` 참조 시 ReferenceError를 유발하지 않도록 refresh 등록을 건너뛴다.
    /// 호출 scope 바깥의 suppress 상태는 save/restore된다.
    pub fn visitWithRefreshSuppressed(self: *Transformer, node_idx: NodeIndex) Error!NodeIndex {
        const saved = self.plugins.refresh.suppress_registration;
        self.plugins.refresh.suppress_registration = true;
        defer self.plugins.refresh.suppress_registration = saved;
        return self.visitNode(node_idx);
    }

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

    /// jsx_element: extra = [tag_name, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn visitJSXElement(self: *Transformer, node: Node) Error!NodeIndex {
        // cssProp pre-processing — `<X css={...}>` 를 styled component 로 추출 (jsx_transform=false
        // 경로 — jsx 가 그대로 출력되는 케이스).
        const working_node = (try styled_components_mod.maybeExtractCssProp(self, node)) orelse node;
        const e = working_node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        const children_len = self.readU32(e, 4);
        const new_children = if (children_len > 0)
            try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = children_len })
        else
            NodeList{ .start = 0, .len = 0 };
        return self.addExtraNode(.jsx_element, working_node.span, &.{
            @intFromEnum(new_tag),
            new_attrs.start,
            new_attrs.len,
            new_children.start,
            new_children.len,
        });
    }

    /// jsx_opening_element: extra = [tag_name, attrs_start, attrs_len]
    fn visitJSXOpeningElement(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitJSXExtraNode(.jsx_opening_element, node);
    }

    /// JSX extra 노드 공통: tag + attrs만 복사 (opening element 등)
    fn visitJSXExtraNode(self: *Transformer, tag: Tag, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(tag, node.span, &.{
            @intFromEnum(new_tag),
            new_attrs.start,
            new_attrs.len,
        });
    }

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    // ================================================================
    // Declaration/function visitors — transformer/declarations.zig로 위임
    // ================================================================
    const declarations_mod = @import("transformer/declarations.zig");
    const visitVariableDeclaration = declarations_mod.visitVariableDeclaration;
    const visitVariableDeclarator = declarations_mod.visitVariableDeclarator;
    const visitFunction = declarations_mod.visitFunction;
    const lowerNewTarget = declarations_mod.lowerNewTarget;
    pub const ParamPropertyResult = declarations_mod.ParamPropertyResult;
    pub const visitParamsCollectProperties = declarations_mod.visitParamsCollectProperties;
    pub const buildParameterPropertyStatements = declarations_mod.buildParameterPropertyStatements;
    pub const insertParameterPropertyAssignmentsAfterSuper = declarations_mod.insertParameterPropertyAssignmentsAfterSuper;
    pub const insertParameterPropertyAssignments = declarations_mod.insertParameterPropertyAssignments;
    pub const insertStatementsAfterSuper = declarations_mod.insertStatementsAfterSuper;
    pub const prependStatementsToBody = declarations_mod.prependStatementsToBody;

    /// arrow_function_expression: extra = [params_list, body, flags]
    /// flags: 0x01 = async
    fn visitArrowFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const params_idx = self.readNodeIdx(e, 0);
        const body_idx = self.readNodeIdx(e, 1);
        const flags = self.readU32(e, 2);
        const new_params = try self.visitNode(params_idx);
        const new_body = try self.visitBodyWorkletAware(body_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_params), @intFromEnum(new_body), flags });
        const result = try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = node.span, .data = .{ .extra = new_extra } });

        // Plugin dispatch: auto-workletization 등 AST 플러그인 적용
        const is_auto_worklet = self.plugins.worklet.auto_next;
        if (is_auto_worklet or self.options.plugins.len > 0) {
            // parser가 arrow params를 항상 formal_parameters list로 정규화하므로 tag 체크 불필요.
            const orig_params_list: NodeList = blk: {
                if (params_idx.isNone()) break :blk .{ .start = 0, .len = 0 };
                const n = self.ast.getNode(params_idx);
                break :blk if (n.tag == .formal_parameters) n.data.list else .{ .start = 0, .len = 0 };
            };
            const new_params_list: NodeList = blk: {
                if (new_params.isNone()) break :blk .{ .start = 0, .len = 0 };
                const n = self.ast.getNode(new_params);
                break :blk if (n.tag == .formal_parameters) n.data.list else .{ .start = 0, .len = 0 };
            };

            if (try self.dispatchFunctionPlugins(result, .{
                .node_idx = result,
                .node_tag = .arrow_function_expression,
                .name = null,
                .body_idx = new_body,
                .params = new_params_list,
                .original_params = orig_params_list,
                .original_body_idx = body_idx,
                .flags = flags,
                .source_path = self.options.jsx_filename,
                .is_auto_worklet = is_auto_worklet,
            })) |replacement| {
                return replacement;
            }
        }

        return result;
    }

    // ================================================================
    // Class + Decorator — transformer/class_decorator.zig로 위임
    // ================================================================
    const class_deco = @import("transformer/class_decorator.zig");

    /// Stage 3 decorator lowering이 필요한 class면 실행해 결과 NodeIndex 반환, 아니면 null.
    /// `unsupported.class` 분기보다 먼저 호출해 ES5 target에서 decorator silent drop을 방지한다.
    fn tryTransformStage3(self: *Transformer, node: Node) Error!?NodeIndex {
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

    /// call_expression: extra = [callee, args_start, args_len, flags]
    pub fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const callee_idx = self.readNodeIdx(e, 0);
        const args_start = self.readU32(e, 1);
        const args_len = self.readU32(e, 2);
        const flags = self.readU32(e, 3);

        // String.{replace,replaceAll} 의 replacement string 안 `$<name>` → `$N` 변환.
        // regex_lower 가 named group 을 strip하면 인덱스 매핑이 깨져 replacement 가 매칭 실패하므로,
        // literal regex + literal string 조합에 한해 replacement 도 함께 변환한다.
        if (self.options.unsupported.regex_named_groups and args_len == 2) {
            if (try self.tryRewriteReplaceNamedRefs(callee_idx, args_start)) |rewritten_args| {
                const new_callee = try self.visitNode(callee_idx);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_callee), rewritten_args.start, rewritten_args.len, flags,
                });
                return self.ast.addNode(.{
                    .tag = .call_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }
        }

        const new_callee = try self.visitNode(callee_idx);

        // Auto-workletization: callee 이름이 플러그인 목록에 매칭되면
        // 해당 인자 위치의 function/arrow에 plugins.worklet.auto_next 플래그를 설정.
        const auto_callee = self.matchAutoWorkletCallee(callee_idx);
        const new_args = if (auto_callee != null)
            try self.visitCallArgsWithAutoWorklet(args_start, args_len, auto_callee.?)
        else
            try self.visitExtraList(.{ .start = args_start, .len = args_len });

        const new_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.ast.addNode(.{
            .tag = .call_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    // ================================================================
    // Regex replacement 변환 — transformer/regex.zig로 위임
    // ================================================================
    const regex_mod = @import("transformer/regex.zig");
    pub const tryRewriteReplaceNamedRefs = regex_mod.tryRewriteReplaceNamedRefs;
    pub const collectConstRegexDeclarators = regex_mod.collectConstRegexDeclarators;

    /// new_expression: extra = [callee, args_start, args_len, flags]
    fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const callee_idx = self.readNodeIdx(e, 0);
        const args_start = self.readU32(e, 1);
        const args_len = self.readU32(e, 2);
        const flags = self.readU32(e, 3);
        const new_callee = try self.visitNode(callee_idx);
        const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });
        const new_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.ast.addNode(.{
            .tag = .new_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    // ================================================================
    // Class/object member visitors — transformer/members.zig로 위임
    // ================================================================
    const members_mod = @import("transformer/members.zig");
    pub const visitMethodDefinition = members_mod.visitMethodDefinition;
    pub const visitPropertyDefinition = members_mod.visitPropertyDefinition;
    pub const visitAccessorProperty = members_mod.visitAccessorProperty;
    const visitObjectProperty = members_mod.visitObjectProperty;
    const visitFormalParameter = members_mod.visitFormalParameter;

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

    /// 함수-유사 노드의 body가 extra_data에서 차지하는 슬롯 오프셋.
    /// parser/ast.zig의 노드 extra 레이아웃 정의와 일치해야 한다.
    fn functionBodyOffset(tag: @import("../parser/ast.zig").Node.Tag) u32 {
        return switch (tag) {
            // arrow: [params(0), body(1), flags]
            .arrow_function_expression => 1,
            // function_declaration/expression/method_definition: [name/key(0), params(1), body(2), flags(3), ...]
            else => 2,
        };
    }

    /// Plugin visitor 훅 dispatch — 지정된 tag에 등록된 훅을 순회하며 first-wins로 호출.
    /// 모든 훅이 null 반환이면 null → caller가 default 방문 진행.
    pub const VisitorHookKind = enum { on_program, on_object_expression, on_call_expression, on_class_declaration, on_class_expression };
    pub fn dispatchVisitor(self: *Transformer, comptime kind: VisitorHookKind, node_idx: NodeIndex) Error!?NodeIndex {
        if (self.options.plugins.len == 0) return null;
        var api = AstTransformCtx{ .transformer = self };
        for (self.options.plugins) |p| {
            const v = p.visitor orelse continue;
            // enum → struct field: @tagName이 런타임 오버헤드 없이 comptime 매핑.
            // 새 훅 추가 시 enum + Visitor struct만 수정하면 됨 (switch 분기 불필요).
            const hook = @field(v, @tagName(kind)) orelse continue;
            const result = hook(p.context, &api, node_idx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PluginFailed => continue,
            };
            if (result) |r| return r;
        }
        return null;
    }

    /// onFunction 플러그인 훅을 실행한다.
    /// 플러그인이 함수를 교체하면 새 NodeIndex를 반환, 아니면 null.
    /// body 수정 시 result 노드의 extra_data를 직접 패치한다.
    pub fn dispatchFunctionPlugins(self: *Transformer, result: NodeIndex, func_info: FunctionInfo) Error!?NodeIndex {
        if (self.options.plugins.len == 0) return null;
        var api = AstTransformCtx{ .transformer = self, .modified_body = null };
        defer api.deinitClosureCache();
        for (self.options.plugins) |p| {
            if (p.onFunction) |hook| {
                hook(p.context, &api, func_info) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PluginFailed => {},
                };
            }
        }
        if (api.modified_body) |new_body_idx| {
            const result_extra = self.ast.getNode(result).data.extra;
            self.ast.extra_data.items[result_extra + functionBodyOffset(func_info.node_tag)] = @intFromEnum(new_body_idx);
        }
        return api.replaced_node;
    }
};
