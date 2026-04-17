//! ZTS Transformer — 핵심 변환 엔진
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
const es2015_params = @import("es2015_params.zig");
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
pub const ast_plugin_mod = @import("ast_plugin.zig");
pub const AstTransformCtx = ast_plugin_mod.AstTransformCtx;
pub const FunctionInfo = ast_plugin_mod.FunctionInfo;
const plugin_mod = @import("../bundler/plugin.zig");
pub const Plugin = plugin_mod.Plugin;

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
pub const DefineEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Transformer 설정.
pub const TransformOptions = struct {
    /// TS 타입 스트리핑 활성화 (기본: true)
    strip_types: bool = true,
    /// console.* 호출 제거 (--drop=console)
    drop_console: bool = false,
    /// debugger 문 제거 (--drop=debugger)
    drop_debugger: bool = false,
    /// 특정 라벨의 labeled statement 제거 (--drop-labels=DEV,TEST)
    drop_labels: []const []const u8 = &.{},
    /// define 글로벌 치환 (D020). 예: process.env.NODE_ENV → "production"
    define: []const DefineEntry = &.{},
    /// React Fast Refresh 활성화. 컴포넌트에 $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// useDefineForClassFields=false: instance field를 constructor의 this.x = value 할당으로 변환.
    /// true(기본값)이면 class field를 그대로 유지 (TC39 [[Define]] semantics).
    /// false이면 TS 4.x 이전 동작 — field를 constructor body로 이동 ([[Set]] semantics).
    use_define_for_class_fields: bool = true,
    /// experimentalDecorators: legacy decorator를 __decorateClass 호출로 변환.
    /// false(기본값)이면 decorator를 TC39 Stage 3 형태로 그대로 출력.
    /// true이면 class/method/property decorator를 esbuild 호환 __decorateClass 호출로 변환.
    experimental_decorators: bool = false,
    /// emitDecoratorMetadata: __metadata("design:paramtypes", [...]) 호출 주입.
    /// NestJS, Angular, TypeORM 등 reflect-metadata 기반 DI에 필요.
    emit_decorator_metadata: bool = false,
    /// Unsupported features bitmask. feature별로 다운레벨링 여부를 결정.
    /// ESTarget(es2020) 또는 엔진 버전(chrome80,safari14)에서 변환됨.
    unsupported: compat.UnsupportedFeatures = .{},

    // --- JSX lowering (Phase 1: 트랜스파일 모드) ---
    /// JSX AST → call_expression 변환 활성화
    jsx_transform: bool = false,
    /// JSX 런타임 모드 (codegen.JsxRuntime과 동일 enum 사용)
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    /// classic 모드 factory (기본: "React.createElement")
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 fragment (기본: "React.Fragment")
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source (기본: "react")
    jsx_import_source: []const u8 = "react",
    /// jsxDEV의 fileName 출력용 파일 경로
    jsx_filename: []const u8 = "",

    /// 플러그인 배열. string-based 훅과 AST 훅을 모두 포함하는 통합 인터페이스.
    /// transformer는 AST 훅(onFunction 등)만 사용.
    plugins: []const Plugin = &.{},

    /// Reanimated worklet plugin의 substituteWebPlatformChecks 옵션 포팅.
    /// true일 때 `isWeb()` / `shouldBeUseWeb()` 호출을 `true` 리터럴로 정적 치환.
    /// web build에서 플랫폼 체크 코드가 항상 true로 평가되므로 dead code 제거 효과.
    substitute_web_platform_checks: bool = false,

    /// Reanimated worklet plugin의 `globals` 옵션 포팅.
    /// 사용자가 지정한 이름은 closure 분석에서 제외 (전역으로 간주).
    /// 예: `globals: ['__DEV__']` → worklet 내 `__DEV__` 참조가 __closure에 포함 안 됨.
    worklet_globals: []const []const u8 = &.{},

    /// worklet 함수의 `__pluginVersion` 값. null이면 기본 ZTS 상수 사용.
    /// Reanimated dev mode (`serializable.native.ts:464`)에서 `jsVersion`과 대조.
    worklet_plugin_version: ?[]const u8 = null,

    /// Reanimated worklet plugin의 `disableWorkletClasses` 옵션 포팅.
    /// true일 때 worklet body의 `new X()` 감지 시 `X__classFactory`를 closure에 자동 주입하지 않음.
    disable_worklet_classes: bool = false,

    pub const compat = @import("compat.zig");
};

/// 런타임 헬퍼 사용 추적 비트맵.
/// transformer가 각 변환 시 해당 비트를 설정하고,
/// 번들러 emitter가 필요한 헬퍼만 출력에 주입한다.
pub const RuntimeHelpers = packed struct(u32) {
    /// __async: async/await → generator wrapper (ES2017)
    async_helper: bool = false,
    /// __extends: class 상속 prototype chain (ES2015)
    extends: bool = false,
    /// __spreadArray: spread 연산 (ES2015)
    spread_array: bool = false,
    /// __generator: generator 상태 머신 (ES2015)
    generator: bool = false,
    /// __rest: destructuring rest (ES2015)
    rest: bool = false,
    /// __values: for-of iterator protocol (ES2015)
    values: bool = false,
    /// __toBinary: base64 → Uint8Array (binary 로더)
    to_binary: bool = false,
    /// __name: 함수/클래스 .name 프로퍼티 보존 (--keep-names)
    keep_names: bool = false,
    /// __classPrivateMethodInit: private method brand check (WeakSet.add with error)
    class_private_method_init: bool = false,
    /// __classPrivateMethodGet: private method access with brand check
    class_private_method_get: bool = false,
    /// __classCallCheck: class를 new 없이 호출 방지 (ES2015 스펙)
    class_call_check: bool = false,
    /// __callSuper: Reflect.construct 기반 super() 호출 (네이티브 클래스 extends 지원)
    call_super: bool = false,
    /// __taggedTemplateLiteral: tagged template 객체 생성 (ES2015)
    tagged_template_literal: bool = false,
    /// __using/__callDispose: using/await using 변환 (ES2025)
    using_ctx: bool = false,
    /// __classStaticPrivateFieldSpecGet/Set: static private field accessor
    class_static_private_field: bool = false,
    /// __esDecorate/__runInitializers: TC39 Stage 3 decorator 변환 (TypeScript 5.0+)
    es_decorator: bool = false,
    /// __asyncValues: for-await-of → while 루프 변환 (ES2018)
    async_values: bool = false,
    _padding: u15 = 0,
};

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
    ast: Ast,

    /// 파서 노드 수. transform() 시작 시 루트 인덱스(parser_node_count - 1) 계산에 사용.
    parser_node_count: u32,

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

    /// semantic analyzer의 심볼 테이블 (unused import 판별용).
    /// 비어 있으면 unused import 제거 비활성.
    symbols: []const Symbol = &.{},

    /// define value의 string_table Span 캐시. options.define과 동일 인덱스.
    /// transform() 시작 시 한 번 빌드하여, tryDefineReplace에서 addString 중복 호출을 방지.
    define_spans: []Span = &.{},

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
    /// 단순 케이스(numeric/string literal + auto-increment)만 지원.
    const_enums: std.ArrayList(ConstEnumDecl) = .empty,

    pub const BlockRenameEntry = struct {
        old_name: []const u8,
        new_name: []const u8,
    };

    pub const GeneratorLabelEntry = struct {
        name: []const u8,
        break_label: u32,
        continue_label: ?u32,
    };

    pub const NewTargetCtx = union(enum) {
        none,
        constructor, // class constructor: new.target → this.constructor
        method, // class method: new.target → void 0
        function_named: Span, // function Fn: new.target → this instanceof Fn ? this.constructor : void 0
    };

    pub const ConstEnumValue = union(enum) {
        number: f64, // ECMAScript Number — 소수/큰 정수 모두 표현 가능
        /// quote 미포함 raw 문자열. AST 출력 시 quote 추가.
        string: []const u8,
    };

    pub const ConstEnumMember = struct {
        name: []const u8,
        value: ConstEnumValue,
    };

    pub const ConstEnumDecl = struct {
        name: []const u8,
        members: []const ConstEnumMember,
        /// enum binding 의 symbol_id. shadowing 검사 — identifier_reference 의 symbol_id 가
        /// 일치할 때만 인라인 (같은 스코프의 다른 변수 잘못 변환 방지). null이면 symbol 정보 없음 → 이름으로만 매칭.
        symbol_id: ?u32,
    };

    pub const PrivateFieldMapping = struct {
        original_name: []const u8, // "#x"
        var_name: []const u8, // "_x"
        is_static: bool = false, // static private field → descriptor 객체 패턴
        class_name: ?[]const u8 = null, // static일 때 클래스명 (brand check용)
    };

    pub const PrivateMethodMapping = struct {
        original_name: []const u8, // "#method" (원본 소스 텍스트)
        weakset_name: []const u8, // "_method" (WeakSet 변수명)
        func_name: []const u8, // "_method_fn" (추출 함수명)
        member_idx: NodeIndex = NodeIndex.none, // method_definition 노드 (ES2015 경로에서 사용)
    };

    // RefreshRegistration / RefreshSignature 타입 정의는 plugin_state.zig로 이사.
    // 외부 모듈 (refresh.zig 등)에서 `Transformer.RefreshRegistration`로 접근 가능하도록 alias 제공.
    pub const RefreshRegistration = plugin_state.RefreshRegistration;
    pub const RefreshSignature = plugin_state.RefreshSignature;

    pub fn init(allocator: std.mem.Allocator, source_ast: *const Ast, options: TransformOptions) Error!Transformer {
        // experimentalDecorators → useDefineForClassFields=false 강제
        // TypeScript/esbuild 동일: decorator가 class field의 setter를 인터셉트하려면
        // assign semantics (this.x = v)가 필요. define semantics는 setter를 무시.
        var opts = options;
        if (opts.experimental_decorators) opts.use_define_for_class_fields = false;

        // 파서 AST를 트랜스포머 allocator로 복제 (원본 보존)
        const cloned_ast = try Ast.cloneForTransformer(source_ast, allocator);

        var self: Transformer = .{
            .ast = cloned_ast,
            .parser_node_count = @intCast(source_ast.nodes.items.len),
            .options = opts,
            .allocator = allocator,
            .scratch = .empty,
            .pending_nodes = .empty,
        };
        if (opts.unsupported.arrow) self.runtime_es5_compat = true;
        return self;
    }

    pub fn deinit(self: *Transformer) void {
        self.ast.deinit();
        self.deinitExceptAst();
    }

    /// AST를 제외한 모든 리소스를 해제한다.
    /// 테스트에서 AST를 별도로 관리할 때 사용.
    pub fn deinitExceptAst(self: *Transformer) void {
        self.scratch.deinit(self.allocator);
        self.pending_nodes.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
        if (self.define_spans.len > 0) self.allocator.free(self.define_spans);
        self.plugins.refresh.registrations.deinit(self.allocator);
        for (self.plugins.refresh.signatures.items) |s| self.allocator.free(s.signature);
        self.plugins.refresh.signatures.deinit(self.allocator);
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
    }

    /// semantic analyzer의 symbol_ids를 통합 배열로 복사한다.
    /// 파서 노드 영역(0..parser_node_count-1)에 symbol_id를 채운다.
    pub fn initSymbolIds(self: *Transformer, analyzer_symbol_ids: []const ?u32) Error!void {
        try self.symbol_ids.appendSlice(self.allocator, analyzer_symbol_ids);
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 변환을 실행한다. 원본 AST의 마지막 노드(program)부터 시작.
    ///
    /// 반환값: 새 AST에서의 루트 NodeIndex.
    /// 변환된 AST는 self.ast에 저장된다.
    pub fn transform(self: *Transformer) Error!NodeIndex {
        // define value를 미리 string_table에 저장하여 tryDefineReplace에서 중복 addString 방지
        if (self.options.define.len > 0) {
            self.define_spans = self.allocator.alloc(Span, self.options.define.len) catch return Error.OutOfMemory;
            for (self.options.define, 0..) |entry, i| {
                self.define_spans[i] = self.ast.addString(entry.value) catch return Error.OutOfMemory;
            }
        }

        // worklet __pluginVersion 문자열 리터럴 span 사전 계산 (매 worklet당 할당 방지)
        if (self.options.worklet_plugin_version) |v| {
            const quoted = std.fmt.allocPrint(self.allocator, "\"{s}\"", .{v}) catch return Error.OutOfMemory;
            defer self.allocator.free(quoted);
            self.plugins.worklet.plugin_version_span = self.ast.addString(quoted) catch return Error.OutOfMemory;
        }

        // 파서의 마지막 노드가 루트 (program). parser_node_count - 1.
        const root_idx: NodeIndex = @enumFromInt(self.parser_node_count - 1);
        const saved_temp_counter = self.temp_var_counter;
        // worklet anonymous naming counter — Transformer 인스턴스 재사용 시 매 transform당 0부터 시작.
        self.plugins.worklet.anonymous_counter = 0;
        var root = try self.visitNode(root_idx);

        // Pass 2: ES2015 params lowering 일괄 적용
        if (self.options.unsupported.default_params) {
            try self.lowerAllFunctionParams();
        }

        // top-level 임시 변수 호이스팅: var _a, _b, ... 선언을 program 앞에 삽입
        if (self.temp_var_counter > saved_temp_counter and !root.isNone()) {
            root = try self.hoistTempVars(root, saved_temp_counter, self.ast.getNode(root_idx).span);
        }

        // ES2015 tagged template: _templateObject 캐싱 함수를 program 맨 앞에 호이스팅
        if (self.tagged_template_fns.items.len > 0 and !root.isNone()) {
            root = try self.prependStatementsToBody(root, self.tagged_template_fns.items);
        }

        // React Fast Refresh: 컴포넌트 등록 코드를 프로그램 끝에 추가 ($RefreshReg$만, $RefreshSig$ 제거)
        if (self.options.react_refresh and self.plugins.refresh.registrations.items.len > 0) {
            return try self.appendRefreshRegistrations(root);
        }

        return root;
    }

    /// Pass 2: 모든 function-like 노드의 params를 일괄 lowering.
    /// Pass 1에서 생성된 모든 function_declaration, function_expression, function,
    /// method_definition 노드를 순회하며, default/rest/destructuring params가 있으면
    /// lowerParams를 적용하고 extra_data를 in-place 수정한다.
    fn lowerAllFunctionParams(self: *Transformer) Error!void {
        const node_count = self.ast.nodes.items.len;
        var i: usize = 0;
        while (i < node_count) : (i += 1) {
            const node = self.ast.nodes.items[i];
            switch (node.tag) {
                .function_declaration, .function_expression, .function, .method_definition => {
                    // extra layout: [name_or_key(0), params(1), body(2), ...]
                    const e = node.data.extra;
                    if (e + 2 >= self.ast.extra_data.items.len) continue;
                    const params_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
                    if (params_idx.isNone() or @intFromEnum(params_idx) >= self.ast.nodes.items.len) continue;
                    const params_node = self.ast.getNode(params_idx);
                    if (params_node.tag != .formal_parameters) continue;
                    const params_list = params_node.data.list;
                    if (params_list.len == 0) continue;
                    if (!es2015_params.ES2015Params(Transformer).hasDefaultOrRest(self, params_list)) continue;

                    var lr = try es2015_params.ES2015Params(Transformer).lowerParamsPass2(self, params_list, node.span);
                    defer lr.body_stmts.deinit(self.allocator);

                    // formal_parameters 노드를 새로 만들어 extras[e+1]에 연결.
                    // (여러 function 노드가 동일 params_idx를 공유할 수 있으므로 in-place mutation 금지:
                    //  prependToFunctionBody 등은 params_idx를 복사하여 새 function 노드를 만든다.)
                    const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                    self.ast.extra_data.items[e + 1] = @intFromEnum(new_params_node);

                    if (lr.body_stmts.items.len > 0) {
                        const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
                        if (!body_idx.isNone()) {
                            const new_body = try self.prependStatementsToBody(body_idx, lr.body_stmts.items);
                            self.ast.extra_data.items[e + 2] = @intFromEnum(new_body);
                        }
                    }
                },
                else => {},
            }
        }
    }

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
        if (self.options.drop_debugger and node.tag == .debugger_statement) {
            return .none;
        }
        if (self.options.drop_console and node.tag == .expression_statement) {
            if (self.isConsoleCall(node)) return .none;
        }
        if (self.options.drop_labels.len > 0 and node.tag == .labeled_statement) {
            const label_node = self.ast.getNode(node.data.binary.left);
            const label_name = self.ast.getText(label_node.span);
            for (self.options.drop_labels) |drop| {
                if (std.mem.eql(u8, label_name, drop)) return .none;
            }
        }

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
            => self.visitTsExpression(node),

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
                return self.visitListNode(node);
            },
            .block_statement,
            .sequence_expression,
            .class_body,
            .formal_parameters,
            .function_body,
            => self.visitListNode(node),

            // JSX — fragment는 .list, element/opening_element는 .extra
            .jsx_fragment => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXFragment(self, node);
                }
                return self.visitListNode(node);
            },

            .template_literal => {
                if (self.options.unsupported.template_literal) {
                    return es2015_template.ES2015Template(Transformer).lowerTemplateLiteral(self, node);
                }
                // no-substitution template (data.none == 0)은 리프 노드 — visitListNode으로 처리하면
                // data.list = {start: X, len: 0}이 되어 codegen의 data.none == 0 체크가 깨짐
                if (node.data.none == 0) return self.copyNodeDirect(node);
                return self.visitListNode(node);
            },

            // array_expression: spread(ES2015) 다운레벨링
            .array_expression => {
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadInArray(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadArray(self, node);
                    }
                }
                return self.visitListNode(node);
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
                return self.visitListNode(node);
            },

            // JSX element/opening_element: .extra 형식 (tag, attrs, children)
            .jsx_element => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXElement(self, node);
                }
                return self.visitJSXElement(node);
            },
            .jsx_opening_element => self.visitJSXOpeningElement(node),

            // === 단항 노드: 자식 1개 재귀 방문 ===
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            => self.visitUnaryNode(node),
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
                return self.visitUnaryNode(node);
            },
            .await_expression => {
                if (self.options.unsupported.async_await) {
                    return es2017_mod.ES2017(Transformer).lowerAwaitExpression(self, node);
                }
                return self.visitUnaryNode(node);
            },
            .yield_expression,
            .rest_element,
            .decorator,
            => self.visitUnaryNode(node),
            // JSX
            .jsx_spread_attribute,
            .jsx_expression_container,
            => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXExpressionContainer(self, node);
                }
                return self.visitUnaryNode(node);
            },
            .jsx_spread_child,
            .chain_expression,
            .computed_property_key,
            .break_statement,
            .continue_statement,
            .import_expression,
            .static_block,
            => self.visitUnaryNode(node),

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
                return self.visitBinaryNode(node);
            },
            .assignment_expression => {
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
                // ES2015/ES2022: this.#x = v → _x.set(this, v)
                if ((self.options.unsupported.class or self.options.unsupported.class_private_field) and self.current_private_fields.len > 0) {
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
                // ES2015: assignment destructuring → sequence expression
                if (self.options.unsupported.destructuring) {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.ast.getNode(left_idx);
                        if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                            return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignment(self, node);
                        }
                    }
                }
                return self.visitBinaryNode(node);
            },
            .while_statement,
            .do_while_statement,
            .with_statement,
            // JSX
            .jsx_attribute,
            .jsx_namespaced_name,
            .jsx_member_expression,
            => self.visitBinaryNode(node),

            // === member expression: extra = [object, property, flags] ===
            .static_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super.method → Parent.prototype.method
                if (self.options.unsupported.class and self.current_super_class != null) {
                    if (es2015_class.ES2015Class(Transformer).isSuperMember(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMember(self, node);
                    }
                }
                return self.visitMemberExpression(node);
            },
            .private_field_expression => {
                // ES2022: this.#method → _method_fn.bind(this) (참조만, 호출 아닌 경우)
                if (self.current_private_methods.len > 0) {
                    if (es2022.ES2022(Transformer).lowerPrivateMethodGet(self, node)) |result| {
                        return result;
                    }
                }
                // ES2015/ES2022: this.#x → _x.get(this)
                if ((self.options.unsupported.class or self.options.unsupported.class_private_field) and self.current_private_fields.len > 0) {
                    if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldGet(self, node)) |result| {
                        return result;
                    }
                }
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
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
                if (self.options.unsupported.class and self.current_super_class != null) {
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
                // for-await 키워드는 ES2018. async_await 자체를 다운레벨링해야 하는 타겟
                // (Hermes / ES5 등)은 for-await 파싱도 불가 — async function wrap 전에
                // 미리 __asyncValues + while 로 변환. (#1381)
                if (self.options.unsupported.async_await) {
                    return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOf(self, node);
                }
                return self.visitForInOfTernary(node);
            },
            .for_of_statement => {
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
                    if (self.options.unsupported.async_await and child.tag == .for_await_of_statement) {
                        const new_label = try self.visitNode(node.data.binary.left);
                        return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOfLabeled(self, child, new_label);
                    }
                    if (self.options.unsupported.for_of and child.tag == .for_of_statement) {
                        const new_label = try self.visitNode(node.data.binary.left);
                        return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatementLabeled(self, child, new_label);
                    }
                }
                return self.visitBinaryNode(node);
            },

            // === extra 기반 노드: 별도 처리 ===
            .variable_declaration => self.visitVariableDeclaration(node),
            .variable_declarator => self.visitVariableDeclarator(node),
            .function_declaration,
            .function_expression,
            => {
                const e = node.data.extra;
                const flags = self.readU32(e, 3);
                if (self.options.unsupported.async_await and (flags & ast_mod.FunctionFlags.is_async) != 0) {
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
                // 관심사 분리: plugin은 worklet 변환만, transformer는 ES downlevel 일관 처리.
                if (self.options.unsupported.class) {
                    return es2015_class.ES2015Class(Transformer).lowerClassDeclaration(self, target_node);
                }
                if (replacement_idx) |r| return r;
                return self.visitClass(node);
            },
            .class_expression => {
                const replacement_idx = try self.dispatchVisitor(.on_class_expression, idx);
                const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
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
                if (self.options.unsupported.class and self.current_super_class != null) {
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
            .export_all_declaration => self.visitBinaryNode(node),
            .catch_clause => {
                if (self.options.unsupported.optional_catch_binding) {
                    return es2019.ES2019(Transformer).lowerOptionalCatchBinding(self, node);
                }
                return self.visitBinaryNode(node);
            },
            .binding_property,
            .assignment_pattern,
            => self.visitBinaryNode(node),
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
                    return es_helpers.makeIdentifierRef(self, "_this");
                }
                return self.copyNodeDirect(node);
            },

            // meta_property: new.target / import.meta
            .meta_property => {
                // new.target (data.none == 1) 다운레벨링
                if (node.data.none == 1 and self.options.unsupported.new_target) {
                    return self.lowerNewTarget(node.span);
                }
                return self.copyNodeDirect(node);
            },

            .boolean_literal,
            .null_literal,
            .numeric_literal,
            .bigint_literal,
            => self.copyNodeDirect(node),
            .string_literal => blk: {
                if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(node);
                const raw = self.ast.getText(node.span);
                // raw는 따옴표를 포함. content 만 변환 후 다시 조립.
                if (raw.len < 2) break :blk self.copyNodeDirect(node);
                const quote = raw[0];
                if (quote != '"' and quote != '\'') break :blk self.copyNodeDirect(node);
                const content = raw[1 .. raw.len - 1];
                const lowered = (try unicode_escape_lower.lowerContent(self.allocator, content)) orelse break :blk self.copyNodeDirect(node);
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
                    break :blk self.copyNodeDirect(node);
                }
                const raw = self.ast.getText(node.span);
                const result = try regex_lower.lower(self.allocator, raw, .{ .unsupported = u });
                const new_text = result.text orelse break :blk self.copyNodeDirect(node);
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
                        return self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = args_span,
                            .data = .{ .string_ref = args_span },
                        });
                    }
                }
                // ES2015 block scoping 격리: 리네이밍된 변수 참조 교체
                if (self.options.unsupported.block_scoping and self.block_rename_stack.items.len > 0) {
                    const text = self.ast.getText(node.data.string_ref);
                    if (self.lookupBlockRename(text)) |new_name| {
                        const new_span = try self.ast.addString(new_name);
                        return self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = new_span,
                            .data = .{ .string_ref = new_span },
                        });
                    }
                }
                return self.copyNodeDirect(node);
            },
            .binding_identifier => {
                // ES2015 block scoping 격리: 리네이밍된 변수 선언 교체
                if (self.options.unsupported.block_scoping and self.block_rename_stack.items.len > 0) {
                    const text = self.ast.getText(node.data.string_ref);
                    if (self.lookupBlockRename(text)) |new_name| {
                        const new_span = try self.ast.addString(new_name);
                        return self.ast.addNode(.{
                            .tag = .binding_identifier,
                            .span = new_span,
                            .data = .{ .string_ref = new_span },
                        });
                    }
                }
                return self.copyNodeDirect(node);
            },
            .template_element => blk: {
                if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(node);
                const raw = self.ast.getText(node.span);
                const lowered = (try unicode_escape_lower.lowerContent(self.allocator, raw)) orelse break :blk self.copyNodeDirect(node);
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
            .assignment_target_identifier,
            => self.copyNodeDirect(node),

            // JSX leaf — jsx_text는 별도 처리 (jsx_transform 시 lowerJSXText)
            .jsx_text => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXText(self, node);
                }
                return self.copyNodeDirect(node);
            },

            // === import/export specifiers ===
            .import_specifier => if (node.data.binary.flags & 1 != 0) .none else self.visitBinaryNode(node),
            .export_specifier => if (node.data.binary.flags & 1 != 0) .none else self.visitBinaryNode(node),
            // default/namespace specifier는 string_ref(span) 복사 — 자식 노드 없음
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            => self.copyNodeDirect(node),

            // === Pattern 노드: 자식 재귀 방문 ===
            .array_pattern,
            .object_pattern,
            .array_assignment_target,
            .object_assignment_target,
            => self.visitListNode(node),

            .binding_rest_element,
            .assignment_target_rest,
            => self.visitUnaryNode(node),
            .assignment_target_with_default,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => self.visitBinaryNode(node),
            // assignment_target_identifier: string_ref → 변환 불필요 (identifier와 동일)

            // === TS enum/namespace: 런타임 코드 생성 (codegen에서 IIFE 출력) ===
            .ts_enum_declaration => self.visitEnumDeclaration(node),
            .ts_enum_member => self.visitBinaryNode(node),
            .ts_enum_body => self.visitListNode(node),
            .ts_module_declaration => self.visitNamespaceDeclaration(node),
            .ts_module_block => self.visitListNode(node),

            // import x = require('y') → const x = require('y')
            .ts_import_equals_declaration => self.visitImportEqualsDeclaration(node),

            // === 나머지: invalid + TS 타입 전용 노드 ===
            // TS 타입 노드는 isTypeOnlyNode 검사(위)에서 이미 .none으로 반환됨.
            // 여기 도달하면 strip_types=false인 경우 → 그대로 복사.
            .invalid => .none,
            else => self.copyNodeDirect(node),
        };
    }

    // ================================================================
    // 노드 복사 헬퍼
    // ================================================================

    /// 노드를 그대로 새 AST에 복사한다 (자식 없는 리프 노드용).
    fn copyNodeDirect(self: *Transformer, node: Node) Error!NodeIndex {
        return self.ast.addNode(node);
    }

    /// 클래스 이름 노드에서 Span 추출. 익명 클래스(none)면 null 반환.
    /// ES2022 static block의 this → 클래스 이름 치환에 사용.
    pub fn getClassNameSpan(self: *Transformer, name_idx: NodeIndex) ?Span {
        if (name_idx.isNone()) return null;
        return self.ast.getNode(name_idx).data.string_ref;
    }

    /// symbol_ids를 target_idx까지 null로 확장.
    fn ensureSymbolIds(self: *Transformer, target_idx: usize) void {
        if (self.symbol_ids.items.len <= target_idx) {
            const needed = target_idx + 1 - self.symbol_ids.items.len;
            self.symbol_ids.appendNTimes(self.allocator, null, needed) catch return;
        }
    }

    /// 파서 노드 → 트랜스포머 노드로 symbol_id 전파.
    /// 통합 AST에서는 old_idx와 new_idx가 같은 배열의 인덱스.
    pub fn propagateSymbolId(self: *Transformer, old_idx: NodeIndex, new_idx: NodeIndex) void {
        if (self.symbol_ids.items.len == 0) return; // 전파 비활성
        if (new_idx.isNone()) return;

        const old_i = @intFromEnum(old_idx);
        const new_i = @intFromEnum(new_idx);

        self.ensureSymbolIds(new_i);

        if (old_i < self.symbol_ids.items.len) {
            // ts_as_expression 등 wrapper 노드가 내부 노드와 같은 new_idx를 반환하면
            // wrapper의 null symbol_id가 내부 노드의 유효한 symbol_id를 덮어쓸 수 있음.
            // 이미 유효한 symbol_id가 설정되어 있으면 null로 덮어쓰지 않음.
            if (self.symbol_ids.items[old_i] != null or self.symbol_ids.items[new_i] == null) {
                self.symbol_ids.items[new_i] = self.symbol_ids.items[old_i];
            }
        }
    }

    /// AST 내에서 노드 간 symbol_id 복사.
    /// 노드 복제 시 symbol_id가 누락되지 않도록 사용.
    pub fn copySymbolId(self: *Transformer, src_idx: NodeIndex, dst_idx: NodeIndex) void {
        if (self.symbol_ids.items.len == 0) return;
        if (src_idx.isNone() or dst_idx.isNone()) return;

        const src_i = @intFromEnum(src_idx);
        const dst_i = @intFromEnum(dst_idx);

        self.ensureSymbolIds(dst_i);

        if (src_i < self.symbol_ids.items.len) {
            if (self.symbol_ids.items[src_i]) |sid| {
                self.symbol_ids.items[dst_i] = sid;
            }
        }
    }

    /// span + old_idx로 identifier_reference 생성 + symbol_id 전파.
    /// ES5 class lowering, decorator 등에서 renamed 이름이 반영되도록 사용.
    pub fn makeIdentifierRefWithSymbol(self: *Transformer, name_span: Span, old_idx: NodeIndex) Error!NodeIndex {
        const ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
        self.propagateSymbolId(old_idx, ref);
        return ref;
    }

    /// export default class/function → ES5 lowering 시 operand가 .none이 되는 케이스 처리.
    /// lowerClassDeclaration이 pending_nodes에 function 등을 넣고 .none을 반환하므로,
    /// 클래스/함수 이름(또는 익명의 합성 이름 _Class)의 identifier reference를 operand로 사용.
    fn visitExportDefaultDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const operand_idx = node.data.unary.operand;
        const new_operand = try self.visitNode(operand_idx);

        if (new_operand.isNone()) {
            const operand_node = self.ast.getNode(operand_idx);
            if (operand_node.tag == .class_declaration or operand_node.tag == .function_declaration) {
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[operand_node.data.extra]);
                // named class/function → 원본 이름 사용
                // anonymous class → lowerClassDeclaration이 "_Class"로 합성 (addString)
                const name_span = if (!name_idx.isNone())
                    self.ast.getNode(name_idx).data.string_ref
                else
                    try self.ast.addString("_Class");
                const name_ref = try self.makeIdentifierRefWithSymbol(name_span, name_idx);
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = name_ref, .flags = node.data.unary.flags } },
                });
            }
        }

        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
        });
    }

    /// 단항 노드: operand를 재귀 방문 후 복사.
    fn visitUnaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_operand = try self.visitNode(node.data.unary.operand);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
        });
    }

    /// 이항 노드: left, right를 재귀 방문 후 복사.
    fn visitBinaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_left = try self.visitNode(node.data.binary.left);
        const new_right = try self.visitNode(node.data.binary.right);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .binary = .{
                .left = new_left,
                .right = new_right,
                .flags = node.data.binary.flags,
            } },
        });
    }

    // ES 다운레벨링 헬퍼 — es_helpers.zig로 위임 (Transformer 메서드 호환)
    fn makeTempVarSpan(self: *Transformer) Error!Span {
        return es_helpers.makeTempVarSpan(self);
    }
    fn isSimpleIdentifier(self: *Transformer, left_idx: NodeIndex) bool {
        return es_helpers.isSimpleIdentifier(self, left_idx);
    }

    // ES 다운레벨링 함수는 es2020.zig, es2021.zig, es_helpers.zig로 분리됨.

    /// unary/update expression: extra = [operand, operator_and_flags]
    fn visitUnaryExtra(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 1 >= self.ast.extra_data.items.len) return NodeIndex.none;

        const operand_idx = self.readNodeIdx(e, 0);
        const op_flags = self.readU32(e, 1);

        // private field update: this.#x++ → _x.set(this, _x.get(this) + 1)
        if (node.tag == .update_expression and (self.options.unsupported.class or self.options.unsupported.class_private_field)) {
            const operand = self.ast.getNode(operand_idx);
            if (operand.tag == .private_field_expression) {
                if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldUpdate(self, operand, op_flags, node.span)) |result| {
                    return try result;
                }
            }
        }

        // `delete obj?.a?.b` lowering: 일반 optional chain lowering 결과인
        // `delete (cond ? void 0 : _a.b)` 는 ConditionalExpression이라 Reference가 아니어서 실제 삭제 안 됨.
        // → `cond ? true : delete _a.b` 형태로 별도 lowering.
        if (node.tag == .unary_expression and self.options.unsupported.optional_chaining and
            (op_flags & 0xff) == @intFromEnum(token_mod.Kind.kw_delete))
        {
            const operand = self.ast.getNode(operand_idx);
            if (es2020.ES2020(Transformer).findOptionalChainBase(self, operand)) |base_idx| {
                return es2020.ES2020(Transformer).lowerOptionalChainCtx(self, operand, base_idx, .delete);
            }
        }

        const new_operand = try self.visitNode(operand_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_operand), op_flags });
        return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// tagged_template_expression: extra = [tag, template, flags]
    fn visitTaggedTemplate(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const tag_idx = self.readNodeIdx(e, 0);
        const tmpl_idx = self.readNodeIdx(e, 1);
        const flags = self.readU32(e, 2);

        // ES2015 tagged template 다운레벨링
        if (self.options.unsupported.template_literal) {
            return self.lowerTaggedTemplate(tag_idx, tmpl_idx, node.span);
        }

        const new_tag = try self.visitNode(tag_idx);
        const new_tmpl = try self.visitNode(tmpl_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_tag), @intFromEnum(new_tmpl), flags });
        return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// member expression: extra = [object, property, flags]
    pub fn visitMemberExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;

        // const enum 인라인: `EnumName.Member` → literal
        if (try self.tryInlineConstEnumMember(node)) |inlined| return inlined;

        const left_idx = self.readNodeIdx(e, 0);
        const right_idx = self.readNodeIdx(e, 1);
        const flags = self.readU32(e, 2);
        const new_left = try self.visitNode(left_idx);
        // computed_member: right는 임의 expression. static_member/private_field: right는 식별자 리프.
        // visitNode가 리프를 copyNodeDirect로 처리하므로 동일하게 visitNode 호출.
        const new_right = try self.visitNode(right_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_left), @intFromEnum(new_right), flags });
        return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// 삼항 노드: a, b, c를 재귀 방문 후 복사.
    fn visitTernaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_a = try self.visitNode(node.data.ternary.a);
        const new_b = try self.visitNode(node.data.ternary.b);
        const new_c = try self.visitNode(node.data.ternary.c);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
        });
    }

    /// for-in/for-of/for-await-of 헤더 전용 ternary visit.
    /// `a`(left) 방문 시 in_for_in_of_header 플래그를 켜서, block_scoping 다운레벨로
    /// let/const → var 변환 시 불필요한 `= void 0` init 주입을 막는다 (#1386).
    fn visitForInOfTernary(self: *Transformer, node: Node) Error!NodeIndex {
        const saved = self.in_for_in_of_header;
        self.in_for_in_of_header = true;
        const new_a = try self.visitNode(node.data.ternary.a);
        self.in_for_in_of_header = saved;
        const new_b = try self.visitNode(node.data.ternary.b);
        const new_c = try self.visitNode(node.data.ternary.c);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
        });
    }

    /// 리스트 노드: 각 자식을 방문, .none이 아닌 것만 새 리스트로 수집.
    fn visitListNode(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015 block scoping 격리: block_statement 진입 시 리네이밍 처리
        if (self.options.unsupported.block_scoping and node.tag == .block_statement) {
            return self.visitBlockWithScoping(node);
        }
        // program/function_body: 함수 스코프의 var 이름 수집
        if (self.options.unsupported.block_scoping and (node.tag == .program or node.tag == .function_body)) {
            self.collectTopLevelVarNames(node.data.list.start, node.data.list.len);
        }
        // Plugin visitor 훅 — program 노드 선취권 (file-level worklet directive 등)
        // visitListNode는 idx를 직접 받지 않으므로 caller(visitNodeInner)에서 이미 dispatch 완료 상태.
        // 여기서는 추가 작업 없음.
        // ES2025: using/await using → try-finally 래핑
        if (self.options.unsupported.using) {
            const Using = es2025_using.ES2025Using(Transformer);
            if (Using.hasUsingDeclaration(self, node.data.list.start, node.data.list.len)) {
                const new_list = try Using.lowerUsingInStatements(self, node.data.list.start, node.data.list.len);
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .list = new_list },
                });
            }
        }
        const new_list = try self.visitExtraList(node.data.list);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// block_statement를 방문하면서 내부 let/const 리네이밍을 적용한다.
    fn visitBlockWithScoping(self: *Transformer, node: Node) Error!NodeIndex {
        const list_start = node.data.list.start;
        const list_len = node.data.list.len;

        const saved_scope_len = self.scope_var_names.items.len;
        const renames_added = try self.pushBlockRenames(list_start, list_len);
        const new_list = try self.visitExtraList(.{ .start = list_start, .len = list_len });

        // 블록 퇴장: rename 맵 + scope_var_names 모두 복원
        if (renames_added > 0) {
            self.block_rename_stack.shrinkRetainingCapacity(self.block_rename_stack.items.len - renames_added);
        }
        self.scope_var_names.shrinkRetainingCapacity(saved_scope_len);

        return self.ast.addNode(.{
            .tag = .block_statement,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// program/function_body의 top-level 선언에서 var/let/const 이름을 scope_var_names에 수집.
    fn collectTopLevelVarNames(self: *Transformer, list_start: u32, list_len: u32) void {
        var i: u32 = 0;
        while (i < list_len) : (i += 1) {
            const raw = self.ast.extra_data.items[list_start + i];
            const stmt = self.ast.getNode(@enumFromInt(raw));
            if (stmt.tag != .variable_declaration) continue;

            const ve = stmt.data.extra;
            const decl_start = self.readU32(ve, 1);
            const decl_len = self.readU32(ve, 2);

            var j: u32 = 0;
            while (j < decl_len) : (j += 1) {
                const decl_raw = self.ast.extra_data.items[decl_start + j];
                const decl = self.ast.getNode(@enumFromInt(decl_raw));
                if (decl.tag != .variable_declarator) continue;

                const name_idx = self.readNodeIdx(decl.data.extra, 0);
                if (name_idx.isNone()) continue;

                const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.allocator);
                BlockScoping.collectBindingNames(self, name_idx, &names) catch continue;

                for (names.items) |name| {
                    if (!self.isNameInScope(name)) {
                        self.scope_var_names.append(self.allocator, name) catch {};
                    }
                }
            }
        }
    }

    /// extra_data의 노드 리스트를 방문하여 새 AST에 복사.
    /// .none이 된 자식은 자동으로 제거된다.
    /// scratch 버퍼를 사용하며, 중첩 호출에 안전 (save/restore 패턴).
    ///
    /// pending_nodes 지원: 각 자식 방문 후 pending_nodes에 쌓인 노드를
    /// 해당 자식 앞에 삽입한다. 이를 통해 1→N 노드 확장이 가능하다.
    /// 예: enum 변환 시 visitNode가 IIFE를 반환하면서 `var Color;`을
    ///     pending_nodes에 push → 리스트에 `var Color;` + IIFE 순서로 삽입.
    pub fn visitExtraList(self: *Transformer, list: NodeList) Error!NodeList {
        // 주의: extra_data.items 슬라이스를 캐시하면 안 됨.
        // visitNode 내부에서 ast.extra_data에 append하면 배열이 재할당되어
        // 캐시된 슬라이스가 dangling pointer가 될 수 있다.
        // 따라서 매 반복마다 start+i로 직접 인덱싱한다.

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // pending_nodes save/restore: 중첩 visitExtraList 호출에 안전.
        // 내부 리스트의 pending_nodes가 외부 리스트로 누출되지 않도록 한다.
        const pending_top = self.pending_nodes.items.len;
        defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

        // trailing_nodes save/restore: 중첩 visitExtraList 호출에 안전.
        const trailing_top = self.trailing_nodes.items.len;
        defer self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            // 매 반복마다 extra_data에서 직접 읽기 (재할당 안전)
            const raw_idx = self.ast.extra_data.items[list.start + i];
            const new_child = try self.visitNode(@enumFromInt(raw_idx));

            // pending_nodes 드레인: visitNode가 추가한 보류 노드를 먼저 삽입
            if (self.pending_nodes.items.len > pending_top) {
                try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                self.pending_nodes.shrinkRetainingCapacity(pending_top);
            }

            if (!new_child.isNone()) {
                try self.scratch.append(self.allocator, new_child);
            }

            // trailing_nodes 드레인: visitNode가 추가한 후행 노드를 자식 뒤에 삽입
            // (예: worklet 함수 뒤의 __workletHash/__closure/__initData 프로퍼티 할당)
            if (self.trailing_nodes.items.len > trailing_top) {
                try self.scratch.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
                self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
            }
        }

        return self.ast.addNodeList(self.scratch.items[scratch_top..]);
    }

    // ================================================================
    // TS expression 변환 — 타입 부분 제거, 값만 보존
    // ================================================================

    /// TS expression (as/satisfies/!/type assertion/instantiation)에서
    /// 값 부분만 추출한다.
    ///
    /// 예: `x as number` → `x` (operand만 반환)
    /// 예: `x!` → `x` (non-null assertion 제거)
    /// 예: `<number>x` → `x` (type assertion 제거)
    /// Flow match expression → (function(_m){if(_m===P){B}else if...})(expr)
    fn visitFlowMatch(self: *Transformer, node: Node) Error!NodeIndex {
        const span = node.span;
        const e = node.data.extra;
        const discriminant_idx = self.readNodeIdx(e, 0);
        const arms_start = self.readU32(e, 1);
        const arms_len = self.readU32(e, 2);

        // arm 인덱스를 미리 로컬에 복사 (visitNode가 extra_data를 재할당할 수 있으므로)
        const arm_indices = try self.allocator.alloc(u32, arms_len);
        defer self.allocator.free(arm_indices);
        for (0..arms_len) |i| {
            arm_indices[i] = self.ast.extra_data.items[arms_start + i];
        }

        const new_discriminant = try self.visitNode(discriminant_idx);

        // 임시 변수 _m
        const match_var = try es_helpers.makeTempVarSpan(self);
        const match_param = try es_helpers.makeBindingIdentifier(self, match_var);
        var else_branch: NodeIndex = .none;

        var i: usize = arm_indices.len;
        while (i > 0) {
            i -= 1;
            const arm = self.ast.getNode(@enumFromInt(arm_indices[i]));
            const pattern = arm.data.binary.left;
            const body_idx = arm.data.binary.right;
            const new_body_raw = try self.visitNode(body_idx);
            // body를 { return body; } 또는 block 그대로 사용
            const body_node = self.ast.getNode(new_body_raw);
            const new_body = if (body_node.tag == .block_statement)
                new_body_raw
            else blk: {
                // expression → { return expr; }
                const return_stmt = try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = new_body_raw, .flags = 0 } },
                });
                const stmts = try self.ast.addNodeList(&.{return_stmt});
                break :blk try self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = span,
                    .data = .{ .list = stmts },
                });
            };

            // wildcard `_` 감지
            const pat_node = self.ast.getNode(pattern);
            const is_wildcard = blk: {
                if (pat_node.tag == .identifier_reference) {
                    const text = self.ast.getText(pat_node.span);
                    break :blk std.mem.eql(u8, text, "_");
                }
                break :blk false;
            };

            if (is_wildcard) {
                else_branch = new_body;
            } else {
                const new_pattern = try self.visitNode(pattern);
                const match_ref = try es_helpers.makeTempVarRef(self, match_var, match_var);
                // _m === pattern
                const test_expr = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{
                        .left = match_ref,
                        .right = new_pattern,
                        .flags = @intFromEnum(token_mod.Kind.eq3),
                    } },
                });
                else_branch = try self.ast.addNode(.{
                    .tag = .if_statement,
                    .span = span,
                    .data = .{ .ternary = .{ .a = test_expr, .b = new_body, .c = else_branch } },
                });
            }
        }

        // function(_m) { if-chain }
        const body_list = if (!else_branch.isNone())
            try self.ast.addNodeList(&.{else_branch})
        else
            @import("../parser/ast.zig").NodeList{ .start = 0, .len = 0 };
        const fn_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = span,
            .data = .{ .list = body_list },
        });
        const fn_params_list = try self.ast.addNodeList(&.{match_param});
        const fn_params_node = try self.ast.addFormalParameters(fn_params_list, span);
        const fn_extra = try self.ast.addExtras(&.{
            @intFromEnum(NodeIndex.none), // name (anonymous)
            @intFromEnum(fn_params_node),
            @intFromEnum(fn_body),
            0, // flags
            @intFromEnum(NodeIndex.none), // return type
        });
        const fn_expr = try self.ast.addNode(.{
            .tag = .function_expression,
            .span = span,
            .data = .{ .extra = fn_extra },
        });

        // (function(_m){...})(discriminant)
        // function expression을 parenthesized로 감싸서 IIFE 형태로 만듦
        const paren_fn = try es_helpers.makeParenExpr(self, fn_expr, span);
        // call_expression extra: [callee, args_start, args_len, flags]
        const args_list = try self.ast.addNodeList(&.{new_discriminant});
        const call_extra = try self.ast.addExtras(&.{
            @intFromEnum(paren_fn),
            args_list.start,
            args_list.len,
            0, // flags
        });
        return self.ast.addNode(.{
            .tag = .call_expression,
            .span = span,
            .data = .{ .extra = call_extra },
        });
    }

    /// Flow component with ref → 2개 statement로 변환:
    ///   function Name_withRef({...props}, ref) { ... }    ← pending_nodes
    ///   const Name = React.forwardRef(Name_withRef);       ← 반환값
    ///
    /// extra = [name, params_start, params_len, body]
    /// Flow component with ref: 파서가 생성한 2개 statement를 방문.
    /// extra = [func_decl, const_decl]
    /// func_decl은 pending_nodes에, const_decl은 반환.
    fn visitFlowComponentWrapper(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const func_decl_idx = self.readNodeIdx(e, 0);
        const const_decl_idx = self.readNodeIdx(e, 1);

        // function Name_withRef 방문 (ES2015 lowering 등 적용)
        const new_func = try self.visitNode(func_decl_idx);
        try self.pending_nodes.append(self.allocator, new_func);

        // const Name = React.forwardRef(Name_withRef) 방문
        return self.visitNode(const_decl_idx);
    }

    fn visitTsExpression(self: *Transformer, node: Node) Error!NodeIndex {
        if (!self.options.strip_types) {
            return self.copyNodeDirect(node);
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

    /// expression_statement가 console.* 호출인지 판별.
    /// console.log(...), console.warn(...), console.error(...) 등.
    fn isConsoleCall(self: *const Transformer, node: Node) bool {
        // expression_statement → unary.operand가 call_expression이어야 함
        const expr_idx = node.data.unary.operand;
        if (expr_idx.isNone()) return false;
        const expr = self.ast.getNode(expr_idx);
        if (expr.tag != .call_expression) return false;

        // call_expression: extra = [callee, args_start, args_len, flags]
        const ce = expr.data.extra;
        if (ce >= self.ast.extra_data.items.len) return false;
        const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
        if (callee_idx.isNone()) return false;
        const callee = self.ast.getNode(callee_idx);

        // callee가 static_member_expression (console.log)이어야 함
        if (callee.tag != .static_member_expression) return false;

        // left가 identifier "console" — extra = [object, property, flags]
        const me = callee.data.extra;
        if (me >= self.ast.extra_data.items.len) return false;
        const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
        if (obj_idx.isNone()) return false;
        const obj = self.ast.getNode(obj_idx);
        if (obj.tag != .identifier_reference) return false;

        const obj_text = self.ast.getText(obj.data.string_ref);
        return std.mem.eql(u8, obj_text, "console");
    }

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

    /// 노드가 define 치환 대상이면 새 string_literal 노드를 반환.
    /// 대상: identifier_reference 또는 static_member_expression 체인.
    fn tryDefineReplace(self: *Transformer, node: Node) ?Error!NodeIndex {
        // 노드의 소스 텍스트를 define key와 비교
        const text = self.getNodeText(node) orelse return null;

        for (self.options.define, 0..) |entry, i| {
            if (std.mem.eql(u8, text, entry.key)) {
                const value_span = self.define_spans[i];
                // 값이 따옴표로 시작하면 string_literal, 아니면 identifier_reference.
                // "production" → string_literal, false/true/숫자 → identifier_reference.
                const is_string = entry.value.len >= 2 and (entry.value[0] == '"' or entry.value[0] == '\'');
                return self.ast.addNode(.{
                    .tag = if (is_string) .string_literal else .identifier_reference,
                    .span = value_span,
                    .data = .{ .string_ref = value_span },
                });
            }
        }
        return null;
    }

    /// 노드의 소스 텍스트를 반환. identifier_reference와 static_member_expression만 지원.
    fn getNodeText(self: *const Transformer, node: Node) ?[]const u8 {
        return switch (node.tag) {
            .identifier_reference => self.ast.getText(node.span),
            .static_member_expression => self.ast.getText(node.span),
            else => null,
        };
    }

    // ================================================================
    // TS enum 변환
    // ================================================================

    /// ts_enum_declaration: extra = [name, members_start, members_len, flags]
    /// flags: 0=일반 enum (codegen에서 IIFE), 1=const enum (선언 삭제 + 멤버를 self.const_enums 에 보관 → visitMemberExpression 에서 literal 인라인).
    fn visitEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 3);

        if (flags == 1) {
            // 평가 가능한 단순 케이스만 등록. 실패해도 선언은 삭제 (참조는 그대로 남아 ReferenceError가 나지만,
            // 기존 동작과 동일하므로 회귀가 아님 — 인라인 가능 케이스만 새로 동작 추가).
            self.collectConstEnum(node) catch {};
            return .none;
        }

        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_members = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(.ts_enum_declaration, node.span, &.{
            @intFromEnum(new_name), new_members.start, new_members.len, flags,
        });
    }

    /// const enum 멤버를 평가하여 self.const_enums 에 추가.
    /// TypeScript spec 의 const enum expression subset 을 지원:
    ///   numeric/string/boolean literal · 단항(`+ - ~ !`) · 이항(산술/비트/비교/논리) · parenthesized ·
    ///   같은 enum 내 다른 멤버 참조(`B = A + 1`) · 외부 const enum 참조(`B = OtherEnum.X`) · 빈 init(auto-inc).
    /// 평가 불가 expression 은 해당 enum 전체 등록을 건너뜀 (인라인 미동작 → 기존 동작 유지, 회귀 아님).
    fn collectConstEnum(self: *Transformer, node: Node) Error!void {
        const e = node.data.extra;
        const name_idx = self.readNodeIdx(e, 0);
        if (name_idx.isNone()) return;
        const name_node = self.ast.getNode(name_idx);
        if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return;
        const enum_name_src = self.ast.getText(name_node.span);

        const members_start = self.readU32(e, 1);
        const members_len = self.readU32(e, 2);

        var collected: std.ArrayList(ConstEnumMember) = .empty;
        errdefer {
            for (collected.items) |m| {
                self.allocator.free(m.name);
                if (m.value == .string) self.allocator.free(m.value.string);
            }
            collected.deinit(self.allocator);
        }

        var prev_number: ?f64 = null;
        var i: u32 = 0;
        while (i < members_len) : (i += 1) {
            const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[members_start + i]);
            const member_node = self.ast.getNode(member_idx);
            if (member_node.tag != .ts_enum_member) return;

            const key_idx = member_node.data.binary.left;
            const init_idx = member_node.data.binary.right;
            if (key_idx.isNone()) return;
            const key_node = self.ast.getNode(key_idx);
            const member_name_src = switch (key_node.tag) {
                .identifier_reference, .binding_identifier => self.ast.getText(key_node.span),
                .string_literal => blk: {
                    const raw = self.ast.getText(key_node.data.string_ref);
                    if (raw.len < 2) return;
                    break :blk raw[1 .. raw.len - 1];
                },
                else => return,
            };

            var value: ConstEnumValue = undefined;
            if (init_idx.isNone()) {
                const next: f64 = if (prev_number) |pv| pv + 1 else 0;
                value = .{ .number = next };
            } else {
                value = (try self.evalConstEnumExpr(init_idx, .{
                    .current_members = collected.items,
                    .current_name = enum_name_src,
                    .current_symbol_id = self.getSymbolIdAt(name_idx),
                })) orelse return;
            }
            switch (value) {
                .number => |n| prev_number = n,
                .string => prev_number = null,
            }

            const owned_name = try self.allocator.dupe(u8, member_name_src);
            errdefer self.allocator.free(owned_name);
            const owned_value: ConstEnumValue = switch (value) {
                .number => |n| .{ .number = n },
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
            };
            try collected.append(self.allocator, .{ .name = owned_name, .value = owned_value });
        }

        const owned_enum_name = try self.allocator.dupe(u8, enum_name_src);
        errdefer self.allocator.free(owned_enum_name);
        const members_owned = try collected.toOwnedSlice(self.allocator);

        // shadowing 안전을 위해 enum binding 의 symbol_id 보관. visitMemberExpression 에서
        // identifier_reference.symbol_id == decl.symbol_id 일 때만 인라인.
        const sym_id = self.getSymbolIdAt(name_idx);

        try self.const_enums.append(self.allocator, .{
            .name = owned_enum_name,
            .members = members_owned,
            .symbol_id = sym_id,
        });
    }

    /// 노드의 symbol_id 조회 (없으면 null).
    fn getSymbolIdAt(self: *const Transformer, idx: NodeIndex) ?u32 {
        if (idx.isNone()) return null;
        const i = @intFromEnum(idx);
        if (i >= self.symbol_ids.items.len) return null;
        return self.symbol_ids.items[i];
    }

    /// 평가 컨텍스트: 현재 collecting 중인 enum의 정보 (self-reference 해결용).
    pub const ConstEnumEvalCtx = struct {
        current_members: []const ConstEnumMember,
        current_name: []const u8,
        current_symbol_id: ?u32,
    };

    /// const enum initializer expression 재귀 평가.
    fn evalConstEnumExpr(
        self: *Transformer,
        expr_idx: NodeIndex,
        ctx: ConstEnumEvalCtx,
    ) Error!?ConstEnumValue {
        const node = self.ast.getNode(expr_idx);
        switch (node.tag) {
            .numeric_literal => {
                const text = self.ast.getText(node.span);
                const n = std.fmt.parseFloat(f64, text) catch {
                    // hex/octal/binary literal 등 parseFloat 실패 시 정수 파싱 시도
                    const ni = std.fmt.parseInt(i64, text, 0) catch return null;
                    return .{ .number = @floatFromInt(ni) };
                };
                return .{ .number = n };
            },
            .string_literal => {
                const raw = self.ast.getText(node.data.string_ref);
                if (raw.len < 2) return null;
                return .{ .string = raw[1 .. raw.len - 1] };
            },
            .boolean_literal => {
                // ECMAScript: true=1, false=0 (Number 변환).
                return .{ .number = if (node.data.none == 1) 1 else 0 };
            },
            .parenthesized_expression => {
                const inner = node.data.unary.operand;
                if (inner.isNone()) return null;
                return self.evalConstEnumExpr(inner, ctx);
            },
            .unary_expression => {
                const ue = node.data.extra;
                if (ue + 1 >= self.ast.extra_data.items.len) return null;
                const operand_idx = self.readNodeIdx(ue, 0);
                const op = @as(token_mod.Kind, @enumFromInt(self.readU32(ue, 1) & 0xff));
                const v = (try self.evalConstEnumExpr(operand_idx, ctx)) orelse return null;
                if (v != .number) return null;
                const n = v.number;
                return switch (op) {
                    .minus => .{ .number = -n },
                    .plus => .{ .number = n },
                    .tilde => .{ .number = @floatFromInt(~@as(i32, @intFromFloat(n))) },
                    .bang => .{ .number = if (n == 0) 1 else 0 },
                    else => null,
                };
            },
            .binary_expression => {
                const lv = (try self.evalConstEnumExpr(node.data.binary.left, ctx)) orelse return null;
                const rv = (try self.evalConstEnumExpr(node.data.binary.right, ctx)) orelse return null;
                const op = @as(token_mod.Kind, @enumFromInt(node.data.binary.flags));
                // 문자열 + 문자열은 concatenation (TS 가 허용).
                if (lv == .string and rv == .string and op == .plus) {
                    const concat = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ lv.string, rv.string });
                    defer self.allocator.free(concat);
                    return .{ .string = try self.allocator.dupe(u8, concat) };
                }
                if (lv != .number or rv != .number) return null;
                const ln = lv.number;
                const rn = rv.number;
                const li: i32 = @intFromFloat(ln);
                const ri: i32 = @intFromFloat(rn);
                return switch (op) {
                    .plus => .{ .number = ln + rn },
                    .minus => .{ .number = ln - rn },
                    .star => .{ .number = ln * rn },
                    .slash => .{ .number = ln / rn },
                    .percent => .{ .number = @rem(ln, rn) },
                    .star2 => .{ .number = std.math.pow(f64, ln, rn) },
                    .shift_left => .{ .number = @floatFromInt(li << @intCast(@as(u5, @truncate(@as(u32, @bitCast(ri)))))) },
                    .shift_right => .{ .number = @floatFromInt(li >> @intCast(@as(u5, @truncate(@as(u32, @bitCast(ri)))))) },
                    .shift_right3 => .{ .number = @floatFromInt(@as(u32, @bitCast(li)) >> @intCast(@as(u5, @truncate(@as(u32, @bitCast(ri)))))) },
                    .pipe => .{ .number = @floatFromInt(li | ri) },
                    .amp => .{ .number = @floatFromInt(li & ri) },
                    .caret => .{ .number = @floatFromInt(li ^ ri) },
                    else => null,
                };
            },
            .identifier_reference => {
                // 같은 enum 안의 다른 멤버 참조 (예: `B = A + 1`)
                const name = self.ast.getText(node.span);
                for (ctx.current_members) |m| {
                    if (std.mem.eql(u8, m.name, name)) return m.value;
                }
                return null;
            },
            .static_member_expression, .computed_member_expression => {
                // 다른 const enum 또는 자기 자신 (`Other.X` from `B = Other.X * 2` inside Other) 참조
                if (try self.tryEvalEnumMemberAccess(node, ctx)) |v| return v;
                return null;
            },
            else => return null,
        }
    }

    /// member access 가 다른 const enum 또는 현재 collecting 중인 enum 의 멤버를 참조하면 그 값을 반환.
    /// `EnumName.Member`, `EnumName["Member"]` 모두 지원. shadowing 검사 적용.
    fn tryEvalEnumMemberAccess(self: *const Transformer, node: Node, ctx: ConstEnumEvalCtx) Error!?ConstEnumValue {
        const e = node.data.extra;
        if (e + 1 >= self.ast.extra_data.items.len) return null;
        const obj_idx = self.readNodeIdx(e, 0);
        const prop_idx = self.readNodeIdx(e, 1);
        if (obj_idx.isNone() or prop_idx.isNone()) return null;

        const obj_node = self.ast.getNode(obj_idx);
        if (obj_node.tag != .identifier_reference) return null;
        const obj_name = self.ast.getText(obj_node.span);
        const obj_sym = self.getSymbolIdAt(obj_idx);

        const prop_name = (memberPropertyName(self, node.tag, prop_idx)) orelse return null;

        // 현재 collecting 중인 enum self-reference (예: `Other.X` from inside Other 정의)
        if (matchesEnumName(ctx.current_name, ctx.current_symbol_id, obj_name, obj_sym)) {
            for (ctx.current_members) |m| {
                if (std.mem.eql(u8, m.name, prop_name)) return m.value;
            }
        }

        for (self.const_enums.items) |decl| {
            if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
            for (decl.members) |m| {
                if (std.mem.eql(u8, m.name, prop_name)) return m.value;
            }
        }
        return null;
    }

    fn matchesEnumName(decl_name: []const u8, decl_sym: ?u32, ref_name: []const u8, ref_sym: ?u32) bool {
        if (decl_sym != null and ref_sym != null) return decl_sym.? == ref_sym.?;
        return std.mem.eql(u8, decl_name, ref_name);
    }

    /// `EnumName.Member` 또는 `EnumName["Member"]` 이면 미리 평가한 literal 노드로 치환.
    /// shadowing 안전: identifier_reference 의 symbol_id 가 enum 선언의 symbol_id 와 일치할 때만 인라인.
    fn tryInlineConstEnumMember(self: *Transformer, node: Node) Error!?NodeIndex {
        if (self.const_enums.items.len == 0) return null;
        if (node.tag != .static_member_expression and node.tag != .computed_member_expression) return null;
        const e = node.data.extra;
        if (e + 1 >= self.ast.extra_data.items.len) return null;
        const obj_idx = self.readNodeIdx(e, 0);
        const prop_idx = self.readNodeIdx(e, 1);
        if (obj_idx.isNone() or prop_idx.isNone()) return null;

        const obj_node = self.ast.getNode(obj_idx);
        if (obj_node.tag != .identifier_reference) return null;
        const obj_name = self.ast.getText(obj_node.span);
        const obj_sym = self.getSymbolIdAt(obj_idx);

        const prop_name = memberPropertyName(self, node.tag, prop_idx) orelse return null;

        for (self.const_enums.items) |decl| {
            if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
            for (decl.members) |m| {
                if (!std.mem.eql(u8, m.name, prop_name)) continue;
                return try self.makeConstEnumLiteralNode(m.value, node.span);
            }
        }
        return null;
    }

    fn memberPropertyName(self: *const Transformer, member_tag: ast_mod.Node.Tag, prop_idx: NodeIndex) ?[]const u8 {
        const prop_node = self.ast.getNode(prop_idx);
        if (member_tag == .static_member_expression) {
            if (prop_node.tag != .identifier_reference) return null;
            return self.ast.getText(prop_node.span);
        }
        // computed: string_literal 만 컴파일타임 평가 가능
        if (prop_node.tag != .string_literal) return null;
        const raw = self.ast.getText(prop_node.data.string_ref);
        if (raw.len < 2) return null;
        return raw[1 .. raw.len - 1];
    }

    /// shadowing 안전 매칭: symbol_id 가 둘 다 있으면 그것으로, 둘 중 하나라도 없으면 이름만으로.
    /// (semantic analyzer 가 비활성인 테스트 환경에서도 동작하도록 fallback.)
    fn enumDeclMatches(decl: ConstEnumDecl, ref_name: []const u8, ref_sym: ?u32) bool {
        if (decl.symbol_id != null and ref_sym != null) {
            return decl.symbol_id.? == ref_sym.?;
        }
        return std.mem.eql(u8, decl.name, ref_name);
    }

    fn makeConstEnumLiteralNode(self: *Transformer, value: ConstEnumValue, _: Span) Error!NodeIndex {
        switch (value) {
            .number => |n| {
                var buf: [64]u8 = undefined;
                // 정수면 정수 형식으로, 아니면 일반 형식으로.
                const s = if (@floor(n) == n and !std.math.isInf(n))
                    std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch return Error.OutOfMemory
                else
                    std.fmt.bufPrint(&buf, "{d}", .{n}) catch return Error.OutOfMemory;
                const num_span = try self.ast.addString(s);
                return self.ast.addNode(.{
                    .tag = .numeric_literal,
                    .span = num_span,
                    .data = .{ .none = 0 },
                });
            },
            .string => |raw| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                try buf.ensureTotalCapacity(self.allocator, raw.len + 2);
                try buf.append(self.allocator, '"');
                try buf.appendSlice(self.allocator, raw);
                try buf.append(self.allocator, '"');
                const str_span = try self.ast.addString(buf.items);
                return self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = str_span,
                    .data = .{ .string_ref = str_span },
                });
            },
        }
    }

    // ================================================================
    // TS namespace 변환
    // ================================================================

    /// ts_module_declaration: binary = { left=name, right=body_or_inner, flags }
    /// flags=1: ambient module declaration (`declare module "*.css" { ... }`) → strip.
    /// flags=0: 일반 namespace → 새 AST에 복사. codegen에서 IIFE로 출력.
    /// import x = require('y') → const x = require('y')
    /// import x = Namespace.Member → const x = Namespace.Member
    fn visitImportEqualsDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const name_idx = node.data.binary.left;
        const value_idx = node.data.binary.right;
        const new_name = try self.visitNode(name_idx);
        const new_value = try self.visitNode(value_idx);
        // variable_declarator: extra = [name, type_ann(none), init]
        const decl_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_name),
            @intFromEnum(NodeIndex.none), // type_ann (stripped)
            @intFromEnum(new_value),
        });
        const declarator = try self.ast.addNode(.{
            .tag = .variable_declarator,
            .span = node.span,
            .data = .{ .extra = decl_extra },
        });
        const scratch_top = self.scratch.items.len;
        try self.scratch.append(self.allocator, declarator);
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.scratch.shrinkRetainingCapacity(scratch_top);
        // variable_declaration: extra = [kind_flags, list.start, list.len]
        // kind = .const
        const var_extra = try self.ast.addExtras(&.{ @intFromEnum(VariableDeclarationKind.@"const"), list.start, list.len });
        return try self.ast.addNode(.{
            .tag = .variable_declaration,
            .span = node.span,
            .data = .{ .extra = var_extra },
        });
    }

    fn visitNamespaceDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        // declare module "*.css" { ... } 같은 ambient module은 런타임 코드 없음 → strip
        if (node.data.binary.flags == 1) return .none;
        const new_name = try self.visitNode(node.data.binary.left);
        const new_body = try self.visitNode(node.data.binary.right);
        // 타입만 있어 전부 스트리핑됐거나, 빈 블록인 namespace → strip
        if (new_body.isNone()) return .none;
        const body_node = self.ast.getNode(new_body);
        if ((body_node.tag == .block_statement or body_node.tag == .ts_module_block) and body_node.data.list.len == 0) {
            return .none;
        }
        return self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = node.span,
            .data = .{ .binary = .{ .left = new_name, .right = new_body, .flags = 0 } },
        });
    }

    // ================================================================
    // 헬퍼
    // ================================================================

    /// extra 인덱스로 NodeIndex 읽기.
    pub fn readNodeIdx(self: *const Transformer, extra_start: u32, offset: u32) NodeIndex {
        return @enumFromInt(self.ast.extra_data.items[extra_start + offset]);
    }

    /// extra 인덱스로 u32 읽기.
    pub fn readU32(self: *const Transformer, extra_start: u32, offset: u32) u32 {
        return self.ast.extra_data.items[extra_start + offset];
    }

    /// 노드를 extra_data로 만들어 새 AST에 추가.
    pub fn addExtraNode(self: *Transformer, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
        const new_extra = try self.ast.addExtras(extras);
        return self.ast.addNode(.{ .tag = tag, .span = span, .data = .{ .extra = new_extra } });
    }

    // ================================================================
    // JSX 노드 변환
    // ================================================================

    /// jsx_element: extra = [tag_name, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn visitJSXElement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        const children_len = self.readU32(e, 4);
        const new_children = if (children_len > 0)
            try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = children_len })
        else
            NodeList{ .start = 0, .len = 0 };
        return self.addExtraNode(.jsx_element, node.span, &.{
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

    /// variable_declaration: extra_data = [kind_flags, list.start, list.len]
    /// binding이 destructuring pattern (object/array)인지 판별.
    inline fn isBindingPattern(self: *const Transformer, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const tag = self.ast.getNode(idx).tag;
        return tag == .object_pattern or tag == .array_pattern;
    }

    fn visitVariableDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015: destructuring pattern → 개별 declarator로 분해
        // ES2018: object rest (...rest) → __rest 호출 (target < es2018)
        if (self.options.unsupported.destructuring) {
            if (es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, node)) {
                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
            }
        } else if (self.options.unsupported.object_spread) {
            if (es2015_destructuring.ES2015Destructuring(Transformer).hasObjectRest(self, node)) {
                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
            }
        }
        const e = node.data.extra;
        const orig_kind = self.ast.variableDeclarationKind(node);
        const kind = if (self.options.unsupported.block_scoping)
            es2015_block_scoping.lowerKind(orig_kind)
        else
            orig_kind;

        // let/const → var 변환 시: 초기화 없는 declarator에 = void 0 추가.
        // let은 블록 스코프로 매 반복 새 바인딩이지만, var는 hoisted되어 이전 값 유지.
        // Metro(Babel)와 동일하게 명시적 undefined 초기화로 의미론 보존.
        //
        // 단, for-in/for-of/for-await-of 헤더의 left는 매 반복 루프가 바인딩에 쓰므로
        // `= void 0`이 불필요하고, 오히려 `for (var k = void 0 in obj)` 는 Annex B
        // legacy 구문(for-in 전용, 비-strict)이라 codegen이 `k = void 0;` 로 hoist해
        // 선언 전에 토해내 strict mode ReferenceError를 유발 (#1386).
        const needs_void_init = self.options.unsupported.block_scoping and
            orig_kind.isLexical() and
            !self.in_for_in_of_header;

        const list_start = self.readU32(e, 1);
        const list_len = self.readU32(e, 2);

        if (needs_void_init) {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var i_loop: u32 = 0;
            while (i_loop < list_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[list_start + i_loop];
                const decl = self.ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) {
                    const new_node = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_node.isNone()) try self.scratch.append(self.allocator, new_node);
                    continue;
                }
                const de = decl.data.extra;
                const name_idx = self.readNodeIdx(de, 0);
                const init_idx = self.readNodeIdx(de, 2);
                const new_name = try self.visitNode(name_idx);

                if (init_idx.isNone()) {
                    // let x; → var x = void 0;
                    // 단 destructuring pattern (`let {x}`, `let [x]`)은 init 추가 금지 —
                    // for-of/for-in의 left에서 매 반복 iter value를 받으며, `{x} = void 0` 같은
                    // statement는 block_statement로 잘못 파싱되어 syntax error (#1302).
                    const is_destructuring = isBindingPattern(self, new_name);
                    const none = @intFromEnum(NodeIndex.none);
                    const init_node: u32 = if (is_destructuring)
                        none
                    else
                        @intFromEnum(try es_helpers.makeVoidZero(self, node.span));
                    const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @intFromEnum(new_name), none, init_node });
                    try self.scratch.append(self.allocator, new_decl);
                } else {
                    const new_init = try self.visitNode(init_idx);
                    const none = @intFromEnum(NodeIndex.none);
                    const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
                    try self.scratch.append(self.allocator, new_decl);
                }
            }

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.addExtraNode(.variable_declaration, node.span, &.{ @intFromEnum(kind), new_list.start, new_list.len });
        }

        const new_list = try self.visitExtraList(.{ .start = list_start, .len = list_len });
        return self.addExtraNode(.variable_declaration, node.span, &.{ @intFromEnum(kind), new_list.start, new_list.len });
    }

    /// variable_declarator: extra_data = [name, type_ann, init]
    fn visitVariableDeclarator(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_init = try self.visitNode(self.readNodeIdx(e, 2));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.variable_declarator, node.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
    }

    /// function/function_declaration/function_expression/arrow_function_expression
    /// extra_data = [name, params_start, params_len, body, flags, return_type]
    ///
    /// parameter property 변환:
    ///   constructor(public x: number) {} →
    ///   constructor(x) { this.x = x; }
    fn visitFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;

        // TS function overload signature: body가 없으면 제거
        // function foo(): void;  ← overload signature (body 없음)
        // function foo(x: number): void;  ← overload signature
        // function foo(x?: number) {}  ← 구현체 (body 있음)
        if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;

        // 일반 함수는 자체 this 바인딩을 가지므로 depth 증가.
        // static block 안에서 function() { this.x } 의 this는 치환하면 안 됨.
        const in_static_block = self.static_block_class_name != null;
        if (in_static_block) self.this_depth += 1;
        defer if (in_static_block) {
            self.this_depth -= 1;
        };

        // ES2015 arrow this/arguments 캡처: 일반 함수는 자체 this/arguments 바인딩을 가짐.
        const saved_arrow_depth = self.arrow_this_depth;
        const saved_needs_this = self.needs_this_var;
        const saved_needs_args = self.needs_arguments_var;
        const saved_super_alias = self.super_call_this_alias;
        self.arrow_this_depth = 0;
        self.needs_this_var = false;
        self.needs_arguments_var = false;
        self.super_call_this_alias = false;

        // ES2015 block scoping: 함수는 새 var 스코프. save/restore.
        const saved_scope_len = self.scope_var_names.items.len;
        const saved_rename_len = self.block_rename_stack.items.len;
        defer {
            self.scope_var_names.shrinkRetainingCapacity(saved_scope_len);
            // 함수 내부에서 추가된 rename 해제
            for (self.block_rename_stack.items[saved_rename_len..]) |entry| self.allocator.free(entry.new_name);
            self.block_rename_stack.shrinkRetainingCapacity(saved_rename_len);
        }

        // ES2015 new.target: 일반 함수 → function_named 컨텍스트
        const saved_new_target_ctx = self.new_target_ctx;
        if (self.options.unsupported.new_target) {
            const name_idx = self.readNodeIdx(e, 0);
            if (!name_idx.isNone()) {
                self.new_target_ctx = .{ .function_named = self.ast.getNode(name_idx).span };
            } else {
                // 익명 함수: new.target → void 0 (이름 없으므로 instanceof 불가)
                self.new_target_ctx = .method;
            }
        }
        defer self.new_target_ctx = saved_new_target_ctx;

        // 임시 변수 카운터 저장 (함수 스코프 내 사용된 임시 변수 호이스팅용)
        const saved_temp_counter = self.temp_var_counter;

        const new_name = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 + parameter property 수집
        const params_idx_old = self.readNodeIdx(e, 1);
        var params_span = node.span;
        var params_list_old = NodeList{ .start = 0, .len = 0 };
        if (!params_idx_old.isNone()) {
            const pnode = self.ast.getNode(params_idx_old);
            if (pnode.tag == .formal_parameters) {
                params_list_old = pnode.data.list;
                params_span = pnode.span;
            }
        }
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const pp = try self.visitParamsCollectProperties(params_list_old);

        // 바디 방문
        const old_body_idx = self.readNodeIdx(e, 2);
        var new_body = try self.visitBodyWorkletAware(old_body_idx);

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_count > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
        }

        // ES2015 arrow this/arguments 캡처: 이 함수 안의 arrow가 this/arguments를 사용했으면
        // var _this = this; / var _arguments = arguments; 를 바디 앞에 삽입.
        if (self.options.unsupported.arrow and !new_body.isNone() and
            (self.needs_this_var or self.needs_arguments_var))
        {
            var capture_stmts: [2]NodeIndex = undefined;
            var capture_count: usize = 0;

            if (self.needs_this_var) {
                const this_init = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = node.span,
                    .data = .{ .none = 0 },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
                capture_count += 1;
            }
            if (self.needs_arguments_var) {
                const args_span = try self.ast.addString("arguments");
                const args_init = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = args_span,
                    .data = .{ .string_ref = args_span },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, node.span);
                capture_count += 1;
            }

            new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
        }

        // 임시 변수 호이스팅: 이 함수 안에서 사용된 _a, _b, ... 선언을 body 앞에 삽입
        if (self.temp_var_counter > saved_temp_counter and !new_body.isNone()) {
            new_body = try self.hoistTempVars(new_body, saved_temp_counter, node.span);
        }

        // arrow 캡처 상태 복원
        self.arrow_this_depth = saved_arrow_depth;
        self.needs_this_var = saved_needs_this;
        self.needs_arguments_var = saved_needs_args;
        self.super_call_this_alias = saved_super_alias;

        // $RefreshSig$ (hook signature) 스캔은 제거 — transform 후 stale AST 인덱스로 OOM 유발.
        // Metro도 직접 스캔하지 않고 Babel/SWC에 위임. $RefreshReg$만 유지.

        const none = @intFromEnum(NodeIndex.none);
        const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
        const result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_params_node),
            @intFromEnum(new_body), self.readU32(e, 3),
            none,
        });

        // Plugin dispatch: onFunction (AST 훅)
        const is_auto_worklet = self.plugins.worklet.auto_next;
        if (try self.dispatchFunctionPlugins(result, .{
            .node_idx = result,
            .node_tag = node.tag,
            .name = self.getFunctionName(self.ast.getNode(result)),
            .body_idx = new_body,
            .params = pp.new_params,
            .original_params = params_list_old,
            .original_body_idx = old_body_idx,
            .flags = self.readU32(e, 3),
            .source_path = self.options.jsx_filename,
            .is_auto_worklet = is_auto_worklet,
        })) |replacement| {
            return replacement;
        }

        // React Fast Refresh: PascalCase 함수 → 컴포넌트 등록
        try self.maybeRegisterRefreshComponent(result);

        return result;
    }

    /// 파라미터 목록을 방문하면서 parameter property (public x 등)를 감지.
    /// modifier를 제거하고 this.x = x 삽입용 이름을 수집한다.
    const ParamPropertyResult = struct {
        new_params: NodeList,
        prop_names: [32]NodeIndex,
        prop_count: usize,
    };

    pub fn visitParamsCollectProperties(self: *Transformer, vp: NodeList) Error!ParamPropertyResult {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var result = ParamPropertyResult{
            .new_params = NodeList{ .start = 0, .len = 0 },
            .prop_names = undefined,
            .prop_count = 0,
        };

        // visitNode가 AST를 변형하므로 인덱스 루프 사용
        var i_loop: u32 = 0;
        while (i_loop < vp.len) : (i_loop += 1) {
            const raw_idx = self.ast.extra_data.items[vp.start + i_loop];
            const param_idx: NodeIndex = @enumFromInt(raw_idx);
            if (param_idx.isNone()) continue;
            const param_node = self.ast.getNode(param_idx);
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            // flags != 0 → parameter property (public/private/protected/readonly/override)
            if (param_node.tag == .formal_parameter and self.ast.extra_data.items[param_node.data.extra + 3] != 0) {
                const inner = try self.visitNode(@enumFromInt(self.ast.extra_data.items[param_node.data.extra]));
                try self.scratch.append(self.allocator, inner);
                if (result.prop_count < result.prop_names.len) {
                    result.prop_names[result.prop_count] = inner;
                    result.prop_count += 1;
                }
            } else {
                const new_param = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_param.isNone()) {
                    try self.scratch.append(self.allocator, new_param);
                }
            }
        }

        result.new_params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return result;
    }

    /// block_statement 바디 앞에 this.x = x; 문들을 삽입한다.
    pub fn insertParameterPropertyAssignments(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
        const body = self.ast.getNode(body_idx);
        if (body.tag != .block_statement) return body_idx;

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // this.x = x 문들을 먼저 추가
        for (prop_names) |name_idx| {
            const name_node = self.ast.getNode(name_idx);
            // this 노드
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = name_node.span,
                .data = .{ .none = 0 },
            });
            // this.x (static member) — extra = [object, property, flags]
            const member_extra = try self.ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(name_idx), 0 });
            const member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = name_node.span,
                .data = .{ .extra = member_extra },
            });
            // this.x = x (assignment)
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = name_node.span,
                .data = .{ .binary = .{ .left = member, .right = name_idx, .flags = 0 } },
            });
            // expression_statement
            const stmt = try self.ast.addNode(.{
                .tag = .expression_statement,
                .span = name_node.span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, stmt);
        }

        // 기존 바디 문들을 추가
        const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// block_statement / program / function_body 앞에 문들을 삽입한다.
    pub fn prependStatementsToBody(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
        const body = self.ast.getNode(body_idx);
        if (body.tag != .block_statement and body.tag != .program and body.tag != .function_body) {
            // 단일 문(non-block)이면 블록으로 감싸서 prepend
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            for (stmts) |stmt| {
                try self.scratch.append(self.allocator, stmt);
            }
            try self.scratch.append(self.allocator, body_idx);
            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = body.span,
                .data = .{ .list = new_list },
            });
        }

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (stmts) |stmt| {
            try self.scratch.append(self.allocator, stmt);
        }

        const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = body.tag,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// ES2015 new.target 변환.
    /// constructor: this.constructor
    /// method: void 0
    /// function_named(Fn): this instanceof Fn ? this.constructor : void 0
    fn lowerNewTarget(self: *Transformer, span: Span) Error!NodeIndex {
        return switch (self.new_target_ctx) {
            .constructor => {
                // this.constructor
                const this_node = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
                const ctor_ref = try es_helpers.makeIdentifierRef(self, "constructor");
                return es_helpers.makeStaticMember(self, this_node, ctor_ref, span);
            },
            .method, .none => es_helpers.makeVoidZero(self, span),
            .function_named => |fn_span| {
                // (this instanceof Fn ? this.constructor : void 0)
                const this1 = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
                const fn_ref = try es_helpers.makeIdentifierRef(self, self.ast.getText(fn_span));
                const instanceof = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{
                        .left = this1,
                        .right = fn_ref,
                        .flags = @intFromEnum(token_mod.Kind.kw_instanceof),
                    } },
                });

                // this.constructor
                const this2 = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
                const ctor_ref = try es_helpers.makeIdentifierRef(self, "constructor");
                const this_ctor = try es_helpers.makeStaticMember(self, this2, ctor_ref, span);

                // void 0
                const void_zero = try es_helpers.makeVoidZero(self, span);

                // conditional → parenthesized (우선순위 보호)
                const cond = try self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = span,
                    .data = .{ .ternary = .{
                        .a = instanceof,
                        .b = this_ctor,
                        .c = void_zero,
                    } },
                });
                return self.ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = span,
                    .data = .{ .unary = .{ .operand = cond, .flags = 0 } },
                });
            },
        };
    }

    /// ES2015 tagged template 다운레벨링.
    /// tag`hello ${name} world` →
    ///   function _templateObject() { var data = __taggedTemplateLiteral(["hello "," world"]); _templateObject = function(){ return data; }; return data; }
    ///   tag(_templateObject(), name)
    fn lowerTaggedTemplate(self: *Transformer, tag_idx: NodeIndex, tmpl_idx: NodeIndex, span: Span) Error!NodeIndex {
        const tmpl = self.ast.getNode(tmpl_idx);
        const source = self.ast.source;

        // template_literal의 quasis(element)와 expressions 분리
        // 구조: [element, expr, element, expr, ..., element]
        // substitution이 없으면 data.none=0, element 1개뿐

        const is_substitution = blk: {
            var pos = tmpl.span.start + 1;
            while (pos < tmpl.span.end) {
                if (source[pos] == '\\') {
                    pos += 2;
                    continue;
                }
                if (source[pos] == '$' and pos + 1 < tmpl.span.end and source[pos + 1] == '{') break :blk true;
                pos += 1;
            }
            break :blk false;
        };

        // --- cooked/raw/expr 배열 구축 (scratch 사용, 힙 할당 없음) ---
        const scratch_base = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_base);

        // scratch에 순서대로: [cooked... | raw... | expr...]
        // 각 영역의 시작 위치를 기록
        var cooked_count: u32 = 0;
        var raw_count: u32 = 0;
        var has_escape = false;

        if (!is_substitution) {
            const text = es2015_template.getTemplateElementText(source, tmpl.span);
            try self.scratch.append(self.allocator, try es2015_template.buildStringLiteral(self, text));
            cooked_count = 1;
        } else {
            const tl_start = tmpl.data.list.start;
            const tl_len = tmpl.data.list.len;
            var i: u32 = 0;
            while (i < tl_len) : (i += 1) {
                const raw_idx = self.ast.extra_data.items[tl_start + i];
                const member = self.ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .template_element) {
                    const text = es2015_template.getTemplateElementText(source, member.span);
                    try self.scratch.append(self.allocator, try es2015_template.buildStringLiteral(self, text));
                    cooked_count += 1;
                }
            }
        }

        // raw 배열 (cooked 뒤에 append)
        const raw_start = self.scratch.items.len;
        if (!is_substitution) {
            const raw_text = es2015_template.getTemplateElementText(source, tmpl.span);
            try self.scratch.append(self.allocator, try es2015_template.buildRawStringLiteral(self, raw_text));
            if (std.mem.indexOf(u8, raw_text, "\\") != null) has_escape = true;
            raw_count = 1;
        } else {
            const tl_start2 = tmpl.data.list.start;
            const tl_len2 = tmpl.data.list.len;
            var j: u32 = 0;
            while (j < tl_len2) : (j += 1) {
                const raw_idx2 = self.ast.extra_data.items[tl_start2 + j];
                const member2 = self.ast.getNode(@enumFromInt(raw_idx2));
                if (member2.tag == .template_element) {
                    const raw_text = es2015_template.getTemplateElementText(source, member2.span);
                    try self.scratch.append(self.allocator, try es2015_template.buildRawStringLiteral(self, raw_text));
                    if (std.mem.indexOf(u8, raw_text, "\\") != null) has_escape = true;
                    raw_count += 1;
                }
            }
        }

        // expr 배열 (raw 뒤에 append)
        const expr_start = self.scratch.items.len;
        if (is_substitution) {
            const tl_start3 = tmpl.data.list.start;
            const tl_len3 = tmpl.data.list.len;
            var k: u32 = 0;
            while (k < tl_len3) : (k += 1) {
                const raw_idx3 = self.ast.extra_data.items[tl_start3 + k];
                const member3 = self.ast.getNode(@enumFromInt(raw_idx3));
                if (member3.tag != .template_element) {
                    try self.scratch.append(self.allocator, try self.visitNode(@enumFromInt(raw_idx3)));
                }
            }
        }
        const expr_count = self.scratch.items.len - expr_start;

        const cooked_slice = self.scratch.items[scratch_base .. scratch_base + cooked_count];
        const raw_slice = self.scratch.items[raw_start .. raw_start + raw_count];
        const expr_slice = self.scratch.items[expr_start .. expr_start + expr_count];

        // --- _templateObject 함수명 생성 ---
        self.tagged_template_counter += 1;
        const fn_name = if (self.tagged_template_counter == 1)
            "_templateObject"
        else blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "_templateObject{d}", .{self.tagged_template_counter});
        };
        defer if (self.tagged_template_counter > 1) self.allocator.free(fn_name);

        // --- cooked 배열 노드 ---
        const cooked_list = try self.ast.addNodeList(cooked_slice);
        const cooked_arr = try self.ast.addNode(.{
            .tag = .array_expression,
            .span = span,
            .data = .{ .list = cooked_list },
        });

        // --- __taggedTemplateLiteral(cooked, [raw]) 호출 ---
        const helper_ref = try es_helpers.makeIdentifierRef(self, "__taggedTemplateLiteral");
        var call_args: [2]NodeIndex = undefined;
        var call_arg_count: u32 = 1;
        call_args[0] = cooked_arr;

        if (has_escape) {
            const raw_list = try self.ast.addNodeList(raw_slice);
            const raw_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = raw_list },
            });
            call_args[1] = raw_arr;
            call_arg_count = 2;
        }

        const helper_args = try self.ast.addNodeList(call_args[0..call_arg_count]);
        const helper_call_extra = try self.ast.addExtras(&.{
            @intFromEnum(helper_ref), helper_args.start, helper_args.len, 0,
        });
        const helper_call = try self.ast.addNode(.{
            .tag = .call_expression,
            .span = span,
            .data = .{ .extra = helper_call_extra },
        });

        // --- var data = __taggedTemplateLiteral(...) ---
        const data_decl = try self.buildVarDecl("data", helper_call, span);

        // --- _templateObject = function() { return data; } ---
        const fn_name_ref = try es_helpers.makeIdentifierRef(self, fn_name);
        const data_ref = try es_helpers.makeIdentifierRef(self, "data");
        const return_stmt = try self.ast.addNode(.{
            .tag = .return_statement,
            .span = span,
            .data = .{ .unary = .{ .operand = data_ref, .flags = 0 } },
        });
        const inner_body_list = try self.ast.addNodeList(&.{return_stmt});
        const inner_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = span,
            .data = .{ .list = inner_body_list },
        });
        const none = @intFromEnum(NodeIndex.none);
        const inner_empty_params = try self.ast.addNodeList(&.{});
        const inner_params_node = try self.ast.addFormalParameters(inner_empty_params, span);
        const inner_func_extra = try self.ast.addExtras(&.{
            none, @intFromEnum(inner_params_node), @intFromEnum(inner_body), 0, none,
        });
        const inner_func = try self.ast.addNode(.{
            .tag = .function_expression,
            .span = span,
            .data = .{ .extra = inner_func_extra },
        });

        // _templateObject = function() { return data; }
        const reassign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = span,
            .data = .{ .binary = .{ .left = fn_name_ref, .right = inner_func, .flags = 0 } },
        });
        const reassign_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = span,
            .data = .{ .unary = .{ .operand = reassign, .flags = 0 } },
        });

        // return data
        const data_ref2 = try es_helpers.makeIdentifierRef(self, "data");
        const return_stmt2 = try self.ast.addNode(.{
            .tag = .return_statement,
            .span = span,
            .data = .{ .unary = .{ .operand = data_ref2, .flags = 0 } },
        });

        // --- function _templateObject() { var data = ...; _templateObject = ...; return data; } ---
        const outer_body_list = try self.ast.addNodeList(&.{ data_decl, reassign_stmt, return_stmt2 });
        const outer_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = span,
            .data = .{ .list = outer_body_list },
        });
        const fn_name_binding_span = try self.ast.addString(fn_name);
        const fn_name_binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = fn_name_binding_span,
            .data = .{ .string_ref = fn_name_binding_span },
        });
        const outer_empty_params = try self.ast.addNodeList(&.{});
        const outer_params_node = try self.ast.addFormalParameters(outer_empty_params, span);
        const outer_func_extra = try self.ast.addExtras(&.{
            @intFromEnum(fn_name_binding), @intFromEnum(outer_params_node), @intFromEnum(outer_body), 0, none,
        });
        const fn_decl = try self.ast.addNode(.{
            .tag = .function_declaration,
            .span = span,
            .data = .{ .extra = outer_func_extra },
        });

        // 호이스팅 목록에 추가
        try self.tagged_template_fns.append(self.allocator, fn_decl);
        self.runtime_helpers.tagged_template_literal = true;

        // --- tag(_templateObject(), ...exprs) 호출 ---
        const new_tag = try self.visitNode(tag_idx);
        const fn_call_ref = try es_helpers.makeIdentifierRef(self, fn_name);
        const empty_args = try self.ast.addNodeList(&.{});
        const tmpl_call_extra = try self.ast.addExtras(&.{
            @intFromEnum(fn_call_ref), empty_args.start, empty_args.len, 0,
        });
        const tmpl_call = try self.ast.addNode(.{
            .tag = .call_expression,
            .span = span,
            .data = .{ .extra = tmpl_call_extra },
        });

        // tag(_templateObject(), expr1, expr2, ...)
        // scratch에서 최종 인자 목록 구성 (기존 cooked/raw/expr 뒤에 append)
        const final_start = self.scratch.items.len;
        try self.scratch.append(self.allocator, tmpl_call);
        for (expr_slice) |expr| {
            try self.scratch.append(self.allocator, expr);
        }
        const final_args = try self.ast.addNodeList(self.scratch.items[final_start..]);
        const final_call_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_tag), final_args.start, final_args.len, 0,
        });
        return self.ast.addNode(.{
            .tag = .call_expression,
            .span = span,
            .data = .{ .extra = final_call_extra },
        });
    }

    /// block_rename_stack에서 이름 조회. 스택 뒤(가장 안쪽 블록)부터 검색.
    pub fn lookupBlockRename(self: *const Transformer, name: []const u8) ?[]const u8 {
        var i = self.block_rename_stack.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.block_rename_stack.items[i];
            if (std.mem.eql(u8, entry.old_name, name)) return entry.new_name;
        }
        return null;
    }

    /// 현재 함수 스코프의 var 이름 목록에 해당 이름이 있는지 확인.
    fn isNameInScope(self: *const Transformer, name: []const u8) bool {
        for (self.scope_var_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// block_statement 진입 시: 내부 let/const 선언을 스캔하여 외부 스코프와
    /// 충돌하는 이름을 찾고 리네이밍 맵을 push한다.
    /// 반환값: push한 rename entry 수 (퇴장 시 pop할 양).
    fn pushBlockRenames(self: *Transformer, list_start: u32, list_len: u32) Error!u32 {
        var renames_added: u32 = 0;

        var i: u32 = 0;
        while (i < list_len) : (i += 1) {
            const raw = self.ast.extra_data.items[list_start + i];
            const stmt = self.ast.getNode(@enumFromInt(raw));
            if (stmt.tag != .variable_declaration) continue;

            const ve = stmt.data.extra;
            if (!self.ast.variableDeclarationKind(stmt).isLexical()) continue;

            const decl_start = self.readU32(ve, 1);
            const decl_len = self.readU32(ve, 2);

            var j: u32 = 0;
            while (j < decl_len) : (j += 1) {
                const decl_raw = self.ast.extra_data.items[decl_start + j];
                const decl = self.ast.getNode(@enumFromInt(decl_raw));
                if (decl.tag != .variable_declarator) continue;

                const name_idx = self.readNodeIdx(decl.data.extra, 0);
                if (name_idx.isNone()) continue;

                // binding pattern에서 모든 이름 수집 (destructuring 지원)
                const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.allocator);
                BlockScoping.collectBindingNames(self, name_idx, &names) catch continue;

                for (names.items) |name| {
                    if (self.isNameInScope(name)) {
                        self.block_rename_counter += 1;
                        const new_name = std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, self.block_rename_counter }) catch return Error.OutOfMemory;
                        self.block_rename_stack.append(self.allocator, .{ .old_name = name, .new_name = new_name }) catch return Error.OutOfMemory;
                        renames_added += 1;
                    } else {
                        self.scope_var_names.append(self.allocator, name) catch return Error.OutOfMemory;
                    }
                }
            }
        }

        return renames_added;
    }

    /// var <name> = <init_value>; 문 생성 (범용 헬퍼).
    /// prefix + 카운터로 고유 이름을 생성한다. (예: _loop, _loop2, _loop3, ...)
    /// 호출부에서 전용 카운터 포인터를 전달하여 다른 기능과 충돌 방지.
    pub fn buildUniqueName(self: *Transformer, prefix: []const u8, counter: *u32) Error![]const u8 {
        counter.* += 1;
        if (counter.* == 1) return prefix;
        return std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, counter.* }) catch return Error.OutOfMemory;
    }

    pub fn buildVarDecl(self: *Transformer, name: []const u8, init_value: NodeIndex, span: Span) Error!NodeIndex {
        const name_span = try self.ast.addString(name);
        const binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });

        const none = @intFromEnum(NodeIndex.none);
        const declarator = try self.addExtraNode(.variable_declarator, span, &.{
            @intFromEnum(binding), none, @intFromEnum(init_value),
        });

        const decl_list = try self.ast.addNodeList(&.{declarator});
        return self.addExtraNode(.variable_declaration, span, &.{
            @intFromEnum(VariableDeclarationKind.@"var"),
            decl_list.start,
            decl_list.len,
        });
    }

    /// 임시 변수 호이스팅: saved_counter..current counter 범위의 var _a, _b, ... 선언을 body 앞에 삽입.
    fn hoistTempVars(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span) Error!NodeIndex {
        const count = self.temp_var_counter - saved_counter;
        if (count == 0) return body_idx;

        // var _a, _b, ... (초기값 없이 선언만)
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var i: u32 = saved_counter;
        while (i < self.temp_var_counter) : (i += 1) {
            var buf: [16]u8 = undefined;
            const name = es_helpers.tempVarName(i, &buf);
            const name_span = try self.ast.addString(name);
            const binding = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = name_span,
                .data = .{ .string_ref = name_span },
            });
            const none = @intFromEnum(NodeIndex.none);
            const declarator = try self.addExtraNode(.variable_declarator, span, &.{
                @intFromEnum(binding), none, none,
            });
            try self.scratch.append(self.allocator, declarator);
        }

        const decl_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        const var_decl = try self.addExtraNode(.variable_declaration, span, &.{
            @intFromEnum(VariableDeclarationKind.@"var"),
            decl_list.start,
            decl_list.len,
        });

        return self.prependStatementsToBody(body_idx, &.{var_decl});
    }

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
    pub const extractCleanVarName = class_deco.extractCleanVarName;
    pub const appendEsDecorateStmt = class_deco.appendEsDecorateStmt;
    pub const wrapInStringLiteral = class_deco.wrapInStringLiteral;
    pub const extractTypeFromSource = class_deco.extractTypeFromSource;

    fn visitForStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const init_idx = self.readNodeIdx(e, 0);

        // ES2015 block scoping: let/const 변수 캡처 감지
        if (self.options.unsupported.block_scoping) {
            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var lexical_names = try BlockScoping.collectLexicalVarNames(self, init_idx);
            defer lexical_names.deinit(self.allocator);

            if (lexical_names.items.len > 0) {
                // 원본 body에서 캡처/제어흐름 분석 (new AST에서는 extra 레이아웃이 변경됨)
                const orig_body_idx = self.readNodeIdx(e, 3);
                const has_capture = BlockScoping.hasCapturedClosure(self, orig_body_idx, lexical_names.items);

                // 제어 흐름 분석도 원본에서 수행
                var flow = BlockScoping.FlowResult{};
                flow.labels = .empty;
                defer flow.labels.deinit(self.allocator);
                if (has_capture) {
                    BlockScoping.analyzeControlFlow(self, orig_body_idx, &flow, 0, 0);
                }

                const new_init = try self.visitNode(init_idx);
                const new_test = try self.visitNode(self.readNodeIdx(e, 1));
                const new_update = try self.visitNode(self.readNodeIdx(e, 2));
                const new_body = try self.visitNode(orig_body_idx);

                if (has_capture) {
                    const result = try BlockScoping.buildLoopClosureWithFlow(
                        self,
                        new_body,
                        lexical_names.items,
                        &flow,
                        node.span,
                    );

                    // var _loop = function(...) { ... };
                    // for (var i = 0; ...) { _loop(i); }
                    const for_node = try self.addExtraNode(.for_statement, node.span, &.{
                        @intFromEnum(new_init),   @intFromEnum(new_test),
                        @intFromEnum(new_update), @intFromEnum(result.call_and_check),
                    });

                    // 두 문을 블록으로 반환 (호이스팅 불필요 — for 문 바로 앞에 삽입)
                    const stmts = try self.ast.addNodeList(&.{ result.loop_fn, for_node });
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = stmts },
                    });
                }

                return self.addExtraNode(.for_statement, node.span, &.{
                    @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
                });
            }
        }

        const new_init = try self.visitNode(init_idx);
        const new_test = try self.visitNode(self.readNodeIdx(e, 1));
        const new_update = try self.visitNode(self.readNodeIdx(e, 2));
        const new_body = try self.visitNode(self.readNodeIdx(e, 3));
        return self.addExtraNode(.for_statement, node.span, &.{
            @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
        });
    }

    /// switch_statement: extra = [discriminant, cases.start, cases.len]
    fn visitSwitchStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_disc = try self.visitNode(self.readNodeIdx(e, 0));
        const new_cases = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(.switch_statement, node.span, &.{
            @intFromEnum(new_disc), new_cases.start, new_cases.len,
        });
    }

    /// switch_case: extra_data = [test, stmts_start, stmts_len]
    fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_test = try self.visitNode(self.readNodeIdx(e, 0));
        const new_stmts = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(.switch_case, node.span, &.{ @intFromEnum(new_test), new_stmts.start, new_stmts.len });
    }

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

    /// `x.replace(/.../u, "...$<n>...")` 패턴 매칭 + replacement string 변환.
    /// 매칭 실패 (callee 형태 다름, regex가 dynamic, replacement가 literal 아님 등) 시 null.
    fn tryRewriteReplaceNamedRefs(self: *Transformer, callee_idx: NodeIndex, args_start: u32) Error!?ast_mod.NodeList {
        const callee = self.ast.getNode(callee_idx);
        if (callee.tag != .static_member_expression) return null;
        const ce = callee.data.extra;
        if (ce + 1 >= self.ast.extra_data.items.len) return null;
        const prop_idx = self.readNodeIdx(ce, 1);
        const prop = self.ast.getNode(prop_idx);
        if (prop.tag != .identifier_reference) return null;
        const prop_name = self.ast.getText(prop.span);
        if (!std.mem.eql(u8, prop_name, "replace") and !std.mem.eql(u8, prop_name, "replaceAll")) return null;

        const arg0_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);
        const arg1_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start + 1]);
        const arg0 = self.ast.getNode(arg0_idx);
        const arg1 = self.ast.getNode(arg1_idx);
        if (arg0.tag != .regexp_literal or arg1.tag != .string_literal) return null;

        const raw = self.ast.getText(arg0.span);
        if (raw.len < 3 or raw[0] != '/') return null;
        const last_slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return null;
        if (last_slash == 0) return null;
        const pattern = raw[1..last_slash];

        const mapping = try regex_lower.extractNamedGroupMap(self.allocator, pattern);
        defer self.allocator.free(mapping);
        if (mapping.len == 0) return null;

        const replace_raw = self.ast.getText(arg1.data.string_ref);
        if (replace_raw.len < 2) return null;
        const quote = replace_raw[0];
        if (quote != '"' and quote != '\'') return null;
        const content = replace_raw[1 .. replace_raw.len - 1];

        const new_content = (try regex_lower.rewriteReplacementNamedRefs(self.allocator, content, mapping)) orelse return null;
        defer self.allocator.free(new_content);

        const new_raw = try std.fmt.allocPrint(self.allocator, "{c}{s}{c}", .{ quote, new_content, quote });
        defer self.allocator.free(new_raw);
        const new_span = try self.ast.addString(new_raw);
        const new_str_node = try self.ast.addNode(.{
            .tag = .string_literal,
            .span = new_span,
            .data = .{ .string_ref = new_span },
        });
        const new_arg0 = try self.visitNode(arg0_idx);
        return self.ast.addNodeList(&[_]NodeIndex{ new_arg0, new_str_node }) catch return Error.OutOfMemory;
    }

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

    // method_definition: extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
    // constructor의 parameter property (public x: number) 변환도 처리.
    // abstract 메서드 (flags bit5=0x20)는 런타임에 존재하면 안 되므로 완전히 제거.
    pub fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 3);
        // abstract 메서드는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0x20) != 0) return NodeIndex.none;
        // TS method overload signature: body가 없으면 제거
        if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 — parameter property 감지
        const params_idx_old = self.readNodeIdx(e, 1);
        var params_span = node.span;
        var params_list_old = NodeList{ .start = 0, .len = 0 };
        if (!params_idx_old.isNone()) {
            const pnode = self.ast.getNode(params_idx_old);
            if (pnode.tag == .formal_parameters) {
                params_list_old = pnode.data.list;
                params_span = pnode.span;
            }
        }
        const pp = try self.visitParamsCollectProperties(params_list_old);

        // arrow this/arguments 캡처: method도 자체 this 바인딩을 가짐 (visitFunction과 동일)
        const saved_arrow_depth = self.arrow_this_depth;
        const saved_needs_this = self.needs_this_var;
        const saved_needs_args = self.needs_arguments_var;
        const saved_super_alias = self.super_call_this_alias;
        self.arrow_this_depth = 0;
        self.needs_this_var = false;
        self.needs_arguments_var = false;
        self.super_call_this_alias = false;

        // ES2015 new.target: method → constructor 또는 void 0
        const saved_new_target_ctx = self.new_target_ctx;
        if (self.options.unsupported.new_target) {
            const is_ctor = blk: {
                if ((flags & 0x01) != 0) break :blk false; // static
                const key_idx = self.readNodeIdx(e, 0);
                const key_node = self.ast.getNode(key_idx);
                if (key_node.tag == .identifier_reference) {
                    const name = self.ast.getText(key_node.span);
                    break :blk std.mem.eql(u8, name, "constructor");
                }
                break :blk false;
            };
            self.new_target_ctx = if (is_ctor) .constructor else .method;
        }
        defer self.new_target_ctx = saved_new_target_ctx;

        var new_body = try self.visitBodyWorkletAware(self.readNodeIdx(e, 2));

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_count > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
        }

        // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
        if (self.options.unsupported.arrow and !new_body.isNone() and
            (self.needs_this_var or self.needs_arguments_var))
        {
            var capture_stmts: [2]NodeIndex = undefined;
            var capture_count: usize = 0;

            if (self.needs_this_var) {
                const this_init = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = node.span,
                    .data = .{ .none = 0 },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
                capture_count += 1;
            }
            if (self.needs_arguments_var) {
                const args_span = try self.ast.addString("arguments");
                const args_init = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = args_span,
                    .data = .{ .string_ref = args_span },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, node.span);
                capture_count += 1;
            }

            new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
        }

        self.arrow_this_depth = saved_arrow_depth;
        self.needs_this_var = saved_needs_this;
        self.needs_arguments_var = saved_needs_args;
        self.super_call_this_alias = saved_super_alias;

        // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
        // method_definition에서는 제거한다.
        const new_decos = if (self.options.experimental_decorators)
            NodeList{ .start = 0, .len = 0 }
        else
            try self.visitExtraList(.{ .start = self.readU32(e, 4), .len = self.readU32(e, 5) });
        const old_body_idx = self.readNodeIdx(e, 2);
        const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
        const result = try self.addExtraNode(.method_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_params_node), @intFromEnum(new_body),
            self.readU32(e, 3),    new_decos.start,               new_decos.len,
        });

        // Plugin dispatch: worklet 등 AST 플러그인 적용
        // method_definition은 object/class 내부에 있으므로 IIFE 교체는 불가.
        // 대신 워크릿 플러그인이 method body 기반으로 function_expression을 생성하여
        // object_property value로 교체할 수 있도록 정보를 전달한다.
        const is_auto_worklet = self.plugins.worklet.auto_next;
        // method 이름 추출 (key가 identifier인 경우)
        const method_name: ?[]const u8 = blk: {
            const key_idx = self.readNodeIdx(e, 0);
            if (key_idx.isNone()) break :blk null;
            const key_node = self.ast.getNode(key_idx);
            if (key_node.tag == .identifier_reference) {
                break :blk self.ast.getText(key_node.span);
            }
            break :blk null;
        };
        if (try self.dispatchFunctionPlugins(result, .{
            .node_idx = result,
            .node_tag = .method_definition,
            .name = method_name,
            .body_idx = new_body,
            .params = pp.new_params,
            .original_params = params_list_old,
            .original_body_idx = old_body_idx,
            .flags = flags,
            .source_path = self.options.jsx_filename,
            .is_auto_worklet = is_auto_worklet,
        })) |replacement| {
            return replacement;
        }

        return result;
    }

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    // abstract 프로퍼티 (flags bit5=0x20) 및 declare 필드 (flags bit6=0x40)는
    // 런타임에 존재하면 안 되므로 완전히 제거.
    // declare 필드가 남으면 undefined로 초기화되어 의미가 바뀜.
    pub fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 2);
        // abstract(0x20), declare(0x40), Flow variance(0x80)는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0xE0) != 0) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
        // property_definition에서는 제거한다.
        const new_decos = if (self.options.experimental_decorators)
            NodeList{ .start = 0, .len = 0 }
        else
            try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = self.readU32(e, 4) });
        return self.addExtraNode(.property_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    // accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
    pub fn visitAccessorProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 2);
        // declare accessor는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0x40) != 0) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = self.readU32(e, 4) });
        return self.addExtraNode(.accessor_property, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    /// object_property: binary = { left=key, right=value, flags }
    fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015: shorthand property 확장 ({ x } → { x: x })
        if (self.options.unsupported.object_extensions and node.data.binary.right.isNone()) {
            return es2015_shorthand.ES2015Shorthand(Transformer).expandShorthand(self, node);
        }
        // non-computed key(identifier, string, numeric)는 property 이름이므로
        // block scoping rename 등 변수 치환을 적용하면 안 됨. copyNodeDirect 사용.
        // symbol_id는 항상 전파: shorthand({ x })에서 codegen이 rename을
        // 감지하여 { x: x$1 }로 확장하는 데 필요. non-shorthand/literal key는
        // codegen이 writeSpan으로 출력하므로 symbol_id가 있어도 무시됨.
        const key_idx = node.data.binary.left;
        const new_key = if (!key_idx.isNone() and self.ast.getNode(key_idx).tag != .computed_property_key)
            try self.copyNodeDirect(self.ast.getNode(key_idx))
        else
            try self.visitNode(key_idx);
        self.propagateSymbolId(key_idx, new_key);
        const new_value = try self.visitNode(node.data.binary.right);
        return self.ast.addNode(.{
            .tag = .object_property,
            .span = node.span,
            .data = .{ .binary = .{
                .left = new_key,
                .right = new_value,
                .flags = node.data.binary.flags,
            } },
        });
    }

    /// formal_parameter:
    ///   extra = [pattern, type_ann, default, flags, deco_start, deco_len]
    /// flags: parameter property modifier (public=0x01, private=0x02, protected=0x04, readonly=0x08, override=0x10)
    /// parameter property (flags!=0)는 visitFunction/visitMethodDefinition에서 직접 처리하지만,
    /// 다른 경로에서 도달할 수 있으므로 방어적으로 처리.
    fn visitFormalParameter(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 3);
        // parameter property: modifier 제거하고 내부 패턴만 반환
        if (flags != 0) {
            return self.visitNode(self.readNodeIdx(e, 0));
        }
        const new_pattern = try self.visitNode(self.readNodeIdx(e, 0));
        const new_default = try self.visitNode(self.readNodeIdx(e, 2));
        const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, 4), .len = self.readU32(e, 5) });
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.formal_parameter, node.span, &.{
            @intFromEnum(new_pattern), none,            @intFromEnum(new_default), // type_ann 제거
            0,                         new_decos.start, new_decos.len,
        });
    }

    fn visitImportDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);

        // Unused import 제거: 모든 specifier의 reference_count가 0이면 import 전체를 제거.
        // side-effect import는 specifier가 없으므로 제거 불가.
        if (self.symbols.len > 0 and self.symbol_ids.items.len > 0 and x.specs_len > 0) {
            if (self.areAllSpecifiersUnused(x.specs_start, x.specs_len)) return .none;
        }

        const new_specs = try self.visitExtraList(.{ .start = x.specs_start, .len = x.specs_len });
        const new_source = try self.visitNode(x.source);
        // phase / attributes는 metadata — transform 대상 아님, 그대로 통과.
        return self.addExtraNode(.import_declaration, node.span, &.{
            new_specs.start,       new_specs.len, @intFromEnum(new_source),
            @intFromEnum(x.phase), x.attrs_start, x.attrs_len,
        });
    }

    /// import의 모든 specifier가 미사용인지 확인한다.
    /// type-only specifier(이미 스트리핑됨)와 reference_count==0인 specifier만 있으면 true.
    fn areAllSpecifiersUnused(self: *Transformer, specs_start: u32, specs_len: u32) bool {
        var i: u32 = 0;
        while (i < specs_len) : (i += 1) {
            const spec_idx_raw = self.ast.extra_data.items[specs_start + i];
            const spec_idx: NodeIndex = @enumFromInt(spec_idx_raw);
            if (spec_idx.isNone()) continue;
            const spec_node = self.ast.getNode(spec_idx);

            // type-only specifier (flags & 1 != 0) → 이미 스트리핑됨, 무시
            if (spec_node.tag == .import_specifier and spec_node.data.binary.flags & 1 != 0) continue;
            if (spec_node.tag == .export_specifier) continue; // 방어적: export specifier는 여기 없지만

            // 심볼 ID를 찾을 노드 인덱스 결정
            const sym_node_idx: u32 = switch (spec_node.tag) {
                // import_specifier: binary.right가 local name 노드
                .import_specifier => blk: {
                    const local_idx = spec_node.data.binary.right;
                    break :blk if (!local_idx.isNone()) @intFromEnum(local_idx) else @intFromEnum(spec_idx);
                },
                // import_default_specifier, import_namespace_specifier: spec 노드 자체가 심볼
                else => @intFromEnum(spec_idx),
            };

            // symbol_ids에서 심볼 ID 조회
            if (sym_node_idx < self.symbol_ids.items.len) {
                if (self.symbol_ids.items[sym_node_idx]) |sym_id| {
                    if (sym_id < self.symbols.len) {
                        if (self.symbols[sym_id].reference_count > 0) return false;
                        continue; // 미사용 — 다음 specifier 확인
                    }
                }
            }
            // symbol_id를 찾지 못하면 보수적으로 유지 (사용 중으로 간주)
            return false;
        }
        return true;
    }

    /// export_named_declaration: extra_data = [declaration, specifiers_start, specifiers_len, source]
    fn visitExportNamedDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_decl = try self.visitNode(self.readNodeIdx(e, 0));
        const new_specs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        const new_source = try self.visitNode(self.readNodeIdx(e, 3));
        // export interface/type alias 등 타입 선언만 있으면 빈 export {} 제거
        // export { type Foo } from './a' 같은 re-export는 source가 있으므로 유지
        if (new_decl.isNone() and new_specs.len == 0 and new_source.isNone()) {
            return NodeIndex.none;
        }
        return self.addExtraNode(.export_named_declaration, node.span, &.{
            @intFromEnum(new_decl), new_specs.start, new_specs.len, @intFromEnum(new_source),
        });
    }

    // ================================================================
    // Comptime 헬퍼 — TS 타입 전용 노드 판별 (D042)
    // ================================================================

    /// TS 타입 전용 노드인지 판별한다 (comptime 평가).
    ///
    /// 이 함수는 컴파일 타임에 평가되므로 런타임 비용이 0이다.
    /// tag의 정수 값 범위로 판별하지 않고 명시적으로 나열한다.
    /// 이유: enum 값 순서가 바뀌어도 안전하게 동작하도록.
    pub fn isTypeOnlyNode(tag: Tag) bool {
        return switch (tag) {
            // TS 타입 키워드 (14개)
            .ts_any_keyword,
            .ts_string_keyword,
            .ts_boolean_keyword,
            .ts_number_keyword,
            .ts_never_keyword,
            .ts_unknown_keyword,
            .ts_null_keyword,
            .ts_undefined_keyword,
            .ts_void_keyword,
            .ts_symbol_keyword,
            .ts_object_keyword,
            .ts_bigint_keyword,
            .ts_this_type,
            .ts_intrinsic_keyword,
            // TS 타입 구문 (23개)
            .ts_type_reference,
            .ts_qualified_name,
            .ts_array_type,
            .ts_tuple_type,
            .ts_named_tuple_member,
            .ts_union_type,
            .ts_intersection_type,
            .ts_conditional_type,
            .ts_type_operator,
            .ts_optional_type,
            .ts_rest_type,
            .ts_indexed_access_type,
            .ts_type_literal,
            .ts_function_type,
            .ts_constructor_type,
            .ts_mapped_type,
            .ts_template_literal_type,
            .ts_infer_type,
            .ts_parenthesized_type,
            .ts_import_type,
            .ts_type_query,
            .ts_literal_type,
            .ts_type_predicate,
            // TS/Flow 선언 (통째로 삭제) — isTypeOnlyDeclaration() 대상 포함
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_interface_body,
            .ts_property_signature,
            .ts_method_signature,
            .ts_call_signature,
            .ts_construct_signature,
            .ts_index_signature,
            .ts_getter_signature,
            .ts_setter_signature,
            // TS 타입 파라미터/this/implements
            .ts_type_parameter,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            .ts_this_parameter,
            .ts_class_implements,
            // namespace는 런타임 코드 생성 → visitNode에서 별도 처리
            // ts_namespace_export_declaration은 타입 전용 (export as namespace X)
            .ts_namespace_export_declaration,
            // TS import/export 특수 형태
            // ts_import_equals_declaration은 런타임 코드 생성 — visitNode에서 별도 처리
            .ts_external_module_reference,
            .ts_export_assignment,
            // enum은 타입 전용이 아님 — 런타임 코드 생성이 필요
            // visitNode의 switch에서 별도 처리
            // Flow 타입 (flow.zig에서 생성)
            .flow_any_keyword,
            .flow_string_keyword,
            .flow_boolean_keyword,
            .flow_number_keyword,
            .flow_never_keyword,
            .flow_null_keyword,
            .flow_void_keyword,
            .flow_symbol_keyword,
            .flow_bigint_keyword,
            .flow_this_type,
            .flow_mixed_keyword,
            .flow_empty_keyword,
            .flow_type_reference,
            .flow_qualified_name,
            .flow_array_type,
            .flow_tuple_type,
            .flow_union_type,
            .flow_intersection_type,
            .flow_function_type,
            .flow_parenthesized_type,
            .flow_literal_type,
            .flow_type_query,
            .flow_nullable_type,
            .flow_type_parameter,
            .flow_type_parameter_declaration,
            .flow_type_parameter_instantiation,
            .flow_this_parameter,
            .flow_type_alias_declaration,
            .flow_opaque_type,
            .flow_interface_declaration,
            .flow_exact_object_type,
            => true,
            else => false,
        };
    }

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
    // Auto-workletization helpers
    // ================================================================

    const AutoWorkletCallee = @import("../bundler/plugin.zig").AutoWorkletCallee;

    /// call_expression의 callee가 auto-workletization 대상 함수인지 매칭.
    /// identifier_reference(직접 호출) 또는 static_member_expression(메서드 호출) 지원.
    fn matchAutoWorkletCallee(self: *Transformer, callee_idx: NodeIndex) ?AutoWorkletCallee {
        if (self.options.plugins.len == 0) return null;
        if (callee_idx.isNone()) return null;

        const callee_node = self.ast.getNode(callee_idx);
        // 합성된 노드(es2018_for_await 등이 만든 __asyncValues 등)는 span 이 string_table 인코딩.
        // self.ast.source[..] 직접 접근 시 STRING_TABLE_BIT 가 set 되어 OOB → SIGBUS (#1404).
        // self.ast.getText(span) 가 두 경로 모두 처리.
        const callee_name: []const u8 = switch (callee_node.tag) {
            // scheduleOnUI(...) 형태
            .identifier_reference => self.ast.getText(callee_node.span),
            // obj.onBegin(...) 형태 — 프로퍼티 이름만 추출
            .static_member_expression => blk: {
                const me = callee_node.data.extra;
                if (me + 1 >= self.ast.extra_data.items.len) break :blk "";
                const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
                if (prop_idx.isNone()) break :blk "";
                const prop = self.ast.getNode(prop_idx);
                break :blk self.ast.getText(prop.span);
            },
            else => return null,
        };
        if (callee_name.len == 0) return null;

        const is_method = callee_node.tag == .static_member_expression;
        for (self.options.plugins) |p| {
            for (p.autoWorkletCallees) |entry| {
                if (entry.is_method != is_method) continue;
                if (!std.mem.eql(u8, entry.name, callee_name)) continue;
                // receiver_kind 검증 — layout_animation은 수신자가 알려진 LA 클래스여야 함
                if (entry.receiver_kind == .layout_animation) {
                    const me = callee_node.data.extra;
                    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
                    if (!self.isLayoutAnimationReceiver(obj_idx)) continue;
                }
                // receiver_kind 검증 — gesture_object는 수신자가 `Gesture.Foo()` 체인이어야 함.
                if (entry.receiver_kind == .gesture_object) {
                    const me = callee_node.data.extra;
                    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
                    if (!self.isGestureObjectReceiver(obj_idx)) continue;
                }
                return entry;
            }
        }
        return null;
    }

    /// Layout Animation receiver 여부 판정.
    /// Babel plugin의 isLayoutAnimationsChainableOrNewOperator 포팅:
    ///  - identifier가 알려진 LA 클래스명이면 true
    ///  - new LAClass(...)면 true
    ///  - LAClass.chainMethod()로 체이닝된 경우 재귀적으로 true (chainMethod는 build/duration 등)
    fn isLayoutAnimationReceiver(self: *Transformer, node_idx: NodeIndex) bool {
        if (node_idx.isNone()) return false;
        const node = self.ast.getNode(node_idx);
        const wp = @import("plugins/worklet_plugin.zig");

        // Identifier — 클래스 이름 직접 매칭
        if (node.tag == .identifier_reference) {
            const name = self.ast.getText(node.span);
            for (wp.LAYOUT_ANIMATION_CLASSES) |c| {
                if (std.mem.eql(u8, c, name)) return true;
            }
            return false;
        }

        // new LAClass(...)
        if (node.tag == .new_expression) {
            const ne = node.data.extra;
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ne]);
            return self.isLayoutAnimationReceiver(callee_idx);
        }

        // LAChain.chainMethod() — 체이닝 메서드 호출
        if (node.tag == .call_expression) {
            const ce = node.data.extra;
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
            const callee_node = self.ast.getNode(callee_idx);
            if (callee_node.tag != .static_member_expression) return false;
            const me = callee_node.data.extra;
            const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
            if (prop_idx.isNone()) return false;
            const prop = self.ast.getNode(prop_idx);
            const prop_name = self.ast.getText(prop.span);
            var chainable = false;
            for (wp.LAYOUT_ANIMATION_CHAINABLE_METHODS) |m| {
                if (std.mem.eql(u8, m, prop_name)) {
                    chainable = true;
                    break;
                }
            }
            if (!chainable) return false;
            const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
            return self.isLayoutAnimationReceiver(obj_idx);
        }

        return false;
    }

    /// Gesture object receiver 여부 판정.
    /// Babel plugin의 containsGestureObject 포팅:
    ///  - `Gesture.Foo()` 직접 (Foo는 GESTURE_OBJECT_NAMES 중 하나) → true
    ///  - `X.method()` 체인이면 X로 재귀
    ///  - 그 외 → false
    fn isGestureObjectReceiver(self: *Transformer, node_idx: NodeIndex) bool {
        if (node_idx.isNone()) return false;
        const node = self.ast.getNode(node_idx);
        if (node.tag != .call_expression) return false;

        const ce = node.data.extra;
        const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
        const callee = self.ast.getNode(callee_idx);
        if (callee.tag != .static_member_expression) return false;

        const me = callee.data.extra;
        const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
        const obj_node = self.ast.getNode(obj_idx);

        // 직접: `Gesture.Foo()` — object가 `Gesture` identifier + property가 gesture object 이름
        if (obj_node.tag == .identifier_reference) {
            const obj_name = self.ast.getText(obj_node.span);
            if (!std.mem.eql(u8, obj_name, "Gesture")) return false;
            const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
            if (prop_idx.isNone()) return false;
            const prop = self.ast.getNode(prop_idx);
            const prop_name = self.ast.getText(prop.span);
            const wp = @import("plugins/worklet_plugin.zig");
            for (wp.GESTURE_OBJECT_NAMES) |g| {
                if (std.mem.eql(u8, g, prop_name)) return true;
            }
            return false;
        }

        // 체인: `X.method().onFoo(...)` — object(= `X.method()`) 재귀
        return self.isGestureObjectReceiver(obj_idx);
    }

    /// Object hook의 object literal 인자를 방문하며, 각 property 값(function/arrow/method)에
    /// auto_next 플래그를 전파하여 worklet으로 변환한다.
    /// Metro+Babel의 `processWorkletizableObject` 대응 (reanimated 'object hooks').
    fn visitObjectExpressionAutoWorklet(self: *Transformer, obj_idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(obj_idx);
        if (node.tag != .object_expression) return self.visitNode(obj_idx);
        const list = node.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const raw = self.ast.extra_data.items[list.start + i];
            const prop_idx: NodeIndex = @enumFromInt(raw);
            if (prop_idx.isNone()) continue;
            const prop = self.ast.getNode(prop_idx);

            switch (prop.tag) {
                // shorthand method: `{ onScroll(e) { ... } }` — method_definition 자체가 worklet
                .method_definition => {
                    const saved = self.plugins.worklet.auto_next;
                    self.plugins.worklet.auto_next = true;
                    const new_prop = try self.visitNode(prop_idx);
                    self.plugins.worklet.auto_next = saved;
                    if (!new_prop.isNone()) try self.scratch.append(self.allocator, new_prop);
                },
                // `{ onScroll: (e) => {...} }` — value가 function/arrow면 workletize
                .object_property => {
                    const value_idx = prop.data.binary.right;
                    const is_fn = blk: {
                        if (value_idx.isNone()) break :blk false;
                        const v = self.ast.getNode(value_idx);
                        break :blk v.tag == .function_expression or v.tag == .arrow_function_expression;
                    };
                    if (is_fn) {
                        const saved = self.plugins.worklet.auto_next;
                        self.plugins.worklet.auto_next = true;
                        const new_value = try self.visitNode(value_idx);
                        self.plugins.worklet.auto_next = saved;
                        const key_idx = prop.data.binary.left;
                        const new_key = if (!key_idx.isNone() and self.ast.getNode(key_idx).tag != .computed_property_key)
                            try self.copyNodeDirect(self.ast.getNode(key_idx))
                        else
                            try self.visitNode(key_idx);
                        const new_prop = try self.ast.addNode(.{
                            .tag = .object_property,
                            .span = prop.span,
                            .data = .{ .binary = .{
                                .left = new_key,
                                .right = new_value,
                                .flags = prop.data.binary.flags,
                            } },
                        });
                        try self.scratch.append(self.allocator, new_prop);
                    } else {
                        const new_prop = try self.visitNode(prop_idx);
                        if (!new_prop.isNone()) try self.scratch.append(self.allocator, new_prop);
                    }
                },
                else => {
                    const new_prop = try self.visitNode(prop_idx);
                    if (!new_prop.isNone()) try self.scratch.append(self.allocator, new_prop);
                },
            }
        }

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = .object_expression,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// auto-workletization이 필요한 call expression의 인자를 개별 방문.
    /// 대상 인자 위치의 function/arrow 방문 전에 plugins.worklet.auto_next 플래그를 설정.
    fn visitCallArgsWithAutoWorklet(self: *Transformer, args_start: u32, args_len: u32, callee: AutoWorkletCallee) Error!NodeList {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const pending_top = self.pending_nodes.items.len;
        defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

        const trailing_top = self.trailing_nodes.items.len;
        defer self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

        var i: u32 = 0;
        while (i < args_len) : (i += 1) {
            const raw_idx = self.ast.extra_data.items[args_start + i];
            const arg_idx: NodeIndex = @enumFromInt(raw_idx);

            // 이 인자가 auto-worklet 대상인지 확인
            const should_auto = blk: {
                for (callee.arg_indices) |idx| {
                    if (idx == 0xFF) break;
                    if (idx == @as(u8, @intCast(i))) break :blk true;
                }
                break :blk false;
            };

            // save/restore: 재귀적 visitNode 내부의 중첩 call_expression이
            // plugins.worklet.auto_next를 오염시키지 않도록 보호.
            const saved_auto = self.plugins.worklet.auto_next;
            var object_hook_arg = false;
            if (should_auto and !arg_idx.isNone()) {
                const arg_node = self.ast.getNode(arg_idx);
                if (arg_node.tag == .function_expression or
                    arg_node.tag == .arrow_function_expression)
                {
                    self.plugins.worklet.auto_next = true;
                } else if (callee.accept_object and arg_node.tag == .object_expression) {
                    object_hook_arg = true;
                }
            }

            const new_child = if (object_hook_arg)
                try self.visitObjectExpressionAutoWorklet(arg_idx)
            else
                try self.visitNode(arg_idx);
            self.plugins.worklet.auto_next = saved_auto;

            // pending_nodes 드레인
            if (self.pending_nodes.items.len > pending_top) {
                try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                self.pending_nodes.shrinkRetainingCapacity(pending_top);
            }

            if (!new_child.isNone()) {
                try self.scratch.append(self.allocator, new_child);
            }

            // trailing_nodes 드레인
            if (self.trailing_nodes.items.len > trailing_top) {
                try self.scratch.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
                self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
            }
        }

        return self.ast.addNodeList(self.scratch.items[scratch_top..]);
    }

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
