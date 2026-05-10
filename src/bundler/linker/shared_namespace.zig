//! Shared namespace object generation for linker metadata.
//!
//! Namespace import/re-export metadata needs both member-access rewrites and,
//! when the namespace is used as a value, an object preamble. This module owns
//! those caches and preamble declarations while `linker.zig` keeps export
//! resolution and symbol population.

const std = @import("std");
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const LinkingMetadata = linker_mod.LinkingMetadata;
const ModuleIndex = @import("../types.zig").ModuleIndex;
const CompiledModule = @import("../compiled_module.zig").CompiledModule;
const profile = @import("../../profile.zig");

const NsExportPair = Linker.NsExportPair;
const SharedNsInline = Linker.SharedNsInline;
const max_chain_depth = 100;

/// 모듈의 중첩 스코프 (비-모듈 스코프) 에 해당 이름이 존재하는지 확인.
/// linker.zig 의 method 와 동일.
fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
    const m = self.getModule(module_index) orelse return false;
    const sem = m.semantic orelse return false;
    for (sem.scope_maps, 0..) |scope_map, scope_idx| {
        if (scope_idx == 0) continue;
        if (scope_map.get(name) != null) return true;
    }
    return false;
}

/// ESM namespace import를 위한 namespace 객체 preamble 생성.
/// namespace import/re-export에 대해 ns_member_rewrites + ns_inline_objects를 등록.
/// buildMetadataForAst 내 3곳에서 동일 패턴을 공유. 캐시는 linker 전역
/// (`self.ns_export_cache` / `self.ns_inline_cache`) — 같은 target 을 여러
/// importer 가 namespace import 할 때 collectExportsRecursive DFS 를 단 한 번만 수행.
///
/// `force_inline`: caller 가 isNamespaceUsedAsValue / exported_locals 등으로 결정한
/// 강제 inline 신호. shadow 충돌은 함수 안에서 자체 감지하여 ns_inline_list 를 활성화.
pub fn registerNamespaceRewrites(
    self: *const Linker,
    ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
    ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
    /// 같은 importer 안에서 여러 namespace import 가 같은 target source 의 inline ns_var
    /// 를 공유하도록 caller 가 owned. `cjs_var_cache` 와 같은 패턴 (`metadata.zig`).
    ns_target_to_var: *std.AutoHashMap(u32, []const u8),
    force_inline: bool,
    importer_mod_idx: u32,
    symbol_id: u32,
    target_mod_idx: u32,
    var_name: []const u8,
) std.mem.Allocator.Error!void {
    var scope = profile.begin(.metadata_register_ns_rewrites);
    defer scope.end();

    const mutable_self = @constCast(self);

    // Fast path: lock 으로 캐시 조회. 히트 시 즉시 반환, 미스 시 lock 밖에서 DFS 수행 후
    // double-check 로 put. DFS 자체는 lock 밖 — 다른 스레드가 먼저 같은 target 을
    // 계산할 경우 중복 수행되지만 최종적으로 하나만 캐시에 남음 (두 번째는 폐기).
    mutable_self.ns_cache_mutex.lock();
    const cache_hit: ?[]NsExportPair = self.ns_export_cache.get(target_mod_idx);
    mutable_self.ns_cache_mutex.unlock();

    const cached_exports = if (cache_hit) |cached| cached else blk: {
        var exports: std.ArrayList(NsExportPair) = .empty;
        // 에러 시에만 정리 — 정상 경로에서는 캐시로 소유권 이동
        errdefer {
            for (exports.items) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            exports.deinit(self.allocator);
        }
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();
        // double-check: 다른 스레드가 먼저 put 했을 수 있음 — 내 계산 폐기
        if (self.ns_export_cache.get(target_mod_idx)) |raced| {
            for (exports.items) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            exports.deinit(self.allocator);
            break :blk raced;
        }
        const owned_slice = try self.allocator.dupe(NsExportPair, exports.items);
        exports.deinit(self.allocator);
        try mutable_self.ns_export_cache.put(self.allocator, target_mod_idx, owned_slice);
        break :blk owned_slice;
    };

    var seen_exports = std.StringHashMap(void).init(self.allocator);
    defer seen_exports.deinit();
    for (cached_exports) |exp| {
        try seen_exports.put(exp.exported, {});
    }

    // importer 의 nested binding 과 충돌하는 export 는 inline 시 self-shadow 무한
    // 재귀 위험 → 매핑 등록을 건너뛰고 has_shadow 로 추적.
    // (예: `const setSelectedLog = (i) => LogBoxData.setSelectedLog(i);` 가
    //  `const setSelectedLog = (i) => setSelectedLog(i);` 로 inline 되는 케이스)
    //
    // 또한 ns_target_mod 가 있는 export (re_export_namespace 등) 는 target_mod 별
    // hoisted ns_var 를 만들고 inner_map 매핑은 그 변수명으로 둔다 — emitStaticMember
    // 가 access site 마다 객체 literal 을 inline emit 하는 회귀 방지 (#1928).
    var inner_map = std.StringHashMap([]const u8).init(self.allocator);
    var has_shadow = false;
    for (cached_exports) |exp| {
        if (hasNestedBinding(self, importer_mod_idx, exp.exported)) {
            has_shadow = true;
            continue;
        }
        if (exp.ns_target_mod) |target| {
            const ns_var = if (ns_target_to_var.get(target)) |cached|
                cached
            else blk: {
                const fresh = try makeUniqueNsVarName(self, exp.exported, &seen_exports);
                try ns_target_to_var.put(target, fresh);
                const obj_str = try buildInlineObjectStr(self, target, 0);
                try ns_inline_list.append(self.allocator, .{
                    .symbol_id = null,
                    .object_literal = obj_str,
                    .var_name = fresh,
                });
                break :blk fresh;
            };
            // inner_map 은 ns_inline_list.entry.var_name pointer 를 borrow — ns_inline
            // 이 owner. inner_map.deinit 은 backing 만 해제, value pointer 는 안 건드림 →
            // 같은 메모리 double-free 없음.
            try inner_map.put(exp.exported, ns_var);
            continue;
        }
        const local = if (exp.owned)
            try self.allocator.dupe(u8, exp.local)
        else
            exp.local;
        try inner_map.put(exp.exported, local);
    }
    try ns_rewrite_list.append(self.allocator, .{
        .symbol_id = symbol_id,
        .map = inner_map,
    });

    // ns_inline_list 활성화 조건: caller 가 명시 (force_inline) 또는 shadow 충돌 발생.
    // 후자의 경우 codegen fallback 이 namespace 객체 access 로 emit 할 수 있도록 객체가 필요.
    if (force_inline or has_shadow) {
        if (self.use_shared_ns_preamble) {
            const ns_var_name = try getOrCreateSharedNamespaceVar(self, target_mod_idx, &seen_exports);
            try ns_inline_list.append(self.allocator, .{
                .symbol_id = symbol_id,
                .object_literal = try self.allocator.dupe(u8, ""),
                .var_name = try self.allocator.dupe(u8, ns_var_name),
                .shared_target_mod_idx = target_mod_idx,
            });
        } else {
            const obj_str = try buildInlineObjectStr(self, target_mod_idx, 0);
            const ns_var_name = try makeUniqueNsVarName(self, var_name, &seen_exports);
            try ns_inline_list.append(self.allocator, .{
                .symbol_id = symbol_id,
                .object_literal = obj_str,
                .var_name = ns_var_name,
            });
        }
    }
}

fn getOrCreateSharedNamespaceVar(
    self: *const Linker,
    target_mod_idx: u32,
    seen_exports: *std.StringHashMap(void),
) std.mem.Allocator.Error![]const u8 {
    const mutable_self = @constCast(self);

    mutable_self.ns_cache_mutex.lock();
    if (self.ns_shared_inline_cache.get(target_mod_idx)) |cached| {
        mutable_self.ns_cache_mutex.unlock();
        return cached.var_name;
    }
    mutable_self.ns_cache_mutex.unlock();

    const object_literal = try buildInlineObjectStr(self, target_mod_idx, 0);
    errdefer self.allocator.free(object_literal);
    const base_name = try makeSharedNamespaceBaseName(self, target_mod_idx);
    defer self.allocator.free(base_name);

    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();

    if (self.ns_shared_inline_cache.get(target_mod_idx)) |raced| {
        self.allocator.free(object_literal);
        return raced.var_name;
    }

    const fresh = try makeUniqueSharedNsVarNameLocked(mutable_self, base_name, seen_exports);
    errdefer self.allocator.free(fresh);
    try mutable_self.ns_shared_inline_order.append(self.allocator, target_mod_idx);
    errdefer _ = mutable_self.ns_shared_inline_order.pop();
    try mutable_self.ns_shared_inline_cache.put(self.allocator, target_mod_idx, .{
        .var_name = fresh,
        .object_literal = object_literal,
    });
    try mutable_self.ns_shared_var_names.put(self.allocator, fresh, {});
    return fresh;
}

pub fn appendSharedNamespacePreamble(self: *const Linker, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    const sorted_targets = try self.allocator.dupe(u32, self.ns_shared_inline_order.items);
    defer self.allocator.free(sorted_targets);
    const SortCtx = struct {
        linker: *const Linker,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            const ap = if (ctx.linker.getModule(a)) |m| m.path else "";
            const bp = if (ctx.linker.getModule(b)) |m| m.path else "";
            const order = std.mem.order(u8, ap, bp);
            if (order != .eq) return order == .lt;
            return a < b;
        }
    };
    std.mem.sort(u32, sorted_targets, SortCtx{ .linker = self }, SortCtx.lessThan);

    for (sorted_targets) |target_mod_idx| {
        const entry = self.ns_shared_inline_cache.get(target_mod_idx) orelse continue;
        try out.appendSlice(self.allocator, "var ");
        try out.appendSlice(self.allocator, entry.var_name);
        try out.appendSlice(self.allocator, " = ");
        try out.appendSlice(self.allocator, entry.object_literal);
        try out.appendSlice(self.allocator, ";\n");
    }
}

pub fn restoreSharedNamespaceDecls(self: *const Linker, decls: []const CompiledModule.SharedNsDecl) std.mem.Allocator.Error!void {
    const mutable_self = @constCast(self);
    for (decls) |decl| {
        const target_idx = self.graph.path_to_module.get(decl.target_path) orelse continue;
        const target_mod_idx = @intFromEnum(target_idx);

        mutable_self.ns_cache_mutex.lock();
        if (self.ns_shared_inline_cache.get(target_mod_idx) != null) {
            mutable_self.ns_cache_mutex.unlock();
            continue;
        }
        mutable_self.ns_cache_mutex.unlock();

        const owned_var = try self.allocator.dupe(u8, decl.var_name);
        errdefer self.allocator.free(owned_var);
        const owned_obj = try self.allocator.dupe(u8, decl.object_literal);
        errdefer self.allocator.free(owned_obj);

        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();
        if (self.ns_shared_inline_cache.get(target_mod_idx) != null) {
            self.allocator.free(owned_var);
            self.allocator.free(owned_obj);
            continue;
        }
        if (self.ns_shared_var_names.contains(owned_var)) {
            self.allocator.free(owned_var);
            self.allocator.free(owned_obj);
            continue;
        }
        try mutable_self.ns_shared_inline_order.append(self.allocator, target_mod_idx);
        errdefer _ = mutable_self.ns_shared_inline_order.pop();
        try mutable_self.ns_shared_inline_cache.put(self.allocator, target_mod_idx, .{
            .var_name = owned_var,
            .object_literal = owned_obj,
        });
        try mutable_self.ns_shared_var_names.put(self.allocator, owned_var, {});
    }
}

pub fn collectSharedNamespaceDecls(
    self: *const Linker,
    allocator: std.mem.Allocator,
    md: *const LinkingMetadata,
) std.mem.Allocator.Error![]const CompiledModule.SharedNsDecl {
    var decls: std.ArrayList(CompiledModule.SharedNsDecl) = .empty;
    errdefer {
        for (decls.items) |d| {
            allocator.free(d.target_path);
            allocator.free(d.var_name);
            allocator.free(d.object_literal);
        }
        decls.deinit(allocator);
    }

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (md.ns_inline_objects.entries) |entry| {
        const target_mod_idx = entry.shared_target_mod_idx orelse continue;
        if (seen.contains(target_mod_idx)) continue;
        try seen.put(target_mod_idx, {});

        const target = self.getModule(target_mod_idx) orelse continue;
        @constCast(self).ns_cache_mutex.lock();
        const shared_copy = if (self.ns_shared_inline_cache.get(target_mod_idx)) |shared| SharedNsInline{
            .var_name = shared.var_name,
            .object_literal = shared.object_literal,
        } else null;
        @constCast(self).ns_cache_mutex.unlock();
        const shared = shared_copy orelse continue;

        const target_path = try allocator.dupe(u8, target.path);
        errdefer allocator.free(target_path);
        const var_name = try allocator.dupe(u8, shared.var_name);
        errdefer allocator.free(var_name);
        const object_literal = try allocator.dupe(u8, shared.object_literal);
        errdefer allocator.free(object_literal);

        try decls.append(allocator, .{
            .target_path = target_path,
            .var_name = var_name,
            .object_literal = object_literal,
        });
    }

    return decls.toOwnedSlice(allocator);
}

fn makeSharedNamespaceBaseName(self: *const Linker, target_mod_idx: u32) std.mem.Allocator.Error![]const u8 {
    const target = self.getModule(target_mod_idx) orelse return self.allocator.dupe(u8, "ns");
    const basename = std.fs.path.basename(target.path);
    const without_ext = if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    if (without_ext.len == 0 or !(std.ascii.isAlphabetic(without_ext[0]) or without_ext[0] == '_' or without_ext[0] == '$')) {
        try buf.append(self.allocator, '_');
    }
    for (without_ext) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
            try buf.append(self.allocator, c);
        } else {
            try buf.append(self.allocator, '_');
        }
    }
    return buf.toOwnedSlice(self.allocator);
}

fn makeUniqueSharedNsVarNameLocked(
    self: *Linker,
    base: []const u8,
    seen_exports: *std.StringHashMap(void),
) std.mem.Allocator.Error![]const u8 {
    var candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns", .{base});
    if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;

    var i: usize = 2;
    while (true) : (i += 1) {
        self.allocator.free(candidate);
        candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns_{d}", .{ base, i });
        if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;
    }
}

/// namespace preamble 변수명을 export 이름과 충돌하지 않도록 생성.
/// "z" → "z_ns", 충돌 시 "z_ns2", "z_ns3", ...
fn makeUniqueNsVarName(self: *const Linker, base: []const u8, exports: *const std.StringHashMap(void)) std.mem.Allocator.Error![]const u8 {
    // 첫 시도: base_ns
    const first = try std.mem.concat(self.allocator, u8, &.{ base, "_ns" });
    if (!exports.contains(first)) return first;
    self.allocator.free(first);

    // 충돌 시 progressive suffix: base_ns2, base_ns3, ...
    // export 수가 유한하므로 반드시 종료
    var suffix: u32 = 2;
    while (true) : (suffix += 1) {
        var buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{suffix}) catch unreachable;
        const candidate = try std.mem.concat(self.allocator, u8, &.{ base, "_ns", num_str });
        if (!exports.contains(candidate)) return candidate;
        self.allocator.free(candidate);
    }
}

/// 모듈의 모든 export를 인라인 객체 문자열로 생성 (재귀적).
/// `export * as ns` export는 소스 모듈의 인라인 객체로 중첩.
/// 결과는 `self.ns_inline_cache` 에 target_mod_idx 별로 캐싱 — linker 전역 공유.
fn buildInlineObjectStr(
    self: *const Linker,
    target_mod_idx: u32,
    depth: u32,
) std.mem.Allocator.Error![]const u8 {
    if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
    const target_any = self.getModule(target_mod_idx) orelse
        return try self.allocator.dupe(u8, "{}");

    const mutable_self = @constCast(self);

    // 캐시 히트: 복사본 반환 (호출자가 소유권을 가짐)
    mutable_self.ns_cache_mutex.lock();
    const cache_hit = self.ns_inline_cache.get(target_mod_idx);
    mutable_self.ns_cache_mutex.unlock();
    if (cache_hit) |cached_str| {
        return try self.allocator.dupe(u8, cached_str);
    }

    var exports: std.ArrayList(NsExportPair) = .empty;
    defer {
        for (exports.items) |exp| {
            if (exp.owned) self.allocator.free(exp.local);
        }
        exports.deinit(self.allocator);
    }
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var visited = std.AutoHashMap(u32, void).init(self.allocator);
    defer visited.deinit();
    try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

    // export * as ns 패턴 수집 (별도 처리 — 재귀 인라인 필요)
    const target = target_any;
    var ns_re_exports = std.StringHashMap(u32).init(self.allocator); // exported_name → source_mod
    defer ns_re_exports.deinit();
    for (target.export_bindings) |eb| {
        if (eb.kind == .re_export_namespace) {
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < target.import_records.len) {
                    const src = target.import_records[rec_idx].resolved;
                    if (!src.isNone()) {
                        try ns_re_exports.put(eb.exported_name, @intFromEnum(src));
                    }
                }
            }
        }
    }

    // getter 객체 생성 (Rolldown 호환): { get prop() { return local; } }
    // 값 복사 대신 getter를 사용하여 live binding을 보존한다.
    // circular dep에서 init 시점에 아직 undefined인 변수도 사용 시점에 올바르게 참조.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, "{");
    for (exports.items, 0..) |exp, idx| {
        if (idx > 0) try buf.appendSlice(self.allocator, ", ");
        const needs_quote = needsPropertyQuoteForExport(exp.exported);
        // export * as ns 패턴이면 재귀 인라인 (값으로 참조)
        if (ns_re_exports.get(exp.exported)) |src_mod| {
            if (needs_quote) {
                try buf.appendSlice(self.allocator, "\"");
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, "\": ");
            } else {
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, ": ");
            }
            const nested = try buildInlineObjectStr(self, src_mod, depth + 1);
            defer self.allocator.free(nested);
            try buf.appendSlice(self.allocator, nested);
        } else {
            // getter: get prop() { return local; }
            try buf.appendSlice(self.allocator, "get ");
            if (needs_quote) {
                try buf.appendSlice(self.allocator, "\"");
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, "\"");
            } else {
                try buf.appendSlice(self.allocator, exp.exported);
            }
            try buf.appendSlice(self.allocator, "() { return ");
            try buf.appendSlice(self.allocator, exp.local);
            try buf.appendSlice(self.allocator, "; }");
        }
    }
    try buf.appendSlice(self.allocator, "}");
    const result = try self.allocator.dupe(u8, buf.items);

    // double-check 후 put. race 로 다른 스레드가 이미 put 했으면 내 result 폐기.
    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();
    if (self.ns_inline_cache.get(target_mod_idx)) |raced| {
        self.allocator.free(result);
        return try self.allocator.dupe(u8, raced);
    }
    try mutable_self.ns_inline_cache.put(self.allocator, target_mod_idx, result);
    return try self.allocator.dupe(u8, result);
}

/// JS 예약어인 export 이름은 프로퍼티 키에 따옴표 필요.
fn needsPropertyQuoteForExport(name: []const u8) bool {
    if (name.len == 0) return true;
    const reserved = [_][]const u8{
        "default", "class",      "function", "var",    "let",    "const",
        "if",      "else",       "for",      "while",  "do",     "switch",
        "case",    "break",      "continue", "return", "throw",  "try",
        "catch",   "finally",    "new",      "delete", "typeof", "void",
        "in",      "instanceof", "this",     "with",   "yield",  "await",
        "import",  "export",     "extends",  "super",  "enum",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    if (name[0] >= '0' and name[0] <= '9') return true;
    if (name[0] != '_' and name[0] != '$' and !(name[0] >= 'a' and name[0] <= 'z') and !(name[0] >= 'A' and name[0] <= 'Z')) return true;
    return false;
}
