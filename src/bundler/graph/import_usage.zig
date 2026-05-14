const std = @import("std");
const types = @import("../types.zig");
const module_mod = @import("../module.zig");
const module_parser = @import("../../parser/module.zig");
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;

const Module = module_mod.Module;

/// import_records[rec_i] 가 가리키는 source 의 import_declaration 노드를 source span
/// 일치로 찾고, 그 안의 모든 named binding 이름이 AST 어디에서도 `identifier_reference`
/// 로 등장하지 않으면 true (자기 참조 제외).
///
/// implicit type-only — TS type annotation 안에서만 쓰이는 binding — 은 parser 가 type
/// 노드를 폐기하거나 child_offsets 가 비어있어서 value position 의 identifier_reference
/// 가 AST 어디에도 안 나타남. babel typescript preset 의 statement elision 과 동등.
///
/// 텍스트 매칭이라 semantic analyzer 의 type-position 추적 한계와 무관. 보수적 — default
/// / namespace specifier 가 하나라도 있으면 false, 동명 binding 이 다른 import 에서 value
/// 로 쓰여도 false.
///
/// allocation 실패 시 false (= keep) — resolver 는 기존 hard error 경로 유지.
pub fn isImportAllBindingsUnused(self: anytype, module: *const Module, record: types.ImportRecord) bool {
    const ast_ptr = if (module.ast) |*a| a else return false;

    var binding_names: std.ArrayList([]const u8) = .empty;
    defer binding_names.deinit(self.allocator);
    // import_specifier 가 자체적으로 imported/local 식별자를 `identifier_reference` 로
    // 보유 (parseIdentifierName) — 이들 NodeIndex 를 따로 수집해서 self-reference 제외.
    var spec_self_nodes: std.ArrayList(NodeIndex) = .empty;
    defer spec_self_nodes.deinit(self.allocator);

    var found_decl = false;
    for (ast_ptr.nodes.items) |n| {
        if (n.tag != .import_declaration) continue;
        const e = n.data.extra;
        if (e + 2 >= ast_ptr.extra_data.items.len) continue;
        const x = module_parser.readImportDeclExtras(ast_ptr, e);
        if (x.is_type_only) continue; // type-only declaration 은 runtime record 없음
        if (x.source.isNone()) continue;
        const source_node = ast_ptr.getNode(x.source);
        // record.span 이 정확히 source string literal span 이라 start 비교로 unique
        // (`import_scanner.tryExtractImportDecl` 가 동일 span 사용).
        if (source_node.span.start != record.span.start) continue;
        found_decl = true;

        if (x.specs_len == 0) return false; // side-effect import
        if (x.specs_start + x.specs_len > ast_ptr.extra_data.items.len) return false;
        const spec_indices = ast_ptr.extra_data.items[x.specs_start .. x.specs_start + x.specs_len];
        for (spec_indices) |raw_idx| {
            const spec_idx: NodeIndex = @enumFromInt(raw_idx);
            if (spec_idx.isNone()) return false;
            const spec_node = ast_ptr.getNode(spec_idx);
            // default / namespace 는 보수적으로 keep — JSX pragma 등 implicit value use.
            if (spec_node.tag != .import_specifier) return false;
            const left_idx = spec_node.data.binary.left;
            const local_idx = spec_node.data.binary.right;
            const local_node = if (!local_idx.isNone()) ast_ptr.getNode(local_idx) else spec_node;
            binding_names.append(self.allocator, ast_ptr.getText(local_node.span)) catch return false;

            // `import { A as B }` 면 left/right 둘 다 다른 NodeIndex — 모두 self.
            if (!left_idx.isNone()) {
                spec_self_nodes.append(self.allocator, left_idx) catch return false;
            }
            if (!local_idx.isNone() and @intFromEnum(local_idx) != @intFromEnum(left_idx)) {
                spec_self_nodes.append(self.allocator, local_idx) catch return false;
            }
        }
        break;
    }
    if (!found_decl or binding_names.items.len == 0) return false;

    for (ast_ptr.nodes.items, 0..) |n, ni| {
        if (n.tag != .identifier_reference) continue;
        const this_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(ni)));
        var is_spec_self = false;
        for (spec_self_nodes.items) |s| {
            if (@intFromEnum(this_idx) == @intFromEnum(s)) {
                is_spec_self = true;
                break;
            }
        }
        if (is_spec_self) continue;
        const text = ast_ptr.getText(n.span);
        for (binding_names.items) |name| {
            if (std.mem.eql(u8, text, name)) return false;
        }
    }
    return true;
}
