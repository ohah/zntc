const Span = @import("../lexer/token.zig").Span;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const es_helpers = @import("es_helpers.zig");

pub const AstOwnership = enum { owned, borrowed };

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
    constructor, // class constructor: new.target -> this.constructor
    method, // class method: new.target -> void 0
    function_named: Span, // function Fn: new.target -> this instanceof Fn ? this.constructor : void 0
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
};

/// `class_name` distinguishes instance vs static private methods.
/// null -> instance WeakSet, non-null -> static descriptor + class brand check.
pub const PrivateMethodMapping = struct {
    original_name: []const u8, // "#method"
    weakset_name: []const u8, // "_method"
    func_name: []const u8, // "_method_fn" / "_method_get" / "_method_set"
    member_idx: NodeIndex = NodeIndex.none,
    // Standalone function_declaration span. Keeps leading comments anchored before
    // `function _fn()` instead of after the function header (#1516).
    member_span: Span = .{ .start = 0, .end = 0 },
    kind: es_helpers.PrivateMethodKind = .method,
    class_name: ?[]const u8 = null,
};
