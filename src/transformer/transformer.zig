//! ZTS Transformer — 핵심 변환 엔진
//!
//! 원본 AST를 읽고 새 AST를 빌드한다.
//!
//! 작동 원리:
//!   1. 원본 AST(old_ast)의 루트 노드부터 시작
//!   2. 각 노드의 tag를 switch로 분기
//!   3. TS 전용 노드는 스킵(.none 반환) 또는 변환
//!   4. JS 노드는 자식을 재귀 방문 후 새 AST(new_ast)에 복사
//!
//! 메모리:
//!   - new_ast는 별도 allocator로 생성 (D041)
//!   - 변환 완료 후 old_ast는 해제 가능
//!   - new_ast의 source는 old_ast와 같은 소스를 참조 (zero-copy)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const Data = Node.Data;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
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
const es2015_params = @import("es2015_params.zig");
const es2015_spread = @import("es2015_spread.zig");
const es2015_arrow = @import("es2015_arrow.zig");
const es2015_for_of = @import("es2015_for_of.zig");
const es2015_destructuring = @import("es2015_destructuring.zig");
const es2015_block_scoping = @import("es2015_block_scoping.zig");
const es2015_class = @import("es2015_class.zig");
const es2015_generator = @import("es2015_generator.zig");
const es_helpers = @import("es_helpers.zig");
const Symbol = @import("../semantic/symbol.zig").Symbol;

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
    /// ES 타겟 레벨. 이 버전 이하의 문법을 하위 호환 코드로 변환.
    /// esnext(기본값)이면 변환 없음.
    target: Target = .esnext,

    pub const Target = enum {
        es5,
        es2015,
        es2016,
        es2017,
        es2018,
        es2019,
        es2020,
        es2021,
        es2022,
        es2024,
        esnext,

        /// 해당 타겟에서 ES2015 변환이 필요한지 (target < es2015, 즉 es5).
        /// arrow, template literal, class, destructuring, for-of, let/const,
        /// default/rest params, spread, computed property, shorthand, generator.
        pub fn needsES2015(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2015);
        }
        /// 해당 타겟에서 exponentiation operator (**) 변환이 필요한지
        pub fn needsExponentiation(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2016);
        }
        /// 해당 타겟에서 nullish coalescing (??) 변환이 필요한지
        pub fn needsNullishCoalescing(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2020);
        }
        /// 해당 타겟에서 optional chaining (?.) 변환이 필요한지
        pub fn needsOptionalChaining(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2020);
        }
        /// 해당 타겟에서 logical assignment (??=, ||=, &&=) 변환이 필요한지
        pub fn needsLogicalAssignment(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2021);
        }
        /// 해당 타겟에서 class static block 변환이 필요한지
        pub fn needsClassStaticBlock(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2022);
        }
        /// 해당 타겟에서 optional catch binding 변환이 필요한지
        pub fn needsOptionalCatchBinding(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2019);
        }
        /// 해당 타겟에서 async/await 변환이 필요한지
        pub fn needsAsyncAwait(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2017);
        }
        /// 해당 타겟에서 object spread 변환이 필요한지
        pub fn needsObjectSpread(self: Target) bool {
            return @intFromEnum(self) < @intFromEnum(Target.es2018);
        }
    };
};

/// 런타임 헬퍼 사용 추적 비트맵.
/// transformer가 각 변환 시 해당 비트를 설정하고,
/// 번들러 emitter가 필요한 헬퍼만 출력에 주입한다.
pub const RuntimeHelpers = packed struct(u16) {
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
    _padding: u8 = 0,
};

/// AST-to-AST 변환기.
///
/// 사용법:
/// ```zig
/// var t = Transformer.init(allocator, &old_ast, .{});
/// const new_root = try t.transform();
/// // t.new_ast 에 변환된 AST가 들어있다
/// ```
pub const Transformer = struct {
    /// 원본 AST (읽기 전용)
    old_ast: *const Ast,

    /// 변환 결과를 저장할 새 AST
    new_ast: Ast,

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

    /// 원본 AST의 symbol_ids (semantic analyzer가 생성). null이면 전파 안 함.
    old_symbol_ids: []const ?u32 = &.{},
    /// 새 AST 기준 symbol_ids. new_ast에 노드 추가 시 자동 전파.
    new_symbol_ids: std.ArrayList(?u32) = .empty,

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

    /// ES2015 class extends: 현재 클래스의 super class 이름 Span.
    /// class body 방문 중 설정되어, super() → Parent.call(this),
    /// super.method() → Parent.prototype.method.call(this) 변환에 사용.
    current_super_class: ?Span = null,

    /// ES2015 generator: labeled break/continue를 위한 label 스택.
    /// labeled_statement 진입 시 push, 퇴장 시 pop.
    generator_label_stack: std.ArrayList(GeneratorLabelEntry) = .empty,

    /// ES2015 generator: for loop의 update label (labeled continue 대상).
    /// collectForOperations에서 update nop 추가 직전에 설정.
    generator_for_update_label: ?u32 = null,

    /// ES2015 class private fields: "#name" → "_name" 매핑.
    /// class body 방문 중 설정되어, this.#x → _x.get(this), this.#x = v → _x.set(this, v) 변환에 사용.
    current_private_fields: []const PrivateFieldMapping = &.{},

    /// 현재 함수 스코프에서 arrow body가 this를 사용하여 var _this = this 삽입이 필요한지.
    needs_this_var: bool = false,

    /// 현재 함수 스코프에서 arrow body가 arguments를 사용하여 var _arguments = arguments 삽입이 필요한지.
    needs_arguments_var: bool = false,

    /// 런타임 헬퍼 사용 추적.
    /// 각 변환이 헬퍼를 사용하면 해당 비트를 설정한다.
    /// 번들러 emitter가 이 비트맵을 읽어 필요한 헬퍼만 출력에 주입한다.
    runtime_helpers: RuntimeHelpers = .{},

    /// React Fast Refresh: 감지된 컴포넌트 등록 목록.
    /// transform 완료 후 프로그램 끝에 $RefreshReg$ 호출로 주입.
    refresh_registrations: std.ArrayList(RefreshRegistration) = .empty,

    /// React Fast Refresh: Hook 시그니처 등록 목록.
    /// 프로그램 끝에 var _s = $RefreshSig$(); + _s(Component, "sig") 호출로 주입.
    refresh_signatures: std.ArrayList(RefreshSignature) = .empty,

    pub const GeneratorLabelEntry = struct {
        name: []const u8,
        break_label: u32,
        continue_label: ?u32,
    };

    pub const PrivateFieldMapping = struct {
        original_name: []const u8, // "#x"
        var_name: []const u8, // "_x"
    };

    const RefreshRegistration = struct {
        /// _c / _c2 핸들 변수의 string_table Span (재사용)
        handle_span: Span,
        /// 컴포넌트 이름 (문자열)
        name: []const u8,
    };

    const RefreshSignature = struct {
        /// _s / _s2 핸들 변수의 string_table Span
        handle_span: Span,
        /// 컴포넌트 이름 (문자열)
        component_name: []const u8,
        /// Hook 시그니처 문자열 ("useState{[foo, setFoo](0)}\nuseEffect{}")
        signature: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, old_ast: *const Ast, options: TransformOptions) Transformer {
        // experimentalDecorators → useDefineForClassFields=false 강제
        // TypeScript/esbuild 동일: decorator가 class field의 setter를 인터셉트하려면
        // assign semantics (this.x = v)가 필요. define semantics는 setter를 무시.
        var opts = options;
        if (opts.experimental_decorators) opts.use_define_for_class_fields = false;

        return .{
            .old_ast = old_ast,
            .new_ast = Ast.init(allocator, old_ast.source),
            .options = opts,
            .allocator = allocator,
            .scratch = .empty,
            .pending_nodes = .empty,
        };
    }

    pub fn deinit(self: *Transformer) void {
        self.new_ast.deinit();
        self.scratch.deinit(self.allocator);
        self.pending_nodes.deinit(self.allocator);
        if (self.define_spans.len > 0) self.allocator.free(self.define_spans);
        self.refresh_registrations.deinit(self.allocator);
        for (self.refresh_signatures.items) |s| self.allocator.free(s.signature);
        self.refresh_signatures.deinit(self.allocator);
        self.generator_label_stack.deinit(self.allocator);
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 변환을 실행한다. 원본 AST의 마지막 노드(program)부터 시작.
    ///
    /// 반환값: 새 AST에서의 루트 NodeIndex.
    /// 변환된 AST는 self.new_ast에 저장된다.
    pub fn transform(self: *Transformer) Error!NodeIndex {
        // define value를 미리 string_table에 저장하여 tryDefineReplace에서 중복 addString 방지
        if (self.options.define.len > 0) {
            self.define_spans = self.allocator.alloc(Span, self.options.define.len) catch return Error.OutOfMemory;
            for (self.options.define, 0..) |entry, i| {
                self.define_spans[i] = self.new_ast.addString(entry.value) catch return Error.OutOfMemory;
            }
        }

        // 파서는 parse() 끝에 program 노드를 추가하므로 마지막 노드가 루트
        const root_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(self.old_ast.nodes.items.len - 1)));
        const saved_temp_counter = self.temp_var_counter;
        var root = try self.visitNode(root_idx);

        // top-level 임시 변수 호이스팅: var _a, _b, ... 선언을 program 앞에 삽입
        if (self.temp_var_counter > saved_temp_counter and !root.isNone()) {
            root = try self.hoistTempVars(root, saved_temp_counter, self.old_ast.getNode(root_idx).span);
        }

        // React Fast Refresh: 컴포넌트 등록 + Hook 시그니처 코드를 프로그램 끝에 추가
        if (self.options.react_refresh and
            (self.refresh_registrations.items.len > 0 or self.refresh_signatures.items.len > 0))
        {
            return try self.appendRefreshRegistrations(root);
        }

        return root;
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
        const node = self.old_ast.getNode(idx);

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

        // --------------------------------------------------------
        // 3단계: define 글로벌 치환
        // --------------------------------------------------------
        if (self.options.define.len > 0) {
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
            => self.visitTsExpression(node),

            // === 리스트 노드: 자식을 하나씩 방문하며 복사 ===
            .program,
            .block_statement,
            .sequence_expression,
            .class_body,
            .formal_parameters,
            // JSX — fragment는 .list, element/opening_element는 .extra
            .jsx_fragment,
            .function_body,
            => self.visitListNode(node),

            .template_literal => {
                if (self.options.target.needsES2015()) {
                    return es2015_template.ES2015Template(Transformer).lowerTemplateLiteral(self, node);
                }
                // no-substitution template (data.none == 0)은 리프 노드 — visitListNode으로 처리하면
                // data.list = {start: X, len: 0}이 되어 codegen의 data.none == 0 체크가 깨짐
                if (node.data.none == 0) return self.copyNodeDirect(node);
                return self.visitListNode(node);
            },

            // array_expression: spread(ES2015) 다운레벨링
            .array_expression => {
                if (self.options.target.needsES2015()) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadInArray(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadArray(self, node);
                    }
                }
                return self.visitListNode(node);
            },

            // object_expression: spread(ES2018) 또는 computed property(ES2015) 다운레벨링
            .object_expression => {
                if (self.options.target.needsObjectSpread()) {
                    if (es2018.ES2018(Transformer).hasSpreadProperty(self, node)) {
                        return es2018.ES2018(Transformer).lowerObjectSpread(self, node);
                    }
                }
                if (self.options.target.needsES2015()) {
                    if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, node)) {
                        return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, node);
                    }
                }
                return self.visitListNode(node);
            },

            // JSX element/opening_element: .extra 형식 (tag, attrs, children)
            .jsx_element => self.visitJSXElement(node),
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
                    const inner_tag = self.old_ast.getNode(inner).tag;
                    if (inner_tag == .ts_as_expression or
                        inner_tag == .ts_satisfies_expression or
                        inner_tag == .ts_non_null_expression or
                        inner_tag == .ts_type_assertion or
                        inner_tag == .flow_as_expression)
                    {
                        return self.visitNode(inner);
                    }
                }
                return self.visitUnaryNode(node);
            },
            .await_expression => {
                if (self.options.target.needsAsyncAwait()) {
                    return es2017_mod.ES2017(Transformer).lowerAwaitExpression(self, node);
                }
                return self.visitUnaryNode(node);
            },
            .yield_expression,
            .rest_element,
            .decorator,
            // JSX
            .jsx_spread_attribute,
            .jsx_expression_container,
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
                if (self.options.target.needsExponentiation() and node.tag == .binary_expression) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .star2) {
                        return es2016.ES2016(Transformer).lowerExponentiation(self, node);
                    }
                }
                // ES 다운레벨링: ?? → ternary
                if (self.options.target.needsNullishCoalescing() and node.tag == .logical_expression) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .question2) {
                        return es2020.ES2020(Transformer).lowerNullishCoalescing(self, node);
                    }
                }
                return self.visitBinaryNode(node);
            },
            .assignment_expression => {
                // ES 다운레벨링: **= → a = Math.pow(a, b) (es2016)
                if (self.options.target.needsExponentiation()) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .star2_eq) {
                        return es2016.ES2016(Transformer).lowerExponentiationAssignment(self, node);
                    }
                }
                // ES 다운레벨링: ??=, ||=, &&= (es2021)
                if (self.options.target.needsLogicalAssignment()) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .question2_eq) {
                        return es2021.ES2021(Transformer).lowerNullishAssignment(self, node);
                    } else if (op == .pipe2_eq) {
                        return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .pipe2);
                    } else if (op == .amp2_eq) {
                        return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .amp2);
                    }
                }
                // ES2015: this.#x = v → _x.set(this, v)
                if (self.options.target.needsES2015() and self.current_private_fields.len > 0) {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.old_ast.getNode(left_idx);
                        if (left_node.tag == .private_field_expression) {
                            if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldSet(self, node)) |result| {
                                return result;
                            }
                        }
                    }
                }
                // ES2015: assignment destructuring → sequence expression
                if (self.options.target.needsES2015()) {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.old_ast.getNode(left_idx);
                        if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                            return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignment(self, node);
                        }
                    }
                }
                return self.visitBinaryNode(node);
            },
            .while_statement,
            .do_while_statement,
            .labeled_statement,
            .with_statement,
            // JSX
            .jsx_attribute,
            .jsx_namespaced_name,
            .jsx_member_expression,
            => self.visitBinaryNode(node),

            // === member expression: extra = [object, property, flags] ===
            .static_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.target.needsOptionalChaining()) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super.method → Parent.prototype.method
                if (self.options.target.needsES2015() and self.current_super_class != null) {
                    if (es2015_class.ES2015Class(Transformer).isSuperMember(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMember(self, node);
                    }
                }
                return self.visitMemberExpression(node);
            },
            .private_field_expression => {
                // ES2015: this.#x → _x.get(this)
                if (self.options.target.needsES2015() and self.current_private_fields.len > 0) {
                    if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldGet(self, node)) |result| {
                        return result;
                    }
                }
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.target.needsOptionalChaining()) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                return self.visitMemberExpression(node);
            },
            .computed_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.target.needsOptionalChaining()) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                return self.visitMemberExpression(node);
            },

            // === unary/update expression: extra = [operand, operator_and_flags] ===
            .unary_expression,
            .update_expression,
            => self.visitUnaryExtra(node),

            // === 삼항 노드: 자식 3개 재귀 방문 ===
            .if_statement,
            .conditional_expression,
            .for_in_statement,
            .for_await_of_statement,
            .try_statement,
            => self.visitTernaryNode(node),
            .for_of_statement => {
                if (self.options.target.needsES2015()) {
                    return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatement(self, node);
                }
                return self.visitTernaryNode(node);
            },

            // === extra 기반 노드: 별도 처리 ===
            .variable_declaration => self.visitVariableDeclaration(node),
            .variable_declarator => self.visitVariableDeclarator(node),
            .function_declaration,
            .function_expression,
            => {
                if (self.options.target.needsAsyncAwait()) {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 4 < extras.len and (extras[e + 4] & ast_mod.FunctionFlags.is_async) != 0) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncFunction(self, node);
                    }
                }
                // ES2015: generator function → 상태 머신
                if (self.options.target.needsES2015()) {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 4 < extras.len and (extras[e + 4] & ast_mod.FunctionFlags.is_generator) != 0) {
                        return es2015_generator.ES2015Generator(Transformer).lowerGeneratorFunction(self, node);
                    }
                }
                return self.visitFunction(node);
            },
            .function,
            => self.visitFunction(node),
            .arrow_function_expression => {
                if (self.options.target.needsAsyncAwait()) {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 < extras.len and (extras[e + 2] & ast_mod.ArrowFlags.is_async) != 0) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncArrow(self, node);
                    }
                }
                if (self.options.target.needsES2015()) {
                    return es2015_arrow.ES2015Arrow(Transformer).lowerArrowFunction(self, node);
                }
                return self.visitArrowFunction(node);
            },
            .class_declaration => {
                if (self.options.target.needsES2015()) {
                    return es2015_class.ES2015Class(Transformer).lowerClassDeclaration(self, node);
                }
                return self.visitClass(node);
            },
            .class_expression => {
                if (self.options.target.needsES2015()) {
                    return es2015_class.ES2015Class(Transformer).lowerClassExpression(self, node);
                }
                return self.visitClass(node);
            },
            .for_statement => self.visitForStatement(node),
            .switch_statement => self.visitSwitchStatement(node),
            .switch_case => self.visitSwitchCase(node),
            .call_expression => {
                // ES 다운레벨링: ?.() → ternary (target < es2020)
                if (self.options.target.needsOptionalChaining()) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super(args) → Parent.call(this, args)
                // ES2015: super.method(args) → Parent.prototype.method.call(this, args)
                if (self.options.target.needsES2015() and self.current_super_class != null) {
                    if (es2015_class.ES2015Class(Transformer).isSuperCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperCall(self, node);
                    }
                    if (es2015_class.ES2015Class(Transformer).isSuperMethodCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMethodCall(self, node);
                    }
                }
                // ES2015: spread in call → .apply()
                if (self.options.target.needsES2015()) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadCall(self, node);
                    }
                }
                return self.visitCallExpression(node);
            },
            .new_expression => {
                if (self.options.target.needsES2015()) {
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
            .export_default_declaration => self.visitUnaryNode(node),
            .export_all_declaration => self.visitBinaryNode(node),
            .catch_clause => {
                if (self.options.target.needsOptionalCatchBinding()) {
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
                        return self.new_ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = class_span,
                            .data = .{ .string_ref = class_span },
                        });
                    }
                }
                // ES2015 arrow this 캡처: arrow body 안의 this → _this
                if (self.options.target.needsES2015() and self.arrow_this_depth > 0) {
                    self.needs_this_var = true;
                    const this_span = try self.new_ast.addString("_this");
                    return self.new_ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = this_span,
                        .data = .{ .string_ref = this_span },
                    });
                }
                return self.copyNodeDirect(node);
            },

            .boolean_literal,
            .null_literal,
            .numeric_literal,
            .string_literal,
            .bigint_literal,
            .regexp_literal,
            => self.copyNodeDirect(node),
            .identifier_reference => {
                // ES2015 arrow arguments 캡처: arrow body 안의 arguments → _arguments
                if (self.options.target.needsES2015() and self.arrow_this_depth > 0) {
                    const text = self.old_ast.getText(node.data.string_ref);
                    if (std.mem.eql(u8, text, "arguments")) {
                        self.needs_arguments_var = true;
                        const args_span = try self.new_ast.addString("_arguments");
                        return self.new_ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = args_span,
                            .data = .{ .string_ref = args_span },
                        });
                    }
                }
                return self.copyNodeDirect(node);
            },
            .private_identifier,
            .binding_identifier,
            .empty_statement,
            .debugger_statement,
            .directive,
            .hashbang,
            .super_expression,
            .meta_property,
            .template_element,
            .elision,
            // JSX leaf
            .jsx_text,
            .jsx_empty_expression,
            .jsx_identifier,
            .jsx_closing_element,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            .assignment_target_identifier,
            => self.copyNodeDirect(node),

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
        return self.new_ast.addNode(node);
    }

    /// 클래스 이름 노드에서 Span 추출. 익명 클래스(none)면 null 반환.
    /// ES2022 static block의 this → 클래스 이름 치환에 사용.
    fn getClassNameSpan(self: *Transformer, name_idx: NodeIndex) ?Span {
        if (name_idx.isNone()) return null;
        return self.new_ast.getNode(name_idx).data.string_ref;
    }

    /// 원본 → 새 노드의 symbol_id 전파.
    fn propagateSymbolId(self: *Transformer, old_idx: NodeIndex, new_idx: NodeIndex) void {
        if (self.old_symbol_ids.len == 0) return; // 전파 비활성
        if (new_idx.isNone()) return;

        const old_i = @intFromEnum(old_idx);
        const new_i = @intFromEnum(new_idx);

        // new_symbol_ids를 new_ast 노드 수만큼 확장
        while (self.new_symbol_ids.items.len <= new_i) {
            self.new_symbol_ids.append(self.allocator, null) catch return;
        }

        if (old_i < self.old_symbol_ids.len) {
            // ts_as_expression 등 wrapper 노드가 내부 노드와 같은 new_idx를 반환하면
            // wrapper의 null symbol_id가 내부 노드의 유효한 symbol_id를 덮어쓸 수 있음.
            // 이미 유효한 symbol_id가 설정되어 있으면 null로 덮어쓰지 않음.
            if (self.old_symbol_ids[old_i] != null or self.new_symbol_ids.items[new_i] == null) {
                self.new_symbol_ids.items[new_i] = self.old_symbol_ids[old_i];
            }
        }
    }

    /// 단항 노드: operand를 재귀 방문 후 복사.
    fn visitUnaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_operand = try self.visitNode(node.data.unary.operand);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
        });
    }

    /// 이항 노드: left, right를 재귀 방문 후 복사.
    fn visitBinaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_left = try self.visitNode(node.data.binary.left);
        const new_right = try self.visitNode(node.data.binary.right);
        return self.new_ast.addNode(.{
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
        const extras = self.old_ast.extra_data.items;
        if (e + 1 >= extras.len) return NodeIndex.none;

        // private field update: this.#x++ → _x.set(this, _x.get(this) + 1)
        if (node.tag == .update_expression and self.options.target.needsES2015()) {
            const operand_idx: NodeIndex = @enumFromInt(extras[e]);
            const operand = self.old_ast.getNode(operand_idx);
            if (operand.tag == .private_field_expression) {
                const op_flags = extras[e + 1];
                if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldUpdate(self, operand, op_flags, node.span)) |result| {
                    return try result;
                }
            }
        }

        const new_operand = try self.visitNode(@enumFromInt(extras[e]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_operand), extras[e + 1] });
        return self.new_ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// tagged_template_expression: extra = [tag, template, flags]
    fn visitTaggedTemplate(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 2 >= extras.len) return NodeIndex.none;
        const new_tag = try self.visitNode(@enumFromInt(extras[e]));
        const new_tmpl = try self.visitNode(@enumFromInt(extras[e + 1]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_tag), @intFromEnum(new_tmpl), extras[e + 2] });
        return self.new_ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// member expression: extra = [object, property, flags]
    pub fn visitMemberExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 2 >= extras.len) return NodeIndex.none;
        const new_left = try self.visitNode(@enumFromInt(extras[e]));
        // computed_member: right는 임의 expression. static_member/private_field: right는 식별자 리프.
        // visitNode가 리프를 copyNodeDirect로 처리하므로 동일하게 visitNode 호출.
        const new_right = try self.visitNode(@enumFromInt(extras[e + 1]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_left), @intFromEnum(new_right), extras[e + 2] });
        return self.new_ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// 삼항 노드: a, b, c를 재귀 방문 후 복사.
    fn visitTernaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_a = try self.visitNode(node.data.ternary.a);
        const new_b = try self.visitNode(node.data.ternary.b);
        const new_c = try self.visitNode(node.data.ternary.c);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
        });
    }

    /// 리스트 노드: 각 자식을 방문, .none이 아닌 것만 새 리스트로 수집.
    fn visitListNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_list = try self.visitExtraList(node.data.list.start, node.data.list.len);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// extra_data의 노드 리스트를 방문하여 새 AST에 복사.
    /// .none이 된 자식은 자동으로 제거된다.
    /// scratch 버퍼를 사용하며, 중첩 호출에 안전 (save/restore 패턴).
    ///
    /// pending_nodes 지원: 각 자식 방문 후 pending_nodes에 쌓인 노드를
    /// 해당 자식 앞에 삽입한다. 이를 통해 1→N 노드 확장이 가능하다.
    /// 예: enum 변환 시 visitNode가 IIFE를 반환하면서 `var Color;`을
    ///     pending_nodes에 push → 리스트에 `var Color;` + IIFE 순서로 삽입.
    pub fn visitExtraList(self: *Transformer, start: u32, len: u32) Error!NodeList {
        const old_indices = self.old_ast.extra_data.items[start .. start + len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // pending_nodes save/restore: 중첩 visitExtraList 호출에 안전.
        // 내부 리스트의 pending_nodes가 외부 리스트로 누출되지 않도록 한다.
        const pending_top = self.pending_nodes.items.len;
        defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

        for (old_indices) |raw_idx| {
            const new_child = try self.visitNode(@enumFromInt(raw_idx));

            // pending_nodes 드레인: visitNode가 추가한 보류 노드를 먼저 삽입
            if (self.pending_nodes.items.len > pending_top) {
                try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                self.pending_nodes.shrinkRetainingCapacity(pending_top);
            }

            if (!new_child.isNone()) {
                try self.scratch.append(self.allocator, new_child);
            }
        }

        return self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
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
            const op_node = self.old_ast.getNode(operand);
            if (op_node.tag == .parenthesized_expression and !op_node.data.unary.operand.isNone()) {
                const inner = self.old_ast.getNode(op_node.data.unary.operand);
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
        const expr = self.old_ast.getNode(expr_idx);
        if (expr.tag != .call_expression) return false;

        // call_expression: extra = [callee, args_start, args_len, flags]
        const ce = expr.data.extra;
        if (ce >= self.old_ast.extra_data.items.len) return false;
        const callee_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[ce]);
        if (callee_idx.isNone()) return false;
        const callee = self.old_ast.getNode(callee_idx);

        // callee가 static_member_expression (console.log)이어야 함
        if (callee.tag != .static_member_expression) return false;

        // left가 identifier "console" — extra = [object, property, flags]
        const me = callee.data.extra;
        if (me >= self.old_ast.extra_data.items.len) return false;
        const obj_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[me]);
        if (obj_idx.isNone()) return false;
        const obj = self.old_ast.getNode(obj_idx);
        if (obj.tag != .identifier_reference) return false;

        const obj_text = self.old_ast.source[obj.data.string_ref.start..obj.data.string_ref.end];
        return std.mem.eql(u8, obj_text, "console");
    }

    // ================================================================
    // define 글로벌 치환
    // ================================================================

    /// 노드가 define 치환 대상이면 새 string_literal 노드를 반환.
    /// 대상: identifier_reference 또는 static_member_expression 체인.
    fn tryDefineReplace(self: *Transformer, node: Node) ?Error!NodeIndex {
        // 노드의 소스 텍스트를 define key와 비교
        const text = self.getNodeText(node) orelse return null;

        for (self.options.define, 0..) |entry, i| {
            if (std.mem.eql(u8, text, entry.key)) {
                // transform() 시작 시 캐싱된 string_table Span 사용 (addString 중복 방지)
                const value_span = self.define_spans[i];
                return self.new_ast.addNode(.{
                    .tag = .string_literal,
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
            .identifier_reference => self.old_ast.source[node.data.string_ref.start..node.data.string_ref.end],
            .static_member_expression => self.old_ast.source[node.span.start..node.span.end],
            else => null,
        };
    }

    // ================================================================
    // TS enum 변환
    // ================================================================

    /// ts_enum_declaration: extra = [name, members_start, members_len]
    /// enum 노드를 새 AST에 복사. codegen에서 IIFE 패턴으로 출력.
    /// extra = [name, members_start, members_len, flags]
    /// flags: 0=일반 enum, 1=const enum
    fn visitEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 3);

        // const enum (flags=1): isolatedModules 모드에서는 삭제 (D011)
        // 같은 파일 내 인라이닝은 향후 구현
        if (flags == 1) {
            return .none; // const enum 선언 삭제
        }

        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_members = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.ts_enum_declaration, node.span, &.{
            @intFromEnum(new_name), new_members.start, new_members.len, flags,
        });
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
        const decl_extra = try self.new_ast.addExtras(&.{
            @intFromEnum(new_name),
            @intFromEnum(NodeIndex.none), // type_ann (stripped)
            @intFromEnum(new_value),
        });
        const declarator = try self.new_ast.addNode(.{
            .tag = .variable_declarator,
            .span = node.span,
            .data = .{ .extra = decl_extra },
        });
        const scratch_top = self.scratch.items.len;
        try self.scratch.append(self.allocator, declarator);
        const list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        self.scratch.shrinkRetainingCapacity(scratch_top);
        // variable_declaration: extra = [kind_flags, list.start, list.len]
        // kind_flags=2: const
        const var_extra = try self.new_ast.addExtras(&.{ 2, list.start, list.len });
        return try self.new_ast.addNode(.{
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
        const body_node = self.new_ast.getNode(new_body);
        if ((body_node.tag == .block_statement or body_node.tag == .ts_module_block) and body_node.data.list.len == 0) {
            return .none;
        }
        return self.new_ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = node.span,
            .data = .{ .binary = .{ .left = new_name, .right = new_body, .flags = 0 } },
        });
    }

    // ================================================================
    // 헬퍼
    // ================================================================

    /// extra_data에서 연속된 필드를 슬라이스로 읽기.
    fn readExtras(self: *const Transformer, start: u32, len: u32) []const u32 {
        return self.old_ast.extra_data.items[start .. start + len];
    }

    /// extra 인덱스로 NodeIndex 읽기.
    fn readNodeIdx(self: *const Transformer, extra_start: u32, offset: u32) NodeIndex {
        return @enumFromInt(self.old_ast.extra_data.items[extra_start + offset]);
    }

    /// extra 인덱스로 u32 읽기.
    fn readU32(self: *const Transformer, extra_start: u32, offset: u32) u32 {
        return self.old_ast.extra_data.items[extra_start + offset];
    }

    /// 노드를 extra_data로 만들어 새 AST에 추가.
    fn addExtraNode(self: *Transformer, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
        const new_extra = try self.new_ast.addExtras(extras);
        return self.new_ast.addNode(.{ .tag = tag, .span = span, .data = .{ .extra = new_extra } });
    }

    // ================================================================
    // JSX 노드 변환
    // ================================================================

    /// jsx_element: extra = [tag_name, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn visitJSXElement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        const children_len = self.readU32(e, 4);
        const new_children = if (children_len > 0)
            try self.visitExtraList(self.readU32(e, 3), children_len)
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
        const new_attrs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
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
    fn visitVariableDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015: destructuring pattern → 개별 declarator로 분해
        // ES2018: object rest (...rest) → __rest 호출 (target < es2018)
        if (self.options.target.needsES2015()) {
            if (es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, node)) {
                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
            }
        } else if (self.options.target.needsObjectSpread()) {
            if (es2015_destructuring.ES2015Destructuring(Transformer).hasObjectRest(self, node)) {
                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
            }
        }
        const e = node.data.extra;
        const kind_flags = if (self.options.target.needsES2015())
            es2015_block_scoping.lowerKindFlags(self.readU32(e, 0))
        else
            self.readU32(e, 0);
        const new_list = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.variable_declaration, node.span, &.{ kind_flags, new_list.start, new_list.len });
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
        if (self.readNodeIdx(e, 3).isNone()) return NodeIndex.none;

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
        self.arrow_this_depth = 0;
        self.needs_this_var = false;
        self.needs_arguments_var = false;

        // 임시 변수 카운터 저장 (함수 스코프 내 사용된 임시 변수 호이스팅용)
        const saved_temp_counter = self.temp_var_counter;

        const new_name = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 + parameter property 수집
        const params_start = self.readU32(e, 1);
        const params_len = self.readU32(e, 2);
        const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // ES2015: default/rest params → 파라미터 축소 + 바디 문 삽입
        var es2015_body_stmts: ?std.ArrayList(NodeIndex) = null;
        defer if (es2015_body_stmts) |*s| s.deinit(self.allocator);

        const pp = if (self.options.target.needsES2015() and
            es2015_params.ES2015Params(Transformer).hasDefaultOrRest(self, params_start, params_len))
        blk: {
            const lower_result = try es2015_params.ES2015Params(Transformer).lowerParams(
                self,
                params_start,
                params_len,
                node.span,
            );
            es2015_body_stmts = lower_result.body_stmts;
            break :blk ParamPropertyResult{
                .new_params = lower_result.new_params,
                .prop_names = undefined,
                .prop_count = 0,
            };
        } else try self.visitParamsCollectProperties(old_params);

        // 바디 방문
        const old_body_idx = self.readNodeIdx(e, 3);
        var new_body = try self.visitNode(old_body_idx);

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_count > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
        }

        // ES2015 default/rest 바디 문 삽입
        if (es2015_body_stmts) |stmts| {
            if (stmts.items.len > 0 and !new_body.isNone()) {
                new_body = try self.prependStatementsToBody(new_body, stmts.items);
            }
        }

        // ES2015 arrow this/arguments 캡처: 이 함수 안의 arrow가 this/arguments를 사용했으면
        // var _this = this; / var _arguments = arguments; 를 바디 앞에 삽입.
        if (self.options.target.needsES2015() and !new_body.isNone() and
            (self.needs_this_var or self.needs_arguments_var))
        {
            var capture_stmts: [2]NodeIndex = undefined;
            var capture_count: usize = 0;

            if (self.needs_this_var) {
                const this_init = try self.new_ast.addNode(.{
                    .tag = .this_expression,
                    .span = node.span,
                    .data = .{ .none = 0 },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
                capture_count += 1;
            }
            if (self.needs_arguments_var) {
                const args_span = try self.new_ast.addString("arguments");
                const args_init = try self.new_ast.addNode(.{
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

        // React Fast Refresh: Hook 시그니처 감지 + _s() 호출 삽입
        // 함수 이름을 old_ast에서 추출 (new_name은 아직 extra에 추가 전이므로)
        const old_name_idx = self.readNodeIdx(e, 0);
        const func_name_for_sig: ?[]const u8 = if (!old_name_idx.isNone()) blk: {
            const old_name_node = self.old_ast.getNode(old_name_idx);
            if (old_name_node.tag == .binding_identifier or old_name_node.tag == .identifier_reference) {
                break :blk self.old_ast.getText(old_name_node.data.string_ref);
            }
            break :blk null;
        } else null;
        try self.maybeRegisterRefreshSignature(func_name_for_sig, old_body_idx, &new_body);

        const none = @intFromEnum(NodeIndex.none);
        const result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), pp.new_params.start, pp.new_params.len,
            @intFromEnum(new_body), self.readU32(e, 4),  none,
        });

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

    fn visitParamsCollectProperties(self: *Transformer, old_params: []const u32) Error!ParamPropertyResult {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var result = ParamPropertyResult{
            .new_params = NodeList{ .start = 0, .len = 0 },
            .prop_names = undefined,
            .prop_count = 0,
        };

        for (old_params) |raw_idx| {
            const param_node = self.old_ast.getNode(@enumFromInt(raw_idx));
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            // flags != 0 → parameter property (public/private/protected/readonly/override)
            if (param_node.tag == .formal_parameter and self.old_ast.extra_data.items[param_node.data.extra + 3] != 0) {
                const inner = try self.visitNode(@enumFromInt(self.old_ast.extra_data.items[param_node.data.extra]));
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

        result.new_params = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return result;
    }

    /// block_statement 바디 앞에 this.x = x; 문들을 삽입한다.
    fn insertParameterPropertyAssignments(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
        const body = self.new_ast.getNode(body_idx);
        if (body.tag != .block_statement) return body_idx;

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // this.x = x 문들을 먼저 추가
        for (prop_names) |name_idx| {
            const name_node = self.new_ast.getNode(name_idx);
            // this 노드
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = name_node.span,
                .data = .{ .none = 0 },
            });
            // this.x (static member) — extra = [object, property, flags]
            const member_extra = try self.new_ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(name_idx), 0 });
            const member = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = name_node.span,
                .data = .{ .extra = member_extra },
            });
            // this.x = x (assignment)
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = name_node.span,
                .data = .{ .binary = .{ .left = member, .right = name_idx, .flags = 0 } },
            });
            // expression_statement
            const stmt = try self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = name_node.span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, stmt);
        }

        // 기존 바디 문들을 추가
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// block_statement / program / function_body 앞에 문들을 삽입한다.
    pub fn prependStatementsToBody(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
        const body = self.new_ast.getNode(body_idx);
        if (body.tag != .block_statement and body.tag != .program and body.tag != .function_body) return body_idx;

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (stmts) |stmt| {
            try self.scratch.append(self.allocator, stmt);
        }

        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = body.tag,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// var <name> = <init_value>; 문 생성 (범용 헬퍼).
    pub fn buildVarDecl(self: *Transformer, name: []const u8, init_value: NodeIndex, span: Span) Error!NodeIndex {
        const name_span = try self.new_ast.addString(name);
        const binding = try self.new_ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });

        const none = @intFromEnum(NodeIndex.none);
        const declarator = try self.addExtraNode(.variable_declarator, span, &.{
            @intFromEnum(binding), none, @intFromEnum(init_value),
        });

        const decl_list = try self.new_ast.addNodeList(&.{declarator});
        return self.addExtraNode(.variable_declaration, span, &.{
            0, // var
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
            const name_span = try self.new_ast.addString(name);
            const binding = try self.new_ast.addNode(.{
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

        const decl_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const var_decl = try self.addExtraNode(.variable_declaration, span, &.{
            0, // var
            decl_list.start,
            decl_list.len,
        });

        return self.prependStatementsToBody(body_idx, &.{var_decl});
    }

    /// arrow_function_expression: extra = [params, body, flags]
    /// flags: 0x01 = async
    fn visitArrowFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 2 >= extras.len) return NodeIndex.none;
        const new_params = try self.visitNode(@enumFromInt(extras[e]));
        const new_body = try self.visitNode(@enumFromInt(extras[e + 1]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_params), @intFromEnum(new_body), extras[e + 2] });
        return self.new_ast.addNode(.{ .tag = .arrow_function_expression, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// class_declaration / class_expression
    /// extra_data = [name, super_class, body, type_params, implements_start, implements_len]
    /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
    fn visitClass(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;

        // Fast path: useDefineForClassFields=true AND !experimentalDecorators → 기존 동작
        // 멤버별 분류가 불필요하므로 body를 통째로 방문한다.
        if (self.options.use_define_for_class_fields and !self.options.experimental_decorators) {
            const new_name = try self.visitNode(self.readNodeIdx(e, 0));
            const new_super = try self.visitNode(self.readNodeIdx(e, 1));

            // ES2022 다운레벨링: static block → IIFE (target < es2022)
            if (self.options.target.needsClassStaticBlock()) {
                var new_body: NodeIndex = .none;
                var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
                defer static_block_iifes.deinit(self.allocator);

                // 클래스 이름 추출 → static block 안의 this 치환에 사용.
                const class_name_span = self.getClassNameSpan(new_name);

                const had_static_blocks = try es2022.ES2022(Transformer).lowerStaticBlocks(
                    self,
                    self.readNodeIdx(e, 2),
                    &new_body,
                    &static_block_iifes,
                    class_name_span,
                );

                if (had_static_blocks) {
                    const new_decos = try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7));
                    const none = @intFromEnum(NodeIndex.none);
                    const class_result = try self.addExtraNode(node.tag, node.span, &.{
                        @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
                        none,                   0,                       0,
                        new_decos.start,        new_decos.len,
                    });

                    // class 노드를 pending_nodes에 넣고, static block IIFE를 그 뒤에 추가
                    try self.pending_nodes.append(self.allocator, class_result);
                    for (static_block_iifes.items) |iife| {
                        try self.pending_nodes.append(self.allocator, iife);
                    }
                    return .none;
                }
            }

            const new_body = try self.visitNode(self.readNodeIdx(e, 2));
            const new_decos = try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7));
            const none = @intFromEnum(NodeIndex.none);
            return self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
                none,                   0,                       0,
                new_decos.start,        new_decos.len,
            });
        }

        // Slow path: useDefineForClassFields=false 또는 experimentalDecorators
        // 클래스 바디의 멤버들을 개별로 분석해야 하므로, class_body를 직접 순회한다.
        return self.visitClassWithAssignSemantics(node);
    }

    /// useDefineForClassFields=false / experimentalDecorators 처리.
    /// 멤버를 개별 분류하여 instance field를 constructor로 이동하고,
    /// experimental decorator를 __decorateClass 호출로 변환한다.
    fn visitClassWithAssignSemantics(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const has_super = !self.readNodeIdx(e, 1).isNone();
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_super = try self.visitNode(self.readNodeIdx(e, 1));

        // 원본 class_body를 직접 순회
        const body_idx = self.readNodeIdx(e, 2);
        const body_node = self.old_ast.getNode(body_idx);
        const body_members = self.old_ast.extra_data.items[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];

        // 멤버 분류: class_members(새 body), field_assignments(constructor 이동 대상),
        // member_decorators(experimental decorator 대상)를 동시에 수집한다.
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var class_members: std.ArrayList(NodeIndex) = .empty;
        defer class_members.deinit(self.allocator);

        var field_assignments: std.ArrayList(FieldAssignment) = .empty;
        defer field_assignments.deinit(self.allocator);

        var member_decorators: std.ArrayList(MemberDecoratorInfo) = .empty;
        defer {
            for (member_decorators.items) |md| {
                self.allocator.free(md.decorators);
            }
            member_decorators.deinit(self.allocator);
        }

        var existing_constructor: ?NodeIndex = null;
        var existing_constructor_pos: ?usize = null;

        // ES2022 다운레벨링: static block → IIFE (target < es2022)
        var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
        defer static_block_iifes.deinit(self.allocator);

        var static_field_assignments: std.ArrayList(FieldAssignment) = .empty;
        defer static_field_assignments.deinit(self.allocator);

        var ctor_param_decos: std.ArrayList(NodeIndex) = .empty;
        defer ctor_param_decos.deinit(self.allocator);

        var ctx = ClassMemberContext{
            .class_members = &class_members,
            .field_assignments = &field_assignments,
            .member_decorators = &member_decorators,
            .existing_constructor = &existing_constructor,
            .existing_constructor_pos = &existing_constructor_pos,
            .static_block_iifes = if (self.options.target.needsClassStaticBlock()) &static_block_iifes else null,
            .static_field_assignments = if (!self.options.use_define_for_class_fields) &static_field_assignments else null,
            .ctor_param_decos = &ctor_param_decos,
        };

        // ES2022 static block this 치환을 위한 클래스 이름 추출
        if (self.options.target.needsClassStaticBlock()) {
            ctx.class_name_span = self.getClassNameSpan(new_name);
        }

        for (body_members) |raw_idx| {
            try self.classifyClassMember(raw_idx, &ctx);
        }

        // computed key 호이스트: class 전에 var _a; _a = foo; 삽입 (esbuild 호환)
        // assign semantics에서 computed key는 class 평가 전에 한 번만 평가되어야 함
        if (!self.options.use_define_for_class_fields) {
            var computed_idx: u8 = 0;
            for (field_assignments.items) |*field| {
                if (field.is_computed) {
                    const key_node = self.new_ast.getNode(field.key);
                    const actual_key = if (key_node.tag == .computed_property_key)
                        key_node.data.unary.operand
                    else
                        field.key;

                    // var _a; / var _b; / ... (computed field별 고유 이름)
                    var name_buf: [4]u8 = undefined;
                    name_buf[0] = '_';
                    name_buf[1] = 'a' + computed_idx;
                    const temp_span = try self.new_ast.addString(name_buf[0..2]);
                    computed_idx += 1;
                    const temp_binding = try self.new_ast.addNode(.{
                        .tag = .binding_identifier,
                        .span = temp_span,
                        .data = .{ .string_ref = temp_span },
                    });
                    const declarator_extra = try self.new_ast.addExtras(&.{
                        @intFromEnum(temp_binding),
                        @intFromEnum(NodeIndex.none),
                        @intFromEnum(NodeIndex.none),
                    });
                    const declarator = try self.new_ast.addNode(.{
                        .tag = .variable_declarator,
                        .span = field.span,
                        .data = .{ .extra = declarator_extra },
                    });
                    const decl_list = try self.new_ast.addNodeList(&.{declarator});
                    const var_decl_extra = try self.new_ast.addExtras(&.{ 0, decl_list.start, decl_list.len });
                    const var_decl = try self.new_ast.addNode(.{
                        .tag = .variable_declaration,
                        .span = field.span,
                        .data = .{ .extra = var_decl_extra },
                    });
                    try self.pending_nodes.append(self.allocator, var_decl);

                    // _a = foo; 대입
                    const temp_ref = try self.new_ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = temp_span,
                        .data = .{ .string_ref = temp_span },
                    });
                    const assign = try self.new_ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = field.span,
                        .data = .{ .binary = .{ .left = temp_ref, .right = actual_key, .flags = 0 } },
                    });
                    const assign_stmt = try self.new_ast.addNode(.{
                        .tag = .expression_statement,
                        .span = field.span,
                        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
                    });
                    try self.pending_nodes.append(self.allocator, assign_stmt);

                    // field의 key를 임시 변수로 교체
                    const new_computed = try self.new_ast.addNode(.{
                        .tag = .computed_property_key,
                        .span = field.span,
                        .data = .{ .unary = .{ .operand = temp_ref, .flags = 0 } },
                    });
                    field.key = new_computed;
                }
            }
        }

        // instance field를 constructor에 삽입 (useDefineForClassFields=false)
        if (field_assignments.items.len > 0) {
            try self.applyFieldAssignments(
                &class_members,
                field_assignments.items,
                existing_constructor,
                existing_constructor_pos,
                has_super,
            );
        }

        // class body 노드 생성
        const body_list = try self.new_ast.addNodeList(class_members.items);
        const new_body = try self.new_ast.addNode(.{
            .tag = .class_body,
            .span = body_node.span,
            .data = .{ .list = body_list },
        });

        // experimentalDecorators — decorator를 class에서 제거하고 __decorateClass 호출 생성
        if (self.options.experimental_decorators) {
            const old_deco_start = self.readU32(e, 6);
            const old_deco_len = self.readU32(e, 7);

            if (old_deco_len > 0 or member_decorators.items.len > 0 or ctor_param_decos.items.len > 0) {
                return try self.transformExperimentalDecorators(
                    node,
                    new_name,
                    new_super,
                    new_body,
                    old_deco_start,
                    old_deco_len,
                    member_decorators.items,
                    static_block_iifes.items,
                    static_field_assignments.items,
                    ctor_param_decos.items,
                );
            }
        }

        // decorator 리스트 복사 (experimental이 아닌 경우)
        const new_decos = if (!self.options.experimental_decorators)
            try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7))
        else
            NodeList{ .start = 0, .len = 0 };

        const none = @intFromEnum(NodeIndex.none);

        // static field / static block이 있으면 class 뒤에 할당문 추가
        const has_static_fields = static_field_assignments.items.len > 0;
        const has_static_blocks = static_block_iifes.items.len > 0;

        if (has_static_fields or has_static_blocks) {
            const class_result = try self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
                none,                   0,                       0,
                new_decos.start,        new_decos.len,
            });
            try self.pending_nodes.append(self.allocator, class_result);
            // static field: Foo.z = 2;
            for (static_field_assignments.items) |field| {
                const stmt = try self.buildStaticFieldAssignment(new_name, field);
                try self.pending_nodes.append(self.allocator, stmt);
            }
            for (static_block_iifes.items) |iife| {
                try self.pending_nodes.append(self.allocator, iife);
            }
            return .none;
        }

        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            new_decos.start,        new_decos.len,
        });
    }

    /// ClassName.key = value; 할당문을 생성한다.
    fn buildStaticFieldAssignment(self: *Transformer, class_name: NodeIndex, field: FieldAssignment) Error!NodeIndex {
        // ClassName
        const name_node = self.new_ast.getNode(class_name);
        const cls_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = name_node.span,
            .data = .{ .string_ref = name_node.span },
        });
        const member = if (field.is_computed) blk: {
            // computed: ClassName[key]
            const me_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(cls_ref),
                @intFromEnum(field.key),
                0,
            });
            break :blk try self.new_ast.addNode(.{
                .tag = .computed_member_expression,
                .span = field.span,
                .data = .{ .extra = me_extra },
            });
        } else blk: {
            break :blk try es_helpers.makeStaticMember(self, cls_ref, field.key, field.span);
        };
        // ClassName.key = value
        const assign = try self.new_ast.addNode(.{
            .tag = .assignment_expression,
            .span = field.span,
            .data = .{ .binary = .{ .left = member, .right = field.value, .flags = 0 } },
        });
        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = field.span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
    }

    /// 단일 클래스 멤버를 분류하여 적절한 목록에 추가한다.
    /// - property_definition: assign semantics 대상이면 field_assignments에, 아니면 class_members에
    /// - method_definition: constructor면 기록, 일반 메서드면 class_members에
    /// - 기타: class_members에 그대로 추가
    /// visitClassWithAssignSemantics에서 멤버 분류에 사용되는 컨텍스트.
    /// 6개 포인터 파라미터를 하나로 묶어 함수 시그니처를 단순화.
    const ClassMemberContext = struct {
        class_members: *std.ArrayList(NodeIndex),
        field_assignments: *std.ArrayList(FieldAssignment),
        member_decorators: *std.ArrayList(MemberDecoratorInfo),
        existing_constructor: *?NodeIndex,
        existing_constructor_pos: *?usize,
        /// ES2022 다운레벨링: static block → IIFE (target < es2022 일 때 사용)
        static_block_iifes: ?*std.ArrayList(NodeIndex) = null,
        /// ES2022 static block 안의 this → 클래스 이름 치환에 사용
        class_name_span: ?Span = null,
        /// useDefineForClassFields=false: static field → class 밖 할당문
        static_field_assignments: ?*std.ArrayList(FieldAssignment) = null,
        /// constructor parameter decorator → class-level __decorateClass에 포함
        ctor_param_decos: *std.ArrayList(NodeIndex),
    };

    fn classifyClassMember(
        self: *Transformer,
        raw_idx: u32,
        ctx: *ClassMemberContext,
    ) Error!void {
        const member = self.old_ast.getNode(@enumFromInt(raw_idx));

        // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
        if (member.tag == .property_definition) {
            try self.classifyPropertyDefinition(raw_idx, member, ctx);
            return;
        }

        // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
        if (member.tag == .method_definition) {
            try self.classifyMethodDefinition(member, ctx);
            return;
        }

        // ES2022 다운레벨링: static block → IIFE (target < es2022)
        if (member.tag == .static_block and ctx.static_block_iifes != null) {
            const iife = try es2022.ES2022(Transformer).buildStaticBlockIIFE(self, member, ctx.class_name_span);
            try ctx.static_block_iifes.?.append(self.allocator, iife);
            return;
        }

        // 기타 멤버 (static_block, accessor_property 등): 그대로 방문
        const new_member = try self.visitNode(@enumFromInt(raw_idx));
        if (!new_member.isNone()) {
            try ctx.class_members.append(self.allocator, new_member);
        }
    }

    /// property_definition 멤버를 분류한다.
    /// - abstract/declare → 스트리핑 (스킵)
    /// - experimental decorators → member_decorators에 수집
    /// - assign semantics (non-static, non-abstract, non-declare, 초기화 있음) → field_assignments에
    /// - 나머지 → class_members에 그대로 방문
    fn classifyPropertyDefinition(
        self: *Transformer,
        raw_idx: u32,
        member: Node,
        ctx: *ClassMemberContext,
    ) Error!void {
        const class_members = ctx.class_members;
        const field_assignments = ctx.field_assignments;
        const member_decorators = ctx.member_decorators;
        const me = member.data.extra;
        const flags = self.readU32(me, 2);
        const is_static = (flags & 0x01) != 0;
        const is_abstract = (flags & 0x20) != 0;
        const is_declare = (flags & 0x40) != 0;

        // abstract/declare는 항상 스트리핑
        if (self.options.strip_types and (flags & 0x60) != 0) {
            return;
        }

        // decorator 수집 (experimental decorators — 경로와 무관하게 한 번만)
        if (self.options.experimental_decorators) {
            const deco_start = self.readU32(me, 3);
            const deco_len = self.readU32(me, 4);
            if (deco_len > 0) {
                const new_key = try self.visitNode(self.readNodeIdx(me, 0));
                try self.collectMemberDecorators(member_decorators, deco_start, deco_len, 0, 0, new_key, is_static, 2);
            }
        }

        // useDefineForClassFields=false: non-static instance field를 constructor로 이동
        if (!self.options.use_define_for_class_fields and !is_static and !is_abstract and !is_declare) {
            const key_idx = self.readNodeIdx(me, 0);
            const init_idx = self.readNodeIdx(me, 1);
            if (!init_idx.isNone()) {
                const new_key = try self.visitNode(key_idx);
                const new_init = try self.visitNode(init_idx);
                const key_node = self.old_ast.getNode(key_idx);
                const is_computed = (key_node.tag == .computed_property_key);
                try field_assignments.append(self.allocator, .{
                    .key = new_key,
                    .value = new_init,
                    .is_computed = is_computed,
                    .span = member.span,
                });
            }
            return;
        }

        // useDefineForClassFields=false + static field
        if (!self.options.use_define_for_class_fields and is_static) {
            const key_idx = self.readNodeIdx(me, 0);
            const init_idx = self.readNodeIdx(me, 1);
            if (init_idx.isNone()) return; // 초기값 없음 → 타입 선언만, 제거
            // 초기값 있음 → class 밖 할당문으로 이동 (Foo.z = 2)
            if (ctx.static_field_assignments) |sfa| {
                const new_key = try self.visitNode(key_idx);
                const new_init = try self.visitNode(init_idx);
                const key_node = self.old_ast.getNode(key_idx);
                try sfa.append(self.allocator, .{
                    .key = new_key,
                    .value = new_init,
                    .is_computed = (key_node.tag == .computed_property_key),
                    .span = member.span,
                });
                return;
            }
            // static_field_assignments가 없으면 (use_define_for_class_fields=true) 그대로 유지
        }

        // 그 외: 그대로 방문
        const new_member = try self.visitNode(@enumFromInt(raw_idx));
        if (!new_member.isNone()) {
            try class_members.append(self.allocator, new_member);
        }
    }

    /// method_definition 멤버를 분류한다.
    /// - constructor → existing_constructor/existing_constructor_pos에 기록
    /// - experimental decorators가 있는 일반 메서드 → member_decorators에 수집
    /// - 나머지 → class_members에 추가
    fn classifyMethodDefinition(
        self: *Transformer,
        member: Node,
        ctx: *ClassMemberContext,
    ) Error!void {
        const class_members = ctx.class_members;
        const member_decorators = ctx.member_decorators;
        const me = member.data.extra;
        const flags = self.readU32(me, 4);
        const is_static = (flags & 0x01) != 0;

        // constructor 감지
        const is_ctor = if (!is_static) blk: {
            const key_idx = self.readNodeIdx(me, 0);
            const key_node = self.old_ast.getNode(key_idx);
            if (key_node.tag == .identifier_reference) {
                const name = self.old_ast.source[key_node.span.start..key_node.span.end];
                break :blk std.mem.eql(u8, name, "constructor");
            }
            break :blk false;
        } else false;

        if (is_ctor) {
            // constructor parameter decorator → class-level __decorateClass에 포함
            if (self.options.experimental_decorators) {
                const params_start = self.readU32(me, 1);
                const params_len = self.readU32(me, 2);
                try self.collectParamDecorators(ctx.ctor_param_decos, params_start, params_len);
            }

            const new_member = try self.visitMethodDefinition(member);
            if (!new_member.isNone()) {
                ctx.existing_constructor.* = new_member;
                ctx.existing_constructor_pos.* = class_members.items.len;
                try class_members.append(self.allocator, new_member);
            }
            return;
        }

        // 일반 메서드: member decorator + parameter decorator 수집 (single-pass)
        if (self.options.experimental_decorators) {
            const deco_start = self.readU32(me, 5);
            const deco_len = self.readU32(me, 6);
            const params_start = self.readU32(me, 1);
            const params_len = self.readU32(me, 2);
            if (deco_len > 0 or params_len > 0) {
                const new_key = try self.visitNode(self.readNodeIdx(me, 0));
                try self.collectMemberDecorators(
                    member_decorators,
                    deco_start,
                    deco_len,
                    params_start,
                    params_len,
                    new_key,
                    is_static,
                    1,
                );
            }
        }

        const new_member = try self.visitMethodDefinition(member);
        if (!new_member.isNone()) {
            try class_members.append(self.allocator, new_member);
        }
    }

    /// 수집된 field assignments를 constructor에 삽입한다.
    /// 기존 constructor가 있으면 body에 삽입하고, 없으면 새로 생성한다.
    fn applyFieldAssignments(
        self: *Transformer,
        class_members: *std.ArrayList(NodeIndex),
        fields: []const FieldAssignment,
        existing_constructor: ?NodeIndex,
        existing_constructor_pos: ?usize,
        has_super: bool,
    ) Error!void {
        if (existing_constructor) |ctor_idx| {
            // 기존 constructor의 body에 field assignments 삽입
            const updated_ctor = try self.insertFieldAssignmentsIntoConstructor(ctor_idx, fields, has_super);
            // position으로 직접 교체 (선형 검색 불필요)
            if (existing_constructor_pos) |pos| {
                class_members.items[pos] = updated_ctor;
            }
        } else {
            // constructor가 없으면 새로 생성
            const new_ctor = try self.buildConstructorWithFieldAssignments(fields, has_super);
            // class body 맨 앞에 삽입
            try class_members.insert(self.allocator, 0, new_ctor);
        }
    }

    /// useDefineForClassFields=false: instance field → constructor this.x = value 정보
    const FieldAssignment = struct {
        key: NodeIndex,
        value: NodeIndex,
        is_computed: bool,
        span: Span,
    };

    /// experimentalDecorators: member decorator 정보
    pub const MemberDecoratorInfo = struct {
        /// decorator expression들 (new AST)
        decorators: []NodeIndex,
        /// member key (new AST)
        key: NodeIndex,
        /// static 여부
        is_static: bool,
        /// descriptor 종류: 1=method, 2=property
        kind: u32,
    };

    /// decorator 노드에서 expression 부분을 visit하여 반환.
    /// decorator 태그이면 operand(expression)를, 아니면 노드 자체를 visit.
    pub fn visitDecoratorExpression(self: *Transformer, raw_idx: u32) Error!NodeIndex {
        const deco_node = self.old_ast.getNode(@enumFromInt(raw_idx));
        return if (deco_node.tag == .decorator)
            self.visitNode(deco_node.data.unary.operand)
        else
            self.visitNode(@enumFromInt(raw_idx));
    }

    /// experimentalDecorators: member/parameter decorator를 수집하여 MemberDecoratorInfo에 저장.
    /// parameter decorator는 __decorateParam(index, dec) 호출 노드로 래핑.
    /// params_start/params_len이 0이면 parameter decorator 수집을 건너뜀.
    pub fn collectMemberDecorators(
        self: *Transformer,
        list: *std.ArrayList(MemberDecoratorInfo),
        deco_start: u32,
        deco_len: u32,
        params_start: u32,
        params_len: u32,
        key: NodeIndex,
        is_static: bool,
        kind: u32,
    ) Error!void {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // 1) parameter decorator → __decorateParam(index, dec)
        if (params_len > 0) {
            try self.appendParamDecorators(&self.scratch, params_start, params_len);
        }

        // 2) member decorator (method/property 자체에 붙은 decorator)
        if (deco_len > 0) {
            const old_deco_indices = self.old_ast.extra_data.items[deco_start .. deco_start + deco_len];
            for (old_deco_indices) |raw_idx| {
                try self.scratch.append(self.allocator, try self.visitDecoratorExpression(raw_idx));
            }
        }

        const collected = self.scratch.items[scratch_top..];
        if (collected.len == 0) return;

        const deco_nodes = try self.allocator.alloc(NodeIndex, collected.len);
        @memcpy(deco_nodes, collected);

        try list.append(self.allocator, .{
            .decorators = deco_nodes,
            .key = key,
            .is_static = is_static,
            .kind = kind,
        });
    }

    /// __decorateParam(index, decorator) 호출 expression 노드 생성
    /// constructor의 parameter decorator만 수집하여 __decorateParam 노드 리스트에 추가.
    /// collectMemberDecorators의 param 수집 부분과 동일한 appendParamDecorators를 사용.
    pub fn collectParamDecorators(
        self: *Transformer,
        list: *std.ArrayList(NodeIndex),
        params_start: u32,
        params_len: u32,
    ) Error!void {
        try self.appendParamDecorators(list, params_start, params_len);
    }

    /// parameter decorator를 __decorateParam(index, dec) 형태로 변환하여 list에 추가.
    /// collectMemberDecorators와 collectParamDecorators 양쪽에서 사용.
    fn appendParamDecorators(
        self: *Transformer,
        list: anytype,
        params_start: u32,
        params_len: u32,
    ) Error!void {
        const zero_span = Span{ .start = 0, .end = 0 };
        const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];
        for (old_params, 0..) |raw_idx, param_index| {
            const param = self.old_ast.getNode(@enumFromInt(raw_idx));
            if (param.tag != .formal_parameter) continue;
            const pe = param.data.extra;
            const pdeco_start = self.old_ast.extra_data.items[pe + 4];
            const pdeco_len = self.old_ast.extra_data.items[pe + 5];
            if (pdeco_len == 0) continue;

            const pdeco_indices = self.old_ast.extra_data.items[pdeco_start .. pdeco_start + pdeco_len];
            for (pdeco_indices) |deco_raw_idx| {
                const dec_expr = try self.visitDecoratorExpression(deco_raw_idx);
                const param_deco = try self.buildDecorateParamCall(param_index, dec_expr, zero_span);
                try list.append(self.allocator, param_deco);
            }
        }
    }

    pub fn buildDecorateParamCall(
        self: *Transformer,
        param_index: usize,
        dec_expr: NodeIndex,
        span: Span,
    ) Error!NodeIndex {
        // callee: __decorateParam
        const callee_span = try self.new_ast.addString("__decorateParam");
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = callee_span,
            .data = .{ .string_ref = callee_span },
        });

        // arg1: index (numeric literal)
        var index_buf: [10]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buf, "{d}", .{param_index}) catch "0";
        const index_span = try self.new_ast.addString(index_text);
        const index_node = try self.new_ast.addNode(.{
            .tag = .numeric_literal,
            .span = index_span,
            .data = .{ .number_bytes = @bitCast(@as(f64, @floatFromInt(param_index))) },
        });

        // arg2: decorator expression
        const args = try self.new_ast.addNodeList(&.{ index_node, dec_expr });
        return self.addExtraNode(.call_expression, span, &.{
            @intFromEnum(callee), args.start, args.len, 0,
        });
    }

    /// useDefineForClassFields=false: 기존 constructor body에 field assignments 삽입.
    /// super()가 있으면 그 뒤에, 없으면 body 맨 앞에 삽입.
    fn insertFieldAssignmentsIntoConstructor(
        self: *Transformer,
        ctor_idx: NodeIndex,
        fields: []const FieldAssignment,
        has_super: bool,
    ) Error!NodeIndex {
        // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
        const ctor_node = self.new_ast.getNode(ctor_idx);
        const ce = ctor_node.data.extra;
        const ctor_extras = self.new_ast.extra_data.items[ce .. ce + 7];
        const body_idx: NodeIndex = @enumFromInt(ctor_extras[3]);

        if (body_idx.isNone()) return ctor_idx;

        const body = self.new_ast.getNode(body_idx);
        if (body.tag != .block_statement) return ctor_idx;

        const old_list = body.data.list;
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // super() 호출을 찾아서 그 뒤에 삽입
        var insert_pos: usize = 0;
        if (has_super) {
            for (old_stmts, 0..) |raw_idx, idx| {
                if (self.isSuperCallStatement(@enumFromInt(raw_idx))) {
                    insert_pos = idx + 1;
                    break;
                }
            }
        }

        // insert_pos 전의 문장들
        for (old_stmts[0..insert_pos]) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        // field assignments 삽입
        for (fields) |field| {
            const assign_stmt = try self.buildThisAssignment(field);
            try self.scratch.append(self.allocator, assign_stmt);
        }

        // insert_pos 후의 문장들
        for (old_stmts[insert_pos..]) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_body = try self.new_ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });

        // constructor method_definition을 새 body로 재생성
        return self.addExtraNode(.method_definition, ctor_node.span, &.{
            ctor_extras[0],         ctor_extras[1], ctor_extras[2],
            @intFromEnum(new_body), ctor_extras[4], ctor_extras[5],
            ctor_extras[6],
        });
    }

    /// super() 호출 expression_statement인지 판별
    fn isSuperCallStatement(self: *const Transformer, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const stmt = self.new_ast.getNode(idx);
        if (stmt.tag != .expression_statement) return false;
        const expr_idx = stmt.data.unary.operand;
        if (expr_idx.isNone()) return false;
        const expr = self.new_ast.getNode(expr_idx);
        if (expr.tag != .call_expression) return false;
        // call_expression: extra = [callee, args_start, args_len, flags]
        const ce = expr.data.extra;
        if (ce >= self.new_ast.extra_data.items.len) return false;
        const callee_idx: NodeIndex = @enumFromInt(self.new_ast.extra_data.items[ce]);
        if (callee_idx.isNone()) return false;
        const callee = self.new_ast.getNode(callee_idx);
        return callee.tag == .super_expression;
    }

    /// useDefineForClassFields=false: constructor가 없을 때 새로 생성.
    /// extends가 있으면 super(...args) 호출 포함.
    fn buildConstructorWithFieldAssignments(
        self: *Transformer,
        fields: []const FieldAssignment,
        has_super: bool,
    ) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var params_list = NodeList{ .start = 0, .len = 0 };

        // extends가 있으면: constructor(...args) { super(...args); this.x = v; }
        if (has_super) {
            // ...args 파라미터
            const args_span = try self.new_ast.addString("args");
            const args_id = try self.new_ast.addNode(.{
                .tag = .binding_identifier,
                .span = args_span,
                .data = .{ .string_ref = args_span },
            });
            const rest = try self.new_ast.addNode(.{
                .tag = .rest_element,
                .span = zero_span,
                .data = .{ .unary = .{ .operand = args_id, .flags = 0 } },
            });
            params_list = try self.new_ast.addNodeList(&.{rest});

            // super(...args) 호출
            const super_expr = try self.new_ast.addNode(.{
                .tag = .super_expression,
                .span = zero_span,
                .data = .{ .none = 0 },
            });
            const args_ref = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = args_span,
                .data = .{ .string_ref = args_span },
            });
            const spread_args = try self.new_ast.addNode(.{
                .tag = .spread_element,
                .span = zero_span,
                .data = .{ .unary = .{ .operand = args_ref, .flags = 0 } },
            });
            const call_args = try self.new_ast.addNodeList(&.{spread_args});
            const super_call = try self.addExtraNode(.call_expression, zero_span, &.{
                @intFromEnum(super_expr), call_args.start, call_args.len, 0,
            });
            const super_stmt = try self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = zero_span,
                .data = .{ .unary = .{ .operand = super_call, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, super_stmt);
        }

        // this.x = value 할당들
        for (fields) |field| {
            const stmt = try self.buildThisAssignment(field);
            try self.scratch.append(self.allocator, stmt);
        }

        const body_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const body = try self.new_ast.addNode(.{
            .tag = .block_statement,
            .span = zero_span,
            .data = .{ .list = body_list },
        });

        // constructor key
        const ctor_span = try self.new_ast.addString("constructor");
        const ctor_key = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = ctor_span,
            .data = .{ .string_ref = ctor_span },
        });

        // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
        const empty_decos = try self.new_ast.addNodeList(&.{});
        return self.addExtraNode(.method_definition, zero_span, &.{
            @intFromEnum(ctor_key), params_list.start, params_list.len,
            @intFromEnum(body), 0, // flags=0 (non-static, normal method)
            empty_decos.start,  empty_decos.len,
        });
    }

    /// this.key = value; expression statement 생성
    fn buildThisAssignment(self: *Transformer, field: FieldAssignment) Error!NodeIndex {
        const this_node = try self.new_ast.addNode(.{
            .tag = .this_expression,
            .span = field.span,
            .data = .{ .none = 0 },
        });

        // computed key 또는 string/numeric literal key: this[key] = value
        // 일반 identifier key: this.key = value
        // string literal ("foo")이나 numeric literal (0)은 dot notation 불가 → bracket notation
        const key_node = self.new_ast.getNode(field.key);
        const needs_bracket = field.is_computed or key_node.tag == .string_literal or key_node.tag == .numeric_literal;
        const member = if (needs_bracket) blk: {
            // computed_property_key의 내부 expression을 꺼냄
            const actual_key = if (key_node.tag == .computed_property_key) key_node.data.unary.operand else field.key;
            const member_extra = try self.new_ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(actual_key), 0 });
            break :blk try self.new_ast.addNode(.{
                .tag = .computed_member_expression,
                .span = field.span,
                .data = .{ .extra = member_extra },
            });
        } else blk: {
            const member_extra = try self.new_ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(field.key), 0 });
            break :blk try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = field.span,
                .data = .{ .extra = member_extra },
            });
        };

        const assign = try self.new_ast.addNode(.{
            .tag = .assignment_expression,
            .span = field.span,
            .data = .{ .binary = .{ .left = member, .right = field.value, .flags = 0 } },
        });
        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = field.span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
    }

    /// experimentalDecorators: class/member decorator를 __decorateClass 호출로 변환.
    ///
    /// 입력: @sealed class Foo { @log method() {} }
    /// 출력:
    ///   let Foo = class Foo {};
    ///   __decorateClass([log], Foo.prototype, "method", 1);
    ///   Foo = __decorateClass([sealed], Foo);
    fn transformExperimentalDecorators(
        self: *Transformer,
        node: Node,
        new_name: NodeIndex,
        new_super: NodeIndex,
        new_body: NodeIndex,
        old_deco_start: u32,
        old_deco_len: u32,
        member_decos: []const MemberDecoratorInfo,
        static_block_iifes: []const NodeIndex,
        static_field_assigns: []const FieldAssignment,
        ctor_param_decos: []const NodeIndex,
    ) Error!NodeIndex {
        const none = @intFromEnum(NodeIndex.none);
        const decorate_span = try self.new_ast.addString("__decorateClass");

        // class 이름 텍스트를 가져옴 (let Foo = class Foo {} 에 필요)
        const class_name_text = if (!new_name.isNone()) blk: {
            const name_node = self.new_ast.getNode(new_name);
            break :blk self.new_ast.getText(name_node.data.string_ref);
        } else null;

        // class node 생성 (decorator 없이)
        const empty_list = try self.new_ast.addNodeList(&.{});
        const class_node = try self.addExtraNode(.class_expression, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            empty_list.start, empty_list.len, // decorator 제거
        });

        // class decorator 또는 constructor param decorator가 있으면 → let Foo = class Foo {}; 로 변환
        if ((old_deco_len > 0 or ctor_param_decos.len > 0) and class_name_text != null) {
            // let Foo = class Foo {};
            const name_span = self.new_ast.getNode(new_name).data.string_ref;
            const var_name = try self.new_ast.addNode(.{
                .tag = .binding_identifier,
                .span = name_span,
                .data = .{ .string_ref = name_span },
            });
            // variable_declarator: extra = [name, type_ann, init_val]
            const declarator = try self.addExtraNode(.variable_declarator, node.span, &.{
                @intFromEnum(var_name),
                @intFromEnum(NodeIndex.none), // type_ann
                @intFromEnum(class_node), // init_val
            });
            const decl_list = try self.new_ast.addNodeList(&.{declarator});
            const var_decl = try self.addExtraNode(.variable_declaration, node.span, &.{
                1, decl_list.start, decl_list.len, // 1 = let
            });

            // pending_nodes에 let 선언 추가 (visitExtraList가 class 노드 앞에 삽입)
            try self.pending_nodes.append(self.allocator, var_decl);

            // member decorator 호출: __decorateClass([dec], Foo.prototype, "name", kind)
            for (member_decos) |md| {
                const call_stmt = try self.buildDecorateClassMemberCall(decorate_span, name_span, md);
                try self.pending_nodes.append(self.allocator, call_stmt);
            }

            // class + constructor param decorator 호출: Foo = __decorateClass([...paramDecos, ...classDecos], Foo)
            const class_deco_stmt = try self.buildDecorateClassCall(decorate_span, name_span, old_deco_start, old_deco_len, ctor_param_decos);
            try self.pending_nodes.append(self.allocator, class_deco_stmt);

            // static field: Foo.x = value (decorator 호출 뒤에 배치)
            for (static_field_assigns) |field| {
                const stmt = try self.buildStaticFieldAssignment(new_name, field);
                try self.pending_nodes.append(self.allocator, stmt);
            }

            for (static_block_iifes) |iife| {
                try self.pending_nodes.append(self.allocator, iife);
            }

            return .none;
        }

        // class decorator가 없고 member decorator만 있는 경우
        // pending_nodes는 child 앞에 삽입되므로, class 노드도 pending에 넣고
        // decorator 호출을 그 뒤에 추가한 후 .none을 반환한다.
        if (member_decos.len > 0 and class_name_text != null) {
            const name_span = self.new_ast.getNode(new_name).data.string_ref;

            // class 노드를 pending에 추가
            const class_result = try self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
                none,                   0,                       0,
                empty_list.start, empty_list.len, // decorator 제거
            });
            try self.pending_nodes.append(self.allocator, class_result);

            for (member_decos) |md| {
                const call_stmt = try self.buildDecorateClassMemberCall(decorate_span, name_span, md);
                try self.pending_nodes.append(self.allocator, call_stmt);
            }

            for (static_field_assigns) |field| {
                const stmt = try self.buildStaticFieldAssignment(new_name, field);
                try self.pending_nodes.append(self.allocator, stmt);
            }

            for (static_block_iifes) |iife| {
                try self.pending_nodes.append(self.allocator, iife);
            }

            return .none;
        }

        // decorator가 없는 경우
        // ES2022: static block이 있으면 class를 pending에 넣고 IIFE를 뒤에 추가
        if (static_block_iifes.len > 0) {
            const class_result = try self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
                none,                   0,                       0,
                empty_list.start,       empty_list.len,
            });
            try self.pending_nodes.append(self.allocator, class_result);
            for (static_block_iifes) |iife| {
                try self.pending_nodes.append(self.allocator, iife);
            }
            return .none;
        }

        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            empty_list.start,       empty_list.len,
        });
    }

    /// __decorateClass([dec1, dec2], Foo.prototype, "methodName", kind) 호출문 생성
    pub fn buildDecorateClassMemberCall(
        self: *Transformer,
        decorate_span: Span,
        class_name_span: Span,
        md: MemberDecoratorInfo,
    ) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        // callee: __decorateClass
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = decorate_span,
            .data = .{ .string_ref = decorate_span },
        });

        // arg1: [dec1, dec2, ...]
        const deco_array_list = try self.new_ast.addNodeList(md.decorators);
        const deco_array = try self.new_ast.addNode(.{
            .tag = .array_expression,
            .span = zero_span,
            .data = .{ .list = deco_array_list },
        });

        // arg2: Foo.prototype (instance) or Foo (static)
        const class_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = class_name_span,
            .data = .{ .string_ref = class_name_span },
        });
        const target = if (!md.is_static) blk: {
            const proto_span = try self.new_ast.addString("prototype");
            const proto_id = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = proto_span,
                .data = .{ .string_ref = proto_span },
            });
            const me = try self.new_ast.addExtras(&.{ @intFromEnum(class_ref), @intFromEnum(proto_id), 0 });
            break :blk try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = zero_span,
                .data = .{ .extra = me },
            });
        } else class_ref;

        // arg3: "methodName" 또는 computed key expression
        const key_node = self.new_ast.getNode(md.key);
        const key_string = if (key_node.tag == .computed_property_key)
            // computed key: [expr] → 그대로 expression 전달
            key_node.data.unary.operand
        else blk: {
            // 일반 key: identifier/string → 따옴표로 감싼 문자열 리터럴
            const key_text = self.new_ast.getText(key_node.data.string_ref);
            var quoted_buf: [256]u8 = undefined;
            quoted_buf[0] = '"';
            const copy_len = @min(key_text.len, quoted_buf.len - 2);
            @memcpy(quoted_buf[1 .. 1 + copy_len], key_text[0..copy_len]);
            quoted_buf[1 + copy_len] = '"';
            const quoted_span = try self.new_ast.addString(quoted_buf[0 .. 2 + copy_len]);
            break :blk try self.new_ast.addNode(.{
                .tag = .string_literal,
                .span = quoted_span,
                .data = .{ .string_ref = quoted_span },
            });
        };

        // arg4: kind (1=method, 2=property) — string_table에 숫자 텍스트 저장
        const kind_text = if (md.kind == 1) "1" else "2";
        const kind_span = try self.new_ast.addString(kind_text);
        const kind_node = try self.new_ast.addNode(.{
            .tag = .numeric_literal,
            .span = kind_span,
            .data = .{ .number_bytes = @bitCast(@as(f64, @floatFromInt(md.kind))) },
        });

        const args = try self.new_ast.addNodeList(&.{ deco_array, target, key_string, kind_node });
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee), args.start, args.len, 0,
        });
        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });
    }

    /// Foo = __decorateClass([...ctorParamDecos, ...classDecos], Foo) 호출문 생성 (class + constructor param decorator)
    pub fn buildDecorateClassCall(
        self: *Transformer,
        decorate_span: Span,
        class_name_span: Span,
        old_deco_start: u32,
        old_deco_len: u32,
        ctor_param_decos: []const NodeIndex,
    ) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        // callee: __decorateClass
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = decorate_span,
            .data = .{ .string_ref = decorate_span },
        });

        // arg1: [...ctorParamDecos, ...classDecos]
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // constructor parameter decorators 먼저 (TypeScript 순서: __param → class decorator)
        for (ctor_param_decos) |param_deco| {
            try self.scratch.append(self.allocator, param_deco);
        }

        // class decorators
        if (old_deco_len > 0) {
            const old_deco_indices = self.old_ast.extra_data.items[old_deco_start .. old_deco_start + old_deco_len];
            for (old_deco_indices) |raw_idx| {
                try self.scratch.append(self.allocator, try self.visitDecoratorExpression(raw_idx));
            }
        }

        const deco_array_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const deco_array = try self.new_ast.addNode(.{
            .tag = .array_expression,
            .span = zero_span,
            .data = .{ .list = deco_array_list },
        });

        // arg2: Foo
        const class_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = class_name_span,
            .data = .{ .string_ref = class_name_span },
        });

        const args = try self.new_ast.addNodeList(&.{ deco_array, class_ref });
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee), args.start, args.len, 0,
        });

        // Foo = __decorateClass([dec], Foo)
        const lhs = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = class_name_span,
            .data = .{ .string_ref = class_name_span },
        });
        const assign = try self.new_ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = lhs, .right = call, .flags = 0 } },
        });
        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
    }

    /// for_statement: extra_data = [init, test, update, body]
    fn visitForStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_init = try self.visitNode(self.readNodeIdx(e, 0));
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
        const new_cases = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.switch_statement, node.span, &.{
            @intFromEnum(new_disc), new_cases.start, new_cases.len,
        });
    }

    /// switch_case: extra_data = [test, stmts_start, stmts_len]
    fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_test = try self.visitNode(self.readNodeIdx(e, 0));
        const new_stmts = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.switch_case, node.span, &.{ @intFromEnum(new_test), new_stmts.start, new_stmts.len });
    }

    /// call_expression: extra = [callee, args_start, args_len, flags]
    pub fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 3 >= extras.len) return NodeIndex.none;
        const callee: NodeIndex = @enumFromInt(extras[e]);
        const args_start = extras[e + 1];
        const args_len = extras[e + 2];
        const flags = extras[e + 3];
        const new_callee = try self.visitNode(callee);
        const new_args = try self.visitExtraList(args_start, args_len);
        const new_extra = try self.new_ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.new_ast.addNode(.{
            .tag = .call_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// new_expression: extra = [callee, args_start, args_len, flags]
    fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 3 >= extras.len) return NodeIndex.none;
        const callee: NodeIndex = @enumFromInt(extras[e]);
        const args_start = extras[e + 1];
        const args_len = extras[e + 2];
        const flags = extras[e + 3];
        const new_callee = try self.visitNode(callee);
        const new_args = try self.visitExtraList(args_start, args_len);
        const new_extra = try self.new_ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.new_ast.addNode(.{
            .tag = .new_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    // constructor의 parameter property (public x: number) 변환도 처리.
    // abstract 메서드 (flags bit5=0x20)는 런타임에 존재하면 안 되므로 완전히 제거.
    fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 4);
        // abstract 메서드는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0x20) != 0) return NodeIndex.none;
        // TS method overload signature: body가 없으면 제거
        if (self.readNodeIdx(e, 3).isNone()) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 — parameter property 감지
        const params_start = self.readU32(e, 1);
        const params_len = self.readU32(e, 2);
        const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];
        const pp = try self.visitParamsCollectProperties(old_params);

        var new_body = try self.visitNode(self.readNodeIdx(e, 3));

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_count > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
        }

        // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
        // method_definition에서는 제거한다.
        const new_decos = if (self.options.experimental_decorators)
            NodeList{ .start = 0, .len = 0 }
        else
            try self.visitExtraList(self.readU32(e, 5), self.readU32(e, 6));
        return self.addExtraNode(.method_definition, node.span, &.{
            @intFromEnum(new_key), pp.new_params.start, pp.new_params.len, @intFromEnum(new_body),
            self.readU32(e, 4),    new_decos.start,     new_decos.len,
        });
    }

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    // abstract 프로퍼티 (flags bit5=0x20) 및 declare 필드 (flags bit6=0x40)는
    // 런타임에 존재하면 안 되므로 완전히 제거.
    // declare 필드가 남으면 undefined로 초기화되어 의미가 바뀜.
    fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 2);
        // abstract 프로퍼티 또는 declare 필드는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0x60) != 0) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
        // property_definition에서는 제거한다.
        const new_decos = if (self.options.experimental_decorators)
            NodeList{ .start = 0, .len = 0 }
        else
            try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        return self.addExtraNode(.property_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    // accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
    fn visitAccessorProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 2);
        // declare accessor는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0x40) != 0) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        const new_decos = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        return self.addExtraNode(.accessor_property, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    /// object_property: binary = { left=key, right=value, flags }
    fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015: shorthand property 확장 ({ x } → { x: x })
        if (self.options.target.needsES2015() and node.data.binary.right.isNone()) {
            return es2015_shorthand.ES2015Shorthand(Transformer).expandShorthand(self, node);
        }
        const new_key = try self.visitNode(node.data.binary.left);
        const new_value = try self.visitNode(node.data.binary.right);
        return self.new_ast.addNode(.{
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
        const new_decos = try self.visitExtraList(self.readU32(e, 4), self.readU32(e, 5));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.formal_parameter, node.span, &.{
            @intFromEnum(new_pattern), none,            @intFromEnum(new_default), // type_ann 제거
            0,                         new_decos.start, new_decos.len,
        });
    }

    /// import_declaration:
    ///   모든 import는 extra = [specs_start, specs_len, source_node] 형식.
    ///   side-effect import (import "module")은 specs_len=0.
    fn visitImportDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const specs_start = self.readU32(e, 0);
        const specs_len = self.readU32(e, 1);

        // Unused import 제거: 모든 specifier의 reference_count가 0이면 import 전체를 제거.
        // side-effect import (import 'foo')는 specifier가 없으므로 제거하지 않음.
        if (self.symbols.len > 0 and self.old_symbol_ids.len > 0 and specs_len > 0) {
            const all_unused = self.areAllSpecifiersUnused(specs_start, specs_len);
            if (all_unused) return .none;
        }

        const new_specs = try self.visitExtraList(specs_start, specs_len);
        const new_source = try self.visitNode(self.readNodeIdx(e, 2));
        return self.addExtraNode(.import_declaration, node.span, &.{
            new_specs.start, new_specs.len, @intFromEnum(new_source),
        });
    }

    /// import의 모든 specifier가 미사용인지 확인한다.
    /// type-only specifier(이미 스트리핑됨)와 reference_count==0인 specifier만 있으면 true.
    fn areAllSpecifiersUnused(self: *Transformer, specs_start: u32, specs_len: u32) bool {
        var i: u32 = 0;
        while (i < specs_len) : (i += 1) {
            const spec_idx_raw = self.old_ast.extra_data.items[specs_start + i];
            const spec_idx: NodeIndex = @enumFromInt(spec_idx_raw);
            if (spec_idx.isNone()) continue;
            const spec_node = self.old_ast.getNode(spec_idx);

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
            if (sym_node_idx < self.old_symbol_ids.len) {
                if (self.old_symbol_ids[sym_node_idx]) |sym_id| {
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
        const new_specs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
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
            // TS 선언 (통째로 삭제)
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
            => true,
            else => false,
        };
    }

    // ================================================================
    // React Fast Refresh — 컴포넌트 등록 주입
    // ================================================================

    /// 함수 이름이 React 컴포넌트 명명 규칙(PascalCase)인지 확인.
    fn isComponentName(name: []const u8) bool {
        if (name.len == 0) return false;
        return name[0] >= 'A' and name[0] <= 'Z';
    }

    /// 함수 노드에서 이름 텍스트를 추출한다.
    /// function_declaration의 extra[0]이 binding_identifier.
    /// new_ast의 extra_data에서 읽음 (visitFunction이 이미 new_ast에 노드를 생성했으므로).
    fn getFunctionName(self: *Transformer, func_node: Node) ?[]const u8 {
        const e = func_node.data.extra;
        if (e >= self.new_ast.extra_data.items.len) return null;
        const name_idx: NodeIndex = @enumFromInt(self.new_ast.extra_data.items[e]);
        if (name_idx.isNone()) return null;
        const name_node = self.new_ast.getNode(name_idx);
        if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return null;
        return self.new_ast.getText(name_node.data.string_ref);
    }

    /// 변환된 함수 노드가 React 컴포넌트이면 등록 정보를 수집한다.
    /// visitFunction에서 호출.
    fn maybeRegisterRefreshComponent(self: *Transformer, new_func_idx: NodeIndex) Error!void {
        if (!self.options.react_refresh) return;

        const func_node = self.new_ast.getNode(new_func_idx);
        const name = self.getFunctionName(func_node) orelse return;
        if (!isComponentName(name)) return;

        // 핸들 변수명 생성 + 등록 (프로그램 끝에서 일괄 주입)
        const handle_span = try self.makeRefreshHandle();
        try self.refresh_registrations.append(self.allocator, .{
            .handle_span = handle_span,
            .name = name,
        });
    }

    /// _c, _c2, _c3, ... 핸들 변수명 생성
    fn makeRefreshHandle(self: *Transformer) Error!Span {
        const idx = self.refresh_registrations.items.len;
        if (idx == 0) {
            return self.new_ast.addString("_c");
        }
        var buf: [16]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "_c{d}", .{idx + 1}) catch return error.OutOfMemory;
        return self.new_ast.addString(len);
    }

    /// 프로그램 끝에 var _c, _c2; $RefreshReg$(_c, "Name"); ... 를 추가한다.
    fn appendRefreshRegistrations(self: *Transformer, root: NodeIndex) Error!NodeIndex {
        const prog = self.new_ast.getNode(root);
        if (prog.tag != .program) return root;

        const old_list = prog.data.list;
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // 기존 문장 복사
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        // _c = App; _c2 = Helper; 할당문 (함수 선언 뒤에 실행)
        for (self.refresh_registrations.items) |reg| {
            const assign_stmt = try self.buildRefreshAssignment(reg);
            try self.scratch.append(self.allocator, assign_stmt);
        }

        // var _c, _c2, ...; 선언
        const var_decl = try self.buildRefreshVarDeclaration();
        try self.scratch.append(self.allocator, var_decl);

        // var _s = $RefreshSig$(); 선언들
        const refresh_sig_span = try self.new_ast.addString("$RefreshSig$");
        for (self.refresh_signatures.items) |sig| {
            const sig_decl = try self.buildRefreshSigDeclaration(sig, refresh_sig_span);
            try self.scratch.append(self.allocator, sig_decl);
        }

        // _s(Component, "signature"); 호출들
        for (self.refresh_signatures.items) |sig| {
            const sig_call = try self.buildRefreshSigCall(sig);
            try self.scratch.append(self.allocator, sig_call);
        }

        // $RefreshReg$(_c, "ComponentName"); 호출들
        const refresh_reg_span = try self.new_ast.addString("$RefreshReg$");
        for (self.refresh_registrations.items) |reg| {
            const reg_stmt = try self.buildRefreshRegCall(reg, refresh_reg_span);
            try self.scratch.append(self.allocator, reg_stmt);
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = .program,
            .span = prog.span,
            .data = .{ .list = new_list },
        });
    }

    /// _c = ComponentName; 할당문 생성
    fn buildRefreshAssignment(self: *Transformer, reg: RefreshRegistration) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        const handle_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = reg.handle_span,
            .data = .{ .string_ref = reg.handle_span },
        });
        const comp_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = zero_span,
            .data = .{ .string_ref = try self.new_ast.addString(reg.name) },
        });
        const assign = try self.new_ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = handle_ref, .right = comp_ref, .flags = 0 } },
        });
        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
    }

    /// var _c, _c2, ...; 선언 노드 생성
    fn buildRefreshVarDeclaration(self: *Transformer) Error!NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        const none = @intFromEnum(NodeIndex.none);

        for (self.refresh_registrations.items) |reg| {
            const binding = try self.new_ast.addNode(.{
                .tag = .binding_identifier,
                .span = reg.handle_span,
                .data = .{ .string_ref = reg.handle_span },
            });

            // variable_declarator: extra = [name, type_ann(none), init(none)]
            const declarator = try self.addExtraNode(.variable_declarator, reg.handle_span, &.{
                @intFromEnum(binding),
                none, // type annotation
                none, // initializer
            });
            try self.scratch.append(self.allocator, declarator);
        }

        const decl_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.addExtraNode(.variable_declaration, .{ .start = 0, .end = 0 }, &.{
            0, // var
            decl_list.start,
            decl_list.len,
        });
    }

    /// $RefreshReg$(_c, "ComponentName"); 호출문 생성
    fn buildRefreshRegCall(self: *Transformer, reg: RefreshRegistration, refresh_reg_span: Span) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = refresh_reg_span,
            .data = .{ .string_ref = refresh_reg_span },
        });

        const handle_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = reg.handle_span,
            .data = .{ .string_ref = reg.handle_span },
        });

        // "ComponentName" 문자열 리터럴 (따옴표 포함)
        var quoted_buf: [256]u8 = undefined;
        const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{reg.name}) catch return error.OutOfMemory;
        const quoted_span = try self.new_ast.addString(quoted);
        const name_str = try self.new_ast.addNode(.{
            .tag = .string_literal,
            .span = quoted_span,
            .data = .{ .string_ref = quoted_span },
        });

        const args = try self.new_ast.addNodeList(&.{ handle_ref, name_str });
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            args.start,
            args.len,
            0,
        });

        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });
    }

    /// var _s = $RefreshSig$(); 선언 생성
    fn buildRefreshSigDeclaration(self: *Transformer, sig: RefreshSignature, refresh_sig_span: Span) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };
        const none = @intFromEnum(NodeIndex.none);

        // $RefreshSig$() 호출
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = refresh_sig_span,
            .data = .{ .string_ref = refresh_sig_span },
        });
        const empty_args = try self.new_ast.addNodeList(&.{});
        const init_call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            empty_args.start,
            empty_args.len,
            0,
        });

        // var _s = $RefreshSig$();
        const binding = try self.new_ast.addNode(.{
            .tag = .binding_identifier,
            .span = sig.handle_span,
            .data = .{ .string_ref = sig.handle_span },
        });
        const declarator = try self.addExtraNode(.variable_declarator, sig.handle_span, &.{
            @intFromEnum(binding),
            none, // type annotation
            @intFromEnum(init_call),
        });

        const decl_list = try self.new_ast.addNodeList(&.{declarator});
        return self.addExtraNode(.variable_declaration, zero_span, &.{
            0, // var
            decl_list.start,
            decl_list.len,
        });
    }

    /// _s(Component, "signature"); 호출문 생성
    fn buildRefreshSigCall(self: *Transformer, sig: RefreshSignature) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        // _s 식별자
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = sig.handle_span,
            .data = .{ .string_ref = sig.handle_span },
        });

        // Component 식별자
        const comp_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = zero_span,
            .data = .{ .string_ref = try self.new_ast.addString(sig.component_name) },
        });

        // "signature" 문자열 리터럴
        var quoted_buf: [1024]u8 = undefined;
        const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{sig.signature}) catch return error.OutOfMemory;
        const quoted_span = try self.new_ast.addString(quoted);
        const sig_str = try self.new_ast.addNode(.{
            .tag = .string_literal,
            .span = quoted_span,
            .data = .{ .string_ref = quoted_span },
        });

        // _s(Component, "signature")
        const args = try self.new_ast.addNodeList(&.{ comp_ref, sig_str });
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            args.start,
            args.len,
            0,
        });

        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });
    }

    // ================================================================
    // React Fast Refresh — Hook 시그니처 ($RefreshSig$)
    // ================================================================

    /// Hook 호출 이름이 React Hook인지 확인 (use 접두사 + 다음 문자가 대문자).
    fn isHookCall(name: []const u8) bool {
        if (!std.mem.startsWith(u8, name, "use")) return false;
        // "use" 자체도 React 19 hook
        if (name.len == 3) return true;
        // use 다음 문자가 대문자 (useState, useEffect, useMyHook 등)
        return name[3] >= 'A' and name[3] <= 'Z';
    }

    /// old_ast에서 함수 body 내의 Hook 호출을 스캔하여 시그니처 문자열을 생성한다.
    /// Hook이 없으면 null 반환.
    fn scanHookSignature(self: *Transformer, func_body_idx: NodeIndex) Error!?[]const u8 {
        if (!self.options.react_refresh) return null;
        if (func_body_idx.isNone()) return null;

        var sig_buf: std.ArrayList(u8) = .empty;
        defer sig_buf.deinit(self.allocator);

        // old_ast에서 body의 자식 문장들을 순회
        const body_node = self.old_ast.getNode(func_body_idx);
        if (body_node.tag != .block_statement) return null;

        const list = body_node.data.list;
        const stmts = self.old_ast.extra_data.items[list.start .. list.start + list.len];

        for (stmts) |raw_stmt_idx| {
            const stmt_idx: NodeIndex = @enumFromInt(raw_stmt_idx);
            // 재귀적으로 Hook 호출 검색
            try self.findHookCallsInNode(stmt_idx, &sig_buf, null);
        }

        if (sig_buf.items.len == 0) return null;
        return try self.allocator.dupe(u8, sig_buf.items);
    }

    /// Hook 호출을 찾아 시그니처 버퍼에 추가한다 (old_ast 기준).
    /// binding_ctx: 부모 variable_declarator의 LHS 바인딩 텍스트 (null이면 없음).
    fn findHookCallsInNode(self: *Transformer, idx: NodeIndex, sig_buf: *std.ArrayList(u8), binding_ctx: ?[]const u8) Error!void {
        if (idx.isNone()) return;
        if (@intFromEnum(idx) >= self.old_ast.nodes.items.len) return;
        const node = self.old_ast.getNode(idx);

        // call_expression에서 Hook 호출 감지
        if (node.tag == .call_expression) {
            const e = node.data.extra;
            if (self.old_ast.hasExtra(e, 1)) {
                const callee_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[e]);
                if (!callee_idx.isNone() and @intFromEnum(callee_idx) < self.old_ast.nodes.items.len) {
                    const callee = self.old_ast.getNode(callee_idx);
                    var hook_name: ?[]const u8 = null;

                    if (callee.tag == .identifier_reference) {
                        const name = self.old_ast.getText(callee.data.string_ref);
                        if (isHookCall(name)) hook_name = name;
                    } else if (callee.tag == .static_member_expression) {
                        const me = callee.data.binary;
                        if (!me.right.isNone() and @intFromEnum(me.right) < self.old_ast.nodes.items.len) {
                            const prop = self.old_ast.getNode(me.right);
                            if (prop.tag == .identifier_reference) {
                                const name = self.old_ast.getText(prop.data.string_ref);
                                if (isHookCall(name)) hook_name = name;
                            }
                        }
                    }

                    if (hook_name) |name| {
                        if (sig_buf.items.len > 0) {
                            try sig_buf.appendSlice(self.allocator, "\\n");
                        }
                        try sig_buf.appendSlice(self.allocator, name);
                        try sig_buf.append(self.allocator, '{');
                        // 바인딩 패턴 포함: useState{[foo, setFoo](0)}
                        if (binding_ctx) |b| {
                            try sig_buf.appendSlice(self.allocator, b);
                        }
                        // 첫 번째 인자 포함 (useState/useReducer의 초기값)
                        if (self.old_ast.hasExtra(e, 3)) {
                            const args_start = self.old_ast.extra_data.items[e + 1];
                            const args_len = self.old_ast.extra_data.items[e + 2];
                            if (args_len > 0 and args_start < self.old_ast.extra_data.items.len) {
                                const first_arg_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[args_start]);
                                if (!first_arg_idx.isNone() and @intFromEnum(first_arg_idx) < self.old_ast.nodes.items.len) {
                                    const first_arg = self.old_ast.getNode(first_arg_idx);
                                    if (first_arg.span.start < first_arg.span.end and
                                        first_arg.span.start & 0x8000_0000 == 0)
                                    {
                                        try sig_buf.append(self.allocator, '(');
                                        try sig_buf.appendSlice(self.allocator, self.old_ast.source[first_arg.span.start..first_arg.span.end]);
                                        try sig_buf.append(self.allocator, ')');
                                    }
                                }
                            }
                        }
                        try sig_buf.append(self.allocator, '}');
                    }
                }
            }
            return;
        }

        // 중첩 함수는 스킵
        switch (node.tag) {
            .function_declaration, .function_expression, .arrow_function_expression => return,
            else => {},
        }

        // expression_statement → 내부 expression 탐색
        if (node.tag == .expression_statement) {
            try self.findHookCallsInNode(node.data.unary.operand, sig_buf, null);
            return;
        }

        // variable_declaration → declarator들 탐색
        if (node.tag == .variable_declaration) {
            const e = node.data.extra;
            if (self.old_ast.hasExtra(e, 3)) {
                const list_start = self.old_ast.extra_data.items[e + 1];
                const list_len = self.old_ast.extra_data.items[e + 2];
                if (list_start + list_len <= self.old_ast.extra_data.items.len) {
                    const items = self.old_ast.extra_data.items[list_start .. list_start + list_len];
                    for (items) |raw| {
                        try self.findHookCallsInNode(@enumFromInt(raw), sig_buf, null);
                    }
                }
            }
            return;
        }

        // variable_declarator → LHS 바인딩 추출 + init 탐색
        if (node.tag == .variable_declarator) {
            const e = node.data.extra;
            if (self.old_ast.hasExtra(e, 3)) {
                // LHS 바인딩 텍스트 추출 (binding_identifier 또는 array/object pattern)
                const lhs_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[e]);
                var lhs_text: ?[]const u8 = null;
                if (!lhs_idx.isNone() and @intFromEnum(lhs_idx) < self.old_ast.nodes.items.len) {
                    const lhs = self.old_ast.getNode(lhs_idx);
                    if (lhs.span.start < lhs.span.end and lhs.span.start & 0x8000_0000 == 0) {
                        lhs_text = self.old_ast.source[lhs.span.start..lhs.span.end];
                    }
                }

                const init_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[e + 2]);
                try self.findHookCallsInNode(init_idx, sig_buf, lhs_text);
            }
            return;
        }

        // block_statement → 자식 문장들 탐색
        if (node.tag == .block_statement) {
            const l = node.data.list;
            if (l.len > 0 and l.start + l.len <= self.old_ast.extra_data.items.len) {
                const items = self.old_ast.extra_data.items[l.start .. l.start + l.len];
                for (items) |raw| {
                    try self.findHookCallsInNode(@enumFromInt(raw), sig_buf, null);
                }
            }
        }
    }

    /// _s / _s2 핸들 변수명 생성
    fn makeSigHandle(self: *Transformer) Error!Span {
        const idx = self.refresh_signatures.items.len;
        if (idx == 0) {
            return self.new_ast.addString("_s");
        }
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "_s{d}", .{idx + 1}) catch return error.OutOfMemory;
        return self.new_ast.addString(name);
    }

    /// Hook 시그니처가 있는 컴포넌트를 등록하고, body에 _s() 호출을 삽입한다.
    fn maybeRegisterRefreshSignature(
        self: *Transformer,
        func_name: ?[]const u8,
        old_body_idx: NodeIndex,
        new_body: *NodeIndex,
    ) Error!void {
        if (!self.options.react_refresh) return;
        const name = func_name orelse return;
        if (!isComponentName(name)) return;

        const signature = try self.scanHookSignature(old_body_idx) orelse return;

        const handle_span = try self.makeSigHandle();
        try self.refresh_signatures.append(self.allocator, .{
            .handle_span = handle_span,
            .component_name = name,
            .signature = signature,
        });

        // body 시작에 _s(); 호출 삽입
        new_body.* = try self.insertSigCallAtBodyStart(new_body.*, handle_span);
    }

    /// 블록 body 시작에 _s(); 호출문을 삽입한다.
    fn insertSigCallAtBodyStart(self: *Transformer, body_idx: NodeIndex, handle_span: Span) Error!NodeIndex {
        const body = self.new_ast.getNode(body_idx);
        if (body.tag != .block_statement) return body_idx;

        const old_list = body.data.list;
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // _s() 호출문
        const zero_span = Span{ .start = 0, .end = 0 };
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = handle_span,
            .data = .{ .string_ref = handle_span },
        });
        const empty_args = try self.new_ast.addNodeList(&.{});
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            empty_args.start,
            empty_args.len,
            0,
        });
        const call_stmt = try self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });

        // [_s(), ...기존 문장들]
        try self.scratch.append(self.allocator, call_stmt);
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }
};
