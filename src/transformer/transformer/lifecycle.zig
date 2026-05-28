//! Transformer construction and teardown helpers.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const state_mod = @import("../state.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const Error = Transformer.Error;
const AstOwnership = state_mod.AstOwnership;

/// 3-constructor 공통: experimental_decorators 가 true 면 use_define_for_class_fields 가 false 여야 한다.
/// stage2 decorator 가 instance field 의 initializer 를 가로채야 하는데, useDefineForClassFields
/// true 는 ECMA-스펙 `[[Define]]` semantics 라 가로챌 곳이 없음. 둘 다 enable 은 모순이라 강제 정정.
fn normalizeOptions(options: TransformOptions) TransformOptions {
    var opts = options;
    if (opts.experimental_decorators) opts.use_define_for_class_fields = false;
    return opts;
}

pub fn init(allocator: std.mem.Allocator, source_ast: *const Ast, options: TransformOptions) Error!Transformer {
    const opts = normalizeOptions(options);

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
    return finishInit(allocator, @constCast(ast), normalizeOptions(options), .borrowed);
}

/// Transformer 가 `source_ast` 의 *mutation 권한* 만 양도받아 직접 transform 한다.
/// `cloneForTransformer` 의 deep copy 를 회피해 peak RSS 절감 — RFC_TRANSFORMER_OWN_AST.
///
/// 호출 후 `source_ast` 는 *transformer.ast 와 동일 instance* (dangling 아님).
/// `Transformer.deinit` 은 ast 를 건드리지 않는다 — 호출자가 `source_ast.deinit()` 책임.
/// `init` (clone 후 owned) 과 달리, `source_ast` 의 후속 사용도 동일 instance 라 안전.
///
/// `transpile path` 전용. bundler 의 graph cache / HMR re-process 는 원본 보존 의무 →
/// 기존 `init` (clone) 사용 유지.
///
/// **사전조건**: caller 의 `source_ast` 는 *pristine parser 결과* 여야 한다.
/// - `transformed_root == null` — 이미 transform 된 ast 면 driver.zig 의 cache-hit 분기가
///   stale root 를 반환하고 transformer 내부 state (symbol_ids/runtime_helpers/refresh registrations)
///   는 비어 emit 시 helper import 가 누락 (silent miscompile).
/// - `transform_boundary == null` — parser 가 아직 boundary 를 세운 적 없어야 한다. 이미
///   세워진 boundary 를 silent overwrite 하면 D1 invariant (boundary 위는 transformer append)
///   가 깨져 resync analyzer 가 transformer 노드를 parser 노드로 오분류한다.
/// debug 빌드에서 assert 로 강제. release 빌드는 doc-contract 만.
pub fn initFromOwnedAst(
    allocator: std.mem.Allocator,
    source_ast: *Ast,
    options: TransformOptions,
) Error!Transformer {
    std.debug.assert(source_ast.transformed_root == null);
    std.debug.assert(source_ast.transform_boundary == null);

    const opts = normalizeOptions(options);
    // D1 (RFC #1672): parser/transformer 영역 경계 스냅샷.
    // `init` 의 clone 직후와 동일 시점 = 호출 시점의 nodes.items.len.
    // assert 통과 후이므로 caller-visible 부작용은 contract 의 일부.
    source_ast.transform_boundary = @intCast(source_ast.nodes.items.len);
    return finishInit(allocator, source_ast, opts, .owned_from_caller);
}

fn finishInit(
    allocator: std.mem.Allocator,
    ast_ptr: *Ast,
    opts: TransformOptions,
    ownership: AstOwnership,
) Error!Transformer {
    const parser_count: u32 = switch (ownership) {
        // `.owned` 는 clone 직후 → nodes.items.len 이 parser 영역 끝.
        // `.owned_from_caller` 는 source_ast 자체가 parser 결과 → 동일.
        .owned, .owned_from_caller => @intCast(ast_ptr.nodes.items.len),
        .borrowed => ast_ptr.transform_boundary orelse @intCast(ast_ptr.nodes.items.len),
    };
    var self: Transformer = .{
        .ast = ast_ptr,
        .parser_node_count = parser_count,
        .options = opts,
        .refresh_enabled_cached = @import("refresh.zig").computeRefreshEnabled(opts),
        .allocator = allocator,
        .scratch = .empty,
        .pending_nodes = .empty,
        .ast_ownership = ownership,
    };
    if (opts.unsupported.arrow) self.runtime_es5_compat = true;
    return self;
}

pub fn deinit(self: *Transformer) void {
    // `.borrowed` 는 외부 owner (보통 module.parse_arena) 가 ast 를 free.
    // `.owned_from_caller` 는 호출자가 ast 인스턴스의 lifetime 보유 (transpile path
    // 에서는 ast 가 arena 안에 있어 arena.deinit() 으로 일괄 회수). transformer 는
    // ast 를 건드리지 않는다.
    // method 호출 = exhaustive switch → 미래 variant 추가 시 컴파일 에러로 누락 방지.
    if (self.ast_ownership.transformerFreesAst()) {
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
pub fn markRuntimeHelperRef(self: *Transformer, idx: ast_mod.NodeIndex) Error!void {
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
