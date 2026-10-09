const Span = @import("../lexer/token.zig").Span;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const es_helpers = @import("es_helpers.zig");

/// transformer 가 보유한 AST 의 소유 관계.
/// - `.owned`: `init` (clone 후 transformer 가 deinit + destroy)
/// - `.borrowed`: `initBorrow` (외부 owner 가 ast 를 mutate-free, transformer 는 cache hit 분기만)
/// - `.owned_from_caller`: `initFromOwnedAst` (호출자가 ast 인스턴스의 lifetime 보유,
///    transformer 는 *직접 mutate* 하나 deinit/destroy 는 호출자 책임). transpile path
///    에서 cloneForTransformer 회피용 — RFC_TRANSFORMER_OWN_AST 참조.
pub const AstOwnership = enum {
    owned,
    borrowed,
    owned_from_caller,

    /// transformer 의 deinit 이 ast.deinit() + allocator.destroy(ast) 를 수행해야 하는지.
    /// `.owned` 만 true — 그 외엔 외부 owner (borrowed) 또는 caller (owned_from_caller) 책임.
    /// exhaustive switch 로 미래 variant 추가 시 컴파일 에러로 누락 방지.
    pub fn transformerFreesAst(self: AstOwnership) bool {
        return switch (self) {
            .owned => true,
            .borrowed, .owned_from_caller => false,
        };
    }
};

pub const GeneratorLabelEntry = struct {
    name: []const u8,
    break_label: u32,
    continue_label: ?u32,
};

pub const NewTargetCtx = union(enum) {
    none,
    constructor, // class constructor: new.target -> this.constructor
    method, // class method: new.target -> void 0
    function_named: NamedFn, // function Fn: new.target -> this instanceof Fn ? this.constructor : void 0

    /// `span` 은 함수 이름, `node` 는 그 바인딩(심볼을 물려준다, #4760).
    pub const NamedFn = struct { span: Span, node: NodeIndex };
};

pub const ConstEnumValue = union(enum) {
    number: f64, // ECMAScript Number: decimals and large integers
    /// Raw string without quotes. The AST printer adds quotes.
    string: []const u8,
};

pub const ConstEnumMember = struct {
    name: []const u8,
    value: ConstEnumValue,
};

pub const ConstEnumDecl = struct {
    name: []const u8,
    members: []const ConstEnumMember,
    /// enum binding symbol id. Used for shadowing checks; member access is inlined
    /// only when identifier_reference points at the same binding. null falls back
    /// to name matching when symbol info is unavailable.
    symbol_id: ?u32,
};

/// `class_name` distinguishes instance vs static private fields.
/// null -> instance WeakMap, non-null -> static descriptor + class brand check.
pub const PrivateFieldMapping = struct {
    original_name: []const u8, // "#x"
    var_name: []const u8, // "_x"
    class_name: ?[]const u8 = null,
    /// Exact generated binding node and SymbolId selected before class
    /// members are visited.
    binding_node: NodeIndex = NodeIndex.none,
    symbol_id: ?u32 = null,
    /// `class_name` 의 원래 바인딩 노드 — 클래스 참조에 심볼을 물려준다 (#4760).
    class_name_node: NodeIndex = NodeIndex.none,
};

/// `class_name` distinguishes instance vs static private methods.
/// null -> instance WeakSet, non-null -> static descriptor + class brand check.
pub const PrivateMethodMapping = struct {
    original_name: []const u8, // "#method"
    weakset_name: []const u8, // "_method"
    /// Exact generated WeakSet/descriptor binding and its producer-selected identity.
    weakset_binding_node: NodeIndex = NodeIndex.none,
    weakset_symbol_id: ?u32 = null,
    func_name: []const u8, // "_method_fn" / "_method_get" / "_method_set"
    /// Exact standalone-function binding, or the inner function binding in a
    /// class-self capture factory.
    func_binding_node: NodeIndex = NodeIndex.none,
    func_symbol_id: ?u32 = null,
    /// Scope reserved for the captured function's class-self factory. The
    /// function binding above belongs to this scope when it is non-none.
    func_factory_scope: ScopeId = .none,
    /// Source class-self identity used by the pre-lowering capture classifier.
    /// Later class/helper visits can change the active transformer context.
    capture_class_self_symbol_id: ?u32 = null,
    /// Captured instance methods expose the returned closure through an outer
    /// variable with the same spelling as the inner function declaration.
    func_outer_binding_node: NodeIndex = NodeIndex.none,
    func_outer_symbol_id: ?u32 = null,
    member_idx: NodeIndex = NodeIndex.none,
    /// Exact parser method owner; member_idx may be a transformed copy.
    source_member_idx: NodeIndex = NodeIndex.none,
    // Standalone function_declaration span. Keeps leading comments anchored before
    // `function _fn()` instead of after the function header (#1516).
    member_span: Span = .{ .start = 0, .end = 0 },
    kind: es_helpers.PrivateMethodKind = .method,
    class_name: ?[]const u8 = null,
    /// `class_name` 의 원래 바인딩 노드 — 클래스 참조에 심볼을 물려준다 (#4760).
    class_name_node: NodeIndex = NodeIndex.none,
};
