//! Code splitting — emitChunks + hash/naming 유틸리티

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;
const rt = @import("../runtime_helpers.zig");
const module_id = @import("../module_id.zig");
const chunk_mod = @import("../chunk.zig");
const ChunkGraph = chunk_mod.ChunkGraph;
const Chunk = chunk_mod.Chunk;
const ChunkIndex = types.ChunkIndex;
const Module = @import("../module.zig").Module;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const rt_names = @import("../../runtime_helper_names.zig");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../../codegen/sourcemap.zig");
const linker_mod = @import("../linker.zig");
const Linker = @import("../linker.zig").Linker;
const SymbolID = @import("../symbol.zig").SymbolID;
const cross_export = @import("../cross_chunk_export.zig");
const RenameTable = @import("../symbol.zig").RenameTable;
const LinkingMetadata = @import("../linker.zig").LinkingMetadata;
const tree_shaker_mod = @import("../tree_shaker.zig");
const TreeShaker = tree_shaker_mod.TreeShaker;
const ALL_EXPORTS_SENTINEL = tree_shaker_mod.ALL_EXPORTS_SENTINEL;
const statement_shaker = @import("../statement_shaker.zig");
const ExportBinding = @import("../binding_scanner.zig").ExportBinding;
const parent = @import("../emitter.zig");
const format_wrapper = @import("format_wrapper.zig");
const plugin_mod = @import("../plugin.zig");
const external_imports = @import("external_imports.zig");
const EmitOptions = parent.EmitOptions;
const OutputFile = parent.OutputFile;
const emitChunkRuntimeHelpers = parent.emitChunkRuntimeHelpers;
const emitModule = parent.emitModule;
const appendRunBeforeMainCalls = parent.appendRunBeforeMainCalls;
const isRunBeforeMainPath = parent.isRunBeforeMainPath;
const shouldInsertRunBeforeMainBefore = parent.shouldInsertRunBeforeMainBefore;
const collectRunBeforeMainClosure = parent.collectRunBeforeMainClosure;
const util = @import("../../util/mod.zig");

const RunBeforeMainCrossImport = struct {
    source_chunk: ChunkIndex,
    name: []const u8,
};

const RunBeforeMainExport = struct { owner: *const Module, symbol: SymbolID };

fn checkedEdgeProvider(l: *const Linker, sym: chunk_mod.CrossChunkSym) !cross_export.Provider {
    const provider = sym.provider orelse return error.MissingCrossChunkProvider;
    if (sym.namespace_output) |expected| {
        const actual = (try provider.namespaceOutputRef(l)) orelse return error.InvalidCrossChunkExport;
        if (!std.meta.eql(actual, expected)) return error.InvalidCrossChunkExport;
    }
    if (provider.owner.index.toU32() != sym.canonical_module or !std.mem.eql(u8, provider.public_name, sym.name)) return error.InvalidCrossChunkExport;
    try provider.validate(l);
    return provider;
}

fn checkedChunkProvider(l: *const Linker, chunk: *const Chunk, sym: chunk_mod.CrossChunkSym) !cross_export.Provider {
    const provider = if (sym.provider) |_| try checkedEdgeProvider(l, sym) else return error.MissingCrossChunkProvider;
    for (chunk.modules.items) |module| if (module == provider.owner.index) return provider;
    return error.InvalidCrossChunkProviderChunk;
}

fn crossChunkPublicName(l: *const Linker, sym: chunk_mod.CrossChunkSym, preserve_modules: bool) ![]const u8 {
    if (l.getCrossChunkGlobalName(sym.canonical_module, sym.name)) |name| return name;
    // PM's unchanged export key is a protocol property, not a local binding.
    if (preserve_modules) return sym.name;
    return error.MissingCrossChunkPublicName;
}

fn firstAsyncChunkModule(chunk: *const Chunk, graph: *const ModuleGraph) ?ModuleIndex {
    for (chunk.modules.items) |index| {
        const module = graph.getModule(index) orelse continue;
        if (module.in_async_cone or module.tla_iife_stmt != null or module.uses_top_level_await) return index;
    }
    return null;
}

/// Resolve the registered helper through its actual provider and output chunk.
/// A canonical local is usable only inside the provider's own chunk.
fn readinessHelperExpression(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    chunk: *const Chunk,
    options: *const EmitOptions,
    linker: *const Linker,
    reg_ids: []const []const u8,
) ![]const u8 {
    const provider = try parent.checkedReadinessAllProvider(graph, linker);
    const helper_chunk_index = chunk_graph.getModuleChunk(provider.module.index);
    if (helper_chunk_index.isNone()) return error.InvalidTlaReadinessHelper;
    if (helper_chunk_index == chunk.index) return try allocator.dupe(u8, provider.local_name);
    const helper_chunk = chunk_graph.getChunk(helper_chunk_index);
    const ext = options.out_extension_js orelse ".js";
    var importer: std.ArrayListUnmanaged(u8) = .empty;
    defer importer.deinit(allocator);
    var helper: std.ArrayListUnmanaged(u8) = .empty;
    defer helper.deinit(allocator);
    try appendChunkOutputPath(chunk, &importer, allocator, options);
    try chunkPlaceholderStem(helper_chunk, &helper, allocator, options);
    const registry = options.format.isWrappedFormat() and !options.preserve_modules;
    const path = if (registry) blk: {
        const raw = @backingInt(helper_chunk_index);
        if (raw >= reg_ids.len) return error.InvalidTlaReadinessHelper;
        break :blk try allocator.dupe(u8, reg_ids[raw]);
    } else if (helper_chunk.explicit_file_name) |file|
        try computeRelativePath(allocator, std.fs.path.dirname(importer.items) orelse "", file, "")
    else if (options.preserve_modules and helper_chunk.rel_dir != null) blk: {
        const target = try computePreserveModulesPath(allocator, helper_chunk.rel_dir.?, ext, options.preserve_modules_root);
        defer allocator.free(target);
        break :blk try computeRelativePath(allocator, std.fs.path.dirname(importer.items) orelse "", target, "");
    } else try computeRelativePath(allocator, std.fs.path.dirname(importer.items) orelse "", helper.items, ext);
    defer allocator.free(path);
    const quoted_path = try quoteChunkPath(allocator, path);
    defer allocator.free(quoted_path);
    const key = try @import("../public_export_key.zig").fromSyntax(allocator, provider.binding.exported_name);
    defer key.deinit(allocator);
    const quoted_key = try std.json.Stringify.valueAlloc(allocator, key.text, .{});
    defer allocator.free(quoted_key);
    return try std.fmt.allocPrint(allocator, "{s}({s})[{s}]", .{ if (registry) "__zntc_require" else "require", quoted_path, quoted_key });
}

/// The key's path slot is compiler-owned AST. Resolve it from the same
/// physical chunk paths used by native import emission, after chunk naming.
/// Source identifiers, export keys, and graph-local indexes are never URLs.
fn appendLexicalRegistryModulePath(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    chunk: *const Chunk,
    options: *const EmitOptions,
    consumer: *const Module,
    provider: *const Module,
    key: @import("../graph/legacy_initialization_registry.zig").Key,
    literals: *std.AutoHashMapUnmanaged(u32, []const u8),
) !void {
    if (key.factory != null) {
        if (options.preserve_modules or !graph.code_splitting or provider.wrap_kind != .esm or
            graph.getModule(consumer.index) != consumer or graph.getModule(provider.index) != provider or
            chunk_graph.getModuleChunk(consumer.index) != chunk.index)
            return error.InvalidLexicalInitializationRegistry;
        return;
    }
    if (!options.preserve_modules or chunk.modules.items.len != 1 or chunk.modules.items[0] != consumer.index or
        graph.getModule(consumer.index) != consumer or graph.getModule(provider.index) != provider or
        consumer.codegen_output_owner == .unassigned or provider.codegen_output_owner == .unassigned or
        chunk_graph.getModuleChunk(consumer.index) != chunk.index) return error.InvalidLexicalInitializationRegistry;
    const target_index = chunk_graph.getModuleChunk(provider.index);
    if (target_index.isNone()) return error.InvalidLexicalInitializationRegistry;
    const target = chunk_graph.getChunk(target_index);
    if (target.modules.items.len != 1 or target.modules.items[0] != provider.index) return error.InvalidLexicalInitializationRegistry;
    const quoted = if (target_index == chunk.index)
        try allocator.dupe(u8, "\"\"")
    else relative_path: {
        var source_path: std.ArrayListUnmanaged(u8) = .empty;
        defer source_path.deinit(allocator);
        var target_path: std.ArrayListUnmanaged(u8) = .empty;
        defer target_path.deinit(allocator);
        try appendChunkOutputPath(chunk, &source_path, allocator, options);
        try appendChunkOutputPath(target, &target_path, allocator, options);
        const relative = try computeRelativePath(allocator, std.fs.path.dirname(source_path.items) orelse "", target_path.items, "");
        defer allocator.free(relative);
        break :relative_path try quoteChunkPath(allocator, relative);
    };
    try putCompilerLiteral(literals, allocator, @backingInt(key.path), quoted);
    const mode = try std.json.Stringify.valueAlloc(allocator, if (options.format == .cjs) "cjs" else "esm", .{});
    try putCompilerLiteral(literals, allocator, @backingInt(key.mode), mode);
}

fn quoteChunkPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, path, cursor, HASH_PLACEHOLDER_PREFIX)) |start| {
        const end = start + HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN;
        if (end > path.len) return error.InvalidChunkHashPlaceholder;
        for (path[start + HASH_PLACEHOLDER_PREFIX.len .. end]) |digit| {
            if (!((digit >= '0' and digit <= '9') or (digit >= 'a' and digit <= 'f') or (digit >= 'A' and digit <= 'F')))
                return error.InvalidChunkHashPlaceholder;
        }
        const segment = try std.json.Stringify.valueAlloc(allocator, path[cursor..start], .{});
        defer allocator.free(segment);
        try out.appendSlice(allocator, segment[1 .. segment.len - 1]);
        // Keep only the compiler's physical sentinel until resolveContentHashes.
        // Encoding it as a JS escape would make the final hash pass miss it.
        try out.appendSlice(allocator, path[start..end]);
        cursor = end;
    }
    const tail = try std.json.Stringify.valueAlloc(allocator, path[cursor..], .{});
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail[1 .. tail.len - 1]);
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

test "readiness helper paths retain real late hash slots without changing literal escapes" {
    const a = std.testing.allocator;
    const slot = HASH_PLACEHOLDER_PREFIX ++ "0123456789abcdef";
    const path = "./quoted\"-\\u0000ZHliteral-한글-" ++ slot ++ ".js";
    const quoted = try quoteChunkPath(a, path);
    defer a.free(quoted);
    const final = try replacePlaceholders(a, quoted, slot, "89abcdef");
    defer a.free(final);
    const parsed = try std.json.parseFromSlice([]const u8, a, final, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("./quoted\"-\\u0000ZHliteral-한글-89abcdef.js", parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, final, HASH_PLACEHOLDER_PREFIX) == null);
}

const ChunkModuleEmitResult = struct {
    code: ?[]const u8 = null,
    mappings: ?[]const SourceMap.Mapping = null,
    names: []const []const u8 = &.{},
    preamble_lines: u32 = 0,
    err: ?anyerror = null,

    fn deinit(self: *ChunkModuleEmitResult, allocator: std.mem.Allocator) void {
        if (self.code) |code| allocator.free(code);
        if (self.mappings) |mappings| allocator.free(mappings);
        for (self.names) |name| allocator.free(name);
        if (self.names.len > 0) allocator.free(self.names);
    }
};

/// Emit the independent module bodies in one chunk. The caller joins the
/// results in sorted module order before rewriting imports and appending code.
fn emitChunkModuleRange(
    allocator: std.mem.Allocator,
    sorted_mods: []const ModuleIndex,
    graph: *const ModuleGraph,
    options: *const EmitOptions,
    linker: ?*Linker,
    entry_mod_idx: ?u32,
    used_names_by_modidx: []const UsedNamesEntry,
    shaker: ?*const TreeShaker,
    with_sourcemap: bool,
    initialized_namespaces: *const std.AutoHashMapUnmanaged(SymbolID, void),
    results: []ChunkModuleEmitResult,
    holder_reservations: *@import("../namespace_holder_reservations.zig").NamespaceHolderReservations,
    lo: usize,
    hi: usize,
) void {
    var i = lo;
    while (i < hi) : (i += 1) {
        const mod_idx = sorted_mods[i];
        const mi = @backingInt(mod_idx);
        if (mi >= graph.moduleCount()) continue;
        const module = graph.getModule(mod_idx) orelse continue;
        if (@import("../runtime_entry_guard_calls.zig").isArtifact(graph, mod_idx)) continue;
        const is_entry = if (entry_mod_idx) |ei| mi == ei else false;
        const used_names: ?[]const []const u8 = if (mi < used_names_by_modidx.len and !used_names_by_modidx[mi].all_used)
            used_names_by_modidx[mi].names
        else
            null;
        var module_options = options.*;
        module_options.preinitialized_esm_namespace = null;
        if (module.exports_symbol) |symbol| {
            const namespace = SymbolID{ .module = module.index, .inner = symbol };
            if (initialized_namespaces.contains(namespace)) module_options.preinitialized_esm_namespace = namespace;
        }
        results[i].code = parent.emitModuleWithHolderReservations(
            allocator,
            module,
            &module_options,
            linker,
            is_entry,
            used_names,
            shaker,
            null,
            if (with_sourcemap) &results[i].mappings else null,
            if (with_sourcemap) &results[i].names else null,
            if (with_sourcemap) &results[i].preamble_lines else null,
            null,
            null,
            null,
            holder_reservations,
        ) catch |err| {
            results[i].err = err;
            continue;
        };
    }
}

/// 동적 청크가 자기 CSS 를 런타임 `<link>` 로 로드하는 prologue 를 buf 에 append.
/// `./<href>` 는 `import.meta.url`(=청크 자신 URL) 기준 해석 → public path/해시
/// 파일명과 무관. 비-DOM(node/worker)에선 no-op. content-hash 계산 전에 호출돼야
/// JS 청크 해시가 prologue 를 포함해 무결성이 유지된다.
/// (css_names 가 디렉터리를 포함하는 비평면 출력은 후속 과제 — basename 가정.)
fn appendCssLinkPrologue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), href: []const u8) !void {
    try buf.appendSlice(allocator, "if(typeof document!==\"undefined\"){var __zntc_css=document.createElement(\"link\");__zntc_css.rel=\"stylesheet\";__zntc_css.href=new URL(\"./");
    try buf.appendSlice(allocator, href);
    try buf.appendSlice(allocator, "\",import.meta.url).href;document.head.appendChild(__zntc_css);}\n");
}

/// 심볼 수준 cross-chunk import 의 **바인딩명**(destructuring 우변/로컬 식별자).
/// dep 청크는 export 를 그 *키*(`default` 같은 예약어 가능)로 노출하지만, 소비자
/// 코드는 그 키를 식별자로 못 쓴다 — 대신 canonical local 명(`_default`, 또는
/// `export default function foo` → `foo`)을 참조한다. `resolveToLocalName` 이
/// default→_default→named-default 체인을 해석해 그 이름을 돌려준다. 비예약어 키는
/// export 명 == 바인딩명(기존 동작 유지). linker 없으면(단위 테스트) 예약어
/// cross-chunk 가 발생하지 않으므로 export 명 그대로.
fn crossChunkBindingName(linker: ?*Linker, sym: chunk_mod.CrossChunkSym) ![]const u8 {
    if (linker) |l| {
        const provider = try checkedEdgeProvider(l, sym);
        if (try provider.namespaceOutputRef(l)) |reference|
            return l.sharedNamespaceEmittedName(reference) orelse error.SharedNamespaceOwnerMissing;
        // The actual Source export edge owns its public key and binding SID.
        // TDZ storage/wrapping does not turn that key into a lexical spelling.
        if (l.getModule(sym.canonical_module)) |module| {
            if (module.findExportBinding(sym.name)) |export_binding| {
                if (try module.quotedExportOrigin(export_binding.*)) |verified| {
                    const local = l.getCrossChunkGlobalName(sym.canonical_module, sym.name) orelse
                        l.getCanonicalByRef(export_binding.symbol) orelse verified.binding_value;
                    if (std.mem.indexOfScalar(u8, local, '\\') != null or
                        !@import("../linker/identifier_name.zig").isIdentifierName(local) or Linker.isReservedName(local))
                        return error.InvalidQuotedExportCanonical;
                    return local;
                }
            }
        }
        if (l.getCrossChunkGlobalName(sym.canonical_module, sym.name)) |g| return g;
        if (Linker.isReservedName(sym.name)) {
            return l.resolveToLocalName(.{
                .module_index = @fromBackingInt(@intCast(sym.canonical_module)),
                .export_name = sym.name,
            }) orelse return error.InvalidCrossChunkLocalName;
        }
    }
    return sym.name;
}

/// Resolve the exact semantic identity behind a cross-chunk export key. Lazy namespace fan-out
/// can discover several public aliases for one local binding; the provider exports that local
/// only once, so the consumer must import the SymbolId once as well.
fn crossChunkSemanticSymbolId(linker: ?*Linker, sym: chunk_mod.CrossChunkSym) ?SymbolID {
    const l = linker orelse return null;
    const module = l.getModule(sym.canonical_module) orelse return null;
    const binding = module.findExportBinding(sym.name) orelse return null;
    if (binding.kind != .local and !binding.hasSyntheticDefault(module.semanticSymbols())) return null;
    const symbol_index = module.exportBindingSemanticIndex(binding.*) orelse return null;
    return SymbolID.make(module.index, symbol_index);
}

/// (#4576) 소비자 청크에서 `binding` 에 대한 **유일** 로컬명을 발급한다. 아직 안 쓰였으면 binding
/// 그대로, 이미 쓰였으면 `binding$N`(N=2,3,…) 중 `used_locals`(선언됨)·`natural_bindings`(다른 binding
/// 의 자연명)에 없는 첫 이름. per-binding 카운터로는 다른 그룹의 자연 `$N`(또는 사용자 `foo$2`)과
/// 충돌하므로(#4576 리뷰 [0]) 반드시 집합으로 유일성을 판정한다.
/// 반환은 borrowed provider binding 또는 `alias_strs` 소유 slice다. 두 집합은 import phase에만
/// borrow하며, provider canonical reset 전에 actual locals를 owned snapshot하고 keys를 비운다.
/// has_global/lazy 로 이름이 고정된 심볼은 호출 전에 예약해 둔다.
fn mintConsumerLocal(
    allocator: std.mem.Allocator,
    binding: []const u8,
    used_locals: *std.StringHashMapUnmanaged(void),
    natural_bindings: *const std.StringHashMapUnmanaged(void),
    alias_strs: *std.ArrayList([]const u8),
) ![]const u8 {
    if (!used_locals.contains(binding)) {
        try used_locals.put(allocator, binding, {});
        return binding;
    }
    var n: u32 = 2;
    while (true) : (n += 1) {
        const cand = try std.fmt.allocPrint(allocator, "{s}${d}", .{ binding, n });
        if (used_locals.contains(cand) or natural_bindings.contains(cand)) {
            allocator.free(cand);
            continue;
        }
        try alias_strs.append(allocator, cand);
        try used_locals.put(allocator, cand, {});
        return cand;
    }
}

/// Reserve already selected lexical bindings, with chunk-owned bytes. The
/// linker clears its prior canonical strings before consuming this list.
fn appendOwnedOccupied(allocator: std.mem.Allocator, occupied: *std.ArrayList([]const u8), name: []const u8) !void {
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try occupied.append(allocator, owned);
}

fn snapshotConsumerLocals(allocator: std.mem.Allocator, used_locals: *const std.StringHashMapUnmanaged(void), occupied: *std.ArrayList([]const u8)) !void {
    var locals = used_locals.keyIterator();
    while (locals.next()) |name| try appendOwnedOccupied(allocator, occupied, name.*);
}

/// (#4572/#4576/#4580/#4579) 소비자 청크에서 `sym` 의 로컬명을 발급하고 body 참조를 정합시킨다.
/// `fixed`(has_global/lazy → 이름 고정)면 binding 그대로, 아니면 mintConsumerLocal 로 유일 발급.
/// 발급한 로컬을 preserve-modules 일 때 `consumer_import_local` 에 적어, 뒤이어 도는 buildMetadataForAst
/// 의 effective_target 이 body 참조를 그 로컬로 맞추게 한다. import 문(여기)이 body 참조의 유일 권위다.
/// ⚠️ (#4579) deconflict 됐을 때만 적으면, minify-identifiers 서 body 의 fallback(target_name)이
/// provider **원본** 로컬명을, import 문은 crossChunkBindingName=provider **mangled** 로컬명을 써 발산
/// (`const t=require();foo()` → foo undefined). default 는 public 명이 없어(=`module.exports=X`) 특히
/// 그렇다. **무조건** 기록으로 둘을 강제 일치시킨다(원인=per-chunk rename_table 이 clearCanonicalNames
/// 로 청크 사이 wipe돼 body path 가 provider mangle 을 못 봄). read(metadata.zig)와 같은 preserve_modules
/// 게이트라 splitting 은 write 도 생략(낭비 방지·gate 를 write 와 co-locate).
/// symbol-level import 블록과 #4580 default 전체바인딩 두 site 공용.
fn exactInitializationHelperCrossExport(linker: *const Linker, sym: chunk_mod.CrossChunkSym) !bool {
    const known_helpers = [_]@TypeOf(linker.graph.lexical_tdz_builtin){ linker.graph.lexical_tdz_builtin, linker.graph.legacy_name_builtin };
    for (known_helpers, 0..) |candidate, index| {
        const known = candidate orelse continue;
        if (known.module_index.toU32() != sym.canonical_module) continue;
        const provider = linker.graph.getModule(known.module_index) orelse return error.InvalidCallsiteTarget;
        if (known.export_index >= provider.export_bindings.len) return error.InvalidCallsiteTarget;
        const binding = provider.export_bindings[known.export_index];
        // The catalog's actual export row selects this edge. Text is only
        // the existing CrossChunkSym export-key contract, never a SID lookup.
        if (!std.mem.eql(u8, binding.exported_name, sym.name)) continue;
        const actual = if (index == 0)
            try @import("../lexical_initialization_builtin.zig").exact(linker.graph)
        else
            try @import("../lexical_initialization_builtin.zig").exactNames(linker.graph);
        if (actual.module != known.module_index or actual.inner != known.symbol_id or
            provider.exportBindingLocalNodeSemanticIndex(binding) != @as(?u32, @backingInt(actual.inner)))
            return error.InvalidCallsiteTarget;
        return true;
    }
    return false;
}

fn deconflictedConsumerLocal(
    linker: ?*Linker,
    sym: chunk_mod.CrossChunkSym,
    binding: []const u8,
    fixed: bool,
    consumer_module_index: ?u32,
    allocator: std.mem.Allocator,
    used_locals: *std.StringHashMapUnmanaged(void),
    natural_bindings: *const std.StringHashMapUnmanaged(void),
    alias_strs: *std.ArrayList([]const u8),
) ![]const u8 {
    var helper_local: ?[]const u8 = null;
    if (linker) |l| {
        if (l.graph.preserve_modules) {
            helper_local = l.getConsumerImportLocal(sym.canonical_module, sym.name);
            if (helper_local) |planned| {
                try used_locals.put(allocator, planned, {});
            } else if (consumer_module_index) |consumer| {
                if (l.preserveRuntimeHelperImportIsShadowed(
                    consumer,
                    sym.canonical_module,
                    sym.name,
                    binding,
                )) {
                    var suffix: u32 = 1;
                    while (true) : (suffix += 1) {
                        const candidate = try std.fmt.allocPrint(allocator, "{s}${d}", .{ binding, suffix });
                        if (used_locals.contains(candidate) or natural_bindings.contains(candidate) or
                            !l.preserveRuntimeHelperImportAliasAvailable(consumer, candidate))
                        {
                            allocator.free(candidate);
                            continue;
                        }
                        try alias_strs.append(allocator, candidate);
                        try used_locals.put(allocator, candidate, {});
                        try l.putConsumerImportLocal(sym.canonical_module, sym.name, candidate);
                        helper_local = candidate;
                        break;
                    }
                }
            }
        }
    }
    const local = helper_local orelse if (fixed)
        binding
    else
        try mintConsumerLocal(allocator, binding, used_locals, natural_bindings, alias_strs);
    // Fixed/global/lazy selections do not necessarily pass through the mint
    // function. They are actual declarations too, so publish them to the same
    // lexical set before the import phase ends.
    try used_locals.put(allocator, local, {});
    if (linker) |l| {
        if (helper_local == null and (l.graph.preserve_modules or try exactInitializationHelperCrossExport(l, sym)))
            try l.putConsumerImportLocal(sym.canonical_module, sym.name, local);
    }
    return local;
}

const ConsumerPropertyOrigin = enum { binding_spelling, module_export_name };

/// Decode the producer's known spelling role exactly once before handing a
/// property StringValue to the member-expression builder. A bare module name
/// is already StringValue; quoted ModuleExportName retains its source encoding.
fn consumerImportPropertyValue(allocator: std.mem.Allocator, spelling: []const u8, origin: ConsumerPropertyOrigin) ![]const u8 {
    switch (origin) {
        .binding_spelling => {
            if (!@import("../linker/identifier_name.zig").isIdentifierName(spelling)) return error.InvalidConsumerImportProperty;
            return @import("../../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(allocator, spelling);
        },
        .module_export_name => {
            if (@import("../linker/preamble_writer.zig").isQuotedName(spelling))
                return @import("../../string_escape.zig").decodeJsStringLiteral(allocator, spelling);
            return spelling;
        },
    }
}

/// The selector carries its existing role explicitly. Binding spellings come
/// from canonical/source identifier producers; public keys may be decoded only
/// from the same verified ordinary provider's actual string-literal edge.
fn ordinaryConsumerPropertyKey(
    allocator: std.mem.Allocator,
    linker: ?*Linker,
    sym: chunk_mod.CrossChunkSym,
    spelling: []const u8,
    origin: ConsumerPropertyOrigin,
) !@import("../public_export_key.zig").Key {
    const keys = @import("../public_export_key.zig");
    if (origin == .binding_spelling) {
        const value = try consumerImportPropertyValue(allocator, spelling, .binding_spelling);
        return .{ .text = value, .owned = value.ptr != spelling.ptr };
    }
    if (!std.mem.eql(u8, spelling, sym.name)) return error.InvalidQuotedConsumerKey;
    if (linker) |l| if (l.getModule(sym.canonical_module)) |module| {
        if (module.findExportBinding(sym.name)) |binding| {
            if (try module.quotedExportOrigin(binding.*)) |verified|
                return keys.fromLiteralSyntax(allocator, verified.literal_syntax);
        }
    };
    // Not applicable keeps its pre-existing property interpretation. This is
    // not permission to decode arbitrary strings or select another SymbolId.
    return keys.fromStringValue(spelling);
}

/// (#4587 target a) preserve-modules CJS 라이브 바인딩 소비자 import 방출.
/// dep 의 재할당(storage) export 를 구조분해로 잡으면 순환에서 로드 시점 undefined 를 박제하므로:
///   1. `const <ns> = require("<bind_arg>");` holder 를 발급하고
///   2. **모든** 심볼을 holder 에서 구조분해해 렉시컬 바인딩을 낸다(#4587 [1]: ns-member/re-export
///      의 bare export-local 참조가 선언되게 — 안 내면 `ReferenceError`).
///   3. 재할당 심볼은 추가로 body 의 **named** 참조를 `<ns>.<key>`(consumer_import_local)로 라이브화
///      한다 — named=live, ns/re-export=snapshot 공존(문서화된 한계).
/// key/local 규칙은 현행 구조분해 site 와 동일(crossChunkBindingName/deconflictedConsumerLocal).
fn emitPmCjsLiveImport(
    allocator: std.mem.Allocator,
    chunk_output: *std.ArrayListUnmanaged(u8),
    linker: ?*Linker,
    graph: *const ModuleGraph,
    dep_module: ModuleIndex,
    syms: []const chunk_mod.CrossChunkSym,
    bind_arg: []const u8,
    lazy_local_keys: bool,
    min: bool,
    legacy_syntax: bool,
    used_locals: *std.StringHashMapUnmanaged(void),
    natural_bindings: *const std.StringHashMapUnmanaged(void),
    alias_strs: *std.ArrayList([]const u8),
    await_namespace: bool,
    async_import_depth: *usize,
    require_callee: []const u8,
    assign_host: bool,
) !void {
    // ns holder: `const ns_x = require("<bind_arg>");`
    const dep_mod = graph.getModule(dep_module) orelse return;
    const ns_base = try types.makeNsVarName(allocator, dep_mod.path);
    // 소유권을 청크-스코프 alias_strs 로 이전한다. mintConsumerLocal 이 ns_base 를 used_locals
    // 키(borrow)로 넣을 수 있어(기존 caller 는 안정 slice 를 넘김) `defer free` 하면 UAF 다.
    try alias_strs.append(allocator, ns_base);
    const ns_local = try mintConsumerLocal(allocator, ns_base, used_locals, natural_bindings, alias_strs);
    if (await_namespace) {
        // This holder already owns the consumer's namespace reads. Carry that
        // same output binding as the callback parameter, after the graph-owned
        // asynchronous provider has completed; do not inspect arbitrary thenables.
        try chunk_output.appendSlice(allocator, if (async_import_depth.* == 0) (if (assign_host) "module.exports = " else "") else "return ");
        try chunk_output.appendSlice(allocator, require_callee);
        try chunk_output.appendSlice(allocator, "(\"");
        try chunk_output.appendSlice(allocator, bind_arg);
        try chunk_output.print(allocator, "\").then(function({s}) {{\n", .{ns_local});
        async_import_depth.* += 1;
    } else {
        try chunk_output.appendSlice(allocator, if (legacy_syntax) "var " else "const ");
        try chunk_output.appendSlice(allocator, ns_local);
        try chunk_output.appendSlice(allocator, if (min) "=require(\"" else " = require(\"");
        try chunk_output.appendSlice(allocator, bind_arg);
        try chunk_output.appendSlice(allocator, if (min) "\");" else "\");\n");
    }

    var destructure_open = false;
    for (syms) |sym| {
        const binding = try crossChunkBindingName(linker, sym);
        const has_global = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null else false;
        const key = if (lazy_local_keys or has_global) binding else sym.name;
        const reassigned = isExportReassigned(graph, dep_module, sym.name);

        // (#4587 [1] 회귀 수정) 렉시컬 바인딩은 재할당 여부와 무관하게 **항상** 낸다.
        // 예전엔 재할당 심볼을 holder 만 내고 `continue` 해 심볼의 로컬 선언이 없었다 →
        // ns-member 재작성(`ns.A`→`A`)·re-export bottom(`exports.A = A`)이 bare export-local
        // 명(`A`)을 참조하는데 미선언 → `ReferenceError: A is not defined`.
        if (legacy_syntax) {
            // The already allocated bindings use member reads when destructuring is unsupported.
        } else if (!destructure_open) {
            try chunk_output.appendSlice(allocator, if (min) "const{" else "const { ");
            destructure_open = true;
        } else {
            try chunk_output.appendSlice(allocator, if (min) "," else ", ");
        }

        if (reassigned) {
            // 재할당 심볼: bare key 로 구조분해(스냅샷 바인딩)해 bare 참조(ns-member/re-export)가
            // 선언되게 하고, **named body 참조**는 consumer_import_local(`<ns>.<key>`)로 라이브
            // 유지(effective_target 이 renames 로 흘림, synthetic_member 와 동일 경로). 즉 named=live,
            // ns/re-export=snapshot 이 공존(문서화된 한계). deconflict 없이 key 그대로 — bare 참조가
            // deconflict 안 된 export-local 명을 쓰고, preserve-modules 는 1 모듈=1 청크라 동명
            // top-level 충돌이 없다(같은 이름 import+local 은 소스 단계 SyntaxError). linker 가
            // null 이면(단위 테스트) 라이브 rename 은 못 걸어도 바인딩은 나므로 무크래시(방어적).
            if (!used_locals.contains(key)) try used_locals.put(allocator, key, {});
            if (legacy_syntax) {
                const quoted = try std.json.Stringify.valueAlloc(allocator, key, .{});
                defer allocator.free(quoted);
                try chunk_output.print(allocator, "var {s}={s}[{s}];\n", .{ key, ns_local, quoted });
            } else try chunk_output.appendSlice(allocator, key);
            if (linker) |l| {
                const property_value = try consumerImportPropertyValue(allocator, key, if (lazy_local_keys or has_global) .binding_spelling else .module_export_name);
                defer if (property_value.ptr != key.ptr) allocator.free(property_value);
                try l.putConsumerImportMember(sym.canonical_module, sym.name, ns_local, property_value);
            }
        } else {
            // 비재할당 심볼: 현행 스냅샷 구조분해.
            const local = try deconflictedConsumerLocal(linker, sym, binding, lazy_local_keys or has_global, null, allocator, used_locals, natural_bindings, alias_strs);
            if (legacy_syntax) {
                const property_key = try ordinaryConsumerPropertyKey(allocator, linker, sym, key, if (lazy_local_keys or has_global) .binding_spelling else .module_export_name);
                defer property_key.deinit(allocator);
                const quoted = try std.json.Stringify.valueAlloc(allocator, property_key.text, .{});
                defer allocator.free(quoted);
                try chunk_output.print(allocator, "var {s}={s}[{s}];\n", .{ local, ns_local, quoted });
            } else if (!std.mem.eql(u8, key, local)) {
                try chunk_output.appendSlice(allocator, key);
                try chunk_output.appendSlice(allocator, if (min) ":" else ": ");
                try chunk_output.appendSlice(allocator, local);
            } else {
                try chunk_output.appendSlice(allocator, key);
            }
        }
    }
    if (destructure_open) {
        try chunk_output.appendSlice(allocator, if (min) "}=" else " } = ");
        try chunk_output.appendSlice(allocator, ns_local);
        try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
    }
}

fn emitPmAsyncWrapperImport(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    linker: ?*Linker,
    provider: *const Module,
    syms: []const chunk_mod.CrossChunkSym,
    path: []const u8,
    helper: []const u8,
    consumer: u32,
    used_locals: *std.StringHashMapUnmanaged(void),
    natural_bindings: *const std.StringHashMapUnmanaged(void),
    alias_strs: *std.ArrayList([]const u8),
) !void {
    const names = try wrapperNamesFor(allocator, provider, null);
    defer names.deinit(allocator);
    const quoted_path = try quoteChunkPath(allocator, path);
    defer allocator.free(quoted_path);
    const state = try std.fmt.allocPrint(allocator, "{s}.state(require({s}))", .{ helper, quoted_path });
    defer allocator.free(state);
    if (names.b) |namespace| try out.print(allocator, "var {s}={s}.namespace;\n", .{ namespace, state });
    var locals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer locals.deinit(allocator);
    for (syms) |sym| {
        const binding = try crossChunkBindingName(linker, sym);
        const global = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) else null;
        const local = try deconflictedConsumerLocal(linker, sym, binding, global != null, consumer, allocator, used_locals, natural_bindings, alias_strs);
        try locals.append(allocator, local);
        try out.print(allocator, "var {s};\n", .{local});
    }
    // Evaluation is owned by publish(), not by an imported forwarding thunk.
    // A real recursive require observes an instantiated namespace and no ready
    // promise yet. Capture that backedge before the provider finishes loading.
    try out.print(allocator, "var {s}=function(){{\n", .{names.a});
    if (names.b) |namespace| try out.print(allocator, "{s}={s}.namespace;\n", .{ namespace, state });
    for (syms, 0..) |sym, index| {
        const global = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) else null;
        const binding = try crossChunkBindingName(linker, sym);
        const key = if (global) |value| value else sym.name;
        const property = try ordinaryConsumerPropertyKey(allocator, linker, sym, key, if (global != null) .binding_spelling else .module_export_name);
        defer property.deinit(allocator);
        const quoted_key = try std.json.Stringify.valueAlloc(allocator, property.text, .{});
        defer allocator.free(quoted_key);
        _ = binding;
        try out.print(allocator, "{s}={s}.internals[{s}];\n", .{ locals.items[index], state, quoted_key });
    }
    try out.print(allocator, "return {s}.__zntc_ready;\n}};\n{s}.__zntc_ready={s}.initializing?void 0:{s}.ready;\n", .{ names.a, names.a, state, state });
}

/// (#4580) 모듈이 default 외 **named** export 를 하나라도 내는가 — `export *`(ESM 스펙상 default
/// 제외, named 확장)를 소스로 **재귀 flatten** 한다. provider 는 `collectExportsRecursive` 로 star 를
/// 펼쳐 named 유무를 판정하므로 소비자도 같아야 한다(안 그러면 star 가 named 0 개일 때 provider 는
/// `module.exports = X` 인데 소비자는 구조분해 → TypeError 잔존, #4580 리뷰 [0]). 미해결/external star
/// 는 provider 도 flatten 불가라 보수적으로 true(구조분해 유지).
fn moduleHasAnyNamedExport(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    m: *const Module,
    seen: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    for (m.export_bindings) |eb| {
        if (eb.kind == .re_export_star) {
            const rec_idx = eb.import_record_index orelse return true;
            if (rec_idx >= m.import_records.len) return true;
            const src_idx = m.import_records[rec_idx].resolved;
            if (src_idx.isNone()) return true; // external → flatten 불가, 보수적 named
            const gop = seen.getOrPut(allocator, @backingInt(src_idx)) catch return true;
            if (gop.found_existing) continue; // 순환 방지
            const src = graph.getModule(src_idx) orelse return true;
            if (moduleHasAnyNamedExport(allocator, graph, src, seen)) return true;
        } else if (!std.mem.eql(u8, eb.exported_name, "default")) {
            return true; // 직접 named (re_export / re_export_namespace 포함)
        }
    }
    return false;
}

/// (#5456) ESM entry 청크(래핑 안 된 entry 모듈)는 entry 모듈의 공개 export 를 codegen 의
/// `export {}` 로만 내고, 중복 export 를 피하려 cross-chunk export 블록에서 그 이름을 뺀다.
/// 그래서 전역명이 공개명과 달라도(`v$1`) 전역명으로는 노출되지 않는다. 소비자는 공개명을
/// key 로 import 하고 전역명을 로컬로 받는다(`import { v as v$1 }`, esbuild 와 같은 형태).
/// 조건은 provider 쪽 필터(xchunk_exports 의 entry_exported 제거)와 정확히 같아야 한다.
fn entryChunkExportsPublicName(
    graph: *const ModuleGraph,
    dep_chunk: *const Chunk,
    name: []const u8,
    options: anytype,
) bool {
    if (options.format != .esm or options.preserve_modules) return false;
    const entry_module = switch (dep_chunk.kind) {
        .entry_point => |info| info.module,
        else => return false,
    };
    const em = graph.getModule(entry_module) orelse return false;
    if (em.wrap_kind.isWrapped()) return false;
    for (em.export_bindings) |eb| {
        if (std.mem.eql(u8, eb.exported_name, name)) return true;
    }
    return false;
}

/// (#4587 target a) dep 청크가 나타내는 단일 모듈 인덱스 (preserve-modules: 1 청크 = 1 모듈).
/// entry_point(비-import-call) 만 — common/manual/dynamic 은 null.
fn depChunkModuleIndex(dep_chunk: *const Chunk) ?ModuleIndex {
    return switch (dep_chunk.kind) {
        .entry_point => |ep| if (ep.is_import_call) null else ep.module,
        else => null,
    };
}

/// (#4587 target a) `dep_module` 의 export `export_name` 이 재할당되는 storage 바인딩인지.
/// **require 타겟(dep) 모듈**을 본다 — re-export 체인일 땐 dep 이 그 이름을 `.local` 로 소유하지
/// 않아(kind=.re_export) false → 소비자가 구조분해(스냅샷) 유지(라이브 전파는 v1 스코프 밖).
/// provider rename(metadata)·끝-할당 skip(emitter) 과 **동일 술어**(exportBindingIsCjsStorage).
fn isExportReassigned(graph: *const ModuleGraph, dep_module: ModuleIndex, export_name: []const u8) bool {
    const m = graph.getModule(dep_module) orelse return false;
    const eb = m.findExportBinding(export_name) orelse return false;
    return m.exportBindingIsCjsStorage(eb.*);
}

/// (#4532 증상4) export 가 **직접 선언한 function 선언**(hoistable)인지. 순환 import 서 소비자가 그
/// export 를 로드 중 접근하면 provider 의 `exports.X = X`(모듈 본문 끝)가 아직 실행 전이라 undefined 다.
/// ESM 은 function 선언이 hoisting 돼 live-binding 으로 항상 함수 → cjs 도 `exports.X=X` 를 require 전에
/// hoist 해 맞춘다. function 선언만 대상(const/let/class 는 hoisting 불가·ESM 도 순환서 TDZ). re-export 는
/// 소스 모듈이 자기 것 hoist 하므로 `.local` 만.
pub fn exportBindingIsHoistableFn(m: *const Module, eb: ExportBinding) bool {
    if (eb.kind != .local) return false;
    // default 는 제외 — `module.exports = X`(default-only) / `exports.default`(mixed) 모드 로직이
    // 별도 처리(hoist 하면 그 로직과 충돌). named function export 만 대상.
    if (std.mem.eql(u8, eb.exported_name, "default")) return false;
    const idx = m.exportBindingLocalNodeSemanticIndex(eb) orelse return false;
    const sem = m.semantic orelse return false;
    if (idx >= sem.symbols.items.len) return false;
    return sem.symbols.items[idx].decl_flags.is_function;
}

/// (#4532 증상4) unwrapped pm-cjs 모듈의 function-decl named export 를 `exports.<X> = <local>;` 로
/// `out` 에 append. 호출부가 require 블록 **앞**에 insert 한다(function 은 hoisted 라 참조 가능).
/// `appendCjsExportBinding(live=false, min=false)` 재사용 — 같은-파일 bottom(emitCjsEntryExports)이
/// minify 무시하고 ` = `/`;\n` 로 내므로 형식 일치(min=false) + export-line 방출 로직 단일화.
fn emitHoistedFnExports(
    l: *Linker,
    graph: *const ModuleGraph,
    mod_idx: u32,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const m = graph.getModule(@fromBackingInt(@intCast(mod_idx))) orelse return;
    for (m.export_bindings) |eb| {
        if (!exportBindingIsHoistableFn(m, eb)) continue;
        const local = l.getCanonicalForExport(eb, mod_idx) orelse return error.InvalidCrossChunkExport;
        const verified = try m.ordinaryQuotedExportLiteral(eb);
        try appendCjsExportBinding(allocator, out, eb.exported_name, if (verified) |value| value.literal_syntax else null, local, false, false);
    }
}

/// (#4580) preserve-modules 단일-모듈 dep 청크의 export shape 가 **default-only** — 즉 provider 가
/// `module.exports = <default>`(default = exports 전체) 를 방출하는지. 이 경우 소비자는 `require()`
/// 결과 **전체**를 default 로 바인딩해야 한다: `const x = require(...)`. `{ default: x }` 구조분해는
/// `.default`=undefined → TypeError(#4580). `.named` OutputExports 는 `exports.default` 를 내므로
/// 호출부에서 auto/default_ 로 게이트한다.
fn cjsDepDefaultOnly(allocator: std.mem.Allocator, graph: *const ModuleGraph, dep_chunk: *const Chunk) bool {
    // (#4587 [6]) entry_point(비-import-call) 판정은 depChunkModuleIndex 로 단일화.
    const mod_idx = depChunkModuleIndex(dep_chunk) orelse return false;
    const m = graph.getModule(mod_idx) orelse return false;
    var has_default = false;
    for (m.export_bindings) |eb| {
        if (eb.kind != .re_export_star and std.mem.eql(u8, eb.exported_name, "default")) {
            has_default = true;
            break;
        }
    }
    if (!has_default) return false;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);
    seen.put(allocator, @backingInt(mod_idx), {}) catch return false;
    return !moduleHasAnyNamedExport(allocator, graph, m, &seen);
}

/// cross-chunk export 의 **provider 측 로컬명**(이 청크에 선언된 실제 식별자, 전역 public 의
/// RHS). owner 모듈 `mi` 가 export `name` 을 어떤 로컬로 들고 있는지 해석한다.
/// - namespace re-export(`export * as X`)는 로컬 심볼이 elided 라 canonical 이 빗나간다 → 청크에
///   materialize 된 shared ns 객체 변수(`ensureSharedNsVar`)가 곧 X 의 실제 값(#3321 후속).
/// - 일반 export 는 canonical rename, 없으면 getExportLocalName(권위 소스)의 비예약어 local
///   (`export { _x as renamed }` 의 `_x`). 예약어 local 은 bare 참조 불가 → null.
/// 못 찾으면 null(호출부가 다른 owner 또는 export 명 fallback 으로 진행). single-owner·collision
/// 양 경로 공용 — 분리돼 있던 단순 해석/full 해석을 하나로 통일.
/// 모듈이 ESM-wrap + top-level await 인가. 그 `init_X()` 호출은 `await` 를 요구하므로 비-async
/// 컨텍스트에선 낼 수 없다: reg_split factory·dev_split factory 는 함수라 top-level await 불가,
/// CJS-format 청크도 top-level await 불가. 세 entry-invoke 지점이 공유해 드리프트를 막는다
/// (각 지점의 컨텍스트별 await-합법성 게이트는 호출부에 남는다 — ESM-format 청크만 허용).
fn isTlaEsmModule(m: anytype) bool {
    return m.wrap_kind == .esm and m.uses_top_level_await;
}

/// (#4120) owner 모듈이 CJS-wrapped 면 cross-chunk export `name` 은 런타임 interop 멤버라 진짜
/// 로컬 바인딩이 없다. provider 청크에 `var <global> = <interop>;` 을 materialize 해 cross-chunk
/// 소비자가 일반 식별자로 import 하게 한다(metadata 의 per-importer preamble 은 #4120 가드로 억제).
/// interop RHS 는 Linker.cjsInteropAccessExpr 로 통합(entry/dynamic buildFinalExports 와 동일 형태).
/// `export {}` *전* 에 1회 emit. require_X 는 모듈 본문에서 이미 정의(var 호이스팅 + memoize).
fn writeCjsInteropMaterialize(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    linker: *Linker,
    owner: *const Module,
    name: []const u8,
    global: []const u8,
    minify: bool,
) !void {
    const rhs = try linker.cjsInteropAccessExpr(allocator, owner, name, minify);
    defer allocator.free(rhs);
    try out.appendSlice(allocator, "var ");
    try out.appendSlice(allocator, global);
    try out.appendSlice(allocator, if (minify) "=" else " = ");
    try out.appendSlice(allocator, rhs);
    try out.appendSlice(allocator, if (minify) ";" else ";\n");
}

pub fn emitChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    options: *const EmitOptions,
    linker: ?*Linker,
) ![]OutputFile {
    if (linker) |l| if (l.graph != graph) return error.InvalidChunkGraphOwner;
    return emitChunksImpl(null, allocator, graph, chunk_graph, options, linker);
}

pub fn emitChunksWithIo(
    io: std.Io,
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    options: *const EmitOptions,
    linker: ?*Linker,
) ![]OutputFile {
    return emitChunksImpl(io, allocator, graph, chunk_graph, options, linker);
}

fn putCompilerLiteral(map: *std.AutoHashMapUnmanaged(u32, []const u8), allocator: std.mem.Allocator, raw: u32, owned: []const u8) !void {
    errdefer allocator.free(owned);
    const slot = try map.getOrPut(allocator, raw);
    if (slot.found_existing) return error.InvalidPmNamespaceCallsite;
    slot.value_ptr.* = owned;
}

fn sortedChunkIndices(allocator: std.mem.Allocator, chunk_graph: *const ChunkGraph) ![]usize {
    const sorted_indices = try allocator.alloc(usize, chunk_graph.chunkCount());
    for (sorted_indices, 0..) |*index, i| index.* = i;
    const SortCtx = struct {
        chunks: []const Chunk,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ca = ctx.chunks[a];
            const cb = ctx.chunks[b];
            // 엔트리 청크 우선
            const a_is_entry: u1 = if (ca.isEntryPoint()) 0 else 1;
            const b_is_entry: u1 = if (cb.isEntryPoint()) 0 else 1;
            if (a_is_entry != b_is_entry) return a_is_entry < b_is_entry;
            // 같은 종류 내에서는 exec_order 순
            return ca.exec_order < cb.exec_order;
        }
    };
    std.mem.sort(usize, sorted_indices, SortCtx{ .chunks = chunk_graph.chunks.items }, SortCtx.lessThan);
    return sorted_indices;
}

// A facade is an output artifact, not a second source module or chunk.
// The shallow chunk view changes only physical filenames; source assignment,
// cross-chunk provider receipts and ModuleIndex/ChunkIndex stay unchanged.
const FacadeGuard = struct {
    target: SymbolID,
    owner: @import("../module.zig").SemanticOwnerToken,
    chunk_index: ChunkIndex,
    public_key: []const u8,
};

const RawFacadeKeys = struct {
    public_keys: []const []const u8 = &.{},
    external_reexports: []const []const u8 = &.{},

    fn deinit(self: RawFacadeKeys, allocator: std.mem.Allocator) void {
        for (self.public_keys) |key| allocator.free(key);
        allocator.free(self.public_keys);
        for (self.external_reexports) |specifier| allocator.free(specifier);
        allocator.free(self.external_reexports);
    }
};

/// Public-key closure follows only constructor-captured parser reexport edges.
/// These strings are Node-CJS lexical metadata, never source SymbolId selectors.
fn collectRawFacadeKeys(allocator: std.mem.Allocator, graph: *const ModuleGraph, source: ModuleIndex) !RawFacadeKeys {
    var pending: std.ArrayListUnmanaged(ModuleIndex) = .empty;
    defer pending.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(allocator);
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (owned.items) |key| allocator.free(key);
        owned.deinit(allocator);
    }
    var externals: std.StringHashMapUnmanaged(void) = .empty;
    defer externals.deinit(allocator);
    var external_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (external_names.items) |specifier| allocator.free(specifier);
        external_names.deinit(allocator);
    }
    try pending.append(allocator, source);
    while (pending.pop()) |index| {
        const seen = try visited.getOrPut(allocator, index.toU32());
        if (seen.found_existing) continue;
        const owner = graph.getModule(index) orelse return error.InvalidPublicEntryFacadeOwner;
        const registry = owner.cjs_public_facade_keys orelse {
            if (owner.exports_kind == .commonjs) return error.InvalidPublicEntryFacadeOwner;
            continue;
        };
        try registry.validate(owner);
        for (registry.direct_keys) |key| {
            if (std.mem.eql(u8, key.value, "default")) continue;
            const entry = try keys.getOrPut(allocator, key.value);
            if (entry.found_existing) continue;
            const copy = try allocator.dupe(u8, key.value);
            errdefer allocator.free(copy);
            try owned.append(allocator, copy);
        }
        for (registry.reexports) |edge| {
            var selected: ?*const types.ImportRecord = null;
            for (owner.import_records) |*record| {
                if (record.kind != .require or record.source_node != edge.source_node) continue;
                if (selected != null) return error.InvalidPublicEntryFacadeOwner;
                selected = record;
            }
            const record = selected orelse return error.InvalidPublicEntryFacadeOwner;
            if (record.is_external) {
                const name = record.externalName();
                const entry = try externals.getOrPut(allocator, name);
                if (!entry.found_existing) {
                    const copy = try allocator.dupe(u8, name);
                    errdefer allocator.free(copy);
                    try external_names.append(allocator, copy);
                }
                continue;
            }
            // A missing target does not invent a module or expose transport keys.
            if (record.resolved.isNone()) return error.InvalidPublicEntryFacadeOwner;
            try pending.append(allocator, record.resolved);
        }
    }
    const public_keys = try owned.toOwnedSlice(allocator);
    errdefer {
        for (public_keys) |key| allocator.free(key);
        allocator.free(public_keys);
    }
    return .{ .public_keys = public_keys, .external_reexports = try external_names.toOwnedSlice(allocator) };
}

const PublicEntryFacade = struct {
    module_index: ModuleIndex,
    chunk_index: ChunkIndex,
    init_identity: SymbolID,
    owner_token: @import("../module.zig").SemanticOwnerToken,
    public_path: []const u8,
    implementation_path: []const u8,
    init_key: []const u8,
    projection: union(enum) {
        esm_default: struct {
            namespace_identity: SymbolID,
            namespace_key: []const u8,
            awaited: bool,
            guard: ?FacadeGuard = null,
        },
        // The callable is the actual source CommonJS wrapper, not an ESM
        // namespace synthesized for a primitive or frozen public value.
        // Decoded public data, never selectors of source binding identities.
        cjs_result: RawFacadeKeys,
    },

    fn isAwaited(self: PublicEntryFacade) bool {
        return switch (self.projection) {
            .esm_default => |esm| esm.awaited,
            .cjs_result => false,
        };
    }

    fn entryGuard(self: PublicEntryFacade) ?FacadeGuard {
        return switch (self.projection) {
            .esm_default => |esm| esm.guard,
            .cjs_result => null,
        };
    }

    fn checkedOwner(self: PublicEntryFacade, graph: *const ModuleGraph, chunk_graph: *const ChunkGraph) !*const Module {
        const owner = graph.getModule(self.module_index) orelse return error.InvalidPublicEntryFacadeOwner;
        const semantic = owner.semantic orelse return error.InvalidPublicEntryFacadeOwner;
        if (self.owner_token == .unassigned or semantic.owner_token != self.owner_token or owner.index != self.module_index or
            @backingInt(owner.index) >= chunk_graph.module_to_chunk.len or !owner.is_entry_point or
            chunk_graph.getModuleChunk(owner.index) != self.chunk_index)
            return error.InvalidPublicEntryFacadeOwner;
        const index = @backingInt(self.chunk_index);
        if (index >= chunk_graph.chunks.items.len) return error.InvalidPublicEntryFacadeOwner;
        const chunk = &chunk_graph.chunks.items[index];
        if (chunk.index != self.chunk_index or chunk.modules.items.len != 1 or chunk.modules.items[0] != owner.index)
            return error.InvalidPublicEntryFacadeOwner;
        switch (self.projection) {
            .esm_default => |esm| {
                if (owner.wrap_kind != .esm or owner.in_async_cone != esm.awaited or
                    !((try owner.esmInitSymbol()).eql(self.init_identity)) or
                    !((try owner.esmNamespaceSymbol()).eql(esm.namespace_identity)) or
                    !std.mem.eql(u8, try owner.esmWrapperName(esm.namespace_identity, null), esm.namespace_key) or
                    !std.mem.eql(u8, try owner.esmWrapperName(self.init_identity, null), self.init_key))
                    return error.InvalidPublicEntryFacadeOwner;
            },
            .cjs_result => |raw| {
                const id = owner.require_symbol orelse return error.InvalidPublicEntryFacadeOwner;
                const index_in_owner = @backingInt(id);
                if (owner.wrap_kind != .cjs or owner.in_async_cone or
                    !self.init_identity.eql(SymbolID.make(owner.index, index_in_owner)) or
                    index_in_owner >= semantic.symbols.items.len or
                    semantic.symbols.items[index_in_owner].synthetic_kind != .cjs_require or
                    !std.mem.eql(u8, owner.getRequireName(null) orelse return error.InvalidPublicEntryFacadeOwner, self.init_key))
                    return error.InvalidPublicEntryFacadeOwner;
                const expected_keys = try collectRawFacadeKeys(chunk_graph.allocator, graph, owner.index);
                defer expected_keys.deinit(chunk_graph.allocator);
                if (raw.public_keys.len != expected_keys.public_keys.len or raw.external_reexports.len != expected_keys.external_reexports.len) return error.InvalidPublicEntryFacadeOwner;
                for (raw.external_reexports, expected_keys.external_reexports) |actual, expected| {
                    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPublicEntryFacadeOwner;
                }
                for (raw.public_keys, expected_keys.public_keys) |actual, expected| {
                    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPublicEntryFacadeOwner;
                }
            },
        }
        if (self.entryGuard()) |guard| {
            if (self.isAwaited() or !(try @import("../runtime_entry_guard_ast.zig").exactBinding(graph)).eql(guard.target)) return error.InvalidPublicEntryFacadeOwner;
            const provider = graph.getModule(guard.target.module) orelse return error.InvalidPublicEntryFacadeOwner;
            const guard_index = @backingInt(guard.chunk_index);
            if (guard_index >= chunk_graph.chunks.items.len) return error.InvalidPublicEntryFacadeOwner;
            const guard_chunk = &chunk_graph.chunks.items[guard_index];
            if (guard_chunk.index != guard.chunk_index or guard_chunk.modules.items.len != 1 or guard_chunk.modules.items[0] != provider.index)
                return error.InvalidPublicEntryFacadeOwner;
            if (provider.semantic == null or provider.semantic.?.owner_token != guard.owner or
                chunk_graph.getModuleChunk(provider.index) != guard.chunk_index or provider.export_bindings.len != 1)
                return error.InvalidPublicEntryFacadeOwner;
            const key = try @import("../public_export_key.zig").fromSyntax(chunk_graph.allocator, provider.export_bindings[0].exported_name);
            defer key.deinit(chunk_graph.allocator);
            if (!std.mem.eql(u8, key.text, guard.public_key)) return error.InvalidPublicEntryFacadeOwner;
        }
        return owner;
    }

    fn deinit(self: PublicEntryFacade, allocator: std.mem.Allocator) void {
        allocator.free(self.public_path);
        allocator.free(self.implementation_path);
        switch (self.projection) {
            .esm_default => |esm| allocator.free(esm.namespace_key),
            .cjs_result => |raw| raw.deinit(allocator),
        }
        allocator.free(self.init_key);
        if (self.entryGuard()) |guard| allocator.free(guard.public_key);
    }
};

fn makePublicEntryFacadeOutput(allocator: std.mem.Allocator, facade: PublicEntryFacade, source_owner_path: []const u8, implementation_path: []const u8, guard_implementation_path: ?[]const u8) !OutputFile {
    const relative = try computeRelativePath(allocator, std.fs.path.dirname(facade.public_path) orelse "", implementation_path, "");
    defer allocator.free(relative);
    const quoted_path = try std.json.Stringify.valueAlloc(allocator, relative, .{});
    defer allocator.free(quoted_path);
    const quoted_init = try std.json.Stringify.valueAlloc(allocator, facade.init_key, .{});
    defer allocator.free(quoted_init);
    const raw_code = switch (facade.projection) {
        .cjs_result => |raw| blk: {
            var body: std.ArrayListUnmanaged(u8) = .empty;
            errdefer body.deinit(allocator);
            try body.print(allocator, "module.exports=(0,require({s})[{s}])();\n", .{ quoted_path, quoted_init });
            for (raw.public_keys) |key| {
                const quoted_key = try std.json.Stringify.valueAlloc(allocator, key, .{});
                defer allocator.free(quoted_key);
                // Node's lexical CJS discovery sees source public properties;
                // the annotation must never execute or mutate frozen values.
                try body.print(allocator, "0&&(module.exports[{s}]=0);\n", .{quoted_key});
            }
            for (raw.external_reexports) |specifier| {
                const quoted = try std.json.Stringify.valueAlloc(allocator, specifier, .{});
                defer allocator.free(quoted);
                try body.print(allocator, "0&&(module.exports=require({s}));\n", .{quoted});
            }
            break :blk try body.toOwnedSlice(allocator);
        },
        .esm_default => |esm| blk: {
            const quoted_namespace = try std.json.Stringify.valueAlloc(allocator, esm.namespace_key, .{});
            defer allocator.free(quoted_namespace);
            var bootstrap: std.ArrayListUnmanaged(u8) = .empty;
            defer bootstrap.deinit(allocator);
            if (!esm.awaited) {
                if (esm.guard) |guard| {
                    const guard_path = guard_implementation_path orelse return error.InvalidPublicEntryFacadeOwner;
                    const guard_relative = try computeRelativePath(allocator, std.fs.path.dirname(facade.public_path) orelse "", guard_path, "");
                    defer allocator.free(guard_relative);
                    const quoted_guard_path = try std.json.Stringify.valueAlloc(allocator, guard_relative, .{});
                    defer allocator.free(quoted_guard_path);
                    const quoted_guard_key = try std.json.Stringify.valueAlloc(allocator, guard.public_key, .{});
                    defer allocator.free(quoted_guard_key);
                    try bootstrap.print(allocator, "require({s})[{s}](implementation[{s}]);", .{ quoted_guard_path, quoted_guard_key, quoted_init });
                } else try bootstrap.print(allocator, "(0,implementation[{s}])();", .{quoted_init});
            }
            break :blk if (esm.awaited)
                try std.fmt.allocPrint(allocator, "module.exports=require({s}).then(function(namespace){{return namespace[\"default\"];}});\n", .{quoted_path})
            else
                try std.fmt.allocPrint(allocator, "module.exports=(function(implementation){{{s}return implementation[{s}][\"default\"];}})(require({s}));\n", .{ bootstrap.items, quoted_namespace, quoted_path });
        },
    };
    defer allocator.free(raw_code);
    const program = try @import("../compiler_output_program.zig").Program.create(allocator, raw_code);
    errdefer program.destroy();
    const code = try program.emit(allocator);
    errdefer allocator.free(code);
    const path = try allocator.dupe(u8, facade.public_path);
    errdefer allocator.free(path);
    const source_path = try allocator.dupe(u8, source_owner_path);
    errdefer allocator.free(source_path);
    const imports = try allocator.alloc([]const u8, if (facade.entryGuard() != null) 2 else 1);
    errdefer allocator.free(imports);
    imports[0] = try allocator.dupe(u8, implementation_path);
    errdefer allocator.free(imports[0]);
    if (facade.entryGuard() != null) imports[1] = try allocator.dupe(u8, guard_implementation_path orelse return error.InvalidPublicEntryFacadeOwner);
    errdefer if (facade.entryGuard() != null) allocator.free(imports[1]);
    const raw_keys: []const []const u8 = switch (facade.projection) {
        .cjs_result => |raw| raw.public_keys,
        .esm_default => &.{},
    };
    const exports = try allocator.alloc([]const u8, raw_keys.len + 1);
    var filled_exports: usize = 0;
    errdefer {
        for (exports[0..filled_exports]) |key| allocator.free(key);
        allocator.free(exports);
    }
    exports[0] = try allocator.dupe(u8, "default");
    filled_exports = 1;
    for (raw_keys) |key| {
        exports[filled_exports] = try allocator.dupe(u8, key);
        filled_exports += 1;
    }
    return .{
        .path = path,
        .contents = code,
        .compiler_output_program = program,
        .imports = imports,
        .exports = exports,
        .public_entry_facade = .{ .module_index = facade.module_index, .implementation_chunk = facade.chunk_index, .source_path = source_path },
    };
}

fn hasSinglePublicDefault(linker: *Linker, owner: *const Module) !bool {
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (owned.items) |item| linker.allocator.free(item);
        owned.deinit(linker.allocator);
    }
    const entries = (try linker.buildFinalExports(true, owner.index.toU32(), owner.export_bindings, &owned)) orelse return false;
    defer linker.allocator.free(entries);
    return entries.len == 1 and !try @import("entry_exports.zig").needsCjsEntryDescriptors(linker.allocator, entries, .auto);
}

/// Actual post-shake public-facade bootstrap demand owns the existing builtin
/// guard export, even though PM has no source bootstrap-call artifact module.
pub fn needsPreservedDefaultFacadeGuard(graph: *const ModuleGraph, linker: *Linker, options: anytype, shaker: ?*const TreeShaker) !bool {
    if (!options.preserve_modules or options.format != .cjs or options.output_exports != .auto or !options.entry_error_guard) return false;
    var modules = graph.modulesIterator();
    while (modules.next()) |owner| {
        if (shaker) |s| if (!s.isIncluded(owner.index.toU32())) continue;
        if (!owner.is_entry_point or owner.wrap_kind != .esm or owner.in_async_cone or !owner.shouldGuard(true)) continue;
        if (try hasSinglePublicDefault(linker, owner)) return true;
    }
    return false;
}

fn emitChunksImpl(
    io: ?std.Io,
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    options: *const EmitOptions,
    linker: ?*Linker,
) ![]OutputFile {
    var facades: std.ArrayListUnmanaged(PublicEntryFacade) = .empty;
    defer {
        for (facades.items) |facade| facade.deinit(allocator);
        facades.deinit(allocator);
    }
    if (options.preserve_modules and options.format == .cjs) {
        const l = linker orelse return error.MissingPublicEntryFacadeLinker;
        for (chunk_graph.chunks.items) |*chunk| {
            const source = preserveModulesWrapperChunk(chunk, graph, options) orelse continue;
            const owner = graph.getModule(source) orelse return error.InvalidPublicEntryFacadeOwner;
            if (!owner.is_entry_point or !owner.wrap_kind.isWrapped()) continue;
            const raw_cjs = owner.wrap_kind == .cjs;
            if (!raw_cjs and options.output_exports != .auto) continue;
            if (chunk.modules.items.len != 1 or chunk.modules.items[0] != source or
                chunk_graph.getModuleChunk(source) != chunk.index)
                return error.InvalidPublicEntryFacadeOwner;
            if (!raw_cjs and !try hasSinglePublicDefault(l, owner)) continue;
            const semantic = owner.semantic orelse return error.InvalidPublicEntryFacadeOwner;
            if (semantic.owner_token == .unassigned) return error.InvalidPublicEntryFacadeOwner;
            const init_identity = if (raw_cjs)
                SymbolID.make(owner.index, @backingInt(owner.require_symbol orelse return error.InvalidPublicEntryFacadeOwner))
            else
                try owner.esmInitSymbol();
            const namespace_identity = if (raw_cjs) null else try owner.esmNamespaceSymbol();
            const namespace_key = if (namespace_identity) |id| try allocator.dupe(u8, try owner.esmWrapperName(id, null)) else null;
            errdefer if (namespace_key) |key| allocator.free(key);
            const init_key = try allocator.dupe(u8, if (raw_cjs)
                owner.getRequireName(null) orelse return error.InvalidPublicEntryFacadeOwner
            else
                try owner.esmWrapperName(init_identity, null));
            errdefer allocator.free(init_key);
            var guard: ?FacadeGuard = null;
            if (!raw_cjs and !owner.in_async_cone and owner.shouldGuard(options.entry_error_guard)) {
                const target = try @import("../runtime_entry_guard_ast.zig").exactBinding(graph);
                const provider = graph.getModule(target.module) orelse return error.InvalidPublicEntryFacadeOwner;
                if (provider.semantic == null or provider.export_bindings.len != 1) return error.InvalidPublicEntryFacadeOwner;
                const provider_chunk = chunk_graph.getModuleChunk(provider.index);
                if (provider_chunk.isNone()) return error.InvalidPublicEntryFacadeOwner;
                const key = try @import("../public_export_key.zig").fromSyntax(allocator, provider.export_bindings[0].exported_name);
                defer key.deinit(allocator);
                guard = .{ .target = target, .owner = provider.semantic.?.owner_token, .chunk_index = provider_chunk, .public_key = try allocator.dupe(u8, key.text) };
            }
            errdefer if (guard) |proof| allocator.free(proof.public_key);
            const public_path = if (chunk.explicit_file_name) |path|
                try allocator.dupe(u8, path)
            else
                try computePreserveModulesPath(allocator, chunk.rel_dir orelse return error.InvalidPublicEntryFacadeOwner, options.out_extension_js orelse ".js", options.preserve_modules_root);
            errdefer allocator.free(public_path);
            // Use the existing generated-chunk naming/hash allocator without
            // creating a second entry role or changing source chunk ownership.
            var naming_view = chunk.*;
            naming_view.explicit_file_name = null;
            naming_view.name_dir = null;
            var naming_options = options.*;
            naming_options.entry_names = options.chunk_names;
            var stem: std.ArrayListUnmanaged(u8) = .empty;
            defer stem.deinit(allocator);
            try chunkPlaceholderStem(&naming_view, &stem, allocator, &naming_options);
            const implementation_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem.items, options.out_extension_js orelse ".js" });
            errdefer allocator.free(implementation_path);
            if (std.mem.eql(u8, implementation_path, public_path)) return error.PublicEntryFacadePathCollision;
            const raw_keys = if (raw_cjs) try collectRawFacadeKeys(allocator, graph, source) else null;
            errdefer if (raw_keys) |keys| keys.deinit(allocator);
            try facades.append(allocator, .{
                .module_index = source,
                .chunk_index = chunk.index,
                .init_identity = init_identity,
                .owner_token = semantic.owner_token,
                .public_path = public_path,
                .implementation_path = implementation_path,
                .init_key = init_key,
                .projection = if (raw_cjs) .{ .cjs_result = raw_keys.? } else .{ .esm_default = .{
                    .namespace_identity = namespace_identity.?,
                    .namespace_key = namespace_key.?,
                    .awaited = owner.in_async_cone,
                    .guard = guard,
                } },
            });
        }
    }
    if (facades.items.len == 0)
        return emitChunksWithoutFacades(io, allocator, graph, chunk_graph, options, linker, &.{});

    const chunks = try allocator.dupe(Chunk, chunk_graph.chunks.items);
    defer allocator.free(chunks);
    var view = chunk_graph.*;
    view.chunks = .empty;
    view.chunks.items = chunks;
    view.chunks.capacity = chunks.len;
    for (facades.items) |facade| {
        const index = @backingInt(facade.chunk_index);
        if (index >= chunks.len or chunks[index].index != facade.chunk_index) return error.InvalidPublicEntryFacadeOwner;
        chunks[index].explicit_file_name = facade.implementation_path;
    }
    const body_outputs = try emitChunksWithoutFacades(io, allocator, graph, &view, options, linker, facades.items);
    var outputs: std.ArrayList(OutputFile) = .empty;
    errdefer {
        for (outputs.items) |output| output.deinit(allocator);
        outputs.deinit(allocator);
    }
    outputs.appendSlice(allocator, body_outputs) catch |err| {
        for (body_outputs) |output| output.deinit(allocator);
        allocator.free(body_outputs);
        return err;
    };
    allocator.free(body_outputs);
    const sorted = try sortedChunkIndices(allocator, &view);
    defer allocator.free(sorted);
    var physical_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer physical_paths.deinit(allocator);
    for (outputs.items) |output| {
        const reserved = try physical_paths.getOrPut(allocator, output.path);
        if (reserved.found_existing) return error.PublicEntryFacadePathCollision;
    }
    for (facades.items) |facade| {
        const owner = try facade.checkedOwner(graph, chunk_graph);
        // Match the actual chunk emission order, not filenames or source names.
        var ordinal: usize = 0;
        var body: ?*const OutputFile = null;
        for (sorted) |ci| {
            if (chunkRestrictSkip(&chunks[ci], ci, options.restrict_to_chunk)) continue;
            if (chunks[ci].index == facade.chunk_index) {
                if (ordinal >= outputs.items.len) return error.InvalidPublicEntryFacadeOwner;
                body = &outputs.items[ordinal];
                break;
            }
            ordinal += 1;
        }
        const implementation = body orelse continue;
        const reserved = try physical_paths.getOrPut(allocator, facade.public_path);
        if (reserved.found_existing) return error.PublicEntryFacadePathCollision;
        var guard_path: ?[]const u8 = null;
        if (facade.entryGuard()) |guard| {
            var guard_ordinal: usize = 0;
            for (sorted) |ci| {
                if (chunkRestrictSkip(&chunks[ci], ci, options.restrict_to_chunk)) continue;
                if (chunks[ci].index == guard.chunk_index) {
                    if (guard_ordinal >= outputs.items.len) return error.InvalidPublicEntryFacadeOwner;
                    guard_path = outputs.items[guard_ordinal].path;
                    break;
                }
                guard_ordinal += 1;
            }
            if (guard_path == null) return error.InvalidPublicEntryFacadeOwner;
        }
        const facade_output = try makePublicEntryFacadeOutput(allocator, facade, owner.path, implementation.path, guard_path);
        errdefer facade_output.deinit(allocator);
        try outputs.append(allocator, facade_output);
    }
    return outputs.toOwnedSlice(allocator);
}

fn emitChunksWithoutFacades(
    io: ?std.Io,
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    options: *const EmitOptions,
    linker: ?*Linker,
    facades: []const PublicEntryFacade,
) ![]OutputFile {
    const module_count = graph.moduleCount();
    // 청크 경계 해석 방식별 허용 포맷(RFC_CJS_IIFE_CODE_SPLITTING.md):
    // - ESM: 네이티브 import().
    // - CJS: P3-A=preserve-modules(모듈 1:1), P3-B=splitting(네이티브 require, §4.3).
    // - IIFE: P3-B PR3=splitting(런타임 레지스트리 `__zntc_*` + `<script>`
    //   로더, §4.1/§4.3). preserve-modules+IIFE 는 미지원.
    // - UMD/AMD: 아직 미지원(레지스트리 부트스트랩 상이 — 후속).
    if (options.format != .esm) {
        const cjs_ok = options.format == .cjs;
        // iife/umd/amd 모두 동일 레지스트리 기계(PR3) + entry 만 보편 wrapper
        // (umd/amd, PR4). preserve-modules 와는 비호환.
        const reg_ok = options.format.isWrappedFormat() and !options.preserve_modules;
        if (!cjs_ok and !reg_ok) {
            return if (options.preserve_modules)
                error.PreserveModulesRequiresESM
            else
                error.CodeSplittingRequiresESM;
        }
    }

    // splitting / manualChunks 모드에서도 namespace import 의 object literal 을
    // referrer 모듈 self-preamble 이 아닌 정의자 청크 preamble 로 분리해야 entry
    // 청크에 vendor 코드가 누출되지 않음. `use_shared_ns_preamble = true` 면
    // finalizeNamespaceData 가 referrer 측 object_literal 을 빈 문자열로 두고,
    // linker 의 ns_shared_inline_cache 에 정의자 mod_idx + 실 object_literal 저장
    // — 청크 emit 시 정의자 모듈이 속한 청크 preamble 에서 inline.
    if (linker) |l| {
        @constCast(l).use_shared_ns_preamble = true;
        @constCast(l).ns_preamble_chunked = true;
        try @constCast(l).prepareEsmInteropRuntimeNamesIfNeeded();
        try @constCast(l).prepareHmrRuntimeInternalNames();
        try @constCast(l).prepareCjsRuntimeName();
        try @constCast(l).prepareToBinaryRuntimeName();
        try @constCast(l).prepareEsmRuntimeName();
    }
    const hmr_runtime_names = if (options.dev_mode) blk: {
        if (linker) |l| break :blk try l.hmrRuntimeInternalNames();
        break :blk rt_names.HmrRuntimeInternalNames{};
    } else rt_names.HmrRuntimeInternalNames{};

    var outputs: std.ArrayList(OutputFile) = .empty;
    errdefer {
        for (outputs.items) |o| o.deinit(allocator);
        outputs.deinit(allocator);
    }

    // 통합(non-split) 경로와 동일하게 statement-level export DCE 를 splitting 경로에도
    // 적용한다. `generateChunks` 는 shaker 로 *모듈 단위* 포함 여부만 거르므로,
    // 포함된 모듈 안의 미사용 export(예: 사용 안 한 `export function`) 와 그 종속
    // top-level 선언은 emit 까지 살아남는다. 그 미사용 export 가 모듈 단위로 이미
    // 제거된 cross-module import(예: default import)를 참조하면 `X is not defined`
    // 런타임 크래시가 난다. shaker(=linker.tree_shaker)와 per-module used_export_names
    // 를 emitModule 에 전달해 emitter.zig 의 statement_shaker 게이트를 활성화한다.
    const shaker: ?*const TreeShaker = if (linker) |l| l.tree_shaker else null;
    var used_names_by_modidx: []UsedNamesEntry = &.{};
    defer if (used_names_by_modidx.len > 0) {
        for (used_names_by_modidx) |un| allocator.free(un.names);
        allocator.free(used_names_by_modidx);
    };
    if (shaker) |s| {
        // module index → *const Module (희소 그래프 대비 별도 슬라이스로 dense 화).
        var mod_ptrs: std.ArrayList(*const Module) = .empty;
        defer mod_ptrs.deinit(allocator);
        try mod_ptrs.ensureTotalCapacity(allocator, module_count);
        var idx_it = graph.modulesIterator();
        while (idx_it.next()) |m| try mod_ptrs.append(allocator, m);
        const computed = try computeAllUsedNames(allocator, mod_ptrs.items, graph, s);
        defer allocator.free(computed); // names 슬라이스는 by_modidx 로 이동
        used_names_by_modidx = try allocator.alloc(UsedNamesEntry, module_count);
        for (used_names_by_modidx) |*e| e.* = .{ .names = &.{}, .all_used = true };
        for (mod_ptrs.items, 0..) |m, i| {
            const mi = m.index.toU32();
            if (mi >= module_count) {
                allocator.free(computed[i].names);
                continue;
            }
            // `export * from "./this"` source 는 cross-chunk export 목록이 모든 export
            // 이름을 over-approx 로 포함한다. emit DCE 로 그 export 선언을 지우면 codegen
            // 의 `export { ... }` 절과 어긋나 Node `Export X is not defined` SyntaxError.
            // 보수적으로 all_used (DCE 미적용) — over-include 는 correctness-safe.
            //
            // (#4120) CJS-wrapped 모듈인데 used export 이름이 *하나도* 수집 안 된 경우(re-export
            // 로만 도달한 동적 import 청크의 CJS — BFS seed 안 됨)도 all_used. 그대로 두면 statement
            // shaker 가 `__commonJS` 콜백 본문을 통째 비워 `__commonJS({…(empty)})` → require_X()=
            // undefined (Bug B). names 가 *있는* CJS(직접 import 등)는 computed 그대로 써 statement/
            // property DCE 를 유지하므로 일반 CJS shaking 회귀 없음(빈 names 만 좁게 보존).
            if (s.isReExportStarTarget(mi) or (m.wrap_kind == .cjs and computed[i].names.len == 0)) {
                allocator.free(computed[i].names);
                used_names_by_modidx[mi] = .{ .names = &.{}, .all_used = true };
            } else {
                used_names_by_modidx[mi] = computed[i];
            }
        }
    }

    // 청크를 exec_order 순으로 정렬하여 결정론적 출력 순서 보장.
    // 엔트리 청크가 먼저, 공통 청크가 나중에 오도록 정렬한다.
    const sorted_indices = try sortedChunkIndices(allocator, chunk_graph);
    defer allocator.free(sorted_indices);

    // IIFE splitting(P3-B PR3): 런타임 레지스트리 활성화. 안정 모듈 ID 의
    // root = preserve_modules_root ?? 모든 entry-point 청크 모듈 절대경로의
    // 공통 조상(module_id, 결정적). 루프 1회 전 계산해 모든 청크가 공유.
    const reg_split = options.format.isWrappedFormat() and !options.preserve_modules;
    var iife_id_root: ?[]const u8 = null;
    defer if (iife_id_root) |r| allocator.free(r);
    if (reg_split) {
        if (options.preserve_modules_root) |r| {
            iife_id_root = try allocator.dupe(u8, r);
        } else {
            var entry_paths: std.ArrayList([]const u8) = .empty;
            defer entry_paths.deinit(allocator);
            for (chunk_graph.chunks.items) |*c| {
                switch (c.kind) {
                    .entry_point => |info| {
                        if (graph.getModule(info.module)) |m|
                            try entry_paths.append(allocator, m.path);
                    },
                    .common, .manual => {},
                }
            }
            iife_id_root = try module_id.commonAncestorDir(allocator, entry_paths.items);
        }
    }

    // 청크 레지스트리 ID 캐시(chunkidx→id). self-register 키·cross-chunk
    // `__zntc_require`·동적 import 가 같은 청크 ID 를 여러 번 요구 →
    // 빌드당 1회 채워 borrow(없으면 O(chunks²) alloc). 끝에서 일괄 해제.
    var reg_ids: [][]const u8 = &.{};
    defer {
        for (reg_ids) |id| allocator.free(id);
        if (reg_ids.len > 0) allocator.free(reg_ids);
    }
    // iife_split_factory 만 다른 EmitOptions — 빌드당 1회(모듈 루프 밖).
    var iife_emit_opts: EmitOptions = undefined;
    if (reg_split) {
        reg_ids = try allocator.alloc([]const u8, chunk_graph.chunkCount());
        for (chunk_graph.chunks.items, 0..) |*c, i|
            reg_ids[i] = try chunkRegistryId(allocator, c, graph, iife_id_root, options);
        iife_emit_opts = options.*;
        iife_emit_opts.iife_split_factory = true;
    }

    for (sorted_indices) |ci| {
        const chunk = &chunk_graph.chunks.items[ci];
        // PR-3b-i: restrict_to_chunk 면 그 청크 하나만 emit(force — lazy seed skip 우회).
        // 아니면 정상 skip predicate(emit 루프 ↔ resolveContentHashes 동일해야 outputs↔
        // sorted_indices 정렬 유지). 비워진 청크 + PR-3a-ii lazy seed 제외.
        if (chunkRestrictSkip(chunk, ci, options.restrict_to_chunk)) continue;
        const provider_edges = try allocator.dupe(chunk_mod.CrossChunkSym, chunk.exports_to_bindings.items);
        defer allocator.free(provider_edges);
        std.mem.sort(chunk_mod.CrossChunkSym, provider_edges, {}, struct {
            fn less(_: void, a: chunk_mod.CrossChunkSym, b: chunk_mod.CrossChunkSym) bool {
                if (a.canonical_module != b.canonical_module) return a.canonical_module < b.canonical_module;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        var chunk_output: std.ArrayList(u8) = .empty;
        var compiler_snippets: std.ArrayListUnmanaged(*@import("../compiler_output_program.zig").Program) = .empty;
        defer {
            for (compiler_snippets.items) |program| program.destroy();
            compiler_snippets.deinit(allocator);
        }

        var initialized_namespaces: std.AutoHashMapUnmanaged(SymbolID, void) = .empty;
        defer initialized_namespaces.deinit(allocator);
        errdefer chunk_output.deinit(allocator);

        // dev+split per-module HMR code (RFC_LAZY_DEV_MODULE_HMR PR-1):
        // dev_mode and collect_module_codes 일 때 이 청크 내 각 모듈의 wrap 된 HMR code 를
        // 모은다. 성공 시 OutputFile.module_dev_codes 로 소유권 이전(toOwnedSlice). 그 전까지
        // errdefer 가 부분 수집분을 해제. 비-dev 면 빈 채로 남아 append 시 null.
        const collect_dev_codes = options.dev_mode and options.collect_module_codes;
        var chunk_dev_codes: std.ArrayList(types.ModuleDevCode) = .empty;
        // 단일 errdefer 블록 — freeItems(항목 메모리) 후 deinit(백킹 slice) 순서.
        // 두 개의 errdefer 로 나누면 LIFO 실행으로 deinit 가 백킹을 먼저 해제한 뒤
        // freeItems 가 해제된 배열을 순회 → use-after-free.
        errdefer {
            types.ModuleDevCode.freeItems(chunk_dev_codes.items, allocator);
            chunk_dev_codes.deinit(allocator);
        }

        // chunk 별 sourcemap builder. eager 경로는 stack alloc 으로 zero-overhead.
        // lazy 경로는 chunk 끝에서 heap 으로 이관되어 OutputFile.sourcemap_builder
        // 로 caller 에 전달 — 그때는 본 함수의 defer 가 deinit 을 skip 한다.
        var chunk_sm: ?SourceMap.SourceMapBuilder = if (options.sourcemap.enable) blk: {
            var sm = SourceMap.SourceMapBuilder.init(allocator);
            sm.source_root = options.sourcemap.source_root orelse "";
            sm.sources_content = options.sourcemap.sources_content;
            break :blk sm;
        } else null;
        var chunk_sm_moved = false;
        defer if (!chunk_sm_moved) {
            if (chunk_sm) |*sm| sm.deinit();
        };

        // RSC: 디렉티브가 파일 첫 문장이어야 React/Next가 인식.
        var hoisted_directives: std.ArrayList(u8) = .empty;
        defer hoisted_directives.deinit(allocator);
        var banner_js = options.banner_js;
        var intro_js = options.intro_js;
        var directive_start: usize = 0;

        // A preserve-modules file has its own strictness boundary. Preserve
        // the source program's strictness outside its initialization wrapper,
        // where exported function declarations are created. Never apply this
        // to a mixed chunk: its CommonJS modules may require sloppy semantics.
        if (options.preserve_modules and options.format == .cjs and chunk.modules.items.len == 1) {
            if (graph.getModule(chunk.modules.items[0])) |module| {
                if (module.semantic) |sem| {
                    if (sem.scopes.len > 0 and sem.scopes[0].is_strict) {
                        // A prefix hashbang must remain the first physical line,
                        // before both strict and subsequently hoisted RSC directives.
                        const prefix = if (banner_js != null) &banner_js else &intro_js;
                        if (prefix.*) |text| {
                            if (std.mem.startsWith(u8, text, "#!")) {
                                var end = text.len;
                                var rest = text.len;
                                for ([_][]const u8{ "\n", "\r", "\xe2\x80\xa8", "\xe2\x80\xa9" }) |terminator| {
                                    if (std.mem.indexOf(u8, text, terminator)) |at| {
                                        if (at < end) {
                                            end = at;
                                            rest = at + terminator.len;
                                        }
                                    }
                                }
                                if (end < text.len and text[end] == '\r' and rest < text.len and text[rest] == '\n') rest += 1;
                                try chunk_output.appendSlice(allocator, text[0..end]);
                                // Normalize the hashbang terminator so generated
                                // line accounting sees the same one physical line.
                                try chunk_output.append(allocator, '\n');
                                directive_start = chunk_output.items.len;
                                prefix.* = if (rest < text.len) text[rest..] else null;
                            }
                        }
                        try chunk_output.appendSlice(allocator, "\"use strict\";\n");
                    }
                }
            }
        }

        // 출력 확장자 (cross-chunk import 경로 + 파일명에 공용)
        const ext = options.out_extension_js orelse ".js";
        const chunk_is_user_entry = switch (chunk.kind) {
            .entry_point => |info| !info.is_dynamic,
            .common, .manual => false,
        };
        // RFC_LAZY_DEV_MODULE_HMR PR-2: dev_split(=dev+code_splitting+lazy)의 reg(IIFE/UMD/AMD)
        // 청크는 글로벌 __zntc_modules 등록 prelude + wrapped 모듈 init 트리거를 받는다.
        // bundler.zig:1622 / finalize.zig 의 dev_split 게이트와 같은 의미(여기선 reg_split 한정).
        const dev_split_chunk = reg_split and options.dev_mode and graph.lazy_compilation;

        // banner 삽입 (각 청크 출력 앞)
        if (banner_js) |banner| {
            try chunk_output.appendSlice(allocator, banner);
            try chunk_output.append(allocator, '\n');
        }
        // intro: reg_split(IIFE/UMD/AMD self-register factory)면 factory IIFE 안 첫 줄로 옮겨
        // 모듈 본문이 closure scope 로 접근 + chunk 별 module-scope 중복 redeclare 회피. 그 외
        // (preserve_modules / cjs / esm) 는 기존 위치(banner 다음, wrapper 밖) 유지.
        if (!reg_split) {
            if (intro_js) |intro| {
                try chunk_output.appendSlice(allocator, intro);
                try chunk_output.append(allocator, '\n');
            }
        }

        // IIFE splitting(P3-B PR3): 레지스트리 활성화 + self-register factory.
        // 순서: [banner/intro] → [entry: public_path + 해석 계층] →
        //   [factory prefix] → [CSS/runtime-helpers/모듈본문/cross-chunk
        //   exports — 모두 factory 안] → [factory suffix] → [entry: bootstrap].
        // prefix 를 여기서(모듈 루프 전) eager emit → sourcemap module_line
        // base offset 이 자연히 정확(insertSlice 회피, RFC §6 IIFE 스파이크
        // 검증 모델: 자기설치형 register + entry 전용 해석 계층).
        if (reg_split) {
            const id = reg_ids[ci]; // borrow (빌드-1회 캐시)
            const min = options.minify_whitespace;

            if (chunk_is_user_entry) {
                // UMD/AMD(PR4): entry 청크를 보편 wrapper 로 감싼다. factory()
                // 반환값(= bootstrap 의 `return __zntc_require(entryId)`)을
                // CJS module.exports / AMD define / global root.X 로 노출.
                // prologue 를 여기서(module_line newline-count 초기화 전, eager)
                // emit → 소스맵 base offset 자연 정확(PR3 eager-prefix 모델).
                // 비-entry 청크·iife 는 wrapper 없음(기존). externals 는 split
                // 에서 wrapper 시그니처에 미연결(빈 리스트, 문서화 한계).
                if (options.format == .umd or options.format == .amd)
                    try format_wrapper.emitFormatPrologue(&chunk_output, allocator, options.format, options.global_name, "", &.{}, &.{}, &.{}, false);
                // public_path 는 동적 청크 <script> src 접두사(런타임). 결정적
                // JSON 문자열(따옴표/역슬래시/개행 이스케이프).
                try chunk_output.appendSlice(allocator, "globalThis.__zntc_public_path=");
                try parent.appendJsStringLiteral(allocator, &chunk_output, options.public_path);
                try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                // 해석 계층(__zntc_require + 브라우저 <script> 로더), 멱등.
                // Classic targets (including Hermes) must parse the loader too;
                // their DOM/Worker paths do not need a native import-expression fallback.
                try rt.appendZntcResolveBrowser(&chunk_output, allocator, min, !options.unsupported.async_await);
            }
            // self-register factory prefix (모든 청크). 본문·exports 가 안에.
            // ⚠ federation_emit.zig(P1-3)가 `({"<reg_id>"` 부분문자열로 expose
            // 청크를 식별 — 이 prefix 형태 변경 시 동반 수정 필요.
            try chunk_output.appendSlice(allocator, "(function(g){");
            // reg_split intro: factory IIFE 안 첫 줄 — closure scope 로 모듈 본문 접근 가능.
            if (options.intro_js) |intro| {
                try chunk_output.appendSlice(allocator, intro);
                try chunk_output.append(allocator, '\n');
            }
            try chunk_output.appendSlice(allocator, rt.ZNTC_REGISTER_INSTALL);
            try chunk_output.appendSlice(allocator, "({\"");
            try chunk_output.appendSlice(allocator, id);
            try chunk_output.appendSlice(allocator, if (min)
                "\":function(exports,module,require){"
            else
                "\": function(exports, module, require) {\n");
        }

        // CSS 코드스플리팅: 이 청크가 소유한 CSS 를 런타임 <link> 로 주입.
        if (options.chunk_css_hrefs) |hrefs| {
            if (ci < hrefs.len) {
                if (hrefs[ci]) |href| try appendCssLinkPrologue(allocator, &chunk_output, href);
            }
        }

        // 청크별 런타임 헬퍼 주입
        var chunk_interop_emitted = false;
        try emitChunkRuntimeHelpers(&chunk_output, allocator, chunk, graph, linker, options, null, &chunk_interop_emitted);

        // dev_split (RFC_LAZY_DEV_MODULE_HMR PR-2): 글로벌 __zntc_modules 등록 prelude.
        // emitChunkRuntimeHelpers 가 청크-로컬 __esm/__commonJS 를 정의한 *직후* 에 주입돼야
        // wrap 이 그 orig 를 캡처. entry 청크 = HMR_RUNTIME(register+core 전부, apply_update
        // 등 머신러리 1회), 비-entry(shared/dynamic) = HMR_CHUNK_REGISTER(글로벌 등록만).
        // 글로벌(__zntc_g.__zntc_modules ||)이라 청크 평가 순서 무관 → cross-chunk hot-replace.
        // reg_split(IIFE/UMD/AMD) 만: ESM 출력은 청크가 native import 라 등록 모델 비대상.
        if (dev_split_chunk) {
            const cjs_factory_name = if (linker) |l|
                try l.cjsFactoryRuntimeName()
            else if (options.minify_whitespace)
                rt.NAMES.CJS_FACTORY_MIN
            else
                "__commonJS";
            const esm_factory_name = if (linker) |l|
                try l.esmFactoryRuntimeName()
            else if (options.minify_whitespace)
                rt.NAMES.ESM_FACTORY_MIN
            else
                "__esm";
            if (chunk_is_user_entry) {
                const helper_names = if (linker) |l|
                    try l.currentEsmInteropRuntimeNames()
                else
                    rt_names.defaultEsmInteropRuntimeNames(options.minify_whitespace);
                try rt.appendHmrRuntimeWithInternalNames(&chunk_output, allocator, options.minify_whitespace, cjs_factory_name, esm_factory_name, helper_names, hmr_runtime_names);
            } else {
                try rt.appendHmrChunkRegisterWithInternalNames(&chunk_output, allocator, cjs_factory_name, esm_factory_name, hmr_runtime_names);
            }
        }

        // ESM external imports (#1962): keep their original prologue position,
        // but emit them only after computeRenamesForModules below. Generated
        // helper imports read exact linker-selected local names, and preserve-
        // modules computes those names per chunk.
        const external_imports_pos = chunk_output.items.len;

        // 이 청크의 정의자 모듈에 속한 namespace object literal 만 inline.
        // referrer 청크가 자기 self-preamble 에 inline 하던 동작 (entry 에 vendor
        // 코드 누출) 을 정의자 청크 preamble 로 옮긴다.
        //
        // (#4502) **생성은 아래 `computeRenamesForModules` 뒤로 미룬다.** ns 객체 getter 본문은
        // 이 청크에 선언이 있는 심볼이면 그 청크의 *확정된* chunk-local 이름을 써야 하는데,
        // 여기(rename 전)선 아직 미확정이다 — 이전엔 그 대리물로 cross-chunk 전역 공개명을
        // 썼고, 그 이름은 정작 이 청크 안엔 선언이 없어 ReferenceError 였다. 텍스트가 들어갈
        // **위치만** 기억해 두고 나중에 `insertSlice` 로 꽂는다 (출력 순서는 종전과 동일 —
        // sourcemap base 인 `module_line` 은 이 insert 이후에 계산되므로 영향 없음).
        var ns_preamble_pos: ?usize = if (linker) |l|
            (if (l.use_shared_ns_preamble) chunk_output.items.len else null)
        else
            null;

        var rbm_cross_imports: std.ArrayList(RunBeforeMainCrossImport) = .empty;
        defer {
            for (rbm_cross_imports.items) |imp| allocator.free(imp.name);
            rbm_cross_imports.deinit(allocator);
        }
        if (chunk_is_user_entry and options.run_before_main.len > 0) {
            try collectRunBeforeMainCrossImports(
                allocator,
                &rbm_cross_imports,
                graph,
                chunk_graph,
                chunk,
                options.run_before_main,
                if (linker) |l| &l.rename_table else null,
            );
            try emitRunBeforeMainCrossImports(
                &chunk_output,
                allocator,
                rbm_cross_imports.items,
                chunk,
                chunk_graph,
                options,
                ext,
                reg_ids,
            );
        }

        // 크로스 청크 import deconfliction:
        // 여러 청크에서 같은 이름의 심볼을 import할 때 충돌 방지.
        // 1단계: 모든 청크로부터의 import 이름 출현 횟수 카운트
        // 2단계: 중복 이름은 `import { x as x$2 }` 형태로 alias 부여
        // (#4572) 이 청크 소비자-로컬 import 이름 오버라이드 맵을 리셋(직전 청크 잔재 제거).
        if (linker) |l| l.clearConsumerImportLocal();
        // (#4576) 선언되는 소비자-로컬은 항상 **binding**(crossChunkBindingName)이다 — export 명이
        // 아니라. 동명 export(특히 `export default`, key=`default`≠binding)면 여러 dep 이 같은 로컬을
        // 선언해 SyntaxError. 올바른 해소는 esbuild/rollup 리네이머처럼 **이미 쓰인 이름 집합**으로
        // 유일 이름을 발급하는 것 — per-binding 카운터는 다른 binding 의 자연 `$N` 이름(또는 사용자
        // 심볼 `foo$2`)과 충돌해 전역 유일성을 못 지킨다(#4576 리뷰 [0][1]).
        //   · natural_bindings: imports_from 의 모든 binding 이름 집합. dedup 이름 발급 시 다른 binding
        //     의 자연명을 침범하지 않도록 skip 판정에 쓴다([0]).
        //   · used_locals: 이 청크에 실제 선언된 로컬명. has_global(전역명 고정)/lazy 는 이름을 못 바꾸니
        //     **먼저** 예약해, 비-global 로컬이 그 이름과 충돌하면 deconflict 되게 한다([1] 순서-의존).
        var natural_bindings: std.StringHashMapUnmanaged(void) = .empty;
        defer natural_bindings.deinit(allocator);
        var used_locals: std.StringHashMapUnmanaged(void) = .empty;
        defer used_locals.deinit(allocator);
        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_ci = @backingInt(dep_chunk_idx);
            const syms = chunk.imports_from.get(dep_ci) orelse continue;
            for (syms.items) |sym| {
                const b = try crossChunkBindingName(linker, sym);
                try natural_bindings.put(allocator, b, {});
                const hg = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null else false;
                if (hg) try used_locals.put(allocator, b, {});
            }
        }

        // alias 문자열을 임시 저장 (defer free)
        var alias_strs: std.ArrayList([]const u8) = .empty;
        defer {
            for (alias_strs.items) |s| allocator.free(s);
            alias_strs.deinit(allocator);
        }

        // CJS 청크 경계 결합을 ESM import 대신 `const {x}=require("...")` /
        // `require("...")` 로 (export 측은 P3-A=모듈별 exports.x / P3-B=Edit 3
        // 의 cross-chunk exports.x). 내부 모듈 본문은 호이스팅 그대로.
        // - pm_cjs (P3-A): preserve-modules+cjs, resolved_path=상대경로
        // - cjs_split (P3-B): cjs+splitting, resolved_path=청크 stem
        //   (둘 다 Node 네이티브 require 가 정적 string 으로 해석).
        const pm_cjs = options.preserve_modules and options.format == .cjs;
        var pm_async_import_depth: usize = 0;
        const pm_protocol_owner: ?ModuleIndex = if (pm_cjs and chunk.modules.items.len == 1) blk: {
            const owner = graph.getModule(chunk.modules.items[0]) orelse break :blk null;
            break :blk if (owner.wrap_kind == .esm and owner.in_async_cone) owner.index else null;
        } else null;
        const pm_sync_facade_owner: ?ModuleIndex = blk: {
            for (facades) |facade| if (facade.chunk_index == chunk.index and !facade.isAwaited()) break :blk facade.module_index;
            break :blk null;
        };
        const pm_instantiation_owner: ?ModuleIndex = if (pm_protocol_owner != null) pm_protocol_owner else pm_sync_facade_owner;
        const pm_readiness = if (pm_protocol_owner != null)
            try readinessHelperExpression(allocator, graph, chunk_graph, chunk, options, linker orelse return error.MissingTlaReadinessHelper, reg_ids)
        else
            null;
        defer if (pm_readiness) |value| allocator.free(value);
        var pm_definition_pos = chunk_output.items.len;
        var pm_definition_code: std.ArrayListUnmanaged(u8) = .empty;
        defer pm_definition_code.deinit(allocator);
        var pm_dependency_states: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (pm_dependency_states.items) |value| allocator.free(value);
            pm_dependency_states.deinit(allocator);
        }
        var split_async_import_depth: usize = 0;
        const split_assign_host = options.format != .cjs or !chunk_is_user_entry or options.output_exports != .none;
        var split_bridge_entries: std.ArrayList(LinkingMetadata.FinalExportEntry) = .empty;
        defer split_bridge_entries.deinit(allocator);
        const cjs_split = options.format == .cjs and !options.preserve_modules;
        const cjs_require = pm_cjs or cjs_split;

        // PR B-4b-1: stack buf → ArrayList reuse. loop 안 단일 alloc amortize.
        var dep_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer dep_buf.deinit(allocator);
        // src_dir 는 importer chunk 의 *최종 stem* (pattern + baked-in slash 포함)
        // 의 dirname. chunk.name_dir 만 보면 `'static/[name]'` 같은 baked-in
        // dir 를 놓침.
        var importer_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer importer_buf.deinit(allocator);
        try appendChunkOutputPath(chunk, &importer_buf, allocator, options);
        const importer_dir = std.fs.path.dirname(importer_buf.items) orelse "";

        // (#4532 증상4) unwrapped pm-cjs 순환에서 function-decl export 를 require 블록 **앞**에 hoist 할
        // 위치·대상 모듈. require 뒤(모듈 본문 끝)에 두면 순환 소비자가 로드 중 undefined 를 집는다.
        // pm-cjs & 비-wrap & entry 청크 & **named export 를 내는 모드(auto/named)** 만 — output_exports
        // `.none`(export 억제)/`.default_`(default 만)에선 hoist 하면 안 된다(#4532 증상4 리뷰 [0]).
        // 실제 삽입은 computeRenamesForModules 후(리네임명 확정).
        const fn_hoist_entry: ?u32 = if (pm_cjs and
            (options.output_exports == .auto or options.output_exports == .named) and
            preserveModulesWrapperChunk(chunk, graph, options) == null)
            (switch (chunk.kind) {
                .entry_point => |info| @backingInt(info.module),
                .common, .manual => null,
            })
        else
            null;
        var fn_hoist_pos: ?usize = if (fn_hoist_entry != null) chunk_output.items.len else null;

        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_chunk = chunk_graph.getChunk(dep_chunk_idx);
            try chunkPlaceholderStem(dep_chunk, &dep_buf, allocator, options);
            const dep_stem = dep_buf.items;
            const dep_ci = @backingInt(dep_chunk_idx);

            // IIFE splitting: 청크 경계는 레지스트리 — 경로 대신 dep 청크의
            // 레지스트리 ID 로 `__zntc_require("<id>")`. resolved_path 불필요.
            const dep_id = if (reg_split) reg_ids[@backingInt(dep_chunk_idx)] else "";

            // import 경로 결정: preserve-modules면 상대 경로, 아니면 "./{stem}{ext}"
            // PR7-2d: 명시 fileName 은 preserve-modules 보다 우선 — 출력 파일명(verbatim)과 import
            // 경로가 일치해야 한다(filename 생성부도 explicit 을 먼저 검사). emit chunk 는 rel_dir
            // 이 null 이라 preserve 분기가 verbatim 을 떨어뜨리면 ref 가 실제 출력과 어긋난다.
            const resolved_path = if (reg_split)
                try allocator.dupe(u8, "")
            else if (dep_chunk.explicit_file_name) |efn|
                // efn 도 importer_dir 기준 상대 경로 — efn 가 dir 포함 시 importer
                // 위치를 무시하면 runtime resolve 가 importer dir 기준으로 잘못 해석.
                try computeRelativePath(allocator, importer_dir, efn, "")
            else if (options.preserve_modules) blk: {
                const dep_path = try computePreserveModulesPath(allocator, dep_chunk.rel_dir orelse "./", ext, options.preserve_modules_root);
                defer allocator.free(dep_path);
                break :blk try computeRelativePath(allocator, importer_dir, dep_path, "");
            } else blk: {
                break :blk try computeRelativePath(allocator, importer_dir, dep_stem, ext);
            };
            defer allocator.free(resolved_path);

            if (pm_readiness) |helper_expr| {
                const dep_owner = depChunkModuleIndex(dep_chunk);
                const async_dep = if (dep_owner) |index|
                    if (graph.getModule(index)) |provider| provider.wrap_kind == .esm and provider.in_async_cone else false
                else
                    false;
                if (async_dep) {
                    const quoted = try quoteChunkPath(allocator, resolved_path);
                    defer allocator.free(quoted);
                    const state = try std.fmt.allocPrint(allocator, "{s}.state(require({s}))", .{ helper_expr, quoted });
                    errdefer allocator.free(state);
                    try pm_dependency_states.append(allocator, state);
                }
            }

            // 청크 경계 결합 형태: esm `import{}from""` / cjs `const{}=require("")`
            // / iife `const{}=__zntc_require("<id>")`. brace·alias 표기는 cjs 와
            // iife 가 동일(`const {` / `name: alias`) — reg_like 로 공유.
            const reg_like = cjs_require or reg_split;
            // iife 의 결합 인자는 dep_id, 그 외는 resolved_path.
            const bind_arg = if (reg_split) dep_id else resolved_path;

            // imports_from에서 이 청크→dep_chunk로 가져오는 심볼 목록 조회
            const symbols = chunk.imports_from.get(dep_ci);

            // (#4524) preserve-modules + **wrap 된 dep** 은 래퍼 심볼만 가져온다 — 심볼 분기
            // 보다 **먼저** 봐야 한다. wrap 된 모듈은 export 명(`foo`)을 파일 밖으로 내지 않는데
            // (본문이 클로저 안), `imports_from` 에는 re-export 해석(resolveExportChain 의 CJS
            // 폴백)으로 그 이름이 등록된다 → 심볼 분기가 먼저 타면 provider 가 내지도 않는
            // `import { foo } from "./legacy.js"` 를 내고, 소비자 preamble 의 `require_legacy` 는
            // 여전히 미-import 다 → `SyntaxError: Identifier 'foo' has already been declared`.
            // (#4528) **CJS dep 만** 심볼 목록을 버린다. CJS 는 본문 전체가 `__commonJS`
            // 클로저 안이라 top-level 에 export 명이 없다(래퍼뿐) — 심볼을 import 하면
            // provider 가 내지도 않는 이름을 가져와 SyntaxError 다.
            // **ESM-wrap 은 다르다**: 선언(`function tag(){}`)은 파일 top-level 에 남고
            // 소비자도 bare 로 참조하므로, 래퍼 심볼 **과 함께** 심볼도 가져와야 한다.
            const pm_wrapper_dep: ?ModuleIndex = preserveModulesWrapperChunk(dep_chunk, graph, options);
            const pm_cjs_dep = if (pm_wrapper_dep) |mi|
                (if (graph.getModule(mi)) |dm0| dm0.wrap_kind == .cjs else false)
            else
                false;
            // (#4528) cjs + **ESM-wrap dep** 의 심볼은 래퍼 분기에서 lazy 로 다룬다(위 참조).
            // 아래 심볼 분기(구조분해 = 값 스냅샷)를 태우면 안 된다.
            const pm_esm_wrap_dep_syms: ?[]chunk_mod.CrossChunkSym = blk: {
                if (pm_wrapper_dep == null or pm_cjs_dep) break :blk null;
                if (!cjs_require) break :blk null; // esm 은 live binding 이라 named import 로 충분
                const sy = symbols orelse break :blk null;
                if (sy.items.len == 0) break :blk null;
                std.mem.sort(chunk_mod.CrossChunkSym, sy.items, {}, struct {
                    fn lt(_: void, a: chunk_mod.CrossChunkSym, b: chunk_mod.CrossChunkSym) bool {
                        return std.mem.lessThan(u8, a.name, b.name);
                    }
                }.lt);
                break :blk sy.items;
            };

            if (pm_wrapper_dep) |dm_idx| {
                // (#4524) preserve-modules: dep 이 CJS 면 그 파일의 `require_X` 썽크를
                // **named import** 해야 한다. CJS 는 정적 export 가 없어 파일 경계를 넘을
                // 수단이 이 썽크뿐인데, 예전엔 side-effect import 만 내고 소비자가 썽크를
                // **렉시컬 참조**해서 `ReferenceError: require_X is not defined` 였다.
                // interop 은 소비자가 자기 preamble(`var d = require_X()`)로 이미 하고 있으므로
                // 이름만 건너오면 그대로 동작한다 — rolldown 과 같은 형태다.
                // 술어는 provider(export emit) 와 **같은 소스**를 본다.
                const dm = graph.getModule(dm_idx).?;
                // (#4528) provider 와 **같은 소스** — canonical(rename_table 미사용).
                const names = try wrapperNamesFor(allocator, dm, null);
                defer names.deinit(allocator);
                const min = options.minify_whitespace;

                if (pm_readiness) |helper_expr| {
                    if (dm.wrap_kind == .esm and dm.in_async_cone) {
                        try emitPmAsyncWrapperImport(
                            allocator,
                            &chunk_output,
                            linker,
                            dm,
                            pm_esm_wrap_dep_syms orelse &.{},
                            bind_arg,
                            helper_expr,
                            @backingInt(pm_protocol_owner.?),
                            &used_locals,
                            &natural_bindings,
                            &alias_strs,
                        );
                        continue;
                    }
                }

                if (!options.preserve_modules and options.format != .esm and dm.wrap_kind == .esm and dm.in_async_cone) {
                    const ns_base = try types.makeNsVarName(allocator, dm.path);
                    try alias_strs.append(allocator, ns_base);
                    const ns_local = try mintConsumerLocal(allocator, ns_base, &used_locals, &natural_bindings, &alias_strs);
                    try chunk_output.appendSlice(allocator, if (split_async_import_depth == 0) (if (split_assign_host) "module.exports = " else "") else "return ");
                    try chunk_output.print(allocator, "{s}(\"{s}\").then(function({s}) {{\n", .{ if (reg_split) "__zntc_require" else "require", bind_arg, ns_local });
                    split_async_import_depth += 1;
                    for ([_]?[]const u8{ names.a, names.b }) |maybe| {
                        const name = maybe orelse continue;
                        const quoted = try std.json.Stringify.valueAlloc(allocator, name, .{});
                        defer allocator.free(quoted);
                        const helper = try readinessHelperExpression(allocator, graph, chunk_graph, chunk, options, linker orelse return error.MissingTlaReadinessHelper, reg_ids);
                        defer allocator.free(helper);
                        try chunk_output.print(allocator, "var {s}={s}.state({s}(\"{s}\")).internals[{s}];\n", .{ name, helper, if (reg_split) "__zntc_require" else "require", bind_arg, quoted });
                    }
                    continue;
                }

                if (cjs_require) {
                    // (#4526) ⚠️ cjs 는 **구조분해하면 안 된다**.
                    // `const { require_b } = require("./b.js")` 는 **로드 시점에 값을 복사**한다.
                    // CJS↔CJS 순환에서 b.js 가 a.js 를 require 하면 a 는 아직 평가 중이라
                    // `exports.require_a` 가 미할당 → b 가 **undefined 를 박제**하고, 나중에
                    // 호출할 때 `TypeError: require_a is not a function`.
                    // node 는 require 가 lazy 라 순환을 정상 처리하고, ESM 은 live binding 이라
                    // 무사하다. cjs 만 이 지연이 없다.
                    //
                    // 래퍼 심볼(`require_X` / `init_X`)은 **함수**라 호출 시점에 조회하도록
                    // forwarding 하면 지연이 복원된다. 실제 호출은 모듈이 완전히 평가된 뒤에
                    // 일어나므로(`entry` → `require_a()` → a 본문 → `require_b()` → …) 그때는
                    // provider 의 `exports.require_X` 가 이미 채워져 있다.
                    // ⚠️ **holder 변수를 두지 않는다.** `const __zntc_w0 = require(...)` 처럼
                    // 우리가 이름을 지어 top-level 에 깔면 그 이름은 deconflict 를 안 거쳐서
                    // 사용자 코드의 동명 top-level 심볼과 **중복 선언**(SyntaxError)이 난다.
                    // `require()` 는 node 가 memoize 하므로 forwarding 안에서 다시 불러도 싸다.
                    //
                    // side-effect require: 실행/등록 순서 보장(기존 동작 유지).
                    try chunk_output.appendSlice(allocator, if (min) "require(\"" else "require(\"");
                    try chunk_output.appendSlice(allocator, bind_arg);
                    try chunk_output.appendSlice(allocator, if (min) "\");" else "\");\n");

                    // `exports_X` (ESM-wrap dep) 는 **객체**라 forwarding 으로 감쌀 수 없다.
                    // 그런데 소비자의 사용처는 **항상** `(init_X(), __toCommonJS(exports_X))` —
                    // 즉 `init_X()` 가 **먼저** 평가되는 순차식이다. 그래서 `let` 으로 선언해 두고
                    // **init forwarding 안에서 갱신**하면, 순환에서 로드 시점에 undefined 였더라도
                    // 읽히기 직전에 진짜 객체로 채워진다.
                    //
                    // ⚠️ eager 복사(`const exports_X = require(...).exports_X`)만 두면 안 된다.
                    // 순환에서 dep 이 **아직 평가 중**이면 provider 의 `exports.exports_X = …` 가
                    // 아직 안 깔려 **undefined 를 박제**하고, 나중에
                    // `__toCommonJS(undefined)` → `TypeError: Cannot convert undefined or null
                    // to object` 로 죽는다. (첫 수정이 여기까지 못 갔다.)
                    if (names.b) |b| {
                        try chunk_output.appendSlice(allocator, if (options.transform_options_base.unsupported.block_scoping) "var " else "let ");
                        try chunk_output.appendSlice(allocator, b);
                        try chunk_output.appendSlice(allocator, if (min) "=require(\"" else " = require(\"");
                        try chunk_output.appendSlice(allocator, bind_arg);
                        try chunk_output.appendSlice(allocator, if (min) "\")." else "\").");
                        try chunk_output.appendSlice(allocator, b);
                        try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                    }

                    // (#4528) ESM-wrap dep 의 **심볼**도 여기서 다룬다. `const { tag } =
                    // require("./b.js")` 로 구조분해하면 **로드 시점 값 스냅샷**이라, 그 값이
                    // `__esm` 클로저(=`init_X()`) 안에서 늦게 대입되는 `const`/`class` 면
                    // undefined 를 박제하고(함수만 hoisting 으로 우연히 살아남는다), 순환에서도
                    // 미평가 값을 집는다. → `let` 으로 선언하고 **init forwarding 안에서 갱신**한다.
                    // 소비자 preamble 은 그 심볼을 쓰기 **전에** 반드시 `init_X()` 를 부른다.
                    // ⚠️ 같은 export 명을 내는 ESM-wrap dep 이 둘 이상이면 `let tag;` 가 **중복
                    // 선언**된다(SyntaxError, 파싱 불가). 심볼 분기가 쓰는 것과 **같은** `$N`
                    // deconflict 를 적용해야 한다 — 로컬명은 아래 init 갱신과도 일치해야 하므로
                    // 한 번 계산해 재사용한다.
                    var pm_locals: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer {
                        for (pm_locals.items) |x| allocator.free(x);
                        pm_locals.deinit(allocator);
                    }
                    // pm_locals 와 인덱스 병행: 각 sym 의 forwarding **read**(provider export 키).
                    // 항목은 borrowed(전역명 맵 slice 또는 sym.name — 둘 다 emit 수명) → list 만 deinit.
                    var pm_reads: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer pm_reads.deinit(allocator);
                    if (pm_esm_wrap_dep_syms) |syms| {
                        for (syms) |sym| {
                            const bind = try crossChunkBindingName(linker, sym);
                            const global_name: ?[]const u8 = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) else null;
                            const has_g = global_name != null;
                            // (#4576) import 블록과 **같은** used_locals 로 유일 로컬 발급(esm=import 블록 /
                            // cjs ESM-wrap=여기, dep 단위 상호배타·집합 공유). has_g 는 전역명 고정(pre-pass
                            // 예약). 발급은 청크 수명 slice → pm_locals 는 항목을 free 하므로 owned 복사.
                            const mint = if (has_g) bind else try mintConsumerLocal(allocator, bind, &used_locals, &natural_bindings, &alias_strs);
                            const local = try allocator.dupe(u8, mint);
                            try pm_locals.append(allocator, local);
                            // read = 전역명(있으면 provider 가 `exports.<global>`) 아니면 export 명(sym.name,
                            // provider 가 `exports.<export명>`). crossChunkBindingName 은 reserved-name 이
                            // 전역명 없을 때 로컬을 반환하므로 read 로는 부적합.
                            try pm_reads.append(allocator, global_name orelse sym.name);
                        }
                        try chunk_output.appendSlice(allocator, if (options.transform_options_base.unsupported.block_scoping) "var " else "let ");
                        for (pm_locals.items, 0..) |local, si| {
                            if (si > 0) try chunk_output.appendSlice(allocator, if (min) "," else ", ");
                            try chunk_output.appendSlice(allocator, local);
                        }
                        try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                    }

                    // `require_X` / `init_X` — 함수. 호출 시점에 조회(lazy forwarding).
                    const legacy_proxy = options.transform_options_base.unsupported.block_scoping;
                    try chunk_output.appendSlice(allocator, if (legacy_proxy) "var " else "const ");
                    try chunk_output.appendSlice(allocator, names.a);
                    try chunk_output.appendSlice(allocator, if (legacy_proxy)
                        (if (min) "=function(){var m=require(\"" else " = function() { var m = require(\"")
                    else
                        (if (min) "=function(){const m=require(\"" else " = function() { const m = require(\""));
                    try chunk_output.appendSlice(allocator, bind_arg);
                    try chunk_output.appendSlice(allocator, if (min) "\");" else "\");\n");
                    if (names.b) |b| {
                        // 순환에서 로드 시점엔 undefined 였을 수 있다 — 읽히기 직전에 갱신.
                        try chunk_output.appendSlice(allocator, if (min) "" else "\t\t");
                        try chunk_output.appendSlice(allocator, b);
                        try chunk_output.appendSlice(allocator, if (min) "=m." else " = m.");
                        try chunk_output.appendSlice(allocator, b);
                        try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                    }
                    if (pm_esm_wrap_dep_syms) |syms| {
                        // ⚠️ **init 을 먼저 돌리고 그 다음에 갱신**해야 한다. dep 의 `const`/`let`/
                        // `class` 값은 `init_X()`(=`__esm` 클로저) **안에서** 대입되므로, 갱신을
                        // init **전에** 하면 여전히 undefined 를 집는다(함수 선언만 hoisting 으로
                        // 우연히 살아남는다 — 바로 그 은폐 패턴). init 은 memoize 라 이후 재갱신이
                        // 없으니 이 순서가 유일한 기회다.
                        try chunk_output.appendSlice(allocator, if (legacy_proxy)
                            (if (min) "var r=m." else "\t\tvar r = m.")
                        else
                            (if (min) "const r=m." else "\t\tconst r = m."));
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) ".apply(this,arguments);" else ".apply(this, arguments);\n");
                        for (0..syms.len) |si| {
                            try chunk_output.appendSlice(allocator, if (min) "" else "\t\t");
                            try chunk_output.appendSlice(allocator, pm_locals.items[si]);
                            try chunk_output.appendSlice(allocator, if (min) "=m." else " = m.");
                            // (#4532 증상1) read 는 **provider 의 export 키**여야 한다: 전역명이 배정됐으면
                            // provider(`pm_wrapped_esm_provider`, #4528)가 `exports.tag$1` 을 내므로 전역명,
                            // 아니면(minify/dev 로 전역명 off) `exports.<export명>` 이라 sym.name. 첫 루프에서
                            // `global_name orelse sym.name` 로 캡처(pm_reads). ⚠️ crossChunkBindingName 은
                            // reserved-name(`default`)이 전역명 없을 때 provider 로컬(`foo`)을 반환해 export
                            // 키(`default`)와 어긋난다 — 그걸 read 로 쓰면 `m.foo` undefined → TypeError.
                            try chunk_output.appendSlice(allocator, pm_reads.items[si]);
                            try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                        }
                        try chunk_output.appendSlice(allocator, if (min) "return r};" else "\t\treturn r;\n\t};\n");
                    } else {
                        try chunk_output.appendSlice(allocator, if (min) "return m." else "\t\treturn m.");
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) ".apply(this,arguments)};" else ".apply(this, arguments);\n\t};\n");
                    }
                } else {
                    // esm: live binding 이라 named import 로 충분하다.
                    // 키는 canonical, 로컬은 mangle 된 이름 — alias 로 잇는다(#4528).
                    try chunk_output.appendSlice(allocator, if (min) "import{" else "import { ");
                    try chunk_output.appendSlice(allocator, names.a);
                    if (names.b) |b| {
                        try chunk_output.appendSlice(allocator, if (min) "," else ", ");
                        try chunk_output.appendSlice(allocator, b);
                    }
                    try chunk_output.appendSlice(allocator, if (min) "}from\"" else " } from \"");
                    try chunk_output.appendSlice(allocator, bind_arg);
                    try chunk_output.appendSlice(allocator, if (min) "\";" else "\";\n");
                }
            }

            // (#4541) 이 dep 청크에서 raw-require 한 CJS 썽크(require_X)를 named import 로 가져온다.
            // esm: `import { require_X } from "…"` / cjs·iife: `const { require_X } = require/__zntc_require`.
            // require_X 는 canonical(reserveWrapperNames 로 전역 유일)이라 rename_table 불요 — provider
            // export·소비자 import·본문 `require_X()` 3자가 같은 이름을 쓴다(#4524 계약과 동일).
            // ⚠️ esm/cjs 포맷만 — reg_split(iife/umd/amd)은 registry 모델이라 별도(후속).
            // ⚠️ preserve-modules 는 #4524 가 자체 wrapper thunk export/import 를 담당하므로 제외.
            var wrapper_import_emitted = false;
            if (!reg_split and !options.preserve_modules) {
                if (chunk.wrapper_cross_imports.get(dep_ci)) |wlist| {
                    if (wlist.items.len > 0) {
                        const min = options.minify_whitespace;
                        std.mem.sort(u32, wlist.items, {}, comptime std.sort.asc(u32));
                        if (cjs_require) {
                            // (#4526) ⚠️ cjs 는 **구조분해 금지**(`const{require_X}=require(...)`는 로드
                            // 시점 값 스냅샷 → CJS↔CJS cross-chunk 순환에서 provider 의 `exports.require_X`
                            // 가 아직 미할당이라 undefined 박제 → TypeError). require_X 는 함수라 **호출
                            // 시점 조회(lazy forwarding)**로 지연을 복원한다(require 는 node memoize).
                            try chunk_output.appendSlice(allocator, "require(\"");
                            try chunk_output.appendSlice(allocator, bind_arg);
                            try chunk_output.appendSlice(allocator, if (min) "\");" else "\");\n");
                            for (wlist.items) |wm| {
                                const tmod = graph.getModule(@fromBackingInt(@intCast(wm))) orelse continue;
                                const wn = try wrapperNamesFor(allocator, tmod, null);
                                defer wn.deinit(allocator);
                                try chunk_output.appendSlice(allocator, "var ");
                                try chunk_output.appendSlice(allocator, wn.a);
                                try chunk_output.appendSlice(allocator, if (min) "=function(){return require(\"" else " = function() { return require(\"");
                                try chunk_output.appendSlice(allocator, bind_arg);
                                try chunk_output.appendSlice(allocator, "\").");
                                try chunk_output.appendSlice(allocator, wn.a);
                                try chunk_output.appendSlice(allocator, if (min) ".apply(this,arguments)};" else ".apply(this, arguments); };\n");
                            }
                        } else {
                            // esm: live binding 이라 named import 로 충분(순환도 안전).
                            try chunk_output.appendSlice(allocator, if (min) "import{" else "import { ");
                            for (wlist.items, 0..) |wm, wi| {
                                const tmod = graph.getModule(@fromBackingInt(@intCast(wm))) orelse continue;
                                const wn = try wrapperNamesFor(allocator, tmod, null);
                                defer wn.deinit(allocator);
                                try chunk_output.appendSlice(allocator, wn.a);
                                if (wi + 1 < wlist.items.len)
                                    try chunk_output.appendSlice(allocator, if (min) "," else ", ");
                            }
                            try chunk_output.appendSlice(allocator, if (min) "}from\"" else " } from \"");
                            try chunk_output.appendSlice(allocator, bind_arg);
                            try chunk_output.appendSlice(allocator, if (min) "\";" else "\";\n");
                        }
                        wrapper_import_emitted = true;
                    }
                }
            }

            if (!options.preserve_modules and (!reg_split or firstAsyncChunkModule(dep_chunk, graph) != null)) {
                if (chunk.esm_wrapper_cross_imports.get(dep_ci)) |initializers| {
                    std.mem.sort(SymbolID, initializers.items, {}, esmInitLessThan);
                    const ready_holder: ?[]const u8 = if ((cjs_require or reg_split) and initializers.items.len != 0 and firstAsyncChunkModule(dep_chunk, graph) != null) blk: {
                        const actual = graph.getModule(initializers.items[0].module) orelse return error.InvalidEsmInitOwner;
                        const base = try types.makeNsVarName(allocator, actual.path);
                        try alias_strs.append(allocator, base);
                        const holder = try mintConsumerLocal(allocator, base, &used_locals, &natural_bindings, &alias_strs);
                        try chunk_output.appendSlice(allocator, if (split_async_import_depth == 0) (if (split_assign_host) "module.exports = " else "") else "return ");
                        try chunk_output.print(allocator, "{s}(\"{s}\").then(function({s}) {{\n", .{ if (reg_split) "__zntc_require" else "require", bind_arg, holder });
                        split_async_import_depth += 1;
                        break :blk holder;
                    } else null;
                    for (initializers.items) |init| {
                        const name = try esmWrapperNameFor(allocator, graph, init, null);
                        defer allocator.free(name);
                        if (ready_holder) |holder| {
                            // The exact wrapper export ledger is part of this
                            // provider's completed namespace. Never read its
                            // Promise as if it already were that namespace.
                            const quoted = try std.json.Stringify.valueAlloc(allocator, name, .{});
                            defer allocator.free(quoted);
                            _ = holder;
                            const helper = try readinessHelperExpression(allocator, graph, chunk_graph, chunk, options, linker orelse return error.MissingTlaReadinessHelper, reg_ids);
                            defer allocator.free(helper);
                            try chunk_output.print(allocator, "var {s}={s}.state({s}(\"{s}\")).internals[{s}];\n", .{ name, helper, if (reg_split) "__zntc_require" else "require", bind_arg, quoted });
                        } else if (cjs_require) {
                            const provider = graph.getModule(init.module) orelse return error.InvalidEsmInitOwner;
                            if ((try provider.esmInitSymbol()).eql(init)) {
                                try chunk_output.print(allocator, "var {s}=function(){{return require(\"{s}\").{s}.apply(this,arguments)}};\n", .{ name, bind_arg, name });
                            } else {
                                try chunk_output.print(allocator, "var {s}=require(\"{s}\").{s};\n", .{ name, bind_arg, name });
                            }
                        } else {
                            try chunk_output.print(allocator, "import {{ {s} }} from \"{s}\";\n", .{ name, bind_arg });
                        }
                        wrapper_import_emitted = true;
                    }
                }
            }

            // (#4580) default-only provider(`module.exports = X`)에서 default 단일 import → require()
            // 결과 **전체**가 default 다. `{ default: x }` 구조분해는 `.default`=undefined(TypeError)
            // 이므로 `const <local> = require("...")` 로 전체를 바인딩한다. dep 이 완전 unwrapped(래퍼
            // 경로 아님)이고 default-only(cjsDepDefaultOnly)이며 auto/default_ 모드일 때만.
            const bind_whole_default = pm_cjs and !pm_cjs_dep and pm_esm_wrap_dep_syms == null and
                pm_wrapper_dep == null and symbols != null and symbols.?.items.len == 1 and
                std.mem.eql(u8, symbols.?.items[0].name, "default") and
                (options.output_exports == .auto or options.output_exports == .default_) and
                cjsDepDefaultOnly(allocator, graph, dep_chunk);
            if (bind_whole_default) {
                const sym = symbols.?.items[0];
                const binding = try crossChunkBindingName(linker, sym);
                // pm_cjs 라 lazy(reg_split/cjs_split=!preserve_modules)는 여기 안 옴 → has_global 만 고정.
                const has_global = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null else false;
                const consumer_module_index = if (options.preserve_modules and chunk.modules.items.len == 1)
                    @as(?u32, @backingInt(chunk.modules.items[0]))
                else
                    null;
                const local = try deconflictedConsumerLocal(linker, sym, binding, has_global, consumer_module_index, allocator, &used_locals, &natural_bindings, &alias_strs);
                try chunk_output.appendSlice(allocator, "const ");
                try chunk_output.appendSlice(allocator, local);
                try chunk_output.appendSlice(allocator, if (options.minify_whitespace) "=require(\"" else " = require(\"");
                try chunk_output.appendSlice(allocator, bind_arg);
                try chunk_output.appendSlice(allocator, if (options.minify_whitespace) "\");" else "\");\n");
            } else if (!pm_cjs_dep and pm_esm_wrap_dep_syms == null and symbols != null and symbols.?.items.len > 0) {
                // 심볼 수준 import: import { a, b } from './chunk-xxx.js';
                // 결정론적 출력을 위해 심볼명(export 키) 정렬
                const SymSort = struct {
                    fn lessThan(_: void, a: chunk_mod.CrossChunkSym, b: chunk_mod.CrossChunkSym) bool {
                        return std.mem.lessThan(u8, a.name, b.name);
                    }
                };
                std.mem.sort(chunk_mod.CrossChunkSym, symbols.?.items, {}, SymSort.lessThan);
                // dep 청크가 심볼을 노출하는 **프로퍼티 키**: lazy(emitLazyEntryExportAll)
                // 는 hoisted 로컬을 *local 명*으로 export-all 하므로 키=바인딩명(예: `_default`)
                // → 축약 `{ _default }`. 비-lazy(production)은 *export 명*(`default`)으로 노출
                // → `{ default: _default }` alias. 키가 dep 노출과 어긋나면 값이 undefined.
                // 조건은 emitLazyEntryExportAll 발동 조건(`reg_fmt and !preserve_modules and
                // lazy`)과 정확히 일치해야 한다 — reg_split(iife/umd/amd) 뿐 아니라 cjs_split
                // 도 emitLazyEntryExportAll 로 local 명 키를 노출하므로 둘 다 포함.
                const lazy_local_keys = graph.lazy_compilation and (reg_split or cjs_split);
                var seen_lazy_symbols: std.AutoHashMapUnmanaged(SymbolID, void) = .empty;
                defer seen_lazy_symbols.deinit(allocator);
                var lazy_unique_symbols: std.ArrayListUnmanaged(chunk_mod.CrossChunkSym) = .empty;
                defer lazy_unique_symbols.deinit(allocator);
                var import_symbols = symbols.?.items;
                if (lazy_local_keys) {
                    try lazy_unique_symbols.ensureTotalCapacity(allocator, import_symbols.len);
                    for (symbols.?.items) |sym| {
                        if (crossChunkSemanticSymbolId(linker, sym)) |symbol_id| {
                            const gop = try seen_lazy_symbols.getOrPut(allocator, symbol_id);
                            if (gop.found_existing) continue;
                        }
                        lazy_unique_symbols.appendAssumeCapacity(sym);
                    }
                    import_symbols = lazy_unique_symbols.items;
                }

                if (!options.preserve_modules and options.format != .esm) {
                    if (firstAsyncChunkModule(dep_chunk, graph)) |async_provider| {
                        try emitPmCjsLiveImport(allocator, &chunk_output, linker, graph, async_provider, import_symbols, bind_arg, lazy_local_keys, options.minify_whitespace, options.transform_options_base.unsupported.block_scoping or options.transform_options_base.unsupported.destructuring, &used_locals, &natural_bindings, &alias_strs, true, &split_async_import_depth, if (reg_split) "__zntc_require" else "require", split_assign_host);
                        continue;
                    }
                }

                // (#4587 target a) preserve-modules CJS 라이브 바인딩: dep 의 재할당(storage)
                // export 를 구조분해(로드 시점 스냅샷)로 잡으면 순환에서 undefined 를 박제한다.
                // 재할당 심볼은 ns holder(`const ns=require()`) + body 참조 `ns.<key>`
                // (consumer_import_local → metadata effective_target), 비재할당은 현행 구조분해.
                // output.exports 게이트(#4587 [3]): provider 가 storage(exports.X) 를 안 내는
                // none/default_ 에서는 소비자도 ns-access 를 하면 안 된다(provider·metadata·codegen
                // 게이트와 동일 값이어야 정합).
                const storage_output_gate = options.output_exports == .auto or options.output_exports == .named;
                const dep_mod_idx: ?ModuleIndex = if (pm_cjs and storage_output_gate) depChunkModuleIndex(dep_chunk) else null;
                const await_pm_namespace = if (pm_protocol_owner != null) false else if (dep_mod_idx) |dmi|
                    if (graph.getModule(dmi)) |provider| provider.in_async_cone else false
                else
                    false;
                var has_reassigned = false;
                if (dep_mod_idx) |dmi| {
                    for (symbols.?.items) |sym| {
                        if (isExportReassigned(graph, dmi, sym.name)) {
                            has_reassigned = true;
                            break;
                        }
                    }
                }
                if (has_reassigned or await_pm_namespace) {
                    try emitPmCjsLiveImport(
                        allocator,
                        &chunk_output,
                        linker,
                        graph,
                        dep_mod_idx.?,
                        import_symbols,
                        bind_arg,
                        lazy_local_keys,
                        options.minify_whitespace,
                        options.transform_options_base.unsupported.block_scoping or options.transform_options_base.unsupported.destructuring,
                        &used_locals,
                        &natural_bindings,
                        &alias_strs,
                        await_pm_namespace,
                        &pm_async_import_depth,
                        "require",
                        true,
                    );
                    continue;
                }

                if (cjs_require and (options.transform_options_base.unsupported.block_scoping or options.transform_options_base.unsupported.destructuring)) {
                    for (import_symbols) |sym| {
                        const binding = try crossChunkBindingName(linker, sym);
                        const has_global = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null else false;
                        const binding_key = lazy_local_keys or (has_global and !entryChunkExportsPublicName(graph, dep_chunk, sym.name, options));
                        const key = if (binding_key) binding else sym.name;
                        const consumer = if (options.preserve_modules and chunk.modules.items.len == 1) @as(?u32, @backingInt(chunk.modules.items[0])) else null;
                        const local = try deconflictedConsumerLocal(linker, sym, binding, lazy_local_keys or has_global, consumer, allocator, &used_locals, &natural_bindings, &alias_strs);
                        const property_key = try ordinaryConsumerPropertyKey(allocator, linker, sym, key, if (binding_key) .binding_spelling else .module_export_name);
                        defer property_key.deinit(allocator);
                        const quoted = try std.json.Stringify.valueAlloc(allocator, property_key.text, .{});
                        defer allocator.free(quoted);
                        try chunk_output.print(allocator, "var {s}=require(\"{s}\")[{s}];\n", .{ local, bind_arg, quoted });
                    }
                    continue;
                }

                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, if (reg_like) "const { " else "import { ");
                } else {
                    try chunk_output.appendSlice(allocator, if (reg_like) "const{" else "import{");
                }
                for (import_symbols, 0..) |sym, si| {
                    const name = sym.name;
                    const binding = try crossChunkBindingName(linker, sym);
                    // #4101 cross-chunk 전역 네이밍: 심볼이 전역 이름을 가지면 그 이름이 곧
                    // provider 노출 키(dev=emitLazyEntryExportAll local-key, production=브리지
                    // `export { local as global }` public)라, 소비자 import key 도 전역명이어야
                    // 동명 다른 모듈(`v`/`v$1`)을 구별한다. lazy 는 항상 binding-key. 전역명
                    // 없으면(map 미populate/비-cross-chunk) export 명 키(기존).
                    const has_global = if (linker) |l| l.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null else false;
                    const key = if (lazy_local_keys or (has_global and !entryChunkExportsPublicName(graph, dep_chunk, name, options)))
                        binding
                    else
                        name;

                    // (#4572/#4576) 선언 로컬은 항상 binding. has_global/lazy 는 고정, 그 외 유일 발급 +
                    // deconflict 시 body 정합(deconflictedConsumerLocal, #4580 전체바인딩 site 와 공용).
                    const consumer_module_index = if (options.preserve_modules and chunk.modules.items.len == 1)
                        @as(?u32, @backingInt(chunk.modules.items[0]))
                    else
                        null;
                    const local = try deconflictedConsumerLocal(linker, sym, binding, lazy_local_keys or has_global, consumer_module_index, allocator, &used_locals, &natural_bindings, &alias_strs);

                    if (!std.mem.eql(u8, key, local)) {
                        // key != local → `key: local` / `key as local`. key!=binding(예약어 export 키
                        // `default`→소비자 local) 또는 deconflict(`binding$N`) 모두 alias 로 방출.
                        try chunk_output.appendSlice(allocator, key);
                        try chunk_output.appendSlice(allocator, if (reg_like) ": " else " as ");
                        try chunk_output.appendSlice(allocator, local);
                    } else {
                        // key == local → 축약 `{ key }`.
                        try chunk_output.appendSlice(allocator, key);
                    }
                    if (si + 1 < symbols.?.items.len) {
                        if (!options.minify_whitespace) {
                            try chunk_output.appendSlice(allocator, ", ");
                        } else {
                            try chunk_output.append(allocator, ',');
                        }
                    }
                }
                // 결합 open: iife=`__zntc_require("`, cjs=`require("`, esm=`from"`
                const sym_open = if (reg_split)
                    (if (options.minify_whitespace) "}=__zntc_require(\"" else " } = __zntc_require(\"")
                else if (cjs_require)
                    (if (options.minify_whitespace) "}=require(\"" else " } = require(\"")
                else
                    (if (options.minify_whitespace) "}from\"" else " } from \"");
                const sym_close = if (reg_like)
                    (if (options.minify_whitespace) "\");" else "\");\n")
                else
                    (if (options.minify_whitespace) "\";" else "\";\n");
                try chunk_output.appendSlice(allocator, sym_open);
                try chunk_output.appendSlice(allocator, bind_arg);
                try chunk_output.appendSlice(allocator, sym_close);
            } else if (pm_wrapper_dep == null and !wrapper_import_emitted) {
                // 심볼 정보 없음 → side-effect (실행/등록 순서 보장용)
                // ⚠️ 래퍼 분기(preserve-modules) 또는 #4541 wrapper named import 가 이미 결합을
                // 냈으면 여기서 또 내면 중복이다.
                if (!options.preserve_modules and options.format != .esm and firstAsyncChunkModule(dep_chunk, graph) != null) {
                    try chunk_output.appendSlice(allocator, if (split_async_import_depth == 0) (if (split_assign_host) "module.exports = " else "") else "return ");
                    try chunk_output.appendSlice(allocator, if (reg_split) "__zntc_require(\"" else "require(\"");
                    try chunk_output.appendSlice(allocator, bind_arg);
                    try chunk_output.appendSlice(allocator, "\").then(function() {\n");
                    split_async_import_depth += 1;
                    continue;
                }
                if (pm_cjs and pm_protocol_owner == null and (options.output_exports == .auto or options.output_exports == .named)) {
                    const async_provider = if (depChunkModuleIndex(dep_chunk)) |dmi|
                        if (graph.getModule(dmi)) |provider| provider.in_async_cone else false
                    else
                        false;
                    if (async_provider) {
                        try chunk_output.appendSlice(allocator, if (pm_async_import_depth == 0) "module.exports = require(\"" else "return require(\"");
                        try chunk_output.appendSlice(allocator, bind_arg);
                        try chunk_output.appendSlice(allocator, "\").then(function() {\n");
                        pm_async_import_depth += 1;
                        continue;
                    }
                }
                const se_open = if (reg_split)
                    "__zntc_require(\""
                else if (cjs_require)
                    "require(\""
                else if (options.minify_whitespace) "import\"" else "import \"";
                const se_close = if (reg_like)
                    (if (options.minify_whitespace) "\");" else "\");\n")
                else
                    (if (options.minify_whitespace) "\";" else "\";\n");
                try chunk_output.appendSlice(allocator, se_open);
                try chunk_output.appendSlice(allocator, bind_arg);
                try chunk_output.appendSlice(allocator, se_close);
            }
        }

        // These declarations now belong to the readiness callback. Hoist their
        // public function values inside that same function scope, after its
        // dependency holders exist, rather than reading an unbound outer name.
        if (pm_async_import_depth > 0 and fn_hoist_entry != null) fn_hoist_pos = chunk_output.items.len;

        // 청크 내 모듈을 정렬. 단일번들(bundleOrderLessThan)과 동일하게 **래핑 모듈
        // (__commonJS/__esm) 먼저, 그 안에서 exec_index** — `var require_X = __commonJS(...)`/
        // `var init_X = __esm(...)` 선언이 그것을 참조하는 비-래핑 코드보다 앞서야 한다.
        // (#4120) 예전 exec_index-only 는 동적 re-export 청크에서 비-래핑 entry(Route, 낮은
        // exec_index)를 그 CJS dep(cjslib) *앞* 에 둬, entry final_exports 의 interop materialize
        // (`__toESM(require_cjslib())`)가 require_cjslib 할당 전에 실행 → TypeError. 래핑은 lazy
        // (body 는 첫 require/init 호출 시 실행)라 선언 reorder 가 side-effect 순서를 바꾸지 않는다.
        const sorted_mods = try allocator.alloc(ModuleIndex, chunk.modules.items.len);
        defer allocator.free(sorted_mods);
        @memcpy(sorted_mods, chunk.modules.items);

        const ModSortCtx = struct {
            graph: *const ModuleGraph,
            fn lessThan(ctx: @This(), a: ModuleIndex, b: ModuleIndex) bool {
                // This real AST module owns the guard's captured global/state.
                // Its Scope0 initialization must precede every consumer body;
                // the ordinary module emitter still publishes it exactly once.
                if (ctx.graph.entry_guard_ast_provider) |provider| {
                    const a_provider = a == provider.module_index;
                    const b_provider = b == provider.module_index;
                    if (a_provider != b_provider) return a_provider;
                }
                const ma = ctx.graph.getModule(a);
                const mb = ctx.graph.getModule(b);
                if (ma == null or mb == null) {
                    const a_exec = if (ma) |m| m.exec_index else std.math.maxInt(u32);
                    const b_exec = if (mb) |m| m.exec_index else std.math.maxInt(u32);
                    return a_exec < b_exec;
                }
                return Module.bundleOrderLessThan({}, ma.?, mb.?);
            }
        };
        std.mem.sort(ModuleIndex, sorted_mods, ModSortCtx{ .graph = graph }, ModSortCtx.lessThan);

        // Import emission already selected these exact lexical locals. Do
        // not reselect provider names or treat live namespace member reads as
        // bare declarations. Every reservation owns its bytes across the
        // linker's clearCanonicalNames and the rest of this chunk's emission.
        var occupied: std.ArrayList([]const u8) = .empty;
        defer {
            for (occupied.items) |name| allocator.free(name);
            occupied.deinit(allocator);
        }
        {
            try snapshotConsumerLocals(allocator, &used_locals, &occupied);
            for (rbm_cross_imports.items) |imp| {
                try appendOwnedOccupied(allocator, &occupied, imp.name);
            }
            // CJS member edges create chunk locals outside source lexical
            // scopes. Reserve their negotiated output names before renaming.
            if (linker) |l| {
                for (provider_edges) |edge| {
                    const provider = try checkedChunkProvider(l, chunk, edge);
                    if (provider.role != .cjs_member) continue;
                    const global = try crossChunkPublicName(l, edge, options.preserve_modules);
                    try appendOwnedOccupied(allocator, &occupied, global);
                }
            }
        }

        // These import-phase tables borrow provider canonical strings. No
        // later phase reads them; drop their keys before that storage is freed.
        used_locals.clearRetainingCapacity();
        natural_bindings.clearRetainingCapacity();

        // per-chunk 리네임 계산: 각 청크는 독립된 네임스페이스이므로
        // 청크 내 모듈들만 대상으로 이름 충돌을 감지한다.
        if (linker) |l| {
            try l.computeRenamesForModules(sorted_mods, occupied.items);
        }

        var holder_reservations = @import("../namespace_holder_reservations.zig").NamespaceHolderReservations.init(allocator);
        defer holder_reservations.deinit();
        if (linker) |l| try holder_reservations.seed(l);
        for (occupied.items) |name| try holder_reservations.reserve(name);

        // Helper-import aliases must agree with body references after this
        // chunk's final names are selected. Generate the ESM import block now,
        // then place it at its original prologue offset before the saved
        // preamble insertion points.
        {
            var chunk_mods: std.ArrayListUnmanaged(*const Module) = .empty;
            defer chunk_mods.deinit(allocator);
            try chunk_mods.ensureTotalCapacity(allocator, chunk.modules.items.len);
            for (chunk.modules.items) |mod_idx| {
                if (graph.getModule(mod_idx)) |m| chunk_mods.appendAssumeCapacity(m);
            }
            var imports_output: std.ArrayList(u8) = .empty;
            defer imports_output.deinit(allocator);
            try external_imports.emitChunkExternalImports(
                &imports_output,
                allocator,
                options.format == .esm,
                chunk_mods.items,
                linker,
                options.minify_whitespace,
            );
            if (imports_output.items.len > 0) {
                try chunk_output.insertSlice(allocator, external_imports_pos, imports_output.items);
                pm_definition_pos += imports_output.items.len;
                if (ns_preamble_pos) |*pos| pos.* += imports_output.items.len;
                if (fn_hoist_pos) |*pos| pos.* += imports_output.items.len;
            }
        }

        // (#4532 증상4) 리네임 확정 후 function-decl export 를 require 블록 앞에 insert.
        // ns_preamble insert(아래)보다 **먼저** — ns_preamble_pos(더 앞) 을 먼저 넣으면 fn_hoist_pos 가
        // 밀린다. 여기서 넣고 나서 ns_preamble 을 더 앞에 넣으면 순서/위치 모두 정확.
        if (fn_hoist_pos) |pos| if (fn_hoist_entry) |emi| if (linker) |l| {
            var fn_exports: std.ArrayList(u8) = .empty;
            defer fn_exports.deinit(allocator);
            try emitHoistedFnExports(l, graph, emi, &fn_exports, allocator);
            if (fn_exports.items.len > 0) {
                try chunk_output.insertSlice(allocator, pos, fn_exports.items);
            }
        };

        // (#4502) 이제 이 청크의 chunk-local 이름이 확정됐다 — 공유 namespace preamble 을
        // 생성해 위에서 잡아 둔 자리에 삽입. getter 본문이 (같은 청크 선언 → 확정 local 명 /
        // 다른 청크 선언 → cross-chunk 전역 공개명) 으로 정확히 해석된다.
        if (ns_preamble_pos) |pos| if (linker) |l| {
            var chunk_targets: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer chunk_targets.deinit(allocator);
            try chunk_targets.ensureTotalCapacity(allocator, @intCast(chunk.modules.items.len));
            for (chunk.modules.items) |mod_idx| {
                chunk_targets.putAssumeCapacity(@backingInt(mod_idx), {});
            }
            // appendSharedNamespacePreambleFiltered 는 linker 의 allocator 로 append 하므로
            // deinit 도 같은 allocator 로 (기존엔 chunk_output 에 직접 append 했었다).
            var ns_preamble: std.ArrayList(u8) = .empty;
            defer ns_preamble.deinit(l.allocator);
            try l.appendSharedNamespacePreambleFiltered(&ns_preamble, &chunk_targets);
            if (ns_preamble.items.len > 0) {
                try chunk_output.insertSlice(allocator, pos, ns_preamble.items);
                pm_definition_pos += ns_preamble.items.len;
            }
        };

        // Namespace allocation is an instantiation step, before dependency evaluation.
        // Its output position is planned directly, using only actual cross-edge SIDs.
        if (options.format == .cjs and !options.preserve_modules and linker != null and linker.?.usesCjsLiveWrapperNamespaces()) {
            var prefix: std.ArrayList(u8) = .empty;
            defer prefix.deinit(allocator);
            var namespaces: std.ArrayListUnmanaged(SymbolID) = .empty;
            defer namespaces.deinit(allocator);
            var identities = chunk.esm_wrapper_cross_exports.keyIterator();
            while (identities.next()) |identity| {
                const owner = graph.getModule(identity.module) orelse return error.InvalidEsmInitOwner;
                if (identity.eql(try owner.esmNamespaceSymbol())) try namespaces.append(allocator, identity.*);
            }
            std.mem.sort(SymbolID, namespaces.items, {}, esmInitLessThan);
            for (namespaces.items) |identity| {
                const local = try esmWrapperNameFor(allocator, graph, identity, linker);
                defer allocator.free(local);
                const public = try esmWrapperNameFor(allocator, graph, identity, null);
                defer allocator.free(public);
                try prefix.print(allocator, "var {s}={{}};exports.{s}={s};\n", .{ local, public, local });
                try initialized_namespaces.put(allocator, identity, {});
            }
            if (prefix.items.len > 0) try chunk_output.insertSlice(allocator, external_imports_pos, prefix.items);
        }

        // 엔트리 모듈 인덱스 (final exports용). manual/common 은 엔트리 모듈 없음.
        const entry_mod_idx: ?u32 = switch (chunk.kind) {
            .entry_point => |info| @backingInt(info.module),
            .common, .manual => null,
        };
        const emit_top_level_rbm = chunk_is_user_entry and options.run_before_main.len > 0;
        var run_before_main_closure: ?std.DynamicBitSet = null;
        defer if (run_before_main_closure) |*closure| closure.deinit();
        if (emit_top_level_rbm) {
            const closure = try collectRunBeforeMainClosure(allocator, graph, options.run_before_main);
            run_before_main_closure = closure;
        }
        const rbm_insert_after_pos = if (run_before_main_closure) |*closure|
            findLastRunBeforeMainPosition(sorted_mods, closure)
        else
            null;
        var rbm_calls_emitted = false;

        // module emit 영역의 base line. null = sourcemap 비활성 → 추적 비용 0.
        // non-null = chunk prologue (banner/intro/runtime helpers/imports) 가 이미
        // 들어간 시점의 줄 수로 초기화 후 module 추가마다 increment.
        var module_line: ?u32 = if (chunk_sm != null)
            @intCast(std.mem.count(u8, chunk_output.items, "\n"))
        else
            null;

        // CommonJS modules this chunk's hoisted modules import run at their
        // import position (#5666).
        var early_cjs_inits: std.ArrayList(parent.EarlyCjsInit) = .empty;
        defer early_cjs_inits.deinit(allocator);
        {
            var in_chunk = try std.DynamicBitSet.initEmpty(allocator, module_count);
            defer in_chunk.deinit();
            for (sorted_mods) |mod_idx| {
                const mi = @backingInt(mod_idx);
                if (mi < module_count) in_chunk.set(mi);
            }
            for (sorted_mods) |mod_idx| {
                const m = graph.getModule(mod_idx) orelse continue;
                try parent.collectEarlyCjsInits(allocator, graph, linker, m, &in_chunk, &early_cjs_inits);
            }
            parent.sortEarlyCjsInits(early_cjs_inits.items);
        }

        // Each module body is independent after this chunk's rename table is
        // finalized. Emit large chunks in parallel, then keep import rewriting,
        // sourcemap assembly, and output concatenation in deterministic order.
        var pm_deferred_exports: parent.DeferredAsyncEntryExports = .{ .module_index = entry_mod_idx orelse 0 };
        defer if (pm_deferred_exports.value) |value| allocator.free(value);
        defer if (pm_deferred_exports.init_name) |value| allocator.free(value);
        defer if (pm_deferred_exports.namespace_name) |value| allocator.free(value);
        var pm_emit_options = if (reg_split) iife_emit_opts else options.*;
        if (pm_async_import_depth > 0 or pm_protocol_owner != null) {
            if (entry_mod_idx == null) return error.MissingAsyncEntryExportOwner;
            pm_emit_options.defer_async_entry_exports = &pm_deferred_exports;
            pm_deferred_exports.pm_protocol = pm_protocol_owner != null;
            // The implementation remains a namespace/readiness provider. Only
            // its separately planned public facade projects the default scalar.
            for (facades) |facade| if (facade.chunk_index == chunk.index) {
                if (pm_protocol_owner != facade.module_index) return error.InvalidPublicEntryFacadeOwner;
                pm_deferred_exports.cjs_value = false;
                break;
            };
        }
        var split_deferred_exports: parent.DeferredAsyncEntryExports = .{ .module_index = entry_mod_idx orelse 0, .cjs_value = !chunk_is_user_entry or options.format == .cjs };
        defer if (split_deferred_exports.value) |value| allocator.free(value);
        var split_emit_options = if (reg_split) iife_emit_opts else options.*;
        const split_needs_readiness = !options.preserve_modules and options.format != .esm and
            (split_async_import_depth > 0 or firstAsyncChunkModule(chunk, graph) != null);
        const split_contexts = try allocator.alloc(parent.DeferredAsyncEntryExports, if (split_needs_readiness) module_count else 0);
        defer allocator.free(split_contexts);
        for (split_contexts, 0..) |*context, index| context.* = .{ .module_index = @intCast(index), .cjs_value = !chunk_is_user_entry or options.format == .cjs };
        defer for (split_contexts) |context| {
            if (context.value) |value| allocator.free(value);
            if (context.init_name) |value| allocator.free(value);
            if (context.namespace_name) |value| allocator.free(value);
        };
        if (split_needs_readiness) {
            for (sorted_mods) |index| {
                const owner = graph.getModule(index) orelse return error.InvalidTlaReadinessOwner;
                if (owner.wrap_kind == .esm and owner.in_async_cone)
                    split_contexts[index.toU32()].internal_module = true;
            }
            split_emit_options.deferred_module_exports = split_contexts;
            if (!chunk_is_user_entry) split_emit_options.output_exports = .named;
            if (entry_mod_idx != null) split_emit_options.defer_async_entry_exports = &split_deferred_exports;
        }
        const internal_readiness_helper = if (graph.tla_readiness_all) |known|
            chunk.modules.items.len == 1 and chunk.modules.items[0] == known.module_index
        else
            false;
        if (internal_readiness_helper) pm_emit_options.output_exports = .named;
        const base_module_emit_options = if (pm_async_import_depth > 0 or pm_protocol_owner != null or internal_readiness_helper) &pm_emit_options else if (split_needs_readiness) &split_emit_options else if (reg_split) &iife_emit_opts else options;
        var compiler_literals: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        defer {
            var values = compiler_literals.valueIterator();
            while (values.next()) |value| allocator.free(value.*);
            compiler_literals.deinit(allocator);
        }
        for (chunk.modules.items) |index| {
            const owner = graph.getModule(index) orelse return error.InvalidPmNamespaceCallsite;
            const registry = @import("../graph/legacy_initialization_registry.zig");
            if (owner.legacy_lexical_writes.len != 0) {
                try registry.validate(graph, owner);
                for (owner.legacy_lexical_writes) |receipt|
                    try appendLexicalRegistryModulePath(allocator, graph, chunk_graph, chunk, options, owner, owner, receipt.key, &compiler_literals);
            }
            if (owner.legacy_lexical_reads.len != 0) {
                try @import("../graph/legacy_lexical_reads.zig").validate(graph, owner);
                for (owner.legacy_lexical_reads) |receipt| if (receipt.registry_key) |key| {
                    try appendLexicalRegistryModulePath(allocator, graph, chunk_graph, chunk, options, owner, receipt.plan.module, key, &compiler_literals);
                };
            }
            for (owner.import_records) |record| {
                const proof = record.pm_namespace_projection orelse continue;
                if (!options.preserve_modules or options.format != .cjs or chunk.modules.items.len != 1) return error.InvalidPmNamespaceCallsite;
                try @import("../pm_dynamic_namespace.zig").validate(graph, owner, record);
                const helper = graph.tla_readiness_all orelse return error.InvalidPmNamespaceCallsite;
                const helper_chunk = chunk_graph.getModuleChunk(helper.module_index);
                const target_chunk = chunk_graph.getModuleChunk(record.resolved);
                if (helper_chunk.isNone() or target_chunk.isNone()) return error.InvalidPmNamespaceCallsite;
                var helper_path: std.ArrayListUnmanaged(u8) = .empty;
                defer helper_path.deinit(allocator);
                var target_path: std.ArrayListUnmanaged(u8) = .empty;
                defer target_path.deinit(allocator);
                try appendChunkOutputPath(chunk_graph.getChunk(helper_chunk), &helper_path, allocator, options);
                try appendChunkOutputPath(chunk_graph.getChunk(target_chunk), &target_path, allocator, options);
                const relative = try computeRelativePath(allocator, std.fs.path.dirname(helper_path.items) orelse "", target_path.items, "");
                defer allocator.free(relative);
                const target = graph.getModule(record.resolved) orelse return error.InvalidPmNamespaceCallsite;
                const quoted = try quoteChunkPath(allocator, relative);
                try putCompilerLiteral(&compiler_literals, allocator, @backingInt(proof.path_node), quoted);
                const init_key = try std.json.Stringify.valueAlloc(allocator, try target.esmWrapperName(try target.esmInitSymbol(), null), .{});
                try putCompilerLiteral(&compiler_literals, allocator, @backingInt(proof.init_node), init_key);
                const namespace_key = try std.json.Stringify.valueAlloc(allocator, try target.esmWrapperName(try target.esmNamespaceSymbol(), null), .{});
                try putCompilerLiteral(&compiler_literals, allocator, @backingInt(proof.namespace_node), namespace_key);
            }
        }
        var literal_emit_options = base_module_emit_options.*;
        if (compiler_literals.count() != 0) literal_emit_options.compiler_literal_overrides = &compiler_literals;
        const module_emit_options = &literal_emit_options;
        const parallelism: usize = @max(1, if (graph.max_threads != 0)
            @as(usize, @intCast(graph.max_threads))
        else
            (std.Thread.getCpuCount() catch 8));
        const parallel_emit = io != null and sorted_mods.len >= 32 and graph.max_threads != 1 and parallelism > 1;
        // Four workers reduce a 5k-module chunk from five group/await rounds
        // (80 range tasks) to three (48); local paired median improved 1.035x.
        const emit_batch_size = if (parallel_emit)
            @min(sorted_mods.len, @min(@as(usize, 2048), @max(@as(usize, 1024), parallelism *| @as(usize, 512))))
        else
            1;
        var batch_start: usize = 0;
        while (batch_start < sorted_mods.len) {
            const batch_end = @min(batch_start + emit_batch_size, sorted_mods.len);
            const batch_mods = sorted_mods[batch_start..batch_end];
            var single_result = [1]ChunkModuleEmitResult{.{}};
            const module_results: []ChunkModuleEmitResult = if (parallel_emit)
                try allocator.alloc(ChunkModuleEmitResult, batch_mods.len)
            else
                single_result[0..];
            defer {
                for (module_results) |*result| result.deinit(allocator);
                if (parallel_emit) allocator.free(module_results);
            }
            if (parallel_emit) {
                for (module_results) |*result| result.* = .{};
            }

            if (parallel_emit) {
                const emit_io = io.?;
                var group: std.Io.Group = .init;
                const range_size = util.chunkSize(batch_mods.len, parallelism);
                var start: usize = 0;
                while (start < batch_mods.len) {
                    const end = @min(start + range_size, batch_mods.len);
                    group.async(emit_io, emitChunkModuleRange, .{
                        allocator,
                        batch_mods,
                        graph,
                        module_emit_options,
                        linker,
                        entry_mod_idx,
                        used_names_by_modidx,
                        shaker,
                        chunk_sm != null,
                        &initialized_namespaces,
                        module_results,
                        &holder_reservations,
                        start,
                        end,
                    });
                    start = end;
                }
                group.await(emit_io) catch {};
            } else {
                emitChunkModuleRange(
                    allocator,
                    batch_mods,
                    graph,
                    module_emit_options,
                    linker,
                    entry_mod_idx,
                    used_names_by_modidx,
                    shaker,
                    chunk_sm != null,
                    &initialized_namespaces,
                    module_results,
                    &holder_reservations,
                    0,
                    batch_mods.len,
                );
            }
            for (module_results) |result| if (result.err) |err| return err;

            for (batch_mods, 0..) |mod_idx, batch_pos| {
                const sorted_pos = batch_start + batch_pos;
                const mi = @backingInt(mod_idx);
                if (mi >= module_count) continue;
                const m = graph.getModule(mod_idx) orelse continue;

                const is_entry = if (entry_mod_idx) |ei| mi == ei else false;
                const module_result = &module_results[batch_pos];
                const raw_code = module_result.code orelse continue;
                const module_mappings = module_result.mappings;
                const module_names = module_result.names;
                const module_preamble_lines = module_result.preamble_lines;

                // 동적 import 경로 리라이트: import('./page') → import('./page.js')
                const rewritten_code = try rewriteDynamicImports(allocator, raw_code, m, graph, chunk_graph, options.public_path, ext, options, reg_ids, linker, &compiler_snippets);
                defer if (rewritten_code) |code| allocator.free(code);
                const code = rewritten_code orelse raw_code;

                // entry 모듈(또는 preserve-modules의 단일 모듈)의 directive prologue 추출.
                // "use client"/"use server"는 청크 최상단으로 호이스팅되어야 RSC가 인식.
                const should_hoist = is_entry or options.preserve_modules;
                const stripped = if (should_hoist)
                    extractLeadingDirectives(code, &hoisted_directives, allocator) catch code
                else
                    code;

                if (emit_top_level_rbm and !rbm_calls_emitted and shouldInsertRunBeforeMainBefore(sorted_pos, rbm_insert_after_pos)) {
                    const before_len = chunk_output.items.len;
                    try appendRunBeforeMainCalls(&chunk_output, allocator, graph, options.run_before_main, options, if (linker) |l| &l.rename_table else null);
                    if (module_line) |*ml| ml.* += @intCast(std.mem.count(u8, chunk_output.items[before_len..], "\n"));
                    rbm_calls_emitted = true;
                }

                if (early_cjs_inits.items.len > 0) {
                    const before_len = chunk_output.items.len;
                    try parent.appendEarlyCjsInitsBefore(&chunk_output, allocator, early_cjs_inits.items, m, linker, options.minify_whitespace);
                    if (module_line) |*ml| ml.* += @intCast(std.mem.count(u8, chunk_output.items[before_len..], "\n"));
                }

                const pm_mapping_base: ?u32 = if (pm_instantiation_owner != null and chunk_sm != null)
                    @intCast(std.mem.count(u8, chunk_output.items[0..pm_definition_pos], "\n") + std.mem.count(u8, pm_definition_code.items, "\n"))
                else
                    null;
                const definition_output = if (pm_instantiation_owner != null) &pm_definition_code else &chunk_output;
                if (!options.minify_whitespace) {
                    try definition_output.appendSlice(allocator, "//#region ");
                    try definition_output.appendSlice(allocator, std.fs.path.basename(m.path));
                    try definition_output.append(allocator, '\n');
                    if (module_line) |*ml| ml.* += 1;
                }

                // 모듈 매핑: codegen mapping + region/endregion fill 까지 dev.zig 가 처리.
                // base_line = module_line - region_lines (region marker 시작 지점 기준).
                // stripped 의 줄 수는 module_line 누적용 + addModuleMappings 인자에 모두
                // 쓰이므로 한 번만 카운트.
                const stripped_lines: u32 = if (chunk_sm != null) @intCast(std.mem.count(u8, stripped, "\n")) else 0;
                if (chunk_sm) |*sm| if (module_mappings) |maps| {
                    const region_lines: u32 = if (options.minify_whitespace) 0 else 1;
                    const endregion_lines: u32 = if (options.minify_whitespace) 0 else 1;
                    try parent.addModuleMappings(.{
                        .sm = sm,
                        .module_id = parent.sourcemapSourcePath(m.path, options),
                        .source = m.source,
                        .maps = maps,
                        .module_names = module_names,
                        .base_line = pm_mapping_base orelse (module_line.? - region_lines),
                        .preamble_lines = module_preamble_lines,
                        .sources_content = options.sourcemap.sources_content,
                        .indent_offset = false,
                        .pre_lines = region_lines,
                        .total_code_lines = stripped_lines,
                        .post_lines = endregion_lines,
                        .plugin_source_maps = m.plugin_source_maps,
                    });
                };

                if (pm_instantiation_owner) |owner| {
                    if (m.index != owner or !m.wrap_kind.isWrapped() or (pm_protocol_owner != null and m.wrap_kind != .esm)) return error.InvalidAsyncEntryExportOwner;
                    // Instantiation definitions precede recursive require;
                    // evaluation stays behind the registered initializer.
                    try pm_definition_code.appendSlice(allocator, stripped);
                } else try chunk_output.appendSlice(allocator, stripped);
                if (module_line) |*ml| ml.* += stripped_lines;
                if (!options.minify_whitespace) {
                    try definition_output.appendSlice(allocator, "//#endregion\n");
                    if (module_line) |*ml| ml.* += 1;
                }

                // dev+split per-module HMR code 수집 (RFC_LAZY_DEV_MODULE_HMR PR-1).
                // 단일 번들(emitter.zig)과 *동일* 형식(wrapDevModuleCode)으로 모은다 — HMR
                // client 가 두 경로 산출을 구분 없이 eval. concat 용 region marker 는 제외하고
                // rewriteDynamicImports 거친 `code` 를 wrap. PR-1 은 수집(인프라)만 — 글로벌
                // 레지스트리 부트스트랩/클라이언트 적용은 후속 PR. sourcemap 은 후속(PR 범위 축소).
                if (collect_dev_codes) {
                    const mod_id = parent.makeModuleId(m.path, options.root_dir);
                    const hmr_code = try parent.wrapDevModuleCode(allocator, code, mod_id, options.sourcemap.enable, hmr_runtime_names);
                    errdefer allocator.free(hmr_code);
                    const id_dup = try allocator.dupe(u8, mod_id);
                    errdefer allocator.free(id_dup);
                    try chunk_dev_codes.append(allocator, .{ .id = id_dup, .code = hmr_code });
                }
            }
            batch_start = batch_end;
        }
        if (emit_top_level_rbm and !rbm_calls_emitted) {
            const before_len = chunk_output.items.len;
            try appendRunBeforeMainCalls(&chunk_output, allocator, graph, options.run_before_main, options, if (linker) |l| &l.rename_table else null);
            if (module_line) |*ml| ml.* += @intCast(std.mem.count(u8, chunk_output.items[before_len..], "\n"));
            rbm_calls_emitted = true;
        }

        // RSC 디렉티브 충돌 검증 (Next.js 스펙).
        warnRscDirectiveConflict(hoisted_directives.items, chunk.rel_dir orelse "<chunk>");

        var rbm_export_names: std.ArrayList([]const u8) = .empty;
        defer {
            for (rbm_export_names.items) |name| allocator.free(name);
            rbm_export_names.deinit(allocator);
        }
        var rbm_export_bindings: std.StringHashMapUnmanaged(RunBeforeMainExport) = .empty;
        defer rbm_export_bindings.deinit(allocator);
        if (options.run_before_main.len > 0) {
            try collectRunBeforeMainExportNames(
                allocator,
                &rbm_export_names,
                &rbm_export_bindings,
                graph,
                chunk_graph,
                chunk,
                options.run_before_main,
                if (linker) |l| &l.rename_table else null,
            );
        }

        // dev_split (RFC_LAZY_DEV_MODULE_HMR PR-2): 청크의 hoisted wrapped 모듈 init 트리거.
        // production 은 모듈이 wrap 안 돼 청크 factory 실행 = 즉시 init 이지만, dev wrap-all 은
        // 모듈을 `init_X = __esm({...})` 로 lazy wrap. 청크 factory 가 init 을 안 부르면 아래
        // cross-chunk `exports.x = local` 이 init 전 값(undefined)을 스냅샷 → cross-chunk 소비자가
        // `const {x} = __zntc_require(...)` 로 undefined 캡처(const export = s/tag undefined 버그;
        // 함수는 hoisting 으로 정상이라 const 만 노출됐다, follow-up #A).
        // ⚠️ user-entry 청크의 *entry 모듈 자체* 는 제외 — 1015 블록 + bootstrap 이 init 하며
        // 그게 앱 실행 시점이라 여기서 당겨 실행하면 안 된다. hoisted **dep** 모듈만 선-init 해
        // const export 스냅샷을 채운다(entry 도 dep 를 import 해 hoist 시킨 경우 포함).
        // __esm memoize=중복 무해.
        if (dev_split_chunk) {
            for (sorted_mods) |mod_idx| {
                const mi = @backingInt(mod_idx);
                if (mi >= module_count) continue;
                // user-entry 청크: entry 모듈 자체는 skip(1015 블록/bootstrap 이 init).
                if (chunk_is_user_entry) {
                    if (entry_mod_idx) |ei| {
                        if (mi == ei) continue;
                    }
                }
                const m = graph.getModule(mod_idx) orelse continue;
                const tla = isTlaEsmModule(m);
                if (m.wrap_kind.isWrapped() and !tla) {
                    try parent.appendModuleCall(&chunk_output, allocator, m, if (linker) |l| &l.rename_table else null);
                }
            }
        }

        // (#4510) **CJS 모듈을 동적 import** 한 청크(`import('./x.cjs')` → dynamic entry 청크).
        // CJS 는 정적 export 가 없어 buildFinalExports 가 null 을 주고, codegen 도 `__commonJS`
        // wrapper 선언만 낸다 → 청크가 (a) 모듈 본문을 **실행조차 안 하고** (b) 아무것도 export
        // 하지 않아, `await import('./x.cjs')` 가 빈 namespace 를 준다.
        // require_X() 호출 자체가 모듈 본문 실행이라 (a)도 함께 해결된다(__commonJS memoize →
        // 다른 청크가 이미 실행했으면 캐시된 exports 재사용, 인스턴스 1개 유지).
        // user entry 청크는 대상 아님 — 그쪽은 bootstrap/`emitCjsEntryExports` 계약이 따로 있다.
        //
        // (#4522) 실어 보내는 값은 **namespace 통째**(`__toESM(require_x())`)여야 한다.
        // 예전엔 `default` 슬롯 하나(`__toESM(require_x()).default`)만 내보냈는데, CJS 의
        // named 멤버는 ESM `export` 문법으로 **정적으로 표현할 수 없어**(CJS 는 정적 export 가
        // 없다) 그대로 유실됐다 → `(await import('./x.cjs')).foo` 가 undefined.
        // 같은-청크 경로는 `import()` **호출 자체**를 `__toESM(require_x())` 표현식으로 치환해
        // namespace 가 통째로 살아남는다 — 그래서 같은 소스가 청킹에 따라 갈렸다.
        // 이제 두 경로가 **같은 값**을 만든다. 소비자는 `.default` 로 벗긴다
        // (`rewriteDynamicImports` 의 cross-chunk 분기 — 그쪽 주석 참조).
        // node/rolldown/rspack 모두 named 멤버를 노출한다(esbuild 만 예외).
        // (#4524) preserve-modules 의 **CJS 모듈 파일**: `require_X` 썽크를 export 한다.
        // CJS 는 정적 export 가 없어 파일 경계를 넘을 수단이 이 썽크뿐이다. 예전엔 아무것도
        // export 하지 않아 소비자가 썽크를 **렉시컬 참조**했고(다른 파일의 지역변수!)
        // `ReferenceError: require_X is not defined` 였다 — 정적 import 조차 못 썼다.
        //
        // interop 은 소비자가 자기 preamble(`var d = require_X()` / `__toESM(require_X())`)로
        // 이미 한다 — 이름만 건너오면 된다. splitting 처럼 provider 가 interop 값을 전역명으로
        // materialize 하는 건 **번들링 기법**이라, "모듈 하나 = 파일 하나, 자기 모양 유지" 인
        // preserve-modules 계약에 맞지 않는다. rolldown 도 썽크를 export 한다.
        //
        // `export default require_X();` 는 방출된 파일을 **단독으로** import 했을 때의 Node
        // CJS↔ESM 계약(default = module.exports)을 맞춘다(rolldown 동일).
        // 소비자(cross_chunk_imports 분기)의 조건과 **정확히 같아야** 한다 — provider 만
        // format 을 보고 있으면 `--format=cjs` 에서 소비자가 `const { require_X } =
        // require("./x.js")` 를 내는데 provider 는 아무것도 안 깔아 undefined 다.
        if (preserveModulesWrapperChunk(chunk, graph, options)) |em_idx| pm_wrap_export: {
            const em = graph.getModule(em_idx) orelse break :pm_wrap_export;
            // (#4528) ⚠️ 래퍼 심볼은 **canonical(미-mangle) 이름**으로 통일한다(rename_table 미사용).
            // `rename_table` 은 **청크별**이라 같은 심볼이 provider emit 시점과 consumer emit
            // 시점에 다른 이름으로 해석됐다 → `import{o}` vs `export{require_a}` 로 어긋나
            // `--minify` 빌드가 통째로 깨졌다. 게다가 청크 **본문**은 canonical 을 그대로 쓴다
            // (래퍼 선언은 emitter 가 직접 찍는다 — codegen 의 rename 대상이 아니다).
            // 그러니 canonical 하나로 맞추면 본문·provider·consumer 3자가 항상 일치한다.
            const names = try wrapperNamesFor(allocator, em, null);
            defer names.deinit(allocator);
            const min = options.minify_whitespace;

            // ⚠️ 래퍼를 **호출**하면 안 된다(`export default require_X();` 금지).
            // 그건 CJS 본문을 provider 파일 **평가 시점**에 실행시킨다:
            //  - CJS↔CJS 순환: `a.cjs` ⇄ `b.cjs` 에서 b.js 가 먼저 평가되며, 아직 미평가인
            //    a.js 의 `require_a`(hoisted `var`, undefined)를 호출 → TypeError.
            //    node 는 require 가 lazy 라 이 순환을 정상 처리한다.
            //  - 조건부 require(`if (x) require('./heavy')`)의 부수효과가 **무조건** 시작 시
            //    실행된다.
            // 래퍼 **선언만** 내보내면 호출 시점이 소비자에게 남아 node 의 lazy 의미가 보존된다.
            // (rolldown 은 `export default require_X();` 를 내지만 같은 순환 위험을 안는다.)
            // (#4528) **user entry** 는 그 파일이 곧 프로그램의 시작점이다 — wrap 된 CJS 는
            // 아무도 `require_X()` 를 부르지 않아 **본문이 아예 실행되지 않았다**(`console.log`
            // 조차 안 찍힘). entry 는 여기서 직접 호출한다. dep 청크는 여전히 lazy 다
            // (eager 호출은 CJS 순환을 죽인다 — 위 주석 참조).
            // ⚠️ preserve-modules 는 **모든 모듈이 자기 entry_point 청크**라 `chunk_is_user_entry`
            // 가 전부 참이다 — 그걸 쓰면 dep 까지 eager 호출해 CJS 순환이 다시 죽는다.
            // 진짜 진입점은 모듈의 `is_entry_point` 플래그다.
            // **user entry** 는 그 파일이 곧 프로그램의 시작점이다 — wrap 된 모듈은 아무도
            // 래퍼를 부르지 않아 **본문이 아예 실행되지 않았다**(`console.log` 조차 안 찍힘).
            // entry 만 여기서 직접 호출한다. dep 은 여전히 lazy 다(eager 호출은 순환을 죽인다).
            //
            // ⚠️ ESM-wrap entry 도 대상이다 — `.cjs` 만 보면 `init_X()` 가 아무 데서도 안 불려
            // 본문이 통째로 미실행이다(같은 결함의 절반만 고친 꼴).
            //
            // ⚠️ **순환에 낀 entry 를 제외하면 안 된다** — entry 가 순환에 끼는 건 흔하고
            // (`main.cjs` ⇄ `b.cjs`), 제외하면 진입점 본문이 아예 안 돈다(조용한 무동작).
            // 단일 entry 순환은 정상 동작한다: 상대(dep)는 eager 호출을 안 하므로 entry 본문이
            // 먼저 돌고 그 안에서 dep 썽크를 부른다 — node 와 같은 순서다.
            // **다중 entry 가 서로 순환**하면(rollup 식 "모든 파일이 entry") ESM 평가 순서상
            // 먼저 평가되는 쪽이 아직 미평가인 상대의 `var require_X`(=undefined)를 불러
            // TypeError 다 — node 는 require 가 dynamic 이라 되지만 ESM 출력으로는 흉내낼 수
            // 없다. 그건 별도 이슈로 남긴다(예전엔 본문이 아예 안 돌아 **조용히** 틀렸다).
            const pm_entry_call = em.is_entry_point and em.wrap_kind.isWrapped() and pm_protocol_owner == null and pm_sync_facade_owner == null;

            if (options.format == .cjs) {
                // Instantiate the exact source init/namespace transport before
                // recursive requires. Only the public facade evaluates it.
                const transport_output = if (pm_sync_facade_owner != null) &pm_definition_code else &chunk_output;
                for ([_]?[]const u8{ names.a, names.b }) |maybe| {
                    const n = maybe orelse continue;
                    try transport_output.appendSlice(allocator, "exports.");
                    try transport_output.appendSlice(allocator, n);
                    try transport_output.appendSlice(allocator, if (min) "=" else " = ");
                    try transport_output.appendSlice(allocator, n);
                    try transport_output.appendSlice(allocator, if (min) ";" else ";\n");
                }
                if (pm_entry_call) {
                    if (em.wrap_kind == .cjs) {
                        // 원본 `.cjs` 진입점과 같은 계약: 본문을 실행하고 그 exports 를 노출.
                        // ⚠️ `module.exports = …` 는 exports **객체를 교체**한다 — 바로 위에서 깐
                        // `exports.require_X` 가 사라져, 이 entry 를 import 하는 다른 파일의
                        // forwarding 썽크가 `undefined.apply` 로 죽는다. 교체 뒤에 **다시 붙인다**.
                        try chunk_output.appendSlice(allocator, if (min) "module.exports=" else "module.exports = ");
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) "();" else "();\n");
                        try chunk_output.appendSlice(allocator, "if(module.exports&&(typeof module.exports==\"object\"||typeof module.exports==\"function\"))module.exports.");
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) "=" else " = ");
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                    } else {
                        // ESM-wrap entry: 본문 실행만(exports 는 exports_X 가 들고 있다).
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) "();" else "();\n");
                    }
                }
            } else {
                try chunk_output.appendSlice(allocator, if (min) "export{" else "export { ");
                try chunk_output.appendSlice(allocator, names.a);
                if (names.b) |b| {
                    try chunk_output.appendSlice(allocator, if (min) "," else ", ");
                    try chunk_output.appendSlice(allocator, b);
                }
                try chunk_output.appendSlice(allocator, if (min) "};" else " };\n");
                if (pm_entry_call) {
                    if (em.wrap_kind == .cjs) {
                        // 본문 실행 + node CJS↔ESM 계약(default = module.exports).
                        try chunk_output.appendSlice(allocator, "export default ");
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) "();" else "();\n");
                    } else {
                        // ESM-wrap entry: 본문 실행만.
                        try chunk_output.appendSlice(allocator, names.a);
                        try chunk_output.appendSlice(allocator, if (min) "();" else "();\n");
                    }
                }
            }
        }

        if (!options.preserve_modules) cjs_dyn_entry: {
            const info = switch (chunk.kind) {
                .entry_point => |i| i,
                .common, .manual => break :cjs_dyn_entry,
            };
            if (!info.is_dynamic) break :cjs_dyn_entry;
            const em = graph.getModule(info.module) orelse break :cjs_dyn_entry;
            if (em.wrap_kind != .cjs) break :cjs_dyn_entry;
            const l = linker orelse break :cjs_dyn_entry;
            // 진짜 `import()` 대상이면 **namespace 통째**(#4522), federation expose /
            // plugin emitFile 이면 기존 계약(`default` = module.exports 값) 그대로.
            const is_ns = dynamicCjsNamespaceEntry(chunk, graph, true, options.preserve_modules) != null;
            const member = if (is_ns) linker_mod.CJS_NS_EXPORT_NAME else "default";
            const expr = try l.cjsInteropAccessExpr(allocator, em, member, options.minify_whitespace);
            defer allocator.free(expr);
            const min = options.minify_whitespace;
            if (options.format == .esm) {
                try chunk_output.appendSlice(allocator, "export default ");
            } else {
                try chunk_output.appendSlice(allocator, if (min) "exports.default=" else "exports.default = ");
            }
            try chunk_output.appendSlice(allocator, expr);
            try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
        }

        // 크로스 청크 export: exports_to에 심볼이 있으면 export 문 생성.
        // 다른 청크가 이 청크에서 심볼을 가져가는 경우에만 출력.
        // preserve-modules에서는 모듈 자체의 export가 유지되므로 cross-chunk export 불필요.
        // linker가 심볼을 rename한 경우 export { local_name as export_name } 형태로 출력.
        // PR-3b-ii: lazy reg(IIFE/CJS) entry 청크는 소비자(동적 청크)가 시작 시 미파싱이라
        // exports_to 가 비어도 export-all 해야 하므로 별도로 진입한다.
        const lazy_reg_entry = graph.lazy_compilation and entry_mod_idx != null and (options.format == .cjs or reg_split);
        // Wrapped PM modules publish their complete public surface through
        // final_export_entries. Cross-chunk aliases may still require additional
        // export keys; remove only keys that the public writer already owns.
        const pm_wrapped_esm_provider = options.preserve_modules and blk: {
            const mi = preserveModulesWrapperChunk(chunk, graph, options) orelse break :blk false;
            const em = graph.getModule(mi) orelse break :blk false;
            break :blk em.wrap_kind == .esm;
        };
        if ((chunk.exports_to.count() > 0 or rbm_export_names.items.len > 0 or lazy_reg_entry) and
            (!options.preserve_modules or pm_wrapped_esm_provider))
        xchunk_exports: {
            // 결정론적 출력을 위해 이름을 정렬
            var export_names: std.ArrayList([]const u8) = .empty;
            defer export_names.deinit(allocator);
            var eit = chunk.exports_to.iterator();
            while (eit.next()) |entry| {
                try appendUniqueName(&export_names, allocator, entry.key_ptr.*);
            }
            for (rbm_export_names.items) |name| {
                try appendUniqueName(&export_names, allocator, name);
            }
            std.mem.sort([]const u8, export_names.items, {}, types.stringLessThan);

            // cjs(P3-A pm / P3-B splitting): 청크가 .js 로 require 되므로
            // ESM `export {}` 를 emit 하면 Node 가 CJS 로 로드 → SyntaxError.
            //  - common/manual 청크(entry 모듈 없음): emitCjsEntryExports 가
            //    안 도므로 cross-chunk 노출 수단이 이 경로뿐 → `exports.x=local;`.
            //  - entry/dynamic 청크(entry_mod_idx != null): entry 모듈 exports
            //    를 emitCjsEntryExports 가 이미 `exports.x`(default/__esModule
            //    interop 포함)로 깔며, cross-chunk 소비자도 그 동일 객체를
            //    require 로 읽음 → 여기서 또 emit 하면 이중정의·module.exports=
            //    재대입 손상·re-export local 미바인딩(ReferenceError). 따라서
            //    **emit 생략**(emitCjsEntryExports 에 일임)이 정확.
            //  - IIFE(reg_split): factory 가 `exports`/`module`/`require`
            //    파라미터를 주므로 CJS 와 동일 모델. entry/dynamic 청크는
            //    emitCjsEntryExports(emitter 가 iife_split_factory 시 CJS 경로로
            //    라우팅 — Edit 9)가 factory-bound exports 를 깔고, common/manual
            //    은 이 경로가 cross-chunk `exports.x=local;`. → cjs 와 동일하게
            //    entry 청크는 break(이중정의·module.exports= 손상 방지).
            const reg_fmt = options.format == .cjs or reg_split;
            // (#4528) ⚠️ preserve-modules 의 **wrap 된 ESM provider** 는 예외다.
            // 이 break 의 전제("entry 모듈 export 는 emitCjsEntryExports 가 이미 깐다")가
            // 거짓이다 — wrap 된 모듈은 export 가 `__export(exports_X, …)` 로 들어가고
            // emitCjsEntryExports 를 타지 않는다. break 하면 `exports.tag` 가 어디서도 안 나와
            // 소비자가 `TypeError: tag is not a function`.
            if (reg_fmt and entry_mod_idx != null and !pm_wrapped_esm_provider) {
                // PR-3b-ii: lazy 면 entry 청크가 hoisted 모듈 export 를 local name 으로 전부
                // 노출(export-all) — on-demand 동적 청크가 시작 시 미파싱 seed 라 어떤 export 를
                // 참조할지 몰라도 찾게 + demand-driven 이 아니라 결정론(seed force-parse 무관).
                // 그 외(eager)는 기존대로 break(emitCjsEntryExports 에 일임).
                if (graph.lazy_compilation) {
                    try emitLazyEntryExportAll(allocator, &chunk_output, graph, linker, sorted_mods, entry_mod_idx.?, module_count, options.minify_whitespace);
                    // dev_split(wrap-all) 동적 청크: entry 모듈이 __esm 래핑이라 emitCjsEntryExports
                    // 를 안 타 entry export 가 청크 exports 에 없다 → `import('./route')` 가 받는
                    // `__zntc_require` 결과에 entry export(render) 누락(#4079 e2e 회귀). entry 만
                    // exported_name 키로 추가. user-entry 는 bootstrap(__zntc_require 결과 미소비)라 제외.
                    if (dev_split_chunk and !chunk_is_user_entry) {
                        try emitWrappedDynamicEntryExports(allocator, &chunk_output, graph, linker, entry_mod_idx.?, options.minify_whitespace);
                    }
                }
                break :xchunk_exports;
            }
            const cjs_x = reg_fmt;

            // 버그 B (#3321 후속): ESM entry/dynamic 청크는 codegen 이 entry
            // 모듈의 소스 `export { ... }`(=그 모듈이 노출하는 모든 export 이름,
            // re-export 포함 — cross-chunk 바인딩으로 로컬화됨)를 //#region 안에
            // 이미 emit 한다. 이 xchunk 블록이 그중 한 이름이라도 또 내면
            // `Duplicate export` SyntaxError (cjs/iife 는 위 break 로 회피, ESM
            // 은 게이트 없음). → ESM 일 때 entry 모듈이 export 하는 이름(kind
            // 무관: .local·.re_export 모두 codegen 이 냄)을 xchunk 에서 제거.
            // entry 모듈 export 가 아닌 cross-chunk 심볼(예: 호이스팅된 다른
            // 모듈 심볼)만 남겨 합집합을 정확히 1회 emit. 전부 제거 시 블록 생략.
            // cross-chunk 소비자는 codegen 이 낸 동일 `export {}` 로 바인딩.
            if (!cjs_x or pm_wrapped_esm_provider) {
                if (entry_mod_idx) |ei| {
                    if (graph.getModule(ModuleIndex.fromUsize(@intCast(ei)))) |em| if (!em.wrap_kind.isWrapped() or (options.preserve_modules and em.wrap_kind == .esm)) {
                        var public_owned: std.ArrayListUnmanaged([]const u8) = .empty;
                        defer {
                            if (linker) |l| {
                                for (public_owned.items) |text| l.allocator.free(text);
                                public_owned.deinit(l.allocator);
                            }
                        }
                        const public_entries = if (options.preserve_modules and em.wrap_kind == .esm)
                            if (linker) |l| try l.buildFinalExports(true, @intCast(ei), em.export_bindings, &public_owned) else null
                        else
                            null;
                        defer if (public_entries) |entries| if (linker) |l| l.allocator.free(entries);
                        // The module public writer and this cross-chunk
                        // exclusion must agree on the exact final-entry role.
                        const owns_public = !cjs_x or if (public_entries) |entries|
                            try @import("entry_exports.zig").needsCjsEntryDescriptors(allocator, entries, options.output_exports)
                        else
                            false;
                        if (owns_public) {
                            var key_arena = std.heap.ArenaAllocator.init(allocator);
                            defer key_arena.deinit();
                            var public_keys: std.StringHashMapUnmanaged(void) = .empty;
                            defer public_keys.deinit(allocator);
                            for (em.export_bindings) |binding| {
                                const key = try @import("../public_export_key.zig").fromSyntax(key_arena.allocator(), binding.exported_name);
                                try public_keys.put(allocator, key.text, {});
                            }
                            if (public_entries) |entries| for (entries) |entry| {
                                const key = try @import("../public_export_key.zig").fromSyntax(key_arena.allocator(), entry.exported);
                                try public_keys.put(allocator, key.text, {});
                            };
                            var w: usize = 0;
                            for (export_names.items) |nm| {
                                const emitted_key = if (pm_wrapped_esm_provider)
                                    if (linker) |l| l.getCrossChunkGlobalName(@intCast(ei), nm) orelse nm else nm
                                else
                                    nm;
                                const key = try @import("../public_export_key.zig").fromSyntax(allocator, emitted_key);
                                defer key.deinit(allocator);
                                if (!public_keys.contains(key.text)) {
                                    export_names.items[w] = nm;
                                    w += 1;
                                }
                            }
                            export_names.shrinkRetainingCapacity(w);
                        }
                    };
                }
                if (export_names.items.len == 0) break :xchunk_exports;
            }

            // A CJS member edge names a runtime property. Materialize each
            // requested owner/property before publishing its chunk export.
            var cjs_interop_globals: std.StringHashMapUnmanaged(void) = .empty;
            defer cjs_interop_globals.deinit(allocator);
            if (linker) |l| {
                for (export_names.items) |name| {
                    for (provider_edges) |edge| {
                        if (!std.mem.eql(u8, edge.name, name)) continue;
                        const provider = try checkedChunkProvider(l, chunk, edge);
                        if (provider.role != .cjs_member) continue;
                        const global = try crossChunkPublicName(l, edge, options.preserve_modules);
                        if (cjs_interop_globals.contains(global)) continue;
                        try writeCjsInteropMaterialize(allocator, &chunk_output, l, provider.owner, name, global, options.minify_whitespace);
                        try cjs_interop_globals.put(allocator, global, {});
                    }
                }
            }

            if (!cjs_x) {
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "export { ");
                } else {
                    try chunk_output.appendSlice(allocator, "export{");
                }
            }
            for (export_names.items, 0..) |name, ni| {
                var emitted_any = false;
                if (linker) |l| {
                    var first_in_group = true;
                    for (provider_edges) |edge| {
                        if (!std.mem.eql(u8, edge.name, name)) continue;
                        const provider = try checkedChunkProvider(l, chunk, edge);
                        const global = try crossChunkPublicName(l, edge, options.preserve_modules);
                        const local = if (provider.role == .cjs_member)
                            if (cjs_interop_globals.contains(global)) global else return error.MissingCrossChunkMaterialization
                        else
                            (try provider.localName(l)) orelse return error.InvalidCrossChunkExport;
                        if (cjs_x) {
                            try appendCjsExportBinding(allocator, &chunk_output, global, null, local, pm_wrapped_esm_provider, options.minify_whitespace);
                            if (split_needs_readiness) try split_bridge_entries.append(allocator, .{ .local = local, .exported = global });
                        } else {
                            if (!first_in_group) try chunk_output.appendSlice(allocator, if (options.minify_whitespace) "," else ", ");
                            try chunk_output.appendSlice(allocator, local);
                            if (!std.mem.eql(u8, local, global)) {
                                try chunk_output.appendSlice(allocator, " as ");
                                try chunk_output.appendSlice(allocator, global);
                            }
                        }
                        first_in_group = false;
                        emitted_any = true;
                    }
                }
                if (!emitted_any) {
                    const local_name = if (linker) |l| blk: {
                        // Run-before-main exports are exact registered wrapper
                        // identities. They have no ordinary value-export carrier.
                        const known = rbm_export_bindings.get(name) orelse return error.MissingCrossChunkProvider;
                        if (l.getModule(known.owner.index.toU32()) != known.owner or known.symbol.module != known.owner.index) return error.InvalidCrossChunkExport;
                        const actual = switch (known.owner.wrap_kind) {
                            .cjs => if (known.owner.require_symbol == known.symbol.inner) known.owner.getRequireName(&l.rename_table) else null,
                            .esm => try known.owner.esmWrapperName(known.symbol, &l.rename_table),
                            .none => null,
                        } orelse return error.MissingWrapperSymbol;
                        if (!std.mem.eql(u8, actual, name)) return error.InvalidCrossChunkExport;
                        break :blk actual;
                    } else name; // Explicit graphless emitter API.
                    if (cjs_x) {
                        try appendCjsExportBinding(allocator, &chunk_output, name, null, local_name, pm_wrapped_esm_provider, options.minify_whitespace);
                    } else {
                        try chunk_output.appendSlice(allocator, local_name);
                        if (!std.mem.eql(u8, local_name, name)) {
                            try chunk_output.appendSlice(allocator, " as ");
                            try chunk_output.appendSlice(allocator, name);
                        }
                    }
                }
                // esm: 다음 export 명으로 trailing comma(cjs 는 statement 라 불필요).
                if (!cjs_x and ni + 1 < export_names.items.len) {
                    try chunk_output.appendSlice(allocator, if (options.minify_whitespace) "," else ", ");
                }
            }
            if (!cjs_x) {
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, " };\n");
                } else {
                    try chunk_output.appendSlice(allocator, "};");
                }
            }
        }

        if (!options.preserve_modules and (!reg_split or split_needs_readiness) and chunk.esm_wrapper_cross_exports.count() > 0) {
            var initializers: std.ArrayListUnmanaged(SymbolID) = .empty;
            defer initializers.deinit(allocator);
            var init_iterator = chunk.esm_wrapper_cross_exports.keyIterator();
            while (init_iterator.next()) |init| try initializers.append(allocator, init.*);
            std.mem.sort(SymbolID, initializers.items, {}, esmInitLessThan);
            for (initializers.items) |init| {
                const local = try esmWrapperNameFor(allocator, graph, init, linker);
                try alias_strs.append(allocator, local);
                const public = try esmWrapperNameFor(allocator, graph, init, null);
                try alias_strs.append(allocator, public);
                if (split_needs_readiness) try split_bridge_entries.append(allocator, .{ .local = local, .exported = public });
                if (initialized_namespaces.contains(init)) continue;
                if (options.format == .cjs or reg_split) {
                    try chunk_output.print(allocator, "exports.{s}={s};\n", .{ public, local });
                } else if (std.mem.eql(u8, local, public)) {
                    try chunk_output.print(allocator, "export {{ {s} }};\n", .{local});
                } else {
                    try chunk_output.print(allocator, "export {{ {s} as {s} }};\n", .{ local, public });
                }
            }
        }

        // (#4541) 다른 청크가 raw-require 한 이 청크의 CJS 썽크(require_X)를 export 한다.
        // esm: `export { require_X };` / cjs: `exports.require_X = require_X;`. require_X 는 이 청크
        // 본문에 `var require_X = __commonJS(...)` 로 이미 선언(모듈 region) → 여기선 참조만.
        // canonical 이름(reserveWrapperNames 전역 유일)이라 소비자 import·본문 `require_X()` 와 일치.
        // ⚠️ esm/cjs 만(reg_split 은 registry 모델, 후속). preserve-modules 는 #4524 담당 → 제외.
        if (!reg_split and !options.preserve_modules and chunk.wrapper_cross_exports.count() > 0) {
            const min = options.minify_whitespace;
            const cjs_out = options.format == .cjs;
            var wids: std.ArrayListUnmanaged(u32) = .empty;
            defer wids.deinit(allocator);
            var wit = chunk.wrapper_cross_exports.keyIterator();
            while (wit.next()) |k| try wids.append(allocator, k.*);
            std.mem.sort(u32, wids.items, {}, comptime std.sort.asc(u32));
            for (wids.items) |wm| {
                const tmod = graph.getModule(@fromBackingInt(@intCast(wm))) orelse continue;
                // ⚠️ 공개명(canonical, 소비자 import 키)과 provider 청크의 **실제 로컬명**을 분리한다.
                // --minify 는 provider 본문의 `var require_X = __commonJS(...)` 선언을 mangle(`r`)하는데
                // (rename_table 은 청크별), 소비자는 canonical `require_X` 로 import·호출한다. 따라서
                // provider 는 `export { <로컬 r> as require_X }`(esm) / `exports.require_X = r`(cjs)로
                // 로컬→공개 aliasing 해야 3자(export·import·본문)가 일치한다.
                const wn_local = try wrapperNamesFor(allocator, tmod, linker);
                defer wn_local.deinit(allocator);
                const wn_pub = try wrapperNamesFor(allocator, tmod, null);
                defer wn_pub.deinit(allocator);
                const same = std.mem.eql(u8, wn_local.a, wn_pub.a);
                if (cjs_out) {
                    try chunk_output.appendSlice(allocator, "exports.");
                    try chunk_output.appendSlice(allocator, wn_pub.a);
                    try chunk_output.appendSlice(allocator, if (min) "=" else " = ");
                    try chunk_output.appendSlice(allocator, wn_local.a);
                    try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                } else {
                    try chunk_output.appendSlice(allocator, if (min) "export{" else "export { ");
                    try chunk_output.appendSlice(allocator, wn_local.a);
                    if (!same) {
                        try chunk_output.appendSlice(allocator, " as ");
                        try chunk_output.appendSlice(allocator, wn_pub.a);
                    }
                    try chunk_output.appendSlice(allocator, if (min) "};" else " };\n");
                }
            }
        }

        if (split_needs_readiness) {
            const l = linker orelse return error.MissingTlaReadinessHelper;
            const helper = try readinessHelperExpression(allocator, graph, chunk_graph, chunk, options, l, reg_ids);
            defer allocator.free(helper);
            var waits: std.ArrayList(u8) = .empty;
            defer waits.deinit(allocator);
            try waits.appendSlice(allocator, helper);
            try waits.appendSlice(allocator, "([");
            const module_contexts = split_emit_options.deferred_module_exports orelse return error.MissingAsyncEntryExportContext;
            // Instantiate all exact module namespaces before evaluation. This
            // makes a recursive edge refer to an owned state, never a guessed
            // Promise/public property on a user object.
            for (sorted_mods) |mod_idx| {
                const context = &module_contexts[mod_idx.toU32()];
                if (!context.internal_module) continue;
                const namespace = context.namespace_name orelse return error.MissingAsyncEntryExportValue;
                try chunk_output.print(allocator, "{s}.register({s},{s});\n", .{ helper, namespace, namespace });
            }
            for (sorted_mods) |mod_idx| {
                const context = &module_contexts[mod_idx.toU32()];
                if (!context.internal_module) continue;
                const provider = graph.getModule(mod_idx) orelse return error.InvalidTlaReadinessOwner;
                const namespace = context.namespace_name orelse return error.MissingAsyncEntryExportValue;
                const initialize = context.init_name orelse return error.MissingAsyncEntryExportValue;
                try chunk_output.print(allocator, "{s}.publish({s},null,{s},[", .{ helper, namespace, initialize });
                var dependency_count: usize = 0;
                var seen_dependencies: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer seen_dependencies.deinit(allocator);
                for (provider.import_records) |record| {
                    if (record.resolved.isNone() or record.kind == .dynamic_import) continue;
                    const dependency_index = record.resolved.toU32();
                    if (dependency_index >= module_contexts.len) return error.InvalidTlaReadinessOwner;
                    const dependency = &module_contexts[dependency_index];
                    if (!dependency.internal_module or std.mem.indexOfScalar(ModuleIndex, chunk.modules.items, record.resolved) == null) continue;
                    const inserted = try seen_dependencies.getOrPut(allocator, dependency_index);
                    if (inserted.found_existing) continue;
                    if (dependency_count != 0) try chunk_output.append(allocator, ',');
                    const dependency_namespace = dependency.namespace_name orelse return error.MissingAsyncEntryExportValue;
                    try chunk_output.print(allocator, "{s}.state({s})", .{ helper, dependency_namespace });
                    dependency_count += 1;
                }
                // Internal readiness resolves void. Returning its namespace here
                // would assimilate a callable public `then` too early.
                try chunk_output.appendSlice(allocator, "],function(){},false);\n");
            }
            var wait_count: usize = 0;
            for (sorted_mods) |mod_idx| {
                const context = &module_contexts[mod_idx.toU32()];
                if (!context.internal_module) continue;
                if (wait_count != 0) try waits.appendSlice(allocator, ",");
                const namespace = context.namespace_name orelse return error.MissingAsyncEntryExportValue;
                try waits.print(allocator, "{s}.state({s}).ready", .{ helper, namespace });
                wait_count += 1;
            }
            try waits.appendSlice(allocator, "])");
            const public_context: ?*parent.DeferredAsyncEntryExports = if (entry_mod_idx) |index|
                if (module_contexts[index].internal_module) &module_contexts[index] else &split_deferred_exports
            else
                null;
            const needs_ready_marker = if (public_context != null and public_context.?.value != null)
                public_context.?.needs_ready_marker
            else
                try @import("entry_exports.zig").readyNamespaceNeedsMarker(allocator, split_bridge_entries.items, true, .named);
            if (needs_ready_marker and !chunk_interop_emitted) {
                const provider = graph.interop_ast_provider orelse return error.MissingAsyncEntryMarkerIdentity;
                if (!provider.active) return error.InteropAstProviderNotActivated;
                // This provider is emitted into each consuming chunk, not imported
                // from an unrelated output chunk. Its exact selected SID names are
                // the same names used by the finalized ready-value renderer.
                _ = try l.esmInteropRuntimeHelperName(.def_prop);
                try @import("../runtime_interop_ast.zig").emit(&chunk_output, allocator, graph, l, options);
                chunk_interop_emitted = true;
            }
            // Preserve the actual host export carrier in the existing private
            // protocol. Public default/namespace values never acquire transport
            // keys, while wrapper consumers retain their exact original carrier.
            try chunk_output.print(allocator, "{s}.register(exports,exports);\n", .{helper});
            if (split_async_import_depth != 0) try chunk_output.appendSlice(allocator, "return ");
            try chunk_output.print(allocator, "{s}.publish(exports,module,function(){{return ", .{helper});
            try chunk_output.appendSlice(allocator, waits.items);
            try chunk_output.appendSlice(allocator, ";},[],function() {\n");
            if (if (public_context) |context| context.value else null) |value| {
                try chunk_output.appendSlice(allocator, value);
            } else {
                const value = try @import("entry_exports.zig").emitReadyEntryExports(allocator, split_bridge_entries.items, null, true, .named, false, try parent.readyEntryMarkerName(allocator, split_bridge_entries.items, true, .named, l));
                defer allocator.free(value);
                try chunk_output.appendSlice(allocator, value);
            }
            try chunk_output.print(allocator, "}},{s});\n", .{if (split_assign_host) "true" else "false"});
            for (0..split_async_import_depth) |_| try chunk_output.appendSlice(allocator, "});\n");
        }

        // Wrapped entry 모듈은 factory body 안에서 명시적으로 호출해야 본문이 실행된다.
        // scope-hoist(.none) entry 는 인라인 실행되지만, require.context/CJS-interop 등으로
        // wrap 된 entry 는 `var require_X=__commonJS(...)`/`var init_X=__esm(...)` 정의만 되고
        // 호출 안 돼 본문 미실행이었다(issue #4039 / verifier BUG2). bootstrap 의
        // `__zntc_require("entry-chunk")` 는 factory 를 1회 실행하므로 여기서 wrapped entry
        // init 을 호출하면 정확히 1회 실행(__commonJS/__esm 가 memoize).
        if (reg_split and chunk_is_user_entry and !split_needs_readiness) {
            if (entry_mod_idx) |ei| {
                if (graph.getModule(@fromBackingInt(@intCast(ei)))) |em| {
                    // TLA(.esm + top-level await) entry 는 appendModuleCall 이 `await init_X()`
                    // 를 내는데, reg_split 청크 factory 는 비-async `function(...)` 이라 top-level
                    // await = SyntaxError. TLA+reg_split entry 는 이 PR 이전에도 미실행이었으므로
                    // 여기서 제외(회귀 없음 — 무효 JS 생성 방지). 비-TLA wrapped entry 만 호출.
                    const tla_entry = isTlaEsmModule(em);
                    if (em.wrap_kind.isWrapped() and !tla_entry) {
                        try parent.appendModuleCall(&chunk_output, allocator, em, if (linker) |l| &l.rename_table else null);
                    }
                }
            }
        }

        // IIFE splitting: self-register factory 닫기 + (entry) bootstrap.
        // prefix `(function(g){<INSTALL>({"id":function(exports,module,require){`
        // 의 짝: factory fn `}` + 객체 `}` + register 호출 `)` + `;` + wrapper
        // fn `}` + wrapper 호출 `)` + GLOBAL + `;`.
        if (reg_split) {
            const min = options.minify_whitespace;
            // reg_split outro: factory IIFE 안 마지막 — register install 호출 후, IIFE close 전.
            // "}});" = fn close + 객체 close + register call close, 그 다음 outro, 마지막 ")" = IIFE close.
            try chunk_output.appendSlice(allocator, if (min) "}});" else "\n}});");
            if (options.outro_js) |outro| {
                try chunk_output.append(allocator, '\n');
                try chunk_output.appendSlice(allocator, outro);
                try chunk_output.append(allocator, '\n');
            }
            try chunk_output.appendSlice(allocator, "})");
            try chunk_output.appendSlice(allocator, rt.ZNTC_IIFE_GLOBAL);
            try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
            if (chunk_is_user_entry) {
                // entry 모듈은 정적 dep 들 뒤에 평가 → bootstrap 으로 실행 개시.
                // ⚠ federation_emit.bootstrapSpan(P1-3)이 아래 두 형태(`return
                // globalThis.__zntc_require("` / `[var <gn> [ ]=[ ]]globalThis.
                // __zntc_require("`)에 강결합 — 변경 시 동반 수정 필요.
                const umd_amd = options.format == .umd or options.format == .amd;
                if (umd_amd) {
                    // UMD/AMD: factory() 반환값 = entry exports. 보편 wrapper 가
                    // module.exports/define/root.X 로 노출(global_name 도 wrapper
                    // 가 처리 — 별도 var 금지). `return` 은 Edit 3 의 prologue
                    // 함수 안이라 합법.
                    try chunk_output.appendSlice(allocator, "return globalThis.__zntc_require(\"");
                } else {
                    // iife: global_name 지정 시 결과를 전역 var 로 노출(기존).
                    if (options.global_name) |gn| {
                        try chunk_output.appendSlice(allocator, "var ");
                        try chunk_output.appendSlice(allocator, gn);
                        try chunk_output.appendSlice(allocator, if (min) "=" else " = ");
                    }
                    try chunk_output.appendSlice(allocator, "globalThis.__zntc_require(\"");
                }
                try chunk_output.appendSlice(allocator, reg_ids[ci]);
                try chunk_output.appendSlice(allocator, if (min) "\");" else "\");\n");
            }
        }

        // (#4537) 표준 splitting(비-reg_split·비-preserve-modules)의 wrapped **user entry**
        // 는 본문을 실행할 호출이 없다. 단일번들은 맨 끝에서 require_X()/init_X() 로 entry 를
        // 실행하는데(emitter.zig:1093, appendGuardedModuleCall), splitting 은 그 호출이 세
        // 경로의 게이트에 전부 걸려 어디서도 안 나온다: dev_split_chunk(reg_split 한정, 게다가
        // entry 자신은 skip)·preserveModulesWrapperChunk(preserve-modules 한정)·reg_split(1559,
        // iife/umd/amd 의 bootstrap). 그래서 `var require_X=__commonJS(...)` 선언만 남고 호출이
        // 없어 entry 본문이 통째로 미실행이었다(#4537). 단일번들과 대칭으로 여기서 호출한다.
        // reg_split=1559, preserve-modules=pm_entry_call 이 각자 담당하므로 제외(이중호출 방지).
        // (__commonJS/__esm memoize 라 설령 중복돼도 본문은 1회지만, 이중 호출문 자체를 막는다.)
        //
        // 게이트는 `chunk_is_user_entry`(비-dynamic `.entry_point`). (#4553) user entry 는 항상 자기
        // entry_point 청크에 있다(manualChunks 로도 relocate 안 됨 — chunk.zig 가 manual 청크에서 user
        // entry 제외) → `.manual`/`.common` 은 user entry 를 담지 않으므로 여기서 볼 필요가 없다.
        // 청크 내 `is_entry_point` 모듈을 스캔해 호출한다 — user entry 이면서 동시에 plugin `emitFile`
        // 된 both-case(같은 non-dynamic entry_point 청크에 공존)도 정확히 1회 호출. dynamic-import
        // 대상은 `is_entry_point=false`(build_flow)라 자동 제외. reg_split(bootstrap)·preserve-modules
        // (pm_entry_call)는 각자 담당하므로 게이트 제외.
        if (!reg_split and !options.preserve_modules and chunk_is_user_entry and !split_needs_readiness) {
            for (sorted_mods) |mod_idx| {
                const em = graph.getModule(mod_idx) orelse continue;
                if (!em.is_entry_point) continue; // user/emitted entry (dynamic-import 대상은 false)
                // CJS-format 청크의 TLA(.esm+top-level await) entry 는 top-level await 가 불가하므로
                // 제외(reg_split TLA 제외와 동일 근거). ESM-format 은 합법이라 appendModuleCall 이
                // `await init_X()` 로 처리한다.
                const tla_cjs = options.format == .cjs and isTlaEsmModule(em);
                if (em.wrap_kind.isWrapped() and !tla_cjs) {
                    // 단일번들과 동일하게 `appendGuardedModuleCall` — entry_error_guard(RN/Metro)
                    // 활성 시 `__zntc_guarded(require_X)` 로 wrap, 아니면 appendModuleCall 과 동등.
                    if (@import("../runtime_entry_guard_calls.zig").find(graph, em.index)) |invocation| {
                        try @import("../runtime_entry_guard_calls.zig").validatePlacement(graph, chunk_graph, invocation);
                        try @import("../runtime_entry_guard_calls.zig").validate(graph, invocation);
                        const artifact = graph.getModule(invocation.module_index) orelse return error.InvalidGuardInvocation;
                        const code = try parent.emitModule(allocator, artifact, options, linker, false, null, null, null, null, null, null, null, null, null) orelse return error.InvalidGuardInvocation;
                        defer allocator.free(code);
                        try chunk_output.appendSlice(allocator, code);
                    } else try parent.appendGuardedModuleCall(&chunk_output, allocator, em, options, if (linker) |l| &l.rename_table else null);
                }
            }
        }

        if (pm_sync_facade_owner != null)
            try chunk_output.insertSlice(allocator, pm_definition_pos, pm_definition_code.items);
        if (pm_protocol_owner != null) {
            const helper_expr = pm_readiness orelse return error.MissingTlaReadinessHelper;
            const namespace = pm_deferred_exports.namespace_name orelse return error.MissingAsyncEntryExportValue;
            const init_name = pm_deferred_exports.init_name orelse return error.MissingAsyncEntryExportValue;
            const value = pm_deferred_exports.value orelse return error.MissingAsyncEntryExportValue;
            try pm_definition_code.print(allocator, "{s}.register(exports,{s});\n", .{ helper_expr, namespace });
            try chunk_output.insertSlice(allocator, pm_definition_pos, pm_definition_code.items);
            try chunk_output.print(allocator, "{s}.publish(exports,module,{s},[", .{ helper_expr, init_name });
            for (pm_dependency_states.items, 0..) |state, index| {
                if (index != 0) try chunk_output.append(allocator, ',');
                try chunk_output.appendSlice(allocator, state);
            }
            try chunk_output.appendSlice(allocator, "],function(){\n");
            try chunk_output.appendSlice(allocator, value);
            try chunk_output.print(allocator, "}},{s});\n", .{if (options.output_exports == .none) "false" else "true"});
        } else if (pm_async_import_depth > 0) {
            const value = pm_deferred_exports.value orelse return error.MissingAsyncEntryExportValue;
            try chunk_output.appendSlice(allocator, value);
            for (0..pm_async_import_depth) |_| try chunk_output.appendSlice(allocator, "});\n");
        }

        // UMD/AMD(PR4): entry 청크 보편 wrapper 닫기(Edit 3 prologue 의 짝).
        // 비-entry/iife 는 prologue 없으므로 epilogue 도 없음(불균형 금지).
        if (reg_split and chunk_is_user_entry and
            (options.format == .umd or options.format == .amd))
            try format_wrapper.emitFormatEpilogue(&chunk_output, allocator, options.format, &.{});

        // Plugin: renderChunk 훅 — 청크 완성 후, footer 전.
        // chunk_name 은 *실제 filename 의 stem* 과 동기 — preserve_modules /
        // explicit_file_name 시 filename 과 drift 되면 plugin (visualizer 등) 이
        // chunk_name 으로 path 복원 시 mismatch.
        if (options.plugins.len > 0) {
            const runner = plugin_mod.PluginRunner.init(options.plugins);
            var rc_stem_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer rc_stem_buf.deinit(allocator);
            const rc_chunk_name: []const u8 = blk: {
                if (chunk.explicit_file_name) |efn| {
                    // explicit fileName 의 stem (실제 ext 제외). efn 의 ext 가
                    // options.out_extension_js 와 다를 수 있으므로
                    // `std.fs.path.extension` 으로 실제 ext 추출.
                    const efn_ext = std.fs.path.extension(efn);
                    const stem_part = efn[0 .. efn.len - efn_ext.len];
                    try rc_stem_buf.appendSlice(allocator, stem_part);
                    break :blk rc_stem_buf.items;
                }
                if (options.preserve_modules and chunk.rel_dir != null) {
                    // preserve-modules: computePreserveModulesPath 결과의 stem.
                    const pm_path = try computePreserveModulesPath(allocator, chunk.rel_dir.?, ext, options.preserve_modules_root);
                    defer allocator.free(pm_path);
                    const pm_ext = std.fs.path.extension(pm_path);
                    const stem_part = pm_path[0 .. pm_path.len - pm_ext.len];
                    try rc_stem_buf.appendSlice(allocator, stem_part);
                    break :blk rc_stem_buf.items;
                }
                try chunkPlaceholderStem(chunk, &rc_stem_buf, allocator, options);
                break :blk rc_stem_buf.items;
            };
            var hook_ctx: plugin_mod.HookContext = .{};
            defer hook_ctx.deinit();
            const chunk_rc_result = runner.runRenderChunk(chunk_output.items, rc_chunk_name, allocator, &hook_ctx) catch |err| switch (err) {
                error.PluginFailed => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (chunk_rc_result) |result| {
                chunk_output.clearRetainingCapacity();
                try chunk_output.appendSlice(allocator, result);
                allocator.free(result);
            }
        }

        // outro: reg_split 면 위 factory IIFE 안에서 이미 emit — 여기선 skip.
        if (!reg_split) {
            if (options.outro_js) |outro| {
                try chunk_output.appendSlice(allocator, outro);
                try chunk_output.append(allocator, '\n');
            }
        }

        // footer 삽입 (각 청크 출력 뒤)
        if (options.footer_js) |footer| {
            try chunk_output.appendSlice(allocator, footer);
            try chunk_output.append(allocator, '\n');
        }

        // 출력 파일명 생성
        const filename = if (chunk.explicit_file_name) |efn|
            // plugin emitFile fileName (#1880 PR7-2d): verbatim — 패턴/hash placeholder/ext 우회.
            // efn 은 확장자를 포함한 최종 경로(Rollup 동형). content-hash 치환 대상 placeholder 가
            // 없으므로 resolveContentHashes 의 path 치환은 no-op.
            try allocator.dupe(u8, efn)
        else if (options.preserve_modules and chunk.rel_dir != null)
            // preserve-modules: 원본 경로에서 root를 제거한 상대 경로 사용
            try computePreserveModulesPath(allocator, chunk.rel_dir.?, ext, options.preserve_modules_root)
        else blk: {
            // 일반 code splitting: "{stem}{ext}" (placeholder hash 포함, 나중에 치환)
            var stem_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer stem_buf.deinit(allocator);
            try chunkPlaceholderStem(chunk, &stem_buf, allocator, options);
            break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem_buf.items, ext });
        };
        errdefer allocator.free(filename);

        if (hoisted_directives.items.len > 0) {
            try chunk_output.insertSlice(allocator, directive_start, hoisted_directives.items);
        }

        // rolldown `chunk.moduleIds` 호환 — 이 chunk 에 포함된 모듈 경로 목록.
        // exec_index 순으로 정렬된 sorted_mods 에서 JS 모듈만 수집 (asset/CSS 제외).
        const module_ids = blk: {
            var ids: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (ids.items) |p| allocator.free(p);
                ids.deinit(allocator);
            }
            for (sorted_mods) |mod_idx| {
                const m = graph.getModule(mod_idx) orelse continue;
                try ids.append(allocator, try allocator.dupe(u8, m.path));
            }
            break :blk try ids.toOwnedSlice(allocator);
        };
        // 이 chunk 가 export 하는 심볼 이름 목록 — 이미 chunk.exports_to 로 수집됨.
        const export_names = blk: {
            var names: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (names.items) |n| allocator.free(n);
                names.deinit(allocator);
            }
            var eit = chunk.exports_to.iterator();
            while (eit.next()) |entry| {
                try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
            if (!options.preserve_modules) {
                for (rbm_export_names.items) |name| {
                    if (containsName(names.items, name)) continue;
                    try names.append(allocator, try allocator.dupe(u8, name));
                }
            }
            // hashmap 순회는 비결정 — 출력 결정성 위해 사전순 정렬 (line 654 와 일관).
            std.mem.sort([]const u8, names.items, {}, types.stringLessThan);
            break :blk try names.toOwnedSlice(allocator);
        };

        // sourcemap builder 를 heap 으로 보관. JSON generate 와 mode 분기
        // (eager / lazy / inline_) 는 모두 finalizeChunkSourceMaps 가 hash 치환
        // 후 단일 처리 — sourcemap "file" 필드가 placeholder 없이 정확 (#2661).
        var chunk_sourcemap_builder: ?*SourceMap.SourceMapBuilder = null;
        if (chunk_sm) |*sm| {
            chunk_sourcemap_builder = try sm.moveToHeap(allocator);
            chunk_sm_moved = true;
        }
        errdefer if (chunk_sourcemap_builder) |b| b.destroy(allocator);

        // sourceMappingURL 주석 (linked 만): placeholder filename 으로 부착해
        // resolveContentHashes 가 final hash 로 치환. external 은 부착 안 함.
        // inline_ 는 finalizeChunkSourceMaps 에서 base64 embed 와 함께 처리
        // (base64 안 placeholder 가 못 치환되는 이슈 회피).
        if (options.sourcemap.enable and options.sourcemap.mode == .linked) {
            try SourceMap.appendSourceMappingURLComment(&chunk_output, allocator, .{
                .mode = .linked,
                .output_filename = std.fs.path.basename(filename),
            }, null);
        }

        const dev_codes_slice: ?[]const types.ModuleDevCode = if (collect_dev_codes and chunk_dev_codes.items.len > 0)
            try chunk_dev_codes.toOwnedSlice(allocator)
        else
            null;

        const snippets = try compiler_snippets.toOwnedSlice(allocator);
        errdefer {
            for (snippets) |program| program.destroy();
            allocator.free(snippets);
        }
        try outputs.append(allocator, .{
            .path = filename,
            .compiler_output_snippets = snippets,
            .contents = try chunk_output.toOwnedSlice(allocator),
            .module_ids = module_ids,
            .exports = export_names,
            .sourcemap_builder = chunk_sourcemap_builder,
            .module_dev_codes = dev_codes_slice,
        });
    }

    // 2패스: content hash 계산 및 placeholder 치환.
    // 각 청크의 content에서 placeholder를 찾아 content hash로 교체한다.
    // esbuild도 동일한 2패스 접근을 사용 (placeholder → content hash).
    try resolveContentHashes(allocator, outputs.items, sorted_indices, chunk_graph, options.restrict_to_chunk);

    // sourcemap finalize: hash 치환 후 final filename 으로 builder generate.
    // mode 별 분기 (lazy / eager / inline_) 는 finalize 안에서 처리.
    if (options.sourcemap.enable) {
        try finalizeChunkSourceMaps(allocator, outputs.items, options.sourcemap);
    }

    return outputs.toOwnedSlice(allocator);
}

fn collectRunBeforeMainCrossImports(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(RunBeforeMainCrossImport),
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    current_chunk: *const Chunk,
    run_before_main: []const []const u8,
    rename_tbl: ?*const RenameTable,
) !void {
    for (run_before_main) |rbm_path| {
        const rbm = graph.findModuleByPath(rbm_path) orelse continue;
        const source_chunk = chunk_graph.getModuleChunk(rbm.index);
        if (source_chunk == .none or source_chunk == current_chunk.index) continue;
        // (#4555 리뷰 [3]) cjs-wrap RBM 을 **이 청크의 어떤 모듈이 raw-require** 하면 skip. 그 경우
        // 메인 cross-chunk import 블록(#4541)이 cjs-wrap 썽크를 forwarding decl(`const require_X =
        // function(){…}`)로 이미 바인딩하므로, 여기서 또 `const {require_X}=require()` 를 내면 **이중
        // 선언 SyntaxError**. RBM 호출부(require_X())는 메인 바인딩을 참조한다. 아무도 raw-require 안
        // 하면(run_before_main 으로만 참조) 메인이 require_X 를 안 바인딩하므로 cross-import 를 유지해
        // 바인딩한다. esm-wrap 은 메인이 side-effect require 라 init_X 미바인딩 → 항상 유지.
        if (rbm.wrap_kind == .cjs) {
            var chunk_raw_requires_rbm = false;
            outer: for (current_chunk.modules.items) |mod_idx| {
                const m = graph.getModule(mod_idx) orelse continue;
                for (m.import_records) |rec| {
                    if (rec.resolved == rbm.index) {
                        chunk_raw_requires_rbm = true;
                        break :outer;
                    }
                }
            }
            if (chunk_raw_requires_rbm) continue;
        }
        const name = try runBeforeMainCallName(allocator, rbm, rename_tbl) orelse continue;

        var duplicate = false;
        for (out.items) |existing| {
            if (existing.source_chunk == source_chunk and std.mem.eql(u8, existing.name, name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(name);
            continue;
        }
        try out.append(allocator, .{ .source_chunk = source_chunk, .name = name });
    }
}

fn findLastRunBeforeMainPosition(sorted_mods: []const ModuleIndex, closure: *const std.DynamicBitSet) ?usize {
    var last: ?usize = null;
    for (sorted_mods, 0..) |mod_idx, i| {
        const module_idx = mod_idx.toUsize();
        if (module_idx < closure.capacity() and closure.isSet(module_idx)) last = i;
    }
    return last;
}

fn emitRunBeforeMainCrossImports(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    imports: []const RunBeforeMainCrossImport,
    current_chunk: *const Chunk,
    chunk_graph: *const ChunkGraph,
    options: *const EmitOptions,
    ext: []const u8,
    /// reg_split(iife/umd/amd) 일 때 dep 청크의 레지스트리 id 조회용. reg_split 아니면 미사용.
    reg_ids: []const []const u8,
) !void {
    // (#4555) 공유 RBM 이 common 청크로 가면 cross-chunk 로 그 init 을 가져와야 한다. 결합 형태는
    // 포맷별로 달라야 유효하다(메인 import 블록과 동일):
    //   · reg_split(iife/umd/amd) → `const { init_X } = __zntc_require("<reg_id>");` (ESM import 는
    //     factory 함수 안이라 SyntaxError 였다 — #4555)
    //   · cjs → `const { init_X } = require("<path>");` (cjs 에 ESM import 는 무효)
    //   · esm → `import { init_X } from "<path>";` (기존)
    const reg_split = options.format.isWrappedFormat() and !options.preserve_modules;
    const min = options.minify_whitespace;
    // 결합 형태는 청크 전체가 같은 포맷이라 loop-invariant — 루프 밖에서 한 번 계산.
    const open = if (reg_split or options.format == .cjs)
        (if (min) "const{" else "const { ")
    else
        (if (min) "import{" else "import { ");
    const mid = if (reg_split)
        (if (min) "}=__zntc_require(\"" else " } = __zntc_require(\"")
    else if (options.format == .cjs)
        (if (min) "}=require(\"" else " } = require(\"")
    else
        (if (min) "}from\"" else " } from \"");
    const close = if (reg_split or options.format == .cjs)
        (if (min) "\");" else "\");\n")
    else
        (if (min) "\";" else "\";\n");

    var dep_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer dep_buf.deinit(allocator);
    // importer_dir 는 경로 계산(비-reg_split)에만 쓰인다 — reg_split 은 reg_id 라 스킵.
    var importer_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer importer_buf.deinit(allocator);
    const importer_dir = if (reg_split) "" else blk: {
        try appendChunkOutputPath(current_chunk, &importer_buf, allocator, options);
        break :blk std.fs.path.dirname(importer_buf.items) orelse "";
    };
    for (imports) |imp| {
        // reg_split 은 레지스트리 id, 그 외는 상대 경로.
        const bind_arg: []const u8 = if (reg_split)
            reg_ids[@backingInt(imp.source_chunk)]
        else blk_path: {
            const dep_chunk = chunk_graph.getChunk(imp.source_chunk);
            // explicit_file_name(plugin emitFile verbatim)을 preserve_modules 보다 **먼저** — 메인
            // cross-chunk 블록(chunks.zig ~738)·파일명 생성부와 동일 순서라야 import 경로가 실제
            // 출력 파일명과 일치(#4555 리뷰 [4]).
            if (dep_chunk.explicit_file_name) |efn| break :blk_path try computeRelativePath(allocator, importer_dir, efn, "");
            if (options.preserve_modules) {
                const dep_path = try computePreserveModulesPath(allocator, dep_chunk.rel_dir orelse "./", ext, options.preserve_modules_root);
                defer allocator.free(dep_path);
                break :blk_path try computeRelativePath(allocator, importer_dir, dep_path, "");
            }
            try chunkPlaceholderStem(dep_chunk, &dep_buf, allocator, options);
            break :blk_path try computeRelativePath(allocator, importer_dir, dep_buf.items, ext);
        };
        defer if (!reg_split) allocator.free(bind_arg);

        try output.appendSlice(allocator, open);
        try output.appendSlice(allocator, imp.name);
        try output.appendSlice(allocator, mid);
        try output.appendSlice(allocator, bind_arg);
        try output.appendSlice(allocator, close);
    }
}

fn collectRunBeforeMainExportNames(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    bindings: *std.StringHashMapUnmanaged(RunBeforeMainExport),
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    current_chunk: *const Chunk,
    run_before_main: []const []const u8,
    rename_tbl: ?*const RenameTable,
) !void {
    for (run_before_main) |rbm_path| {
        const rbm = graph.findModuleByPath(rbm_path) orelse continue;
        const source_chunk = chunk_graph.getModuleChunk(rbm.index);
        if (source_chunk == .none or source_chunk != current_chunk.index) continue;
        const name = try runBeforeMainCallName(allocator, rbm, rename_tbl) orelse continue;
        errdefer allocator.free(name);
        const id = switch (rbm.wrap_kind) {
            .cjs => SymbolID.make(rbm.index, @backingInt(rbm.require_symbol orelse return error.MissingWrapperSymbol)),
            .esm => try rbm.esmInitSymbol(),
            .none => unreachable,
        };
        if (bindings.get(name)) |known| {
            if (known.owner != rbm or !std.meta.eql(known.symbol, id)) return error.DuplicateRunBeforeMainExport;
            allocator.free(name);
            continue;
        }
        try bindings.put(allocator, name, .{ .owner = rbm, .symbol = id });
        errdefer _ = bindings.remove(name);
        try out.append(allocator, name);
    }
}

fn runBeforeMainCallName(allocator: std.mem.Allocator, module: *const Module, rename_tbl: ?*const RenameTable) !?[]const u8 {
    if (!module.wrap_kind.isWrapped()) return null;
    return if (module.wrap_kind == .cjs)
        try module.allocRequireName(allocator, rename_tbl)
    else
        try module.allocInitName(allocator, rename_tbl);
}

fn appendUniqueName(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, name: []const u8) !void {
    if (containsName(list.items, name)) return;
    try list.append(allocator, name);
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

/// 모듈 코드 선두에서 directive prologue (`"use strict"`, `"use client"`,
/// `"use server"` 등 string literal expression statement)를 추출한다.
///
/// 추출된 디렉티브는 `out`에 누적 (각 디렉티브 + ";\n"). 반환값은 디렉티브를
/// 제거한 나머지 코드 (input slice의 일부, 별도 할당 없음).
///
/// 규칙: 공백·줄바꿈·라인 주석(`//`)·블록 주석(`/* */`)을 건너뛰고, "..." 또는
/// '...' 형태의 string literal이 expression statement로 등장하는 동안 반복.
/// 첫 비-디렉티브 토큰을 만나면 중단.
pub fn extractLeadingDirectives(
    code: []const u8,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ![]const u8 {
    var i: usize = 0;
    var last_directive_end: usize = 0;

    while (i < code.len) {
        // 공백 및 주석 스킵
        const ws_end = skipWhitespaceAndComments(code, i);
        i = ws_end;
        if (i >= code.len) break;

        const c = code[i];
        if (c != '"' and c != '\'') break;

        // 문자열 리터럴 끝 찾기 (이스케이프 처리)
        const quote = c;
        var j = i + 1;
        var terminated = false;
        while (j < code.len) : (j += 1) {
            const cj = code[j];
            if (cj == '\\') {
                j += 1;
                continue;
            }
            if (cj == quote) {
                terminated = true;
                break;
            }
            if (cj == '\n') break; // 미종료 문자열 — 중단
        }
        if (!terminated) break;

        const literal_start = i;
        const literal_end = j + 1; // closing quote 포함

        // 다음 토큰이 `;` 또는 줄바꿈이어야 expression statement
        var k = literal_end;
        while (k < code.len and (code[k] == ' ' or code[k] == '\t')) : (k += 1) {}
        if (k >= code.len) {
            // EOF — directive로 인정
            try out.appendSlice(allocator, code[literal_start..literal_end]);
            try out.appendSlice(allocator, ";\n");
            last_directive_end = code.len;
            i = code.len;
            break;
        }

        const after = code[k];
        if (after == ';') {
            try out.appendSlice(allocator, code[literal_start..literal_end]);
            try out.appendSlice(allocator, ";\n");
            i = k + 1;
            last_directive_end = i;
        } else if (after == '\n' or after == '\r') {
            try out.appendSlice(allocator, code[literal_start..literal_end]);
            try out.appendSlice(allocator, ";\n");
            i = k;
            last_directive_end = i;
        } else {
            // 문자열 다음에 다른 토큰 — directive 아님
            break;
        }
    }

    return code[last_directive_end..];
}

/// RSC 디렉티브 리터럴 상수 (single/double quote 양쪽).
const USE_CLIENT_DQ = "\"use client\"";
const USE_CLIENT_SQ = "'use client'";
const USE_SERVER_DQ = "\"use server\"";
const USE_SERVER_SQ = "'use server'";
const USE_CACHE_DQ = "\"use cache\"";
const USE_CACHE_SQ = "'use cache'";

fn containsDirective(hoisted: []const u8, dq: []const u8, sq: []const u8) bool {
    return std.mem.indexOf(u8, hoisted, dq) != null or std.mem.indexOf(u8, hoisted, sq) != null;
}

/// `hoisted` 안에 RSC 디렉티브 충돌이 있으면 stderr에 경고를 출력.
/// Next.js 스펙: `'use client'` + `'use server'`/`'use cache'` 같은 파일 공존 불가.
pub fn warnRscDirectiveConflict(hoisted: []const u8, where: []const u8) void {
    if (hoisted.len == 0) return;
    const has_client = containsDirective(hoisted, USE_CLIENT_DQ, USE_CLIENT_SQ);
    if (!has_client) return;
    const has_server = containsDirective(hoisted, USE_SERVER_DQ, USE_SERVER_SQ);
    const has_cache = containsDirective(hoisted, USE_CACHE_DQ, USE_CACHE_SQ);

    if (has_server) {
        std.debug.print(
            "[zntc] warning: RSC directive conflict — 'use client' and 'use server' coexist in the same file/chunk ({s}). React/Next.js runtime will reject this.\n",
            .{where},
        );
    }
    if (has_cache) {
        std.debug.print(
            "[zntc] warning: RSC directive conflict — 'use client' and 'use cache' coexist in the same file/chunk ({s}). Next.js runtime will reject this.\n",
            .{where},
        );
    }
}

fn skipWhitespaceAndComments(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len) {
        const c = code[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (i + 1 < code.len and c == '/') {
            const c2 = code[i + 1];
            if (c2 == '/') {
                // line comment
                i += 2;
                while (i < code.len and code[i] != '\n') : (i += 1) {}
                continue;
            }
            if (c2 == '*') {
                // block comment
                i += 2;
                while (i + 1 < code.len and !(code[i] == '*' and code[i + 1] == '/')) : (i += 1) {}
                if (i + 1 < code.len) i += 2;
                continue;
            }
        }
        break;
    }
    return i;
}

/// 동적 import 경로를 청크 파일명으로 리라이트한다.
///
/// code splitting 시 `import('./page')` → `import('./page.js')` 변환.
/// 모듈의 import_records에서 dynamic_import 레코드를 찾아,
/// resolve된 대상 모듈이 속한 청크의 파일명으로 specifier를 교체한다.
///
/// 내용이 바뀌지 않으면 null 을 반환해 입력 슬라이스를 빌린다. 리라이트한 결과만 소유하며
/// caller 가 free 해야 한다.
fn rewriteDynamicImports(
    allocator: std.mem.Allocator,
    code: []const u8,
    module: *const Module,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    public_path: []const u8,
    out_ext: []const u8,
    emit_options: *const EmitOptions,
    reg_ids: []const []const u8,
    linker: ?*const Linker,
    compiler_snippets: *std.ArrayListUnmanaged(*@import("../compiler_output_program.zig").Program),
) !?[]const u8 {
    // 경로 정보나 출력 버퍼를 준비하기 전에 리라이트 대상부터 확인한다. 동적 import 가
    // 없거나 모두 이 청크에 없는 대상이면 호출자는 원본 코드를 그대로 쓸 수 있다.
    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.pm_namespace_projection != null) continue;
        // #4616: external 동적 import 는 `resolved == .none` 이라 아래 판정에 안 걸린다.
        // `--external-alias` 대상이면 지정자를 바꿔야 하므로 여기서도 켠다.
        if (rec.kind == .dynamic_import and rec.resolved == .none and rec.external_specifier != null) {
            has_dynamic = true;
            break;
        }
        if (rec.kind == .dynamic_import and rec.resolved != .none) {
            const target_chunk = chunk_graph.getModuleChunk(rec.resolved);
            if (target_chunk != .none) {
                has_dynamic = true;
                break;
            }
        }
    }
    if (!has_dynamic) {
        return null;
    }

    // PR B-4b-1 blocker #1: importer(현재 module 의) chunk dir 정보 캐싱 —
    // 동적 import 결과 path 를 importer chunk dir 기준 relative 로 계산할 때
    // 사용. [dir] 토큰 비활성 시 src_dir="" 이라 결과는 평면 `./stem.ext`.
    // stem_buf 는 ArrayList — loop 안에서 reuse 로 단일 alloc amortize.
    var stem_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer stem_buf.deinit(allocator);

    const src_chunk_idx = chunk_graph.getModuleChunk(module.index);
    // src_dir 는 importer chunk *stem* (pattern + baked-in slash 포함) 의
    // dirname. name_dir 만 보면 baked-in dir 를 못 보고 import path 가
    // importer 위치 기준 잘못 계산됨.
    var importer_stem_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer importer_stem_buf.deinit(allocator);
    const src_chunk_dir: []const u8 = if (src_chunk_idx.isNone())
        ""
    else blk: {
        try appendChunkOutputPath(chunk_graph.getChunk(src_chunk_idx), &importer_stem_buf, allocator, emit_options);
        break :blk std.fs.path.dirname(importer_stem_buf.items) orelse "";
    };

    // 리라이트 수행: 각 dynamic import specifier를 청크 파일명으로 교체.
    // import_records를 순회하면서 코드 내의 specifier 문자열을 찾아 교체한다.
    // codegen이 specifier를 원본 그대로 출력하므로 정확한 문자열 매칭이 가능.
    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    const source_chunk_idx = chunk_graph.getModuleChunk(module.index);

    for (module.import_records) |rec| {
        if (rec.pm_namespace_projection != null) continue;
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) {
            // external: 청크가 없으므로 호출 전체를 바꾸지 않고 **지정자 문자열만** 바꾼다.
            // 안 하면 정적 import 는 새 이름, 동적 import 는 옛 이름이 나가 한 번들에 두
            // 철자가 섞인다 (#4616).
            if (rec.external_specifier) |ext_name| {
                if (try rewriteImportCallSpecifier(allocator, result, rec.specifier, ext_name)) |nr| {
                    allocator.free(result);
                    result = nr;
                }
            }
            continue;
        }

        const target_chunk_idx = chunk_graph.getModuleChunk(rec.resolved);
        if (target_chunk_idx == .none) continue;

        const same_chunk = source_chunk_idx != .none and target_chunk_idx == source_chunk_idx;

        // same-chunk: 대상이 이 청크에 병합됨(manualChunks/auto/inline) → 별도
        // 청크 파일이 없다. raw `import("./x")` 를 그대로 두면 런타임에
        // ERR_MODULE_NOT_FOUND (`./x` 파일 부재) — inline_dynamic_imports 여부와
        // 무관하게 *항상* 깨지므로 항상 재작성한다(기존 `inline_dynamic_imports`
        // 게이트는 manualChunks 병합 시 same-chunk 동적 import 를 깨뜨리는
        // 잠재 버그였음). 대상 wrap_kind 별:
        //  .esm → Promise.resolve().then(()=>(init(),exports))
        //  .cjs → Promise.resolve().then(()=>require_x())
        //  .none(스코프 호이스팅) → 대상의 `.local` export 만 namespace 객체로
        //    스냅샷(esbuild 동일 — 같은 청크 동적 import 는 값 복사, live-binding
        //    아님). re-export 계열(.re_export/.star/.namespace)은 제외: 그 심볼은
        //    이 청크에 로컬 식별자로 바인딩됐다는 보장이 없어(타 청크 binding 을
        //    cross-chunk import 배선으로 참조) 객체에 넣으면 ReferenceError. 키가
        //    JS 식별자가 아니면(ES2022 string export) quote.
        if (same_chunk) {
            const target_mod = graph.getModule(rec.resolved) orelse continue;
            const tmi: u32 = rec.resolved.toU32();
            const replacement_expr = switch (target_mod.wrap_kind) {
                .esm => blk: {
                    const init_name = try target_mod.allocInitName(allocator, if (linker) |l| &l.rename_table else null);
                    defer allocator.free(init_name);
                    const exports_name = try target_mod.allocExportsName(allocator, if (linker) |l| &l.rename_table else null);
                    defer allocator.free(exports_name);
                    const inner = try std.fmt.allocPrint(allocator, "({s}(),{s})", .{ init_name, exports_name });
                    defer allocator.free(inner);
                    break :blk try thenOf(allocator, inner, !emit_options.unsupported.arrow);
                },
                .cjs => blk: {
                    // (#4510) `import('./x.cjs')` 의 결과는 **module namespace** 라 `default` 가
                    // 있어야 한다(Node 의 CJS↔ESM 계약: default = module.exports). raw `require_x()`
                    // 를 그대로 주면 `m.default` 가 undefined. `__toESM` 은 default 를 달아 주고
                    // 멤버도 복사하므로 static import 와 같은 값 해석이 된다.
                    break :blk try dynamicCjsNamespaceExpr(allocator, linker, target_mod, emit_options.minify_whitespace, !emit_options.unsupported.arrow);
                },
                .none => blk: {
                    // namespace 객체 합성: { <exported>: <청크-로컬 이름>, ... }
                    // 청크-로컬 이름은 linker.getCanonicalForExport(kind-aware,
                    // .local 은 symbol-ref→safeIdentifierName) 로 해석.
                    var ns: std.ArrayList(u8) = .empty;
                    errdefer ns.deinit(allocator);
                    try ns.appendSlice(allocator, "Promise.resolve().then(()=>({");
                    var n: usize = 0;
                    for (target_mod.export_bindings) |eb| {
                        if (eb.kind != .local) continue; // re-export 계열 제외(상단 주석)
                        const exported = eb.exported_name;
                        const local = (if (linker) |l|
                            l.getCanonicalForExport(eb, tmi)
                        else
                            target_mod.exportBindingLocalName(eb)) orelse return error.InvalidCrossChunkExport;
                        if (n > 0) try ns.append(allocator, ',');
                        if (isAsciiJsIdent(exported)) {
                            try ns.appendSlice(allocator, exported);
                        } else {
                            // ES2022 string export 등 비식별자 → quote(객체 키로
                            // 항상 합법). parent.appendJsStringLiteral 재사용.
                            try parent.appendJsStringLiteral(allocator, &ns, exported);
                        }
                        try ns.append(allocator, ':');
                        try ns.appendSlice(allocator, local);
                        n += 1;
                    }
                    try ns.appendSlice(allocator, "}))");
                    break :blk try ns.toOwnedSlice(allocator);
                },
            };
            defer allocator.free(replacement_expr);

            const new_result_opt = try rewriteImportCallToWrapper(allocator, result, rec.specifier, replacement_expr);
            if (new_result_opt) |new_result| {
                allocator.free(result);
                result = new_result;
            }
            continue;
        }

        const target_chunk = chunk_graph.getChunk(target_chunk_idx);

        // 청크 파일명 생성: public_path가 있으면 "{public_path}{stem}{ext}", 없으면
        // importer chunk dir 기준 상대 경로(`computeRelativePath`).
        // PR7-2d: 명시 fileName chunk 는 verbatim(패턴/hash 우회) — public_path 만 prefix.
        // PR B-4b-1 blocker #1: dynamic import 도 [dir] 토큰 활성화 시 dep_stem
        // 이 dir 포함 — importer chunk dir 기준 relative 계산.
        try chunkPlaceholderStem(target_chunk, &stem_buf, allocator, emit_options);
        const stem = stem_buf.items;
        const replacement = if (target_chunk.explicit_file_name) |efn|
            (if (public_path.len > 0)
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ public_path, efn })
            else
                try computeRelativePath(allocator, src_chunk_dir, efn, ""))
        else if (public_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ public_path, stem, out_ext })
        else blk: {
            // dynamic import 도 importer chunk dir 기준 상대 경로 — pattern
            // baked-in slash (`'static/[name]'`) 케이스에서 runtime resolve 정합.
            break :blk try computeRelativePath(allocator, src_chunk_dir, stem, out_ext);
        };
        defer allocator.free(replacement);

        // (#4522) 대상이 **CJS 인 dynamic entry 청크**면 그 청크는 namespace 를 `default`
        // 슬롯에 통째로 실어 보낸다(위 `cjs_dyn_entry` 참조 — CJS 의 named 멤버는 ESM
        // export 문법으로 정적 표현이 불가능해서 그 방법밖에 없다). 소비자는 한 겹 벗겨야
        // 진짜 namespace 를 얻는다. 조건은 provider 쪽 emit 조건과 **정확히 같아야** 한다.
        const cjs_dyn_unwrap = blk: {
            const mi = dynamicCjsNamespaceEntry(
                target_chunk,
                graph,
                linker != null,
                emit_options.preserve_modules,
            ) orelse break :blk false;
            // 그 청크가 **이 대상 모듈**의 dynamic entry 일 때만. (CJS 가 남의 dynamic entry
            // 청크에 병합돼 들어온 경우엔 provider 가 그 모듈용 namespace 를 안 낸다.)
            break :blk mi == rec.resolved;
        };
        const unwrap: []const u8 = if (cjs_dyn_unwrap) ".default" else "";

        // cjs+splitting(P3-B): 네이티브 import() 가 없으므로 호출 전체를
        //   Promise.resolve().then(()=>require("./chunk.js"))
        // 로 재작성(RFC §4.3, 디리스크 스파이크 검증). 대상 청크는 dynamic
        // entry 라 emitCjsEntryExports 가 exports.x 를 깔아둠 → require() 결과가
        // 곧 namespace. require 캐시가 재호출 시 상태 보존(스파이크 count 검증).
        // ESM 은 specifier 만 청크 파일명으로 치환(네이티브 import() 유지).
        // iife+splitting(P3-B PR3): 네이티브 import() 없음 →
        //   __zntc_load_chunk("<stem><ext>").then(function(){return __zntc_require("<id>")})
        // 청크파일은 bare(접두 ./ 없음) — 로더가 __zntc_public_path 접두.
        // 대상 청크는 dynamic entry → id = entry 모듈 안정 모듈 ID. require
        // 캐시가 상태 보존(스파이크 검증). RFC §4.3 + PR3 결정(<script>).
        const reg_split = emit_options.format.isWrappedFormat() and !emit_options.preserve_modules;
        if (reg_split) {
            const target_id = reg_ids[@backingInt(target_chunk_idx)]; // borrow
            const chunkfile = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, out_ext });
            defer allocator.free(chunkfile);
            const wrapper = try std.fmt.allocPrint(allocator, "__zntc_load_chunk(\"{s}\").then(function(){{return __zntc_require(\"{s}\"){s}}})", .{ chunkfile, target_id, unwrap });
            defer allocator.free(wrapper);
            if (try rewriteImportCallToWrapper(allocator, result, rec.specifier, wrapper)) |new_result| {
                allocator.free(result);
                result = new_result;
            }
            continue;
        }

        if (emit_options.format == .cjs and emit_options.preserve_modules) pm_dynamic_esm: {
            const target = graph.getModule(rec.resolved) orelse return error.InvalidDynamicNamespaceOwner;
            if (target.wrap_kind != .esm) break :pm_dynamic_esm;
            if (src_chunk_idx.isNone()) return error.InvalidDynamicNamespaceOwner;
            // A with/attributes boundary retains the original native import
            // and its option evaluation. Its projector has its own analyzed
            // local scope and no foreign lexical reads in the user's scope.
            const l = linker orelse return error.MissingTlaReadinessHelper;
            const provider = try parent.checkedReadinessAllProvider(graph, l);
            const helper_chunk = chunk_graph.getModuleChunk(provider.module.index);
            const projection_target_chunk = chunk_graph.getModuleChunk(target.index);
            if (helper_chunk.isNone() or projection_target_chunk.isNone()) return error.InvalidDynamicNamespaceOwner;
            var importer_file: std.ArrayListUnmanaged(u8) = .empty;
            defer importer_file.deinit(allocator);
            var helper_file: std.ArrayListUnmanaged(u8) = .empty;
            defer helper_file.deinit(allocator);
            var target_file: std.ArrayListUnmanaged(u8) = .empty;
            defer target_file.deinit(allocator);
            try appendChunkOutputPath(chunk_graph.getChunk(src_chunk_idx), &importer_file, allocator, emit_options);
            try appendChunkOutputPath(chunk_graph.getChunk(helper_chunk), &helper_file, allocator, emit_options);
            try appendChunkOutputPath(chunk_graph.getChunk(projection_target_chunk), &target_file, allocator, emit_options);
            const helper_relative = try computeRelativePath(allocator, std.fs.path.dirname(importer_file.items) orelse "", helper_file.items, "");
            defer allocator.free(helper_relative);
            const target_relative = try computeRelativePath(allocator, std.fs.path.dirname(helper_file.items) orelse "", target_file.items, "");
            defer allocator.free(target_relative);
            const quoted_helper = try quoteChunkPath(allocator, helper_relative);
            defer allocator.free(quoted_helper);
            const quoted_target = try quoteChunkPath(allocator, target_relative);
            defer allocator.free(quoted_target);
            const helper_key = try std.json.Stringify.valueAlloc(allocator, provider.binding.exported_name, .{});
            defer allocator.free(helper_key);
            const init_key = try std.json.Stringify.valueAlloc(allocator, try target.esmWrapperName(try target.esmInitSymbol(), null), .{});
            defer allocator.free(init_key);
            const namespace_key = try std.json.Stringify.valueAlloc(allocator, try target.esmWrapperName(try target.esmNamespaceSymbol(), null), .{});
            defer allocator.free(namespace_key);
            const source = try std.fmt.allocPrint(allocator, "module.exports=function(){{return import(\"\").then(function(namespace){{return namespace.default[{s}].importNamespace(\"\",{s},{s},{s});}});}};", .{ helper_key, init_key, namespace_key, if (target.in_async_cone) "true" else "false" });
            defer allocator.free(source);
            const program = try @import("../compiler_output_program.zig").Program.create(allocator, source);
            var owned = false;
            defer if (!owned) program.destroy();
            var helper_path_node: ?NodeIndex = null;
            var provider_path_node: ?NodeIndex = null;
            for (program.ast.nodes.items) |node| {
                if (node.tag == .import_expression) {
                    if (helper_path_node != null) return error.InvalidCompilerOutputProgram;
                    helper_path_node = node.data.binary.left;
                }
                if (node.tag != .call_expression) continue;
                const callee = program.ast.getNode(program.ast.readExtraNode(node.data.extra, 0));
                if (callee.tag != .static_member_expression) continue;
                const property = program.ast.getNode(program.ast.readExtraNode(callee.data.extra, 1));
                if (!std.mem.eql(u8, program.ast.identifierNameText(property), "importNamespace")) continue;
                if (provider_path_node != null or program.ast.readExtra(node.data.extra, 2) != 4) return error.InvalidCompilerOutputProgram;
                provider_path_node = @fromBackingInt(program.ast.extra_data.items[program.ast.readExtra(node.data.extra, 1)]);
            }
            try program.bindLiteral(.native_helper_path, helper_path_node orelse return error.InvalidCompilerOutputProgram, quoted_helper);
            try program.bindLiteral(.provider_path, provider_path_node orelse return error.InvalidCompilerOutputProgram, quoted_target);
            const callback = try program.emitValue(allocator);
            defer allocator.free(callback);
            const suffix = try std.fmt.allocPrint(allocator, ".then({s})", .{callback});
            defer allocator.free(suffix);
            const updated = (try rewriteImportCallAppendSuffix(allocator, result, rec.specifier, replacement, suffix)) orelse return error.InvalidDynamicNamespaceCallsite;
            compiler_snippets.append(allocator, program) catch |err| {
                allocator.free(updated);
                return err;
            };
            owned = true;
            allocator.free(result);
            result = updated;
            continue;
        }

        const cjs_split = emit_options.format == .cjs and !emit_options.preserve_modules;
        if (cjs_split) {
            const inner_req = try std.fmt.allocPrint(allocator, "require(\"{s}\"){s}", .{ replacement, unwrap });
            defer allocator.free(inner_req);
            const wrapper = try thenOf(allocator, inner_req, !emit_options.unsupported.arrow);
            defer allocator.free(wrapper);
            if (try rewriteImportCallToWrapper(allocator, result, rec.specifier, wrapper)) |new_result| {
                allocator.free(result);
                result = new_result;
            }
            continue;
        }

        // (#4524) preserve-modules: 대상 파일은 `export default require_X()` 로 **raw
        // module.exports** 를 낸다(모듈 자기 모양 유지 — `import d from './legacy.js'` 가
        // module.exports 여야 하므로 namespace 를 실을 수 없다). 그래서 namespace 합성은
        // **소비자**가 한다: `import(...).then((m)=>__toESM(m.default))` (rolldown 동일).
        if (emit_options.preserve_modules) pm_dyn_cjs: {
            const tm = graph.getModule(rec.resolved) orelse break :pm_dyn_cjs;
            if (tm.wrap_kind != .cjs) break :pm_dyn_cjs;
            const toesm = if (linker) |l|
                try l.esmInteropRuntimeHelperName(.to_esm)
            else
                rt_names.helperName("__toESM", emit_options.minify_whitespace);
            // provider 는 래퍼 **선언만** export 한다(호출 금지 — 순환/조건부 require 보호).
            // 그래서 소비자가 썽크를 호출해 namespace 를 만든다: `__toESM(m.require_X())`.
            const thunk = try tm.allocRequireName(allocator, if (linker) |l| &l.rename_table else null);
            defer allocator.free(thunk);
            // Native import() always provides default = raw module.exports,
            // including objects carrying an authored __esModule property.
            const suffix = try std.fmt.allocPrint(allocator, ".then((m)=>{s}(m.{s}(),1))", .{ toesm, thunk });
            defer allocator.free(suffix);
            if (try rewriteImportCallAppendSuffix(
                allocator,
                result,
                rec.specifier,
                replacement,
                suffix,
            )) |new_result| {
                allocator.free(result);
                result = new_result;
                continue;
            }
            // 폴백: suffix 를 못 붙였으면 최소한 specifier 는 고친다(아래 공통 경로).
        }

        // ESM: 네이티브 import() 유지 — specifier 만 청크 파일명으로 교체.
        // 단 CJS dynamic entry 청크면 namespace 를 한 겹 벗겨야 한다(#4522).
        // ⚠️ 여기서 `rewriteImportCallToWrapper`(첫 indexOf 1회 + attributes 미지원)를 쓰면
        // 문자열 리터럴 선행 occurrence / import attributes 에서 **specifier 가 통째로
        // 미치환** 되어 ERR_MODULE_NOT_FOUND 다(#4295 회귀). specifier 교체는 아래 기존
        // positional-walk 경로와 **같은 규칙**으로 하고 suffix 만 덧붙인다.
        if (cjs_dyn_unwrap) {
            if (try rewriteImportCallAppendSuffix(
                allocator,
                result,
                rec.specifier,
                replacement,
                ".then((m)=>m.default)",
            )) |new_result| {
                allocator.free(result);
                result = new_result;
                continue;
            }
            // 폴백: suffix 를 못 붙였으면 최소한 specifier 는 고친다(아래 공통 경로).
        }

        // 실제 `import("specifier")` 호출 안의 specifier 만 교체 (prefix 충돌/문자열 리터럴 회피).
        if (try rewriteImportSpecifier(allocator, result, rec.specifier, replacement)) |new_result| {
            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

/// `import()` 대체식을 만든다: `Promise.resolve().then(<cb>)`.
/// arrow 를 모르는 타겟(`--target=es5`)에선 function expression 으로 쓴다 — 헬퍼 상수와
/// 래퍼를 ES5 로 바꿔도 이 재작성이 arrow 를 내면 번들이 여전히 파싱 불가다 (#4630).
fn thenOf(allocator: std.mem.Allocator, expr: []const u8, arrow: bool) ![]const u8 {
    return if (arrow)
        std.fmt.allocPrint(allocator, "Promise.resolve().then(()=>{s})", .{expr})
    else
        std.fmt.allocPrint(allocator, "Promise.resolve().then(function(){{return {s}}})", .{expr});
}

/// (#4510) 같은 번들/청크 안에 인라인된 **CJS 모듈의 동적 import** 를 대체할 표현식.
/// `Promise.resolve().then(()=>__toESM(require_x()))` — `import()` 는 module namespace 를
/// resolve 하므로 `default`(= module.exports, Node 의 CJS↔ESM 계약)가 있어야 한다. raw
/// `require_x()` 는 `m.default` 가 undefined 다(#4510-3).
/// interop 인자(node `, 1` vs babel)와 minify 시 헬퍼 축약명(`$tE`)은 static import 경로와
/// 같은 소스(`Linker.cjsInteropAccessExpr`)를 써야 두 경로의 값 해석이 어긋나지 않는다.
/// linker 가 없으면(단위 테스트) 기존 raw require 형태로 폴백.
fn dynamicCjsNamespaceExpr(
    allocator: std.mem.Allocator,
    linker: ?*const Linker,
    target_mod: *const Module,
    minify: bool,
    arrow: bool,
) ![]const u8 {
    if (linker) |l| {
        const ns_expr = try l.cjsInteropAccessExpr(allocator, target_mod, linker_mod.CJS_NS_EXPORT_NAME, minify);
        defer allocator.free(ns_expr);
        return thenOf(allocator, ns_expr, arrow);
    }
    const require_name = try target_mod.allocRequireName(allocator, null);
    defer allocator.free(require_name);
    const call = try std.fmt.allocPrint(allocator, "{s}()", .{require_name});
    defer allocator.free(call);
    return thenOf(allocator, call, arrow);
}

/// `import("specifier")` 호출 전체를 미리 만들어진 expression 으로 교체.
/// 매칭 실패 시 null. codegen 출력 형태 (`import("./x")`) 만 처리 — import attributes
/// 같은 second-arg 폼(`import("./x", {…})`)은 호출 전체 치환이라 닫는 `)` 위치를
/// balance-scan 해야 해 현재 미지원(별도 이슈). specifier 만 바꾸는 경로는
/// `rewriteImportSpecifier` 가 attributes 도 처리한다.
/// Single-file output 용 dynamic import 재작성 (chunk_graph 없음 가정).
/// `emit` (라인 258) 가 사용하는 single-file path 는 chunk 분리 없이 모든 모듈을
/// 한 파일에 합치므로 *동일 bundle = same_chunk* 라는 단순 가정만 필요. dynamic
/// target 이 `wrap_kind = .esm` 으로 promote 됐으면 `Promise.resolve().then(...)`
/// 패턴으로 호출 재작성. React Native/Hermes 는 raw `import()` 문법 자체를 파싱하지
/// 못하므로 unresolved/external literal import 도 parse-safe rejection 으로 낮춘다.
/// 브라우저/Node 계열은 target 이 미 promote 면 그대로 둬 외부 sibling 파일 fallback
/// 가능성을 유지한다.
pub fn rewriteDynamicImportsSingleFile(
    allocator: std.mem.Allocator,
    code: []const u8,
    module: *const Module,
    graph: *const ModuleGraph,
    lower_unresolved_dynamic_imports: bool,
    linker: ?*const Linker,
    minify: bool,
    arrow: bool,
) ![]const u8 {
    const rename_tbl: ?*const RenameTable = if (linker) |l| &l.rename_table else null;
    if (module.import_records.len == 0) return try allocator.dupe(u8, code);
    if (!graph.inline_dynamic_imports) return try allocator.dupe(u8, code);

    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import or rec.callsite_lowered) continue;
        // #4616: external alias 대상도 켠다 — `resolved == .none` 이라 아래 조건에 안 걸린다.
        if (rec.resolved != .none or lower_unresolved_dynamic_imports or rec.external_specifier != null) {
            has_dynamic = true;
            break;
        }
    }
    if (!has_dynamic) return try allocator.dupe(u8, code);

    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import or rec.callsite_lowered) continue;
        if (rec.resolved == .none) {
            // #4616: external alias — 호출 전체가 아니라 지정자 문자열만 바꾼다.
            if (rec.external_specifier) |ext_name| {
                if (try rewriteImportCallSpecifier(allocator, result, rec.specifier, ext_name)) |nr| {
                    allocator.free(result);
                    result = nr;
                }
                continue;
            }
            if (!lower_unresolved_dynamic_imports) continue;

            // RN 릴리즈 번들은 Hermes가 전체 파일을 먼저 파싱한다. 실제로 실행되지
            // 않는 fallback callback 안의 `import()` 도 문법 에러가 되므로, Metro처럼
            // 런타임 실패 표현으로 낮춰 파서 통과를 보장한다.
            const replacement_expr = "Promise.reject(new Error(\"Dynamic import is not available in this React Native bundle\"))";
            const new_result_opt = try rewriteImportCallToWrapper(allocator, result, rec.specifier, replacement_expr);
            if (new_result_opt) |new_result| {
                allocator.free(result);
                result = new_result;
            }
            continue;
        }

        const target_mod = graph.getModule(rec.resolved) orelse continue;
        const replacement_expr = switch (target_mod.wrap_kind) {
            .esm => blk: {
                // RFC #3940 L.5b: caller(emitWithTreeShaking)가 linker 보유 → rt 전달.
                const init_name = try target_mod.allocInitName(allocator, rename_tbl);
                defer allocator.free(init_name);
                const exports_name = try target_mod.allocExportsName(allocator, rename_tbl);
                defer allocator.free(exports_name);
                const inner2 = try std.fmt.allocPrint(allocator, "({s}(),{s})", .{ init_name, exports_name });
                defer allocator.free(inner2);
                break :blk try thenOf(allocator, inner2, arrow);
            },
            // (#4510) CJS 동적 import 의 namespace 는 `__toESM(require_x())` — 위 chunk 경로와 동일.
            .cjs => try dynamicCjsNamespaceExpr(allocator, linker, target_mod, minify, arrow),
            .none => continue,
        };
        defer allocator.free(replacement_expr);

        const new_result_opt = try rewriteImportCallToWrapper(allocator, result, rec.specifier, replacement_expr);
        if (new_result_opt) |new_result| {
            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

/// (#4522) 이 청크가 **동적 CJS entry** 라서 `default` 슬롯에 namespace 를 통째로 싣는가.
/// 그렇다면 그 모듈 인덱스를 돌려준다.
///
/// provider emit(`cjs_dyn_entry`) / consumer unwrap(`rewriteDynamicImports`) / `__toESM` 헬퍼
/// 주입(runtime_helpers) — **세 곳이 반드시 같은 술어**를 봐야 한다. 어긋나면:
///   - provider 만 켜짐 → 소비자가 안 벗겨 값이 한 겹 더 감싸진다.
///   - consumer 만 켜짐 → export 가 없는데 `.default` 를 벗겨 **undefined** → TypeError.
/// 실제로 `linker == null`(scopeHoist=false) 에서 provider 는 bail 하는데 consumer 는 안 봐서
/// 후자가 났다. 그래서 복붙을 없애고 여기 한 곳으로 모은다.
pub fn dynamicCjsNamespaceEntry(
    chunk: *const Chunk,
    graph: *const ModuleGraph,
    has_linker: bool,
    preserve_modules: bool,
) ?ModuleIndex {
    if (preserve_modules) return null;
    if (!has_linker) return null; // provider 가 `linker orelse break` 로 bail 하는 조건
    const info = switch (chunk.kind) {
        .entry_point => |i| i,
        .common, .manual => return null,
    };
    if (!info.is_dynamic) return null;
    // (#4522) federation expose / plugin emitFile 청크도 dynamic entry 모양이지만 그 소비자는
    // zntc 가 아니라 **container factory / 사용자 코드**다. `default` 슬롯 의미를 바꾸면
    // (module.exports 값 → namespace) 그쪽이 조용히 깨진다 → 진짜 `import()` 대상만.
    if (!info.is_import_call) return null;
    const em = graph.getModule(info.module) orelse return null;
    if (em.wrap_kind != .cjs) return null;
    return info.module;
}

/// (#4524) preserve-modules 에서 이 청크가 **wrap 된 모듈 파일**이라 래퍼 심볼을 export
/// 해야 하는가. 그렇다면 그 모듈 인덱스를 돌려준다.
///
/// **루트커즈**: wrap 된 모듈(CJS `__commonJS` / ESM `__esm`)은 본문이 클로저 안이라 파일
/// top-level 에 남는 게 **래퍼 심볼뿐**이다 — CJS 는 `require_X`, ESM-wrap 은 `init_X` /
/// `exports_X`. preserve-modules 는 그걸 export 하지 않아서 소비자가 **다른 파일의 지역변수**
/// 를 렉시컬 참조했다:
///
///     import "./b.js";                                   // side-effect 만
///     const b = (init_b(), __toCommonJS(exports_b));     // ← b.js 의 지역변수!
///
/// → `ReferenceError: init_b is not defined`. 정적 import 조차 못 썼다.
///
/// provider(export emit) 와 consumer(named import emit) 가 **반드시 같은 술어**를 봐야 한다.
/// 어긋나면 소비자가 존재하지 않는 이름을 import 한다 — 실제로 provider 에만 `format == .esm`
/// 조건이 있어 `--format=cjs` 에서 `require_X is not a function` 이 났다.
pub fn preserveModulesWrapperChunk(
    chunk: *const Chunk,
    graph: *const ModuleGraph,
    options: *const EmitOptions,
) ?ModuleIndex {
    if (!options.preserve_modules) return null;
    // 래퍼 심볼을 실어 나를 수 있는 형식만. iife/umd/amd + preserve-modules 는 청크 경계
    // 결합 수단이 없어 대상이 아니다.
    if (options.format != .esm and options.format != .cjs) return null;
    const info = switch (chunk.kind) {
        .entry_point => |i| i,
        .common, .manual => return null,
    };
    const em = graph.getModule(info.module) orelse return null;
    if (!em.wrap_kind.isWrapped()) return null;
    return info.module;
}

/// (#4528) cjs 청크의 cross-chunk export 한 줄.
///
/// 보통은 `exports.<public> = <local>;` — **값 스냅샷**이다. 그런데 preserve-modules 의
/// **ESM-wrap provider** 는 그 값(`const`/`let`/`class`)이 `__esm` 클로저(=`init_X()`) 안에서
/// **늦게 대입**되므로, 파일 top-level 에서 스냅샷하면 **undefined** 가 나간다
/// (함수 선언만 hoisting 으로 우연히 살아남아 버그가 가려진다).
/// → **getter** 로 노출해 읽는 시점에 평가되게 한다(live). 선-init 은 답이 아니다 —
/// ESM-wrap 끼리 순환하면 아직 미평가인 상대의 `init_X`(undefined)를 부르게 된다.
fn appendCjsExportBinding(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    public: []const u8,
    public_key_literal: ?[]const u8,
    local: []const u8,
    live: bool,
    min: bool,
) !void {
    if (!live) {
        if (public_key_literal) |syntax| {
            const keys = @import("../public_export_key.zig");
            const key = try keys.fromLiteralSyntax(allocator, syntax);
            defer key.deinit(allocator);
            try out.appendSlice(allocator, "exports");
            try keys.appendMember(allocator, out, key);
        } else {
            try out.appendSlice(allocator, "exports.");
            try out.appendSlice(allocator, public);
        }
        try out.appendSlice(allocator, if (min) "=" else " = ");
        try out.appendSlice(allocator, local);
        try out.appendSlice(allocator, if (min) ";" else ";\n");
        return;
    }
    try out.appendSlice(allocator, "Object.defineProperty(exports,\"");
    try out.appendSlice(allocator, public);
    try out.appendSlice(allocator, if (min) "\",{get:function(){return " else "\", { get: function() { return ");
    try out.appendSlice(allocator, local);
    try out.appendSlice(allocator, if (min) "},enumerable:true});" else "; }, enumerable: true });\n");
}

/// (#4524) 위 청크가 export/import 해야 할 **래퍼 심볼 이름들**. caller 가 free.
fn esmInitLessThan(_: void, a: SymbolID, b: SymbolID) bool {
    if (a.module != b.module) return @backingInt(a.module) < @backingInt(b.module);
    return @backingInt(a.inner) < @backingInt(b.inner);
}

fn esmWrapperNameFor(allocator: std.mem.Allocator, graph: *const ModuleGraph, id: SymbolID, linker: ?*const Linker) ![]const u8 {
    const module = graph.getModule(id.module) orelse return error.InvalidEsmInitOwner;
    return allocator.dupe(u8, try module.esmWrapperName(id, if (linker) |l| &l.rename_table else null));
}

const WrapperNames = struct {
    a: []const u8,
    b: ?[]const u8 = null,

    fn deinit(self: WrapperNames, allocator: std.mem.Allocator) void {
        allocator.free(self.a);
        if (self.b) |x| allocator.free(x);
    }
};

fn wrapperNamesFor(
    allocator: std.mem.Allocator,
    em: *const Module,
    linker: ?*const Linker,
) !WrapperNames {
    const rt_tbl = if (linker) |l| &l.rename_table else null;
    return switch (em.wrap_kind) {
        .cjs => .{ .a = try em.allocRequireName(allocator, rt_tbl) },
        .esm => .{
            .a = try em.allocInitName(allocator, rt_tbl),
            .b = try em.allocExportsName(allocator, rt_tbl),
        },
        .none => unreachable, // preserveModulesWrapperChunk 가 걸러냄
    };
}

/// (#4522) `import("<spec>")` 호출의 specifier 를 바꾸고 **호출 뒤에** suffix 를 덧붙인다
/// (`import("./c.js").then((m)=>m.default)`).
///
/// `rewriteImportSpecifier` 와 **같은 positional walk** 를 쓴다 — 문자열 리터럴 안의 substring
/// 이나 prefix 충돌(`./x` vs `./xyz`)을 오재작성하지 않고 **모든 occurrence** 를 처리한다.
/// 호출 끝은 괄호 균형으로 찾으므로 import attributes(`import("./x", { with: {…} })`)도
/// 안전하다.
///
/// ⚠️ `rewriteImportCallToWrapper` 를 쓰면 안 된다 — 첫 `indexOf` 1회만 보고(문자열 리터럴이
/// 앞에 있으면 그걸 잡고 실패) attributes 도 의도적으로 미지원이라, 둘 다 **specifier 미치환
/// → ERR_MODULE_NOT_FOUND** 다(#4295 가 고쳤던 바로 그 miscompile).
///
/// 호출 끝을 못 찾으면 null — caller 는 기존 specifier-only 경로로 폴백한다.
fn rewriteImportCallAppendSuffix(
    allocator: std.mem.Allocator,
    code: []const u8,
    specifier: []const u8,
    replacement: []const u8,
    suffix: []const u8,
) !?[]u8 {
    if (specifier.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var any = false;
    while (i < code.len) {
        const rel = std.mem.indexOf(u8, code[i..], specifier) orelse break;
        const pos = i + rel;
        const close: ?usize = blk: {
            const c = importSpecifierCloseAt(code, pos, specifier.len) orelse break :blk null;
            break :blk if (code[c] == ')' or code[c] == ',') c else null;
        };
        if (close) |c| {
            const call_end = importCallEndFrom(code, c) orelse {
                out.deinit(allocator);
                return null; // 균형 파괴 — 폴백
            };
            try out.appendSlice(allocator, code[i..pos]);
            try out.appendSlice(allocator, replacement);
            try out.appendSlice(allocator, code[pos + specifier.len .. call_end + 1]);
            try out.appendSlice(allocator, suffix);
            i = call_end + 1;
            any = true;
        } else {
            // import 호출이 아닌 occurrence — 첫 글자만 흘려보내고 다음 후보부터 재검색.
            try out.appendSlice(allocator, code[i .. pos + 1]);
            i = pos + 1;
        }
    }
    if (!any) {
        out.deinit(allocator);
        return null;
    }
    try out.appendSlice(allocator, code[i..]);
    return try out.toOwnedSlice(allocator);
}

/// `import(` 를 닫는 `)` 의 인덱스. `from` 은 specifier 닫는 quote **다음** 바이트(= 이미
/// `import(` 안이므로 depth 1 에서 시작). 문자열 리터럴 안의 괄호는 건너뛴다.
fn importCallEndFrom(code: []const u8, from: usize) ?usize {
    var depth: usize = 1;
    var j = from;
    while (j < code.len) : (j += 1) {
        switch (code[j]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return j;
            },
            '"', '\'', '`' => {
                const q = code[j];
                j += 1;
                while (j < code.len) : (j += 1) {
                    if (code[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (code[j] == q) break;
                }
            },
            else => {},
        }
    }
    return null;
}

fn rewriteImportCallToWrapper(
    allocator: std.mem.Allocator,
    code: []const u8,
    specifier: []const u8,
    replacement: []const u8,
) !?[]u8 {
    if (specifier.len == 0) return null;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    var copied: usize = 0;
    var scan: usize = 0;
    var changed = false;
    while (std.mem.indexOfPos(u8, code, scan, specifier)) |position| {
        scan = position + specifier.len;
        const span = importCallSpanAt(code, position, specifier.len) orelse continue;
        if (span.call_start < copied) continue;
        try output.appendSlice(allocator, code[copied..span.call_start]);
        try output.appendSlice(allocator, replacement);
        copied = span.call_end;
        scan = span.call_end;
        changed = true;
    }
    if (!changed) return null;
    try output.appendSlice(allocator, code[copied..]);
    return try output.toOwnedSlice(allocator);
}

/// `import("K")` 의 **지정자 문자열만** `V` 로 바꾼다 (#4616 external alias).
///
/// `rewriteImportCallToWrapper` 와 달리 호출 전체를 치환하지 않는다 — external 은 청크가 없어
/// 바꿀 표현식이 없고 지정자만 갈아끼우면 된다.
///
/// ⚠️ 모든 등장을 훑되 **치환 결과 뒤에서 이어 찾는다.** 새 이름이 옛 이름을 부분 문자열로
/// 포함하면(`crypto` → `crypto-browserify`) 방금 쓴 자리를 다시 찾아 무한 반복이 된다.
fn rewriteImportCallSpecifier(
    allocator: std.mem.Allocator,
    code: []const u8,
    specifier: []const u8,
    new_spec: []const u8,
) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var scan: usize = 0;
    var hit = false;
    while (scan < code.len) {
        const rel = std.mem.indexOf(u8, code[scan..], specifier) orelse break;
        const pos = scan + rel;
        if (importSpecifierCloseAt(code, pos, specifier.len) != null) {
            try out.appendSlice(allocator, code[scan..pos]);
            try out.appendSlice(allocator, new_spec);
            scan = pos + specifier.len;
            hit = true;
        } else {
            try out.appendSlice(allocator, code[scan .. pos + specifier.len]);
            scan = pos + specifier.len;
        }
    }
    if (!hit) {
        out.deinit(allocator);
        return null;
    }
    try out.appendSlice(allocator, code[scan..]);
    return try out.toOwnedSlice(allocator);
}

const ImportCallSpan = struct { call_start: usize, call_end: usize };

/// `code` 의 `pos` 에서 길이 `spec_len` 인 토큰이 `import("…"`/`import('…'` 형태로 열리고
/// 닫는 quote 까지 맞는지 검증. 맞으면 *닫는 quote 다음* 바이트 인덱스(= specifier 끝 다음
/// 다음)를 반환, 아니면 null. opener+quote 경계로 prefix 충돌(`./x` vs `./xyz`)·문자열 리터럴
/// 내 substring 을 배제한다. 닫는 quote 다음 토큰(`)` 인자1개 vs `,` import attributes)은 caller
/// 가 용도에 맞게 판정한다(반환 인덱스는 항상 `< code.len` 이라 caller 의 `code[close]` 안전).
fn importSpecifierCloseAt(code: []const u8, pos: usize, spec_len: usize) ?usize {
    const opener_len = "import(\"".len;
    if (pos < opener_len) return null;
    const opener = code[pos - opener_len .. pos];
    if (!std.mem.eql(u8, opener, "import(\"") and !std.mem.eql(u8, opener, "import('")) return null;
    const quote = code[pos - 1];
    const after = pos + spec_len;
    if (after + 1 >= code.len) return null;
    if (code[after] != quote) return null;
    return after + 1;
}

/// `code` 의 `pos` 에서 길이 `spec_len` 인 토큰이 실제 `import("…")`/`import('…')` *호출 1개*
/// (인자 1개, 닫는 quote 직후 `)`) 안인지 검증. 맞으면 호출 전체 span(`call_start..call_end`,
/// 닫는 `)` 포함), 아니면 null. 호출 전체를 다른 식으로 치환하는 wrapper 가 사용 — 정확한
/// `call_end` 가 필요하므로 import attributes(`, {…})`)가 붙은 호출은 의도적으로 미지원(닫는
/// `)` 위치가 attributes object 너머라 balance-scan 이 필요, 별도 이슈).
fn importCallSpanAt(code: []const u8, pos: usize, spec_len: usize) ?ImportCallSpan {
    const close = importSpecifierCloseAt(code, pos, spec_len) orelse return null;
    if (code[close] != ')') return null;
    return .{ .call_start = pos - "import(\"".len, .call_end = close + 1 };
}

/// `import("<specifier>")` / `import('<specifier>')` 호출 안의 specifier 텍스트만 replacement
/// 로 교체한다. opener(`import("`/`import('`) + 닫는 quote 경계를 확인하므로 prefix 충돌
/// (`./x` vs `./xyz`)·문자열 리터럴 내 substring 을 오재작성하지 않고, 모든 occurrence 를
/// positional walk 로 처리한다. 매칭 없으면 null. (bare indexOf substring 교체의 #4295 수정)
///
/// import attributes(`import("./x", { with: {…} })`)는 닫는 quote 뒤가 `,` 라 `)` 만 허용하면
/// specifier 가 미교체로 남아 split 청크 파일명을 못 가리키는 miscompile(ESM splitting + 동적
/// import 가 내부 청크로 분리될 때)이 된다. codegen `emitImportExpr`(calls.zig)가 quote 직후
/// 공백 없이 `,` 를 찍으므로 닫는 quote 다음으로 `)` 또는 `,` 를 허용 — specifier *텍스트만*
/// 바꾸는 경로라 attributes 인자는 그대로 보존되어 안전하다(호출 전체를 치환하는
/// `rewriteImportCallToWrapper` 와 달리 정확한 `call_end` 가 불필요). prefix 충돌 방어는
/// `importSpecifierCloseAt` 의 닫는 quote 일치 체크가 담당하므로 `,` 허용해도 무방하다.
fn rewriteImportSpecifier(
    allocator: std.mem.Allocator,
    code: []const u8,
    specifier: []const u8,
    replacement: []const u8,
) !?[]u8 {
    if (specifier.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var any = false;
    while (i < code.len) {
        const rel = std.mem.indexOf(u8, code[i..], specifier) orelse break;
        const pos = i + rel;
        const is_call = if (importSpecifierCloseAt(code, pos, specifier.len)) |close|
            code[close] == ')' or code[close] == ','
        else
            false;
        if (is_call) {
            try out.appendSlice(allocator, code[i..pos]);
            try out.appendSlice(allocator, replacement);
            i = pos + specifier.len;
            any = true;
        } else {
            // import 호출이 아닌 occurrence — 첫 글자만 흘려보내 다음 후보부터 재검색.
            try out.appendSlice(allocator, code[i .. pos + 1]);
            i = pos + 1;
        }
    }
    if (!any) {
        out.deinit(allocator);
        return null;
    }
    try out.appendSlice(allocator, code[i..]);
    return try out.toOwnedSlice(allocator);
}

/// hash 치환 후 chunk 별 sourcemap 마무리. chunk loop 는 모든 chunk 의
/// builder 를 그대로 보관만 하고 mode 결정 (eager / lazy / inline_) 은 본
/// 함수에 단일화:
/// - lazy + (linked|external): builder 그대로 sourcemap_builder 유지 (caller 가
///   호출 시점에 generateJSON)
/// - eager + (linked|external): generateJSONOwned(out.path) → sourcemap, builder destroy
/// - inline_: lazy 옵션 무시하고 항상 eager — generateJSONOwned(out.path) →
///   base64 + contents 끝에 embed, sourcemap=null, builder destroy. base64 가
///   contents 안에 들어가야 하므로 emit 단계 JSON 이 필수.
///
/// `out.path` 가 hash 치환 완료 상태라 sourcemap "file" 필드에 정확한
/// final filename 이 들어가고, placeholder 치환 full-scan 불필요 (#2661).
fn finalizeChunkSourceMaps(
    allocator: std.mem.Allocator,
    outputs: []OutputFile,
    sm_options: SourceMap.SourceMapOptions,
) !void {
    for (outputs) |*out| {
        const builder = out.sourcemap_builder orelse continue;

        // inline_ 는 항상 eager 강제 (base64 가 contents 안에 들어가야 하므로
        // emit 단계 JSON 필요).
        const effective_lazy = sm_options.lazy and sm_options.mode != .inline_;
        if (effective_lazy) continue;

        const json = try builder.generateJSONOwned(out.path);
        // builder 는 이제 사용 끝 — destroy.
        builder.destroy(allocator);
        out.sourcemap_builder = null;

        switch (sm_options.mode) {
            .linked, .external => {
                // linked 의 sourceMappingURL 주석은 chunk loop 에서 contents 에
                // 부착됨. external 은 주석 없음. 둘 다 sourcemap JSON 만 보관.
                out.sourcemap = json;
            },
            .inline_ => {
                // base64 embed → contents 끝에 sourceMappingURL=data: 주석 append.
                // contents 는 owned slice 라 새 ArrayList 로 복사 후 helper 로
                // base64 부착. helper 가 json 을 consume (free) — caller (이 함수)
                // 의 free 책임 해제. slot 은 따로 추적 안 해도 됨 (json 변수
                // 이후 미사용).
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                try buf.appendSlice(allocator, out.contents);
                try SourceMap.appendSourceMappingURLComment(&buf, allocator, .{
                    .mode = .inline_,
                    .inline_json = json,
                }, null);
                allocator.free(out.contents);
                out.contents = try buf.toOwnedSlice(allocator);
                out.sourcemap = null;
            },
        }
    }
}

const PlaceholderInfo = struct {
    placeholder: [HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN]u8,
    real_hash: [HASH_PLACEHOLDER_LEN]u8,
};

/// content hash 계산 + placeholder 치환 (2패스).
/// 모든 청크의 출력이 완성된 후 호출.
/// 각 청크의 placeholder hash를 content hash로 교체한다.
fn resolveContentHashes(
    allocator: std.mem.Allocator,
    outputs: []OutputFile,
    sorted_indices: []const usize,
    chunk_graph: *const ChunkGraph,
    restrict_to_chunk: ?usize,
) !void {
    if (outputs.len == 0) return;

    // 1단계: 각 청크의 placeholder hash와 content hash를 계산.
    // emitChunks 가 `chunk.modules.items.len == 0` 청크(mergeSmallChunks /
    // manualChunks 흡수 후 빈 entry chunk 등)를 skip 하므로 sorted_indices
    // 와 outputs 는 1:1 이 아니다. *비어있지 않은* 청크만 outputs 순서대로
    // 매칭해야 path 의 placeholder 가 올바른 chunk index hash 로 빌드되어
    // 치환된다.
    var infos = try allocator.alloc(PlaceholderInfo, outputs.len);
    defer allocator.free(infos);

    var chunks_to_outputs = try allocator.alloc(usize, outputs.len);
    defer allocator.free(chunks_to_outputs);

    var out_idx: usize = 0;
    for (sorted_indices) |ci| {
        if (out_idx >= outputs.len) break;
        const chunk = &chunk_graph.chunks.items[ci];
        // emit 루프와 *동일* predicate(공유 헬퍼) — outputs↔sorted_indices 정렬 유지.
        if (chunkRestrictSkip(chunk, ci, restrict_to_chunk)) continue;

        buildPlaceholder(chunk, &infos[out_idx].placeholder);
        contentHash(outputs[out_idx].contents, &infos[out_idx].real_hash);
        chunks_to_outputs[out_idx] = ci;
        out_idx += 1;
    }

    // 2단계: 모든 출력에서 모든 placeholder를 content hash로 단일패스 치환.
    // O(N*M) → O(M) (M=content 길이, N=청크 수).
    // `infos[0..out_idx]` 슬라이스로 매칭 — 빈 청크 skip 으로 미초기화 trailing
    // entry 가 생기는 경우(현재 invariant 상 미발생, 미래 predicate drift 가드)
    // 가 replaceAllPlaceholders 의 byte-window 매칭에서 garbage 와 충돌해 silent
    // corruption 을 일으키지 않게 한다. chunks_to_outputs[0..out_idx] 슬라이싱과
    // 동형.
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN;
    const infos_init = infos[0..out_idx];
    for (outputs) |*out| {
        // contents: 모든 placeholder를 한 번의 스캔으로 치환
        const new_contents = try replaceAllPlaceholders(allocator, out.contents, infos_init, ph_total);
        allocator.free(out.contents);
        out.contents = new_contents;

        // path도 동일하게 치환
        const new_path = try replaceAllPlaceholders(allocator, out.path, infos_init, ph_total);
        allocator.free(out.path);
        out.path = new_path;

        // sourcemap 은 finalizeChunkSourceMaps 가 hash 치환 후 final filename 으로
        // generate — 이 시점엔 builder 만 있고 generate 안 된 상태 (#2661).
    }

    // 3단계: imports 메타 채우기 (rolldown `chunk.imports` 호환).
    // path 가 content-hash 까지 확정된 이후에 각 chunk 의 cross_chunk_imports 를
    // 최종 filename 배열로 변환. 1단계의 `chunks_to_outputs` (out_idx → chunk_idx)
    // 를 역매핑해 빈 청크 skip 과 일관된 매핑을 유지한다.
    var chunk_to_out = try allocator.alloc(?usize, chunk_graph.chunks.items.len);
    defer allocator.free(chunk_to_out);
    @memset(chunk_to_out, null);
    for (chunks_to_outputs[0..out_idx], 0..) |ci, oi| {
        chunk_to_out[ci] = oi;
    }

    for (chunks_to_outputs[0..out_idx], 0..) |ci, oi| {
        const chunk = &chunk_graph.chunks.items[ci];
        if (chunk.cross_chunk_imports.items.len == 0) continue;

        var imps: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (imps.items) |p| allocator.free(p);
            imps.deinit(allocator);
        }
        for (chunk.cross_chunk_imports.items) |dep_ci| {
            const dep_out = chunk_to_out[@backingInt(dep_ci)] orelse continue;
            try imps.append(allocator, try allocator.dupe(u8, outputs[dep_out].path));
        }
        outputs[oi].imports = try imps.toOwnedSlice(allocator);
    }
}

/// 최종 content hash 길이 (8자리 hex) — 출력 파일명에 들어가는 hash.
const HASH_PLACEHOLDER_LEN = 8;
/// **중간** placeholder 의 hash 부분 길이 (16자리 hex = full u64 chunkIndexHash). 출력 전 content
/// hash 로 치환되므로 사용자에게 안 보인다. content hash(8)보다 넓게 둬 chunkIndexHash 를 u32 로
/// 절단하지 않는다 — 절단 시 두 청크가 low-32 충돌하면 같은 placeholder 가 돼 cross-chunk import
/// 가 잘못 치환(silent mislink)됐다(#4353). replaceAllPlaceholders 는 이미 길이변경 치환 지원.
const PLACEHOLDER_HASH_LEN = 16;
/// placeholder 구분 문자열. 최종 출력에서 content hash로 치환된다.
/// 다른 코드에서 절대 등장하지 않을 문자열을 사용.
const HASH_PLACEHOLDER_PREFIX = "\x00ZH";

/// 청크의 인덱스 해시로 placeholder 바이트를 생성한다.
/// chunkPlaceholderStem과 resolveContentHashes에서 공용.
fn buildPlaceholder(chunk: *const Chunk, ph: *[HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN]u8) void {
    @memcpy(ph[0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX);
    const idx_hash = chunkIndexHash(chunk);
    // full u64 를 16-hex 로 — u32 절단 시 low-32 충돌로 placeholder 가 겹쳐 오치환됐다(#4353).
    _ = std.fmt.bufPrint(ph[HASH_PLACEHOLDER_PREFIX.len..], "{x:0>16}", .{idx_hash}) catch unreachable;
}

/// ASCII JS 식별자 여부(보수적: 비-ASCII 는 false → 호출부가 quote, 객체
/// 키로 항상 합법이라 안전). 빈 문자열 false.
fn isAsciiJsIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const ok = (c == '_' or c == '$' or
            (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (i > 0 and c >= '0' and c <= '9'));
        if (!ok) return false;
    }
    return true;
}

/// IIFE splitting 의 청크 레지스트리 키(allocator 소유).
/// - entry/dynamic 청크: entry 모듈의 안정 모듈 ID(module_id, relative-path).
///   동적 import 재작성·소비자가 같은 ID 로 `__zntc_require` 한다.
/// - common/manual 청크: 단일 boundary 모듈이 없음 → 청크 placeholder stem
///   (결정적, 청크=레지스트리 단위; 소비자는 named destructure). stem 안의
///   hash placeholder 는 resolveContentHashes 가 self-register 키·소비자
///   `__zntc_require` 인자 양쪽을 같은 최종 해시로 치환 → 일관.
fn chunkRegistryId(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    graph: *const ModuleGraph,
    id_root: ?[]const u8,
    options: *const EmitOptions,
) ![]const u8 {
    switch (chunk.kind) {
        .entry_point => |info| {
            if (graph.getModule(info.module)) |m|
                return module_id.moduleId(allocator, m.path, id_root);
        },
        .common, .manual => {},
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try chunkPlaceholderStem(chunk, &buf, allocator, options);
    return allocator.dupe(u8, buf.items);
}

/// 청크의 placeholder stem을 caller 가 소유한 `out` ArrayList 에 채운다 (확장자 없음).
/// cross-chunk import 등 content가 아직 없는 시점에서 사용.
/// 최종 출력 시 placeholder를 content hash로 치환한다.
///
/// **PR B-4b-1: stack buf → ArrayList** — caller 가 loop 안에서 `out` 을 reuse
/// 하면 단일 alloc amortize, capacity 자동 grow 로 deep monorepo 경로 truncate
/// 0. 결과는 `out.items` 로 caller 가 슬라이스 참조 (out 가 살아있는 동안 유효).
///
/// **현재 정책 (PR B-4a)**: `[dir]` 토큰을 `chunk.name_dir` 로 채운다(PR B-1
/// 의 sanitize 거친 안전한 entry-relative dir; null/`""` 면 빈 dir 분기로
/// leading-slash skip). default 패턴엔 `[dir]` 가 없어 사용자 영향 0 — 사용자가
/// 명시적으로 `[dir]` 토큰을 entry_names/chunk_names 에 넣었을 때만 활성화.
/// (`chunk.rel_dir` 은 preserve-modules 의 *절대 경로+파일명+ext* misnomer 라
/// 사용 금지 — `chunk.name_dir` 은 PR B-1 이 도입한 분리된 안전 필드.)
/// 청크를 출력(outputs)에서 제외하는지 단일 판정. emit 루프와 resolveContentHashes 가
/// *동일* 하게 호출해야 outputs↔sorted_indices 매핑이 어긋나지 않는다(placeholder 치환
/// 누락 방지).
///   - `restrict_to_chunk`(PR-3b-i) 가 있으면 그 인덱스 청크 *하나만* 남기고 전부 skip.
///     지정 청크는 lazy seed 라도 force-emit(on-demand 로 파싱된 단일청크) — 비어있을
///     때만 skip.
///   - 없으면 비워진 청크(mergeSmallChunks/manualChunks 흡수) + PR-3a-ii lazy seed
///     (미파싱, on-demand)를 제외.
/// PR-3b-ii: lazy 시 reg(IIFE/CJS) entry 청크가 hoisted 모듈들의 export 를 *local(deconflict)
/// name* 으로 전부 노출한다 (`exports.<local> = <local>;`). on-demand 동적 청크가 시작 시
/// 어떤 export 를 참조할지 몰라도(seed 미파싱) 찾을 수 있게 — demand-driven(chunk.exports_to)
/// 이 아니라 export-all 이라 seed force-parse 유무와 무관히 결정적(초기 lazy 빌드와 동일).
/// local name 키잉으로 동명 export(shared.v + dup.v, deconflict 로 local 구별) 충돌 회피.
/// Direct local alias는 exact binding의 canonical local 이름으로 노출한다. Re-export는 현재
/// 모듈에 local binding을 만들지 않으므로 건너뛴다. consumer는 canonical source의 실제 local
/// 키를 요청하고, source가 다른 chunk에 있으면 그 provider가 자기 local 키를 노출한다.
/// `re_export_namespace`는 별도 namespace local을 가지므로 계속 포함한다.
/// entry 모듈 자신의 export 는 emitCjsEntryExports 담당 → 제외.
fn lazyEntryExportAllHasLocalBinding(kind: ExportBinding.Kind) bool {
    return kind != .re_export_star and kind != .re_export;
}

fn emitLazyEntryExportAll(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    graph: *const ModuleGraph,
    linker: ?*Linker,
    sorted_mods: []const ModuleIndex,
    entry_mod_idx: usize,
    module_count: usize,
    minify_whitespace: bool,
) !void {
    const l = linker orelse return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var seen_namespace_owners: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen_namespace_owners.deinit(allocator);
    var locals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer locals.deinit(allocator);
    for (sorted_mods) |mod_idx| {
        const mi = @backingInt(mod_idx);
        if (mi >= module_count or mi == entry_mod_idx) continue;
        const m = graph.getModule(mod_idx) orelse continue;
        for (m.export_bindings) |eb| {
            if (eb.kind == .re_export_star) continue;
            // A namespace re-export has no source local binding. Its exact owner is the
            // resolved target module's generated shared namespace object. In lazy mode that
            // object is the provider key consumed by the dynamic chunk; forwarding the
            // re-export spelling here (`exports.api = api`) refers to a local that does not
            // exist and loses owner identity when several modules export `api`.
            if (chunk_mod.nsReExportTarget(graph, mod_idx, eb.exported_name)) |target| {
                const target_index = target.toU32();
                _ = try l.ensureSharedNsVar(target);
                const output_ref = l.sharedNamespaceOutputRef(target) orelse return error.SharedNamespaceOwnerMissing;
                if (l.getSharedNamespaceGlobalName(output_ref)) |global_name| {
                    const owner_seen = try seen_namespace_owners.getOrPut(allocator, target_index);
                    if (owner_seen.found_existing) continue;
                    const key_seen = try seen.getOrPut(allocator, global_name);
                    if (key_seen.found_existing) continue;
                    try locals.append(allocator, global_name);
                    continue;
                }

                // If this namespace is local to the current chunk, no cross-chunk generated
                // name exists. Read the export from its module namespace getter instead of
                // naming the non-existent `export * as` local.
                const gop = try seen.getOrPut(allocator, eb.exported_name);
                if (gop.found_existing) continue;
                const namespace_exports = try m.allocExportsName(allocator, &l.rename_table);
                defer allocator.free(namespace_exports);
                try out.appendSlice(allocator, "exports.");
                try out.appendSlice(allocator, eb.exported_name);
                try out.appendSlice(allocator, if (minify_whitespace) "=" else " = ");
                try out.appendSlice(allocator, namespace_exports);
                try out.appendSlice(allocator, ".");
                try out.appendSlice(allocator, eb.exported_name);
                try out.appendSlice(allocator, if (minify_whitespace) ";" else ";\n");
                continue;
            }
            if (eb.kind == .re_export_namespace) continue;
            // Ordinary named re-exports do not define a local in this module. Their canonical
            // source owner is visited separately, so only local bindings reach the fallback.
            if (!lazyEntryExportAllHasLocalBinding(eb.kind)) continue;
            // 노출 키 = ExportBinding의 exact local identity. Name lookup은 anonymous
            // default facade와 같은 이름의 source binding을 혼동할 수 있다.
            const local = l.getCanonicalForExport(eb, @intCast(mi)) orelse return error.InvalidCrossChunkExport;
            if (local.len == 0) continue;
            const gop = try seen.getOrPut(allocator, local);
            if (gop.found_existing) continue;
            try locals.append(allocator, local);
        }
    }
    std.mem.sort([]const u8, locals.items, {}, types.stringLessThan); // 결정론
    for (locals.items) |local| {
        try out.appendSlice(allocator, "exports.");
        try out.appendSlice(allocator, local);
        try out.appendSlice(allocator, if (minify_whitespace) "=" else " = ");
        try out.appendSlice(allocator, local);
        try out.appendSlice(allocator, if (minify_whitespace) ";" else ";\n");
    }
}

test "lazy entry export-all includes only bindings owned by the current module" {
    try std.testing.expect(lazyEntryExportAllHasLocalBinding(.local));
    try std.testing.expect(!lazyEntryExportAllHasLocalBinding(.re_export));
    try std.testing.expect(!lazyEntryExportAllHasLocalBinding(.re_export_star));
    try std.testing.expect(lazyEntryExportAllHasLocalBinding(.re_export_namespace));
}

/// dev_split(wrap-all) 동적 청크의 entry 모듈(=`import()` 타겟) export 를 청크 `exports` 에
/// **exported_name 키**로 노출한다. RFC_LAZY_DEV_MODULE_HMR PR-2 wrap-all 이후, 동적 청크의
/// entry 모듈이 `__esm` 래핑되어 emitModule 의 emitCjsEntryExports 경로(emitter.zig:2136, CJS/
/// iife_split factory 한정)를 안 탄다 → `__zntc_require("<chunk>")`(= `import('./route')` 결과)
/// 에 entry export(예: `render`)가 없어 `m.render is not a function` (#4079 e2e 회귀). emitLazy-
/// EntryExportAll 은 entry 를 *제외*(소비자가 local-name 으로 참조하는 hoisted dep 용)하므로 여기서
/// entry 만 별도로, 소비자 `import().x` 가 쓰는 exported_name 키로 깐다.
///
/// 값은 entry 모듈의 **네임스페이스 객체(`exports_<entry>`) getter** 로 가져온다 — `__export`
/// getter 가 local·`export { x } from`(re_export)·`export * as ns`(re_export_namespace)·
/// `export * from`(re_export_star)을 모두 chunk-로컬로 정확 해석하므로, exported_name 키로
/// `exports.<name> = <ns>.<name>` 만 깔면 된다. (예전엔 `.local` 만 + local-name 으로 깔아
/// re-export forwarding 동적 route 의 export 가 누락됐다.)
///
/// 이름 집합은 `collectExportsRecursive`(entry 의 effective export = local·re_export·
/// re_export_namespace + `export * from` 의 재귀 전개)로 열거 — `__export` 가 깐 getter 와
/// 동일 집합이라 모두 닿는다. 예전엔 export_bindings 만 돌며 re_export_star 를 skip 해
/// `export * from` 의 star 이름이 동적 청크 exports 에서 누락됐다(#2).
///
/// 전제: entry 가 **ESM 래핑**(`wrap_kind == .esm`, `var exports_<entry>` 선언)이라는 것.
/// dev_split 은 `exports_kind.isEsm()` 모듈을 전부 .esm 으로 강제(graph/finalize.zig:124)하므로
/// **정적 export 를 가진 web dev_split entry 는 항상 .esm** = `exports_<entry>` 보장. 정적
/// export 가 없는 순수 CJS 는 아래 early-return(`export_bindings.len == 0`)로 빠진다. (RN 의
/// mixed-module .cjs 동적 entry 만 이 전제 밖 — pre-existing 한계로 별도 추적, 본 함수 범위 외.)
fn emitWrappedDynamicEntryExports(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    graph: *const ModuleGraph,
    linker: ?*Linker,
    entry_mod_idx: usize,
    minify_whitespace: bool,
) !void {
    const l = linker orelse return;
    const m = graph.getModule(ModuleIndex.fromUsize(entry_mod_idx)) orelse return;
    if (m.export_bindings.len == 0) return;
    // entry 모듈의 네임스페이스 객체(`exports_<entry>`) — `__export` 가 깐 getter 가 local/
    // re-export/namespace-re-export 를 모두 chunk-로컬로 정확 해석. init 트리거가 위에서 entry
    // 포함 모든 모듈 init 을 돌려 네임스페이스를 채운 뒤라 스냅샷 값 정확.
    const ns = try m.allocExportsName(allocator, &l.rename_table);
    defer allocator.free(ns);
    // entry 의 effective export 를 collectExportsRecursive 로 전부 열거 — local·
    // `export {x} from`(re_export)·`export * as ns`(re_export_namespace) + `export * from`
    // (re_export_star) 의 재귀 전개 이름까지 포함. `__export(exports_<entry>, {...})` 가 깐
    // getter 와 동일 집합이라 `exports.<name> = <ns>.<name>` 가 항상 닿는다. 예전엔
    // export_bindings 만 돌며 re_export_star 를 skip 해 `export * from` 의 star 이름이
    // 동적 청크 exports 에서 누락됐다(#2: `import('./route').<star_name>`=undefined).
    var exps: std.ArrayList(Linker.NsExportPair) = .empty;
    var seen_e: std.StringHashMapUnmanaged(void) = .empty;
    var visited_e: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer {
        for (exps.items) |e| if (e.owned) l.allocator.free(e.local);
        exps.deinit(l.allocator);
        seen_e.deinit(l.allocator);
        visited_e.deinit(l.allocator);
    }
    try l.collectExportsRecursive(&exps, &seen_e, &visited_e, ModuleIndex.fromUsize(entry_mod_idx), 0);
    for (exps.items) |pair| {
        if (pair.exported.len == 0) continue;
        // exports.<name> = <ns>.<name> — 네임스페이스 getter 가 local/re-export/star 정확 해석.
        // (스냅샷: 가변 바인딩이 init 후 재할당돼도 갱신 안 됨 — 라우트엔 사실상 함수/const 라 무관.)
        try out.appendSlice(allocator, "exports.");
        try out.appendSlice(allocator, pair.exported);
        try out.appendSlice(allocator, if (minify_whitespace) "=" else " = ");
        try out.appendSlice(allocator, ns);
        try out.appendSlice(allocator, ".");
        try out.appendSlice(allocator, pair.exported);
        try out.appendSlice(allocator, if (minify_whitespace) ";" else ";\n");
    }
}

fn chunkRestrictSkip(chunk: *const Chunk, ci: usize, restrict_to_chunk: ?usize) bool {
    if (restrict_to_chunk) |r| {
        if (ci != r) return true;
        return chunk.modules.items.len == 0;
    }
    return chunk.modules.items.len == 0 or chunk.is_lazy_seed;
}

/// Filename authority shared by physical output and importer location. A PM
/// facade's implementation uses an allocated chunk path, not its source path.
fn appendChunkOutputPath(chunk: *const Chunk, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, options: *const EmitOptions) !void {
    out.clearRetainingCapacity();
    if (chunk.explicit_file_name) |path| return out.appendSlice(allocator, path);
    if (options.preserve_modules and chunk.rel_dir != null) {
        const path = try computePreserveModulesPath(allocator, chunk.rel_dir.?, options.out_extension_js orelse ".js", options.preserve_modules_root);
        defer allocator.free(path);
        return out.appendSlice(allocator, path);
    }
    try chunkPlaceholderStem(chunk, out, allocator, options);
    try out.appendSlice(allocator, options.out_extension_js orelse ".js");
}

fn chunkPlaceholderStem(
    chunk: *const Chunk,
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    options: *const EmitOptions,
) !void {
    // Rollup parity — 청크 종류별 패턴 적용:
    // - *static* entry (사용자 `entryPoints` 로 명시): entry_names + name_dir
    // - *dynamic* entry (`import()` 로 생성된 entry chunk, `is_dynamic=true`):
    //   chunk_names + dir 강제 "" (Rollup `chunkFileNames`)
    // - manualChunks / common: chunk_names + dir 강제 ""
    const is_static_entry = switch (chunk.kind) {
        .entry_point => |ep| !ep.is_dynamic,
        else => false,
    };
    const base_name = chunk.name orelse "chunk";
    const pattern = if (is_static_entry) options.entry_names else options.chunk_names;
    // static entry 만 name_dir 사용 — dynamic/manual/common 은 entry-relative
    // dir 의미 약함 + Rollup `chunkFileNames` 도 dir 토큰 미사용.
    const dir = if (is_static_entry) (chunk.name_dir orelse "") else "";

    // PR-3a-ii / #4079: lazy 빌드의 동적 import 타겟 청크는 `[hash]` 를 경로 기반 안정 hash 로
    // 치환한다(content-hash placeholder \x00ZH prefix 가 없어 resolveContentHashes 가 건드리지
    // 않음 → 안정 이름). lazy seed(미파싱)는 content-hash 불가라 필수고, force-parse 된 동적 타겟
    // (본문 있음·emit 됨)도 같은 path-hash 를 써 entry 의 __zntc_load_chunk URL 이 lazy↔force-parse
    // 전환에 불변(#4079). `use_lazy_path_name` = is_lazy_seed ∪ (lazy 빌드 동적 타겟).
    if (chunk.use_lazy_path_name) {
        var path_hash: [HASH_PLACEHOLDER_LEN]u8 = undefined;
        _ = std.fmt.bufPrint(&path_hash, "{x:0>8}", .{@as(u32, @truncate(chunk.lazy_path_hash))}) catch unreachable;
        try applyNamingPatternWithDir(out, allocator, pattern, base_name, &path_hash, dir);
        return;
    }

    var hash_buf: [HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN]u8 = undefined;
    buildPlaceholder(chunk, &hash_buf);

    try applyNamingPatternWithDir(out, allocator, pattern, base_name, &hash_buf, dir);
}

/// 모듈 인덱스 기반 해시 (placeholder 식별자용, content hash 아님).
fn chunkIndexHash(chunk: *const Chunk) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var sort_buf: [256]u32 = undefined;
    const mod_count = @min(chunk.modules.items.len, 256);
    for (chunk.modules.items[0..mod_count], sort_buf[0..mod_count]) |mod_idx, *sb| {
        sb.* = @backingInt(mod_idx);
    }
    std.mem.sort(u32, sort_buf[0..mod_count], {}, std.sort.asc(u32));
    for (sort_buf[0..mod_count]) |idx| {
        hasher.update(std.mem.asBytes(&idx));
    }
    return hasher.final();
}

/// content hash 계산: 청크의 최종 출력 코드를 Wyhash하여 8자리 hex 반환.
/// placeholder 바이트를 건너뛰어 자기 참조 순환을 방지한다.
pub fn contentHash(content: []const u8, buf: *[HASH_PLACEHOLDER_LEN]u8) void {
    // ph_total 은 *placeholder* 를 건너뛰기 위한 폭이므로 PLACEHOLDER_HASH_LEN(16). 출력 buf 는
    // content hash 폭(HASH_PLACEHOLDER_LEN=8) 유지.
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN;
    var hasher = std.hash.Wyhash.init(0);
    var i: usize = 0;
    var run_start: usize = 0; // 현재 non-placeholder 구간의 시작
    while (i < content.len) {
        if (i + ph_total <= content.len and
            std.mem.eql(u8, content[i..][0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX))
        {
            // placeholder 앞까지의 구간을 벌크 해싱
            if (i > run_start) hasher.update(content[run_start..i]);
            i += ph_total;
            run_start = i;
        } else {
            i += 1;
        }
    }
    // 마지막 구간 벌크 해싱
    if (i > run_start) hasher.update(content[run_start..i]);
    const h = hasher.final();
    _ = std.fmt.bufPrint(buf, "{x:0>8}", .{@as(u32, @truncate(h))}) catch unreachable;
}

/// 모든 placeholder를 단일패스로 치환한다.
/// input을 1회 스캔하면서 "\x00ZH" prefix를 만나면 infos에서 매칭하여 real_hash로 치환.
fn replaceAllPlaceholders(allocator: std.mem.Allocator, input: []const u8, infos: []const PlaceholderInfo, ph_total: usize) ![]const u8 {
    // placeholder가 있는지 빠르게 확인 (없으면 복사만)
    if (std.mem.indexOf(u8, input, HASH_PLACEHOLDER_PREFIX) == null) {
        return try allocator.dupe(u8, input);
    }

    // 최대 크기: 원본과 동일 (placeholder가 real_hash보다 길어서 줄어듦)
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var run_start: usize = 0;
    while (i + ph_total <= input.len) {
        if (std.mem.eql(u8, input[i..][0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX)) {
            // run_start..i 까지의 일반 텍스트 복사
            try result.appendSlice(allocator, input[run_start..i]);
            // infos에서 매칭하는 placeholder 찾기
            const ph_bytes = input[i..][0..ph_total];
            var found = false;
            for (infos) |info| {
                if (std.mem.eql(u8, ph_bytes, &info.placeholder)) {
                    try result.appendSlice(allocator, &info.real_hash);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // 매칭 안 되면 원본 유지
                try result.appendSlice(allocator, ph_bytes);
            }
            i += ph_total;
            run_start = i;
        } else {
            i += 1;
        }
    }
    // 나머지 복사
    try result.appendSlice(allocator, input[run_start..]);
    return result.toOwnedSlice(allocator);
}

/// 단일 placeholder를 실제 content hash로 치환한다.
/// 반환값은 allocator 소유.
fn replacePlaceholders(allocator: std.mem.Allocator, input: []const u8, placeholder_hash: []const u8, real_hash: []const u8) ![]const u8 {
    // placeholder_hash는 "\x00ZH" + 16hex, real_hash는 8hex
    // 치환 대상: placeholder_hash 전체 → real_hash
    const ph_len = HASH_PLACEHOLDER_PREFIX.len + PLACEHOLDER_HASH_LEN;
    if (placeholder_hash.len != ph_len) return try allocator.dupe(u8, input);

    // 치환 횟수 카운트
    var count: usize = 0;
    var pos: usize = 0;
    while (pos + ph_len <= input.len) {
        if (std.mem.eql(u8, input[pos..][0..ph_len], placeholder_hash)) {
            count += 1;
            pos += ph_len;
        } else {
            pos += 1;
        }
    }
    if (count == 0) return try allocator.dupe(u8, input);

    // 새 버퍼 할당 + 치환
    const new_len = input.len - count * ph_len + count * real_hash.len;
    const result = try allocator.alloc(u8, new_len);
    var src: usize = 0;
    var dst: usize = 0;
    while (src < input.len) {
        if (src + ph_len <= input.len and
            std.mem.eql(u8, input[src..][0..ph_len], placeholder_hash))
        {
            @memcpy(result[dst..][0..real_hash.len], real_hash);
            dst += real_hash.len;
            src += ph_len;
        } else {
            result[dst] = input[src];
            dst += 1;
            src += 1;
        }
    }
    return result;
}

/// naming pattern을 적용한다.
/// [name] → base_name, [hash] → hash_str 로 치환. caller 가 소유한 `out`
/// ArrayList 에 결과를 append (clearRetainingCapacity 로 시작 — caller 가
/// loop 안에서 reuse 가능, 단일 alloc amortize).
/// [dir] 토큰을 지원하려면 `applyNamingPatternWithDir` 를 사용한다 — 이
/// 4-arg 변형은 dir = "" 로 위임하므로 패턴에 [dir] 가 있어도 빈 dir 정리
/// 규칙(leading-slash 제거)이 동일 적용된다.
///
/// **PR B-4b-1: stack buf → ArrayList 전환** (`[]u8` slice 시그니처는 deep
/// monorepo 경로 시 silent truncate 위험). capacity 자동 grow 로 100% 안전 +
/// caller reuse 로 단일 alloc amortize → typical 빌드 영향 0.
pub fn applyNamingPattern(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    pattern: []const u8,
    name: []const u8,
    hash_str: []const u8,
) !void {
    return applyNamingPatternWithDir(out, allocator, pattern, name, hash_str, "");
}

/// `applyNamingPattern` 의 [dir] 토큰 지원 변형.
/// [name] → name, [hash] → hash_str, [dir] → dir 로 치환.
/// dir 안 Windows 백슬래시는 URL 구분자 `/` 로 정규화한다.
///
/// **빈 dir 정리 규칙** — esbuild 와 동일 의미:
/// [dir] 가 빈 문자열로 치환될 때, 토큰 *바로 다음* 문자가 `/` 면 그
/// 슬래시도 함께 skip 한다. 단일 entry 가 cwd 루트에 있거나(entry_dir
/// 미설정) 패턴이 `dist/[dir]/[name]` 같이 중간에 [dir] 가 있을 때
/// leading/double-slash 가 생기지 않도록.
///
/// caller 가 `out` 소유 — 매 호출 `clearRetainingCapacity()` 로 시작.
/// 결과는 `out.items` 로 caller 가 슬라이스 참조 (out 가 살아있는 동안 유효).
pub fn applyNamingPatternWithDir(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    pattern: []const u8,
    name: []const u8,
    hash_str: []const u8,
    dir: []const u8,
) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + "[name]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[name]".len], "[name]")) {
            try out.appendSlice(allocator, name);
            i += "[name]".len;
        } else if (i + "[hash]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[hash]".len], "[hash]")) {
            try out.appendSlice(allocator, hash_str);
            i += "[hash]".len;
        } else if (i + "[dir]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[dir]".len], "[dir]")) {
            if (dir.len > 0) {
                try out.ensureUnusedCapacity(allocator, dir.len);
                for (dir) |c| {
                    out.appendAssumeCapacity(if (c == '\\') '/' else c);
                }
                i += "[dir]".len;
            } else {
                // 빈 dir — 토큰만 skip + 인접한 '/' 도 함께 skip (esbuild parity).
                i += "[dir]".len;
                if (i < pattern.len and pattern[i] == '/') i += 1;
            }
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
}

/// used_names 사전 계산 결과.
pub const UsedNamesEntry = struct {
    names: []const []const u8,
    all_used: bool, // true이면 emitModule에 null 전달 (모든 export 사용)
};

/// `export * as X from './src'` 재export 소비자가 모두 precise(namespace_used_properties 설정)이면 true.
/// 하나라도 null(opaque)이거나 소비자 0명이면 false — 호출자가 전체 fallback 사용.
fn areAllReExportNsConsumersPrecise(
    graph: *const ModuleGraph,
    reexporter_idx: u32,
    reexport_name: []const u8,
) bool {
    var it = graph.modulesIterator();
    while (it.next()) |consumer| {
        for (consumer.import_bindings) |ib| {
            if (!Linker.isReExportNsConsumer(consumer.*, ib, reexporter_idx, reexport_name)) continue;
            if (ib.namespace_used_properties == null) return false;
        }
    }
    // 소비자 0명이면 기본 true — 아무도 안 쓰는 re-export이므로 markAll 불필요.
    return true;
}

/// 모든 모듈의 used_names를 사전 계산한다 (순차).
/// tree-shaking의 used export names 로직을 emit 루프에서 분리.
pub fn computeAllUsedNames(
    allocator: std.mem.Allocator,
    sorted: []*const Module,
    graph: *const ModuleGraph,
    shaker: ?*const TreeShaker,
) ![]UsedNamesEntry {
    var list = try allocator.alloc(UsedNamesEntry, sorted.len);
    for (list) |*e| e.* = .{ .names = &.{}, .all_used = true };

    const s = shaker orelse return list;

    // ── 역방향 룩업 맵 사전 구축 ──
    // target_module_index → 해당 모듈을 import하는 바인딩 목록
    // 기존: 매 모듈의 export마다 모든 importer × 모든 binding을 순회 (O(n × e × i × b))
    // 최적화: 맵을 한 번 구축하여 O(1) 룩업 (O(n × relevant_bindings))
    const RevKind = enum {
        import_binding_named,
        import_binding_other,
        re_export,
        /// `export * from './m'` (alias 없음).
        re_export_star,
        /// `export * as ns from './m'` (named namespace).
        re_export_namespace,
    };
    const RevEntry = struct {
        importer_module_index: u32,
        /// import_binding: imported_name / re_export: local_name (= 소스 모듈의 exported_name)
        imported_name: []const u8,
        /// import_binding: local_name (importer 내 바인딩 이름)
        local_name: []const u8,
        /// re_export_namespace의 노출 이름. 다른 kind에서는 사용되지 않음.
        exported_name: []const u8,
        kind: RevKind,
    };

    var reverse_map = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(RevEntry)).empty;
    defer {
        var it = reverse_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        reverse_map.deinit(allocator);
    }

    // 모든 모듈의 import_bindings + export_bindings(re-export)를 순회하여 역방향 맵 구축
    var mod_it = graph.modulesIterator();
    while (mod_it.next()) |importer| {
        const imp_i: u32 = importer.index.toU32();

        // export_bindings 중 re_export / re_export_all → 타겟 모듈로 역매핑
        for (importer.export_bindings) |ieb| {
            if (!ieb.kind.isReExportAll() and ieb.kind != .re_export) continue;
            const rec_idx = ieb.import_record_index orelse continue;
            if (rec_idx >= importer.import_records.len) continue;
            const target = importer.import_records[rec_idx].resolved;
            if (target == .none) continue;
            const target_i: u32 = @backingInt(target);
            const gop = try reverse_map.getOrPut(allocator, target_i);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const ieb_local = importer.exportBindingLocalName(ieb);
            try gop.value_ptr.append(allocator, .{
                .importer_module_index = imp_i,
                .imported_name = ieb_local,
                .local_name = ieb_local,
                .exported_name = ieb.exported_name,
                .kind = switch (ieb.kind) {
                    .re_export_star => .re_export_star,
                    .re_export_namespace => .re_export_namespace,
                    else => .re_export,
                },
            });
        }

        // import_bindings → 타겟 모듈로 역매핑
        for (importer.import_bindings) |ib| {
            if (ib.import_record_index >= importer.import_records.len) continue;
            const target = importer.import_records[ib.import_record_index].resolved;
            if (target == .none) continue;
            const target_i: u32 = @backingInt(target);
            const gop = try reverse_map.getOrPut(allocator, target_i);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{
                .importer_module_index = imp_i,
                .imported_name = ib.imported_name,
                .local_name = ib.local_name,
                .exported_name = "",
                .kind = if (ib.kind == .named) .import_binding_named else .import_binding_other,
            });
        }
    }

    const helper_modules = @import("../../runtime_helper_modules.zig");
    for (sorted, 0..) |m, idx| {
        const mod_idx: u32 = m.index.toU32();
        // #1961: ZNTC runtime helper virtual module 은 모든 export 가 항상 used.
        // tree_shaker 의 export-use 추적이 transformer 가 추가한 import_binding 을
        // 인식 못 하면 helper 정의가 statement_shaker 에 의해 dead 로 elide → 런타임
        // ReferenceError. helper module 은 작아서 over-include 안전.
        if (helper_modules.isVirtualId(m.path)) {
            list[idx] = .{ .names = &.{}, .all_used = true };
            continue;
        }
        // ALL_EXPORTS_SENTINEL 마킹이 있고 BFS reachable_stmts가 없으면 모든 export 사용
        if (s.isExportUsed(mod_idx, ALL_EXPORTS_SENTINEL) and s.getModuleStmtInfos(mod_idx) == null) {
            list[idx] = .{ .names = &.{}, .all_used = true };
            continue;
        }

        var names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        var all_used = false;

        // 현재 모듈을 타겟으로 하는 역방향 엔트리 (없으면 빈 슬라이스)
        const rev_entries: []const RevEntry = if (reverse_map.getPtr(mod_idx)) |entries_list|
            entries_list.items
        else
            &.{};

        for (m.export_bindings) |eb| {
            if (eb.kind.isReExportAll()) continue;
            if (!s.isExportUsed(mod_idx, eb.exported_name)) continue;

            // A local export name and its statement owner both depend on the
            // exact source carrier. If that proof is stale, emit the module
            // conservatively instead of deriving a replacement name from a
            // same-number SID.
            const needs_local_identity = eb.kind == .local or eb.symbol.semanticIndex() != null;
            const output_symbol = if (needs_local_identity)
                (m.exportBindingLocalNodeSemanticIndex(eb) orelse {
                    all_used = true;
                    break;
                })
            else
                null;

            // 크로스-모듈 BFS 도달성
            if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                if (output_symbol) |sym_idx| {
                    if (ts_infos.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
                        if (!s.isStmtReachable(mod_idx, stmt_idx)) continue;
                    }
                }
            }

            // StmtInfo 도달성: 모든 importer에서 이 export의 import가 dead이면 제외
            // 역방향 맵으로 O(relevant_bindings) 탐색
            if (eb.kind == .local and m.importers.items.len > 0) {
                const is_dead = is_dead: {
                    var found_any = false;
                    for (rev_entries) |re| {
                        switch (re.kind) {
                            // 모듈 전체를 re-export → dead 아님
                            .re_export_star, .re_export_namespace => break :is_dead false,
                            // re_export: imported_name이 이 export의 exported_name과 같으면 dead 아님
                            .re_export => {
                                if (std.mem.eql(u8, re.imported_name, eb.exported_name))
                                    break :is_dead false;
                            },
                            // import_binding: imported_name이 이 export의 exported_name과 매칭
                            .import_binding_named, .import_binding_other => {
                                if (!std.mem.eql(u8, re.imported_name, eb.exported_name)) continue;
                                found_any = true;
                                if (s.isImportLiveInModule(re.importer_module_index, re.local_name))
                                    break :is_dead false;
                            },
                        }
                    }
                    break :is_dead found_any;
                };
                if (is_dead) continue;
            }

            const eb_local = m.exportBindingLocalName(eb);
            names_buf.append(allocator, eb_local) catch {
                all_used = true;
                break;
            };
            if (!std.mem.eql(u8, eb.exported_name, eb_local)) {
                names_buf.append(allocator, eb.exported_name) catch {
                    all_used = true;
                    break;
                };
            }
        }

        if (!all_used) {
            // cross-module: importer의 named binding도 포함 (역방향 맵 활용)
            for (rev_entries) |re| {
                if (all_used) break;
                switch (re.kind) {
                    .re_export_star => {},
                    .re_export_namespace => {
                        // #1603 Phase 1b: 모든 소비자가 precise member 접근(namespace_used_properties
                        // 설정됨)이면 subset은 이미 line 957 루프에서 `isExportUsed` 기준으로 반영됨.
                        // 하나라도 opaque(null)이면 source 모듈 전체 export fallback.
                        if (!areAllReExportNsConsumersPrecise(graph, re.importer_module_index, re.exported_name)) {
                            all_used = true;
                        }
                    },
                    .re_export => {},
                    .import_binding_named => {
                        if (!s.isImportLiveInModule(re.importer_module_index, re.local_name)) continue;
                        names_buf.append(allocator, re.imported_name) catch {
                            all_used = true;
                            break;
                        };
                    },
                    .import_binding_other => {},
                }
            }
        }

        if (all_used) {
            names_buf.deinit(allocator);
            list[idx] = .{ .names = &.{}, .all_used = true };
        } else {
            list[idx] = .{
                .names = names_buf.toOwnedSlice(allocator) catch blk: {
                    // OOM: 내부 버퍼 해제 후 all_used 처리 (불완전한 이름 목록 방지)
                    names_buf.deinit(allocator);
                    break :blk &.{};
                },
                .all_used = false,
            };
        }
    }

    return list;
}

fn expectOutputNamesFailClosed(
    allocator: std.mem.Allocator,
    sorted: []*const Module,
    graph: *const ModuleGraph,
    shaker: *const TreeShaker,
    module_slot: usize,
) !void {
    const used_names = try computeAllUsedNames(allocator, sorted, graph, shaker);
    defer {
        for (used_names) |entry| if (!entry.all_used) allocator.free(entry.names);
        allocator.free(used_names);
    }
    try std.testing.expect(used_names[module_slot].all_used);
    try std.testing.expectEqual(@as(usize, 0), used_names[module_slot].names.len);
}

test "used output export names survive ten stale export SID carriers" {
    const test_helpers = @import("../test_helpers.zig");
    const resolve_cache_mod = @import("../resolve_cache.zig");
    const SymbolRef = @import("../symbol.zig").SymbolRef;
    const cases = [_]struct {
        provider: []const u8,
        export_name: []const u8,
        local_name: []const u8,
        import_name: []const u8,
    }{
        .{ .provider = "export const live = 1;\nconst decoy = 2;", .export_name = "live", .local_name = "live", .import_name = "live" },
        .{ .provider = "const live = 1;\nexport { live };\nconst decoy = 2;", .export_name = "live", .local_name = "live", .import_name = "live" },
        .{ .provider = "const live = 1;\nexport { live as publicLive };\nconst decoy = 2;", .export_name = "publicLive", .local_name = "live", .import_name = "publicLive" },
        .{ .provider = "export let live = 1;\nlet decoy = 2;", .export_name = "live", .local_name = "live", .import_name = "live" },
        .{ .provider = "export var live = 1;\nvar decoy = 2;", .export_name = "live", .local_name = "live", .import_name = "live" },
        .{ .provider = "export function live() { return 1; }\nfunction decoy() { return 2; }", .export_name = "live", .local_name = "live", .import_name = "live" },
        .{ .provider = "function live() { return 1; }\nexport { live as publicLive };\nfunction decoy() { return 2; }", .export_name = "publicLive", .local_name = "live", .import_name = "publicLive" },
        .{ .provider = "export class Live {}\nclass decoy {}", .export_name = "Live", .local_name = "Live", .import_name = "Live" },
        .{ .provider = "class Live {}\nexport { Live as PublicLive };\nclass decoy {}", .export_name = "PublicLive", .local_name = "Live", .import_name = "PublicLive" },
        .{ .provider = "const source = 1;\nexport { source as live };\nconst decoy = 2;", .export_name = "live", .local_name = "source", .import_name = "live" },
    };

    for (cases, 0..) |case, case_index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const entry_source = try std.fmt.allocPrint(
            std.testing.allocator,
            "import {{ {s} as used }} from './provider.mjs'; import './foreign.mjs'; console.log(used);",
            .{case.import_name},
        );
        defer std.testing.allocator.free(entry_source);
        try test_helpers.writeFile(tmp.dir, "entry.mjs", entry_source);
        try test_helpers.writeFile(tmp.dir, "provider.mjs", case.provider);
        try test_helpers.writeFile(tmp.dir, "foreign.mjs", case.provider);

        const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir_path);
        const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dir_path, "entry.mjs" });
        defer std.testing.allocator.free(entry_path);

        var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry_path});
        for (0..graph.moduleCount()) |module_index| {
            const module = graph.moduleAtMut(ModuleIndex.fromUsize(module_index)) orelse continue;
            if (std.mem.endsWith(u8, module.path, "provider.mjs") or
                std.mem.endsWith(u8, module.path, "foreign.mjs")) module.side_effects = false;
        }

        var linker = Linker.init(std.testing.allocator, &graph, .esm);
        defer linker.deinit();
        try linker.link();
        linker.populateImportSymbols();
        linker.populateNamespaceAccesses();
        var shaker = try TreeShaker.init(std.testing.allocator, &graph, &linker);
        defer shaker.deinit();
        try shaker.analyze(&.{entry_path});

        const provider_index: u32 = blk: {
            for (0..graph.moduleCount()) |module_index| {
                const module = graph.getModule(ModuleIndex.fromUsize(module_index)) orelse continue;
                if (std.mem.endsWith(u8, module.path, "provider.mjs")) break :blk @intCast(module_index);
            }
            return error.MissingProvider;
        };
        const foreign_index: u32 = blk: {
            for (0..graph.moduleCount()) |module_index| {
                const module = graph.getModule(ModuleIndex.fromUsize(module_index)) orelse continue;
                if (std.mem.endsWith(u8, module.path, "foreign.mjs")) break :blk @intCast(module_index);
            }
            return error.MissingForeignModule;
        };
        const provider = graph.moduleAtMut(ModuleIndex.fromUsize(provider_index)) orelse return error.MissingProvider;
        const foreign = graph.getModule(ModuleIndex.fromUsize(foreign_index)) orelse return error.MissingForeignModule;
        const binding = @constCast(provider.findExportBinding(case.export_name) orelse return error.MissingExportBinding);
        const semantic = if (provider.semantic) |*value| value else return error.MissingProviderSemantic;
        const live_symbol = provider.exportBindingSemanticIndex(binding.*) orelse return error.MissingLiveExportSymbol;
        const decoy_symbol = semantic.scope_maps[0].get("decoy") orelse return error.MissingDecoySymbol;
        const foreign_decoy_symbol = foreign.semantic.?.scope_maps[0].get("decoy") orelse return error.MissingForeignDecoySymbol;
        const infos = shaker.getModuleStmtInfos(provider_index) orelse return error.MissingProviderStmtInfos;
        const decoy_stmt = infos.declaredStmtBySymbol(@intCast(decoy_symbol)) orelse return error.MissingDecoyStatement;
        try std.testing.expect(!shaker.isStmtReachable(provider_index, decoy_stmt));
        try std.testing.expectEqual(@as(?u32, live_symbol), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        const original_symbol = binding.symbol;
        const original_anchor = binding.local_symbol_node;
        const original_kind = binding.kind;
        const original_symbol_ids = semantic.symbol_ids;
        defer {
            binding.symbol = original_symbol;
            binding.local_symbol_node = original_anchor;
            binding.kind = original_kind;
            semantic.symbol_ids = original_symbol_ids;
        }

        const sorted = try std.testing.allocator.alloc(*const Module, graph.moduleCount());
        defer std.testing.allocator.free(sorted);
        var provider_slot: ?usize = null;
        for (0..graph.moduleCount()) |module_index| {
            const current = graph.getModule(ModuleIndex.fromUsize(module_index)) orelse return error.MissingModule;
            sorted[module_index] = current;
            if (current == provider) provider_slot = module_index;
        }
        const slot = provider_slot orelse return error.MissingProviderSlot;
        {
            const baseline = try computeAllUsedNames(std.testing.allocator, sorted, &graph, &shaker);
            defer {
                for (baseline) |entry| if (!entry.all_used) std.testing.allocator.free(entry.names);
                std.testing.allocator.free(baseline);
            }
            try std.testing.expect(!baseline[slot].all_used);
            var found_local_name = false;
            for (baseline[slot].names) |name| {
                if (std.mem.eql(u8, name, case.local_name)) found_local_name = true;
            }
            try std.testing.expect(found_local_name);
        }

        // A valid same-module SID is still the wrong export owner. The scanner's
        // exact local node must stop this stale carrier from hiding a used name.
        binding.symbol = SymbolRef.makeSemantic(provider.index, decoy_symbol);
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        // Equal scalar SIDs from another module must fail the module-owner check.
        binding.symbol = SymbolRef.makeSemantic(foreign.index, live_symbol);
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        // A foreign decoy also cannot seed this module's statement reachability.
        binding.symbol = SymbolRef.makeSemantic(foreign.index, foreign_decoy_symbol);
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        // A mismatched local AST anchor must not authorize the otherwise valid
        // export SymbolRef either.
        binding.symbol = original_symbol;
        var decoy_binding_node: ?u32 = null;
        for (semantic.symbol_ids, 0..) |maybe_symbol, raw| {
            if (maybe_symbol != @as(?u32, @intCast(decoy_symbol)) or raw >= provider.ast.?.nodes.items.len) continue;
            if (provider.ast.?.nodes.items[raw].tag == .binding_identifier) {
                decoy_binding_node = @intCast(raw);
                break;
            }
        }
        binding.local_symbol_node = @fromBackingInt(decoy_binding_node orelse return error.MissingDecoyBindingNode);
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        binding.local_symbol_node = null;
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        binding.local_symbol_node = @as(NodeIndex, .none);
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        const ast = if (provider.ast) |*value| value else return error.MissingProviderAst;
        const extended_symbol_ids = try std.testing.allocator.alloc(?u32, original_symbol_ids.len + 1);
        defer std.testing.allocator.free(extended_symbol_ids);
        @memcpy(extended_symbol_ids[0..original_symbol_ids.len], original_symbol_ids);
        extended_symbol_ids[original_symbol_ids.len] = null;
        semantic.symbol_ids = extended_symbol_ids;
        binding.local_symbol_node = @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len))));
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);
        semantic.symbol_ids = original_symbol_ids;

        binding.local_symbol_node = original_anchor;
        binding.symbol = .invalid;
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);

        binding.symbol = original_symbol;
        const anchor_raw = @backingInt(original_anchor orelse return error.MissingLiveExportAnchor);
        semantic.symbol_ids = original_symbol_ids[0..anchor_raw];
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);
        semantic.symbol_ids = original_symbol_ids;

        var non_identifier: ?NodeIndex = null;
        for (ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .program) {
                non_identifier = @fromBackingInt(@intCast(raw));
                break;
            }
        }
        const non_identifier_node = non_identifier orelse return error.MissingProgramNode;
        const non_identifier_raw = @backingInt(non_identifier_node);
        const mutable_symbol_ids = @constCast(semantic.symbol_ids);
        const previous_non_identifier_sid = mutable_symbol_ids[non_identifier_raw];
        mutable_symbol_ids[non_identifier_raw] = live_symbol;
        binding.local_symbol_node = non_identifier_node;
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);
        mutable_symbol_ids[non_identifier_raw] = previous_non_identifier_sid;
        binding.local_symbol_node = original_anchor;

        // A semantic carrier remains identity-sensitive even if surrounding
        // metadata has classified its export path as a re-export.
        binding.symbol = SymbolRef.makeSemantic(provider.index, decoy_symbol);
        binding.kind = .re_export;
        try std.testing.expectEqual(@as(?u32, null), provider.exportBindingLocalNodeSemanticIndex(binding.*));
        try expectOutputNamesFailClosed(std.testing.allocator, sorted, &graph, &shaker, slot);
        binding.kind = original_kind;
        binding.symbol = original_symbol;
        binding.local_symbol_node = original_anchor;

        const used_names = try computeAllUsedNames(std.testing.allocator, sorted, &graph, &shaker);
        defer {
            for (used_names) |entry| if (!entry.all_used) std.testing.allocator.free(entry.names);
            std.testing.allocator.free(used_names);
        }
        const entry = used_names[slot];
        try std.testing.expect(!entry.all_used);
        var restored_local_name = false;
        for (entry.names) |name| {
            if (std.mem.eql(u8, name, case.local_name)) restored_local_name = true;
        }
        try std.testing.expect(restored_local_name);
        std.debug.print("used output export hostile case {d}: preserved {s} after stale SID {d}\n", .{ case_index + 1, case.local_name, decoy_symbol });
    }
}

test "hoistable function export rejects a same-module decoy SID" {
    const helper = @import("../test_helpers.zig");
    const resolve_cache_mod = @import("../resolve_cache.zig");
    const SymbolRef = @import("../symbol.zig").SymbolRef;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helper.writeFile(tmp.dir, "provider.mjs", "export const live = 1; export function legitimate() {} function decoy() {}");

    const path = try helper.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    try linker.link();

    const module = graph.getModule(ModuleIndex.fromUsize(0)) orelse return error.MissingProvider;
    const binding = @constCast(module.findExportBinding("live") orelse return error.MissingLiveExport);
    const legitimate_binding = module.findExportBinding("legitimate") orelse return error.MissingLegitimateExport;
    const semantic = module.semantic orelse return error.MissingProviderSemantic;
    const decoy_sid = semantic.scope_maps[0].get("decoy") orelse return error.MissingDecoySID;
    try std.testing.expect(exportBindingIsHoistableFn(module, legitimate_binding.*));
    try std.testing.expect(!exportBindingIsHoistableFn(module, binding.*));

    // A valid function SID in this module is still the wrong source binding.
    binding.symbol = SymbolRef.makeSemantic(module.index, decoy_sid);
    try std.testing.expect(!exportBindingIsHoistableFn(module, binding.*));
}

// ============================================================
// preserve-modules 경로 유틸리티
// ============================================================

/// preserve-modules: 모듈의 절대 경로에서 root를 제거하고 출력 상대 경로를 생성한다.
/// 예: abs_path="/Users/me/project/src/utils.ts", root="/Users/me/project/src"
///     → "utils.js"
/// root가 null이면 파일명만 사용 (stem + ext).
fn computePreserveModulesPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    out_ext: []const u8,
    root: ?[]const u8,
) ![]const u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(abs_path));

    if (root) |r| {
        // root 경로를 기준으로 상대 경로 계산
        // abs_path가 root로 시작하면 그 뒷부분을 사용
        const normalized_root = if (r.len > 0 and r[r.len - 1] == '/') r[0 .. r.len - 1] else r;
        if (std.mem.startsWith(u8, abs_path, normalized_root)) {
            var rel = abs_path[normalized_root.len..];
            // 선행 '/' 제거
            if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
            // 확장자를 교체
            const rel_stem = rel[0 .. rel.len - (std.fs.path.extension(rel).len)];
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ rel_stem, out_ext });
        }
    }

    // root가 없거나 매칭 실패 → 공통 부모를 자동 감지하지 않고 파일명만 사용
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, out_ext });
}

/// preserve-modules: 두 모듈 간의 상대 import 경로를 계산한다.
/// src_abs: import하는 모듈의 절대 경로
/// dep_abs: import 대상 모듈의 절대 경로
/// ext: 출력 확장자
/// root: preserve-modules-root (null 가능)
///
/// 반환값: "./utils.js" 또는 "../lib/helper.js" 형태의 상대 경로 (allocator 소유)
fn computeRelativeImportPath(
    allocator: std.mem.Allocator,
    src_abs: []const u8,
    dep_abs: []const u8,
    ext: []const u8,
    root: ?[]const u8,
) ![]const u8 {
    // Resolve the same output paths used by the file writer. Virtual modules
    // live at outdir's root even when their importer has an absolute source path.
    const src_output = try computePreserveModulesPath(allocator, src_abs, ext, root);
    defer allocator.free(src_output);
    const dep_output = try computePreserveModulesPath(allocator, dep_abs, ext, root);
    defer allocator.free(dep_output);
    return computeRelativePath(allocator, std.fs.path.dirname(src_output) orelse "", dep_output, "");
}

/// src_dir에서 dep_path로의 상대 경로를 계산한다.
/// 두 경로 모두 root 기준의 상대 경로여야 한다.
fn computeRelativePath(
    allocator: std.mem.Allocator,
    src_dir: []const u8,
    dep_path_no_ext: []const u8,
    ext: []const u8,
) ![]const u8 {
    // 공통 prefix 찾기 — segment 경계 (`/`) 까지만 매칭. mid-segment 매치는 제외.
    var common_len: usize = 0;
    var matched_full: usize = 0;
    const min_len = @min(src_dir.len, dep_path_no_ext.len);
    for (0..min_len) |i| {
        if (src_dir[i] != dep_path_no_ext[i]) break;
        matched_full = i + 1;
        if (src_dir[i] == '/') common_len = i + 1;
    }
    // src_dir 가 dep_path 의 진짜 prefix 일 때만 segment 매치 (matched_full 로 byte
    // 일치 보장). 길이만 보면 `src_dir="static"`, `dep="chunks/..."` 같이 무관한
    // path 도 prefix 로 잘못 인식해 dep_remaining 손실.
    if (matched_full == src_dir.len and (dep_path_no_ext.len == src_dir.len or
        (dep_path_no_ext.len > src_dir.len and dep_path_no_ext[src_dir.len] == '/')))
    {
        common_len = src_dir.len;
        if (dep_path_no_ext.len > src_dir.len) common_len += 1; // '/' 건너뛰기
    }

    // src_dir에서 common 이후의 깊이
    const src_remaining = if (common_len <= src_dir.len) src_dir[common_len..] else "";
    var depth: usize = 0;
    if (src_remaining.len > 0) {
        depth = 1;
        for (src_remaining) |c| {
            if (c == '/') depth += 1;
        }
    }

    const dep_remaining = if (common_len <= dep_path_no_ext.len) dep_path_no_ext[common_len..] else dep_path_no_ext;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    if (depth == 0) {
        try result.appendSlice(allocator, "./");
    } else {
        for (0..depth) |_| {
            try result.appendSlice(allocator, "../");
        }
    }
    try result.appendSlice(allocator, dep_remaining);
    try result.appendSlice(allocator, ext);

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testExtract(input: []const u8, expected_directives: []const u8, expected_rest: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const rest = try extractLeadingDirectives(input, &out, testing.allocator);
    try testing.expectEqualStrings(expected_directives, out.items);
    try testing.expectEqualStrings(expected_rest, rest);
}

test "extractLeadingDirectives: 단일 use client" {
    try testExtract(
        "\"use client\";\nimport x from 'y';\n",
        "\"use client\";\n",
        "\nimport x from 'y';\n",
    );
}

test "extractLeadingDirectives: use strict + use client" {
    try testExtract(
        "\"use strict\";\n\"use client\";\nfoo();\n",
        "\"use strict\";\n\"use client\";\n",
        "\nfoo();\n",
    );
}

test "extractLeadingDirectives: single quote 'use server'" {
    try testExtract(
        "'use server'\nexport async function f(){}\n",
        "'use server';\n",
        "\nexport async function f(){}\n",
    );
}

test "extractLeadingDirectives: 디렉티브 없음" {
    try testExtract(
        "import x from 'y';\n",
        "",
        "import x from 'y';\n",
    );
}

test "extractLeadingDirectives: 라인 주석 후 디렉티브" {
    try testExtract(
        "// banner\n\"use client\";\nfoo();\n",
        "\"use client\";\n",
        "\nfoo();\n",
    );
}

test "extractLeadingDirectives: 블록 주석 후 디렉티브" {
    try testExtract(
        "/** copyright */\n\"use client\";\nfoo();\n",
        "\"use client\";\n",
        "\nfoo();\n",
    );
}

test "extractLeadingDirectives: 첫 비-string 만나면 중단" {
    try testExtract(
        "\"use client\";\n\"random\";\nimport x;\n",
        "\"use client\";\n\"random\";\n",
        "\nimport x;\n",
    );
}

test "extractLeadingDirectives: 문자열 다음에 + 연산자면 디렉티브 아님" {
    try testExtract(
        "\"foo\" + \"bar\";\n",
        "",
        "\"foo\" + \"bar\";\n",
    );
}

test "extractLeadingDirectives: 이스케이프된 quote 처리" {
    try testExtract(
        "\"use \\\"x\\\" client\";\nfoo();\n",
        "\"use \\\"x\\\" client\";\n",
        "\nfoo();\n",
    );
}

test "extractLeadingDirectives: 빈 입력" {
    try testExtract("", "", "");
}

test "extractLeadingDirectives: 공백만" {
    try testExtract("   \n\t\n", "", "   \n\t\n");
}

test "extractLeadingDirectives: 주석만 (디렉티브 없음)" {
    try testExtract("// just a comment\n/* block */\n", "", "// just a comment\n/* block */\n");
}

test "extractLeadingDirectives: CRLF 줄바꿈" {
    try testExtract(
        "\"use client\";\r\nfoo();\r\n",
        "\"use client\";\n",
        "\r\nfoo();\r\n",
    );
}

test "extractLeadingDirectives: 디렉티브 + 같은 줄에 코드 (semicolon으로 분리)" {
    try testExtract(
        "\"use client\"; foo();\n",
        "\"use client\";\n",
        " foo();\n",
    );
}

test "extractLeadingDirectives: 라인 주석 + 블록 주석 + 디렉티브" {
    try testExtract(
        "// line\n/* block */\n\"use server\";\n",
        "\"use server\";\n",
        "\n",
    );
}

test "extractLeadingDirectives: 두 디렉티브 사이 주석" {
    try testExtract(
        "\"use strict\";\n// between\n\"use client\";\nfoo();\n",
        "\"use strict\";\n\"use client\";\n",
        "\nfoo();\n",
    );
}

test "extractLeadingDirectives: 중첩 블록 주석은 미지원이어도 단순 블록은 OK" {
    try testExtract(
        "/* a */\n/* b */ \"use client\";\nfoo();\n",
        "\"use client\";\n",
        "\nfoo();\n",
    );
}

test "extractLeadingDirectives: 미종료 문자열 — 중단" {
    try testExtract(
        "\"unterminated\nfoo();\n",
        "",
        "\"unterminated\nfoo();\n",
    );
}

test "extractLeadingDirectives: var 선언 → 즉시 중단" {
    try testExtract(
        "var x = 1;\n\"use client\";\n",
        "",
        "var x = 1;\n\"use client\";\n",
    );
}

test "extractLeadingDirectives: 디렉티브 후 EOF" {
    try testExtract(
        "\"use client\"",
        "\"use client\";\n",
        "",
    );
}

test "extractLeadingDirectives: tab/space 들여쓰기된 디렉티브 (스펙상 prologue)" {
    try testExtract(
        "  \"use client\";\nfoo();\n",
        "\"use client\";\n",
        "\nfoo();\n",
    );
}

test "appendCssLinkPrologue: DOM-guarded link injection for href" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendCssLinkPrologue(std.testing.allocator, &buf, "route-a-1a2b3c4d.css");
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "typeof document!==\"undefined\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "rel=\"stylesheet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "new URL(\"./route-a-1a2b3c4d.css\",import.meta.url)") != null);
    try std.testing.expect(std.mem.endsWith(u8, s, "appendChild(__zntc_css);}\n"));
}

test "rewriteImportSpecifier: prefix 충돌·문자열 리터럴·다중 occurrence (#4295)" {
    const a = std.testing.allocator;

    // prefix 충돌: "./x" 가 "./xyz" 의 prefix — import("./xyz") 는 보존돼야 한다.
    {
        const r = (try rewriteImportSpecifier(a, "import(\"./x\");import(\"./xyz\");", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("import(\"./X\");import(\"./xyz\");", r);
    }
    // 문자열 리터럴 내 specifier 는 건드리지 않고 실제 import 만 교체.
    {
        const r = (try rewriteImportSpecifier(a, "const s=\"./x here\";import(\"./x\");", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("const s=\"./x here\";import(\"./X\");", r);
    }
    // 다중 occurrence 모두 교체.
    {
        const r = (try rewriteImportSpecifier(a, "import(\"./x\");import(\"./x\");", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("import(\"./X\");import(\"./X\");", r);
    }
    // single-quote opener.
    {
        const r = (try rewriteImportSpecifier(a, "import('./x')", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("import('./X')", r);
    }
    // 실제 import 호출이 없으면 null.
    {
        try std.testing.expect((try rewriteImportSpecifier(a, "const s=\"./x\";", "./x", "./X")) == null);
    }
}

test "rewriteImportSpecifier: import attributes specifier 교체 + 인자 보존" {
    const a = std.testing.allocator;

    // codegen 비-minify: 닫는 quote 뒤가 `,` — specifier 만 바꾸고 attributes 인자 보존.
    {
        const r = (try rewriteImportSpecifier(a, "import(\"./x\", { with: { type: \"json\" } })", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("import(\"./X\", { with: { type: \"json\" } })", r);
    }
    // codegen minify(공백 없음) + single quote.
    {
        const r = (try rewriteImportSpecifier(a, "import('./x',{with:{type:'json'}})", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("import('./X',{with:{type:'json'}})", r);
    }
    // attributes object 안에 specifier 텍스트가 또 있어도(문자열 리터럴) 진짜 호출만 교체.
    {
        const r = (try rewriteImportSpecifier(a, "import(\"./x\", { with: { src: \"./x\" } })", "./x", "./X")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("import(\"./X\", { with: { src: \"./x\" } })", r);
    }
    // attributes 가 있어도 prefix 충돌은 닫는 quote 불일치로 skip(null).
    {
        try std.testing.expect((try rewriteImportSpecifier(a, "import(\"./xyz\", { with: {} })", "./x", "./X")) == null);
    }
}

test "preserved output paths agree for virtual providers and nested source modules" {
    const cases = [_]struct { source: []const u8, dependency: []const u8, root: ?[]const u8, expected: []const u8 }{
        .{ .source = "/project/src/entry.mjs", .dependency = "runtime-split-entry-guard", .root = null, .expected = "./runtime-split-entry-guard.js" },
        .{ .source = "/project/src/entry.mjs", .dependency = "runtime-split-entry-guard", .root = "/project", .expected = "../runtime-split-entry-guard.js" },
        .{ .source = "/project/src/entry.mjs", .dependency = "/project/lib/value.mjs", .root = null, .expected = "./value.js" },
        .{ .source = "/project/src/entry.mjs", .dependency = "/project/lib/value.mjs", .root = "/project", .expected = "../lib/value.js" },
        .{ .source = "runtime-helper", .dependency = "/project/lib/value.mjs", .root = "/project", .expected = "./lib/value.js" },
    };
    for (cases) |case| {
        const actual = try computeRelativeImportPath(std.testing.allocator, case.source, case.dependency, ".js", case.root);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "PM consumer local lifetime snapshots fixed lazy and minted lexical names only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var natural: std.StringHashMapUnmanaged(void) = .empty;
    var aliases: std.ArrayList([]const u8) = .empty;
    const borrowed = try a.dupe(u8, "t");
    const symbol: chunk_mod.CrossChunkSym = .{ .canonical_module = 1, .name = "default" };
    try std.testing.expectEqualStrings("t", try deconflictedConsumerLocal(null, symbol, borrowed, true, null, a, &used, &natural, &aliases));
    try std.testing.expect(used.contains("t"));
    try std.testing.expectEqualStrings("lazy_local", try deconflictedConsumerLocal(null, symbol, "lazy_local", true, null, a, &used, &natural, &aliases));
    try std.testing.expect(used.contains("lazy_local"));
    try natural.put(a, "t$2", {});
    try std.testing.expectEqualStrings("t$3", try deconflictedConsumerLocal(null, symbol, borrowed, false, null, a, &used, &natural, &aliases));
    // Live namespace metadata may own this expression string, but it is not
    // an emitted lexical declaration and must not enter the reservation set.
    try aliases.append(a, try a.dupe(u8, "ns.live"));
    var occupied: std.ArrayList([]const u8) = .empty;
    try snapshotConsumerLocals(a, &used, &occupied);
    try std.testing.expectEqual(@as(usize, 3), occupied.items.len);
    var found_original = false;
    for (occupied.items) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "ns.live"));
        try std.testing.expect(!std.mem.eql(u8, name, "t$2"));
        if (std.mem.eql(u8, name, "t")) {
            found_original = true;
            try std.testing.expect(name.ptr != borrowed.ptr);
        }
    }
    try std.testing.expect(found_original);
    used.clearRetainingCapacity();
    natural.clearRetainingCapacity();
    // Model the observed provider canonical-storage poison without reading
    // freed memory. The independent owned snapshot must keep the original t.
    @memset(borrowed, 0xaa);
    var original_survived = false;
    for (occupied.items) |name| if (std.mem.eql(u8, name, "t")) {
        original_survived = true;
    };
    try std.testing.expect(original_survived);
}

test "PM plain import alias actual source SID selector metadata and body tuple" {
    const helper = @import("../test_helpers.zig");
    const fixture = @import("../bundler_test/plain_import_alias_fixtures.zig").candidates[0];
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helper.writeFile(tmp.dir, "entry.mjs", fixture.entry);
    try helper.writeFile(tmp.dir, "dep.mjs", fixture.dep);
    try helper.writeFile(tmp.dir, "lazy.mjs", fixture.lazy.?);
    const entry_path = try helper.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry_path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.preserve_modules = true;
    try graph.build(std.testing.io, &.{entry_path});
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    var cg = try chunk_mod.generatePreserveModulesChunks(std.testing.allocator, &graph, &.{entry_path}, null);
    defer cg.deinit();
    linker.module_to_chunk = cg.module_to_chunk;
    defer linker.module_to_chunk = null;
    var entry_module: ?*const Module = null;
    var modules = graph.modulesIterator();
    while (modules.next()) |module| if (std.mem.eql(u8, module.path, entry_path)) {
        entry_module = module;
        break;
    };
    const module = entry_module orelse return error.MissingAliasEntry;
    const ast = if (module.ast) |*value| value else return error.MissingAliasAst;
    const sem = module.semantic orelse return error.MissingAliasSemantic;
    var import_binding: ?linker_mod.ImportBinding = null;
    for (module.import_bindings) |binding| if (binding.kind == .default) {
        try std.testing.expect(import_binding == null);
        import_binding = binding;
    };
    const binding = import_binding orelse return error.MissingAliasImport;
    const anchor = binding.local_symbol_node orelse return error.MissingAliasAnchor;
    try std.testing.expect(binding.local_symbol.moduleIndex() == module.index);
    const sid = binding.local_symbol.semanticIndex() orelse return error.MissingAliasSymbol;
    try std.testing.expectEqual(@as(?u32, sid), sem.symbol_ids[@backingInt(anchor)]);
    try std.testing.expect(sem.symbols.items[sid].kind == .import_binding);
    var callee: NodeIndex = .none;
    for (ast.nodes.items) |node| {
        if (node.tag != .new_expression) continue;
        const candidate = ast.readExtraNode(node.data.extra, 0);
        if (candidate.isNone() or @backingInt(candidate) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(candidate)] != sid) continue;
        try std.testing.expect(callee.isNone());
        callee = candidate;
    }
    try std.testing.expect(!callee.isNone());
    const resolved = linker.getResolvedBinding(module.index.toU32(), binding.local_span) orelse return error.MissingAliasResolved;
    const sym = chunk_mod.CrossChunkSym{ .canonical_module = resolved.canonical.module_index.toU32(), .name = resolved.canonical.export_name, .provider = try @import("../cross_chunk_export.zig").Provider.capture(&linker, resolved.canonical.module_index.toU32(), resolved.canonical.export_name, .ordinary_export) };
    const actual_binding = try crossChunkBindingName(&linker, sym);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var natural: std.StringHashMapUnmanaged(void) = .empty;
    var aliases: std.ArrayList([]const u8) = .empty;
    const selected = try deconflictedConsumerLocal(&linker, sym, actual_binding, linker.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null, module.index.toU32(), a, &used, &natural, &aliases);
    const published = linker.getConsumerImportLocal(sym.canonical_module, sym.name) orelse return error.MissingAliasPublishedLocal;
    try std.testing.expectEqualStrings(selected, published);
    try std.testing.expect(linker.getConsumerImportTarget(sym.canonical_module, sym.name).?.role == .binding);
    try std.testing.expect(std.unicode.utf8ValidateSlice(selected));
    var metadata = try linker.buildMetadataForAst(ast, module.index.toU32(), true, null, .cjs, true);
    defer metadata.deinit();
    var codegen = Codegen.initWithOptions(std.testing.allocator, ast, .{ .module_format = .cjs, .linking_metadata = &metadata, .semantic_symbols = sem.symbols.items });
    defer codegen.deinit();
    try codegen.emitExpr(callee, .lowest, .{});
    std.debug.print("PM plain import alias tuple module={d} bindingNode={d} sourceSID={d} sourceKind={s} sourceScope={d} calleeNode={d} calleeSID={?d} provider={d} export={s} selected={s} selectedFirstByte={d} validUTF8={any} legacyASCIIStart={any} metadata={s} body={s}\n", .{ module.index.toU32(), @backingInt(anchor), sid, @tagName(sem.symbols.items[sid].kind), @backingInt(sem.symbols.items[sid].scope_id), @backingInt(callee), codegen.sourceSymbolId(callee), sym.canonical_module, sym.name, selected, selected[0], std.unicode.utf8ValidateSlice(selected), selected[0] >= 0x21 and selected[0] < 0x80, metadata.renames.get(sid) orelse "<none>", codegen.buf.items });
    for (sem.references) |reference| if (@backingInt(reference.symbol_id) == sid) std.debug.print("PM plain import alias source-row node={d} declaration={d} scope={d} flags={d}\n", .{ @backingInt(reference.node_index), @backingInt(reference.declaration_node_index), @backingInt(reference.scope_id), @as(u8, @bitCast(reference.flags)) });
    try std.testing.expectEqualStrings(selected, codegen.buf.items);
    // Exercise the metadata consumer, not only the lexical helper. The same
    // current source anchor/SID/read survives every malformed owned target.
    for ([_][]const u8{ "\xAA", "name.member", "class", "\\u0063lass" }) |invalid| {
        try linker.putConsumerImportLocal(sym.canonical_module, sym.name, invalid);
        var rejected = try linker.buildMetadataForAst(ast, module.index.toU32(), true, null, .cjs, true);
        defer rejected.deinit();
        try std.testing.expect(!rejected.renames.contains(sid));
        try std.testing.expectEqual(@as(?u32, sid), rejected.symbol_ids[@backingInt(callee)]);
        try std.testing.expectEqual(@as(?u32, sid), sem.symbol_ids[@backingInt(anchor)]);
        try linker.putConsumerImportLocal(sym.canonical_module, sym.name, selected);
        var restored = try linker.buildMetadataForAst(ast, module.index.toU32(), true, null, .cjs, true);
        defer restored.deinit();
        try std.testing.expectEqualStrings(selected, restored.renames.get(sid) orelse return error.MissingRestoredAliasRename);
    }
    std.debug.print("PM plain import alias actual-metadata-invalid-targets=4 restored=4 sameSID={d}\n", .{sid});
}

test "PM plain import alias member StringValue literal backslash retains key" {
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    // This is the StringValue containing a literal backslash, not the raw
    // spelling of an identifier escape. The competing decoded key is 9.
    try linker.putConsumerImportMember(0, "value", "holder", "\\u0061");
    const target = linker.getConsumerImportTarget(0, "value") orelse return error.MissingMemberTarget;
    try std.testing.expect(target.role == .namespace_member_expression);
    const script = try std.fmt.allocPrint(std.testing.allocator, "const holder={{\"\\\\u0061\":7,a:9}};console.log({s});", .{target.text});
    defer std.testing.allocator.free(script);
    const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    std.debug.print("PM plain import alias property StringValue literal-backslash expression={s} expected=7 actual={s}", .{ target.text, actual.stdout });
    try std.testing.expectEqualStrings("7\n", actual.stdout);
}

test "PM plain import alias property origins preserve StringValue keys" {
    const Case = struct { spelling: []const u8, origin: ConsumerPropertyOrigin, value: []const u8 };
    const cases = [_]Case{
        .{ .spelling = "\\u0061", .origin = .binding_spelling, .value = "a" },
        .{ .spelling = "\"\\u0061\"", .origin = .module_export_name, .value = "a" },
        .{ .spelling = "\"\\\\u0061\"", .origin = .module_export_name, .value = "\\u0061" },
        .{ .spelling = "\"\\\"quoted\\\"\"", .origin = .module_export_name, .value = "\"quoted\"" },
        .{ .spelling = "\"한글\"", .origin = .module_export_name, .value = "한글" },
        .{ .spelling = "한글", .origin = .module_export_name, .value = "한글" },
        .{ .spelling = "\\u{10400}", .origin = .binding_spelling, .value = "𐐀" },
        .{ .spelling = "\"\"", .origin = .module_export_name, .value = "" },
        .{ .spelling = "\"😀\"", .origin = .module_export_name, .value = "😀" },
        .{ .spelling = "\"a-b\"", .origin = .module_export_name, .value = "a-b" },
    };
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    for (cases) |case| {
        const value = try consumerImportPropertyValue(std.testing.allocator, case.spelling, case.origin);
        defer if (value.ptr != case.spelling.ptr) std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(case.value, value);
        try linker.putConsumerImportMember(0, "value", "holder", value);
        const target = linker.getConsumerImportTarget(0, "value") orelse return error.MissingMemberTarget;
        try std.testing.expect(target.role == .namespace_member_expression);
        const key = try std.json.Stringify.valueAlloc(std.testing.allocator, case.value, .{});
        defer std.testing.allocator.free(key);
        const script = try std.fmt.allocPrint(std.testing.allocator, "const holder={{}};holder[{s}]=7;console.log({s});", .{ key, target.text });
        defer std.testing.allocator.free(script);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("7\n", actual.stdout);
    }
    std.debug.print("PM plain import alias property-origin-controls=10 native=10\n", .{});
}

test "PM plain import alias lexical validation rejects malformed names without expression inference" {
    const names = @import("../linker/identifier_name.zig");
    for ([_][]const u8{ "plain$1", "이름", "é", "𐐀", "a\u{0301}", "a\u{200c}", "a\u{200d}", "\\u0061", "a\\u0030", "\\u{10400}" }) |valid| {
        try std.testing.expect(try names.isBindingName(std.testing.allocator, valid, Linker.isReservedName));
    }
    for ([_][]const u8{ "", "\x00", "\xAA", "\xEC\x9D", "\xC0\xAF", "\xED\xA0\x80", "9name", "name.member", "name()", "name space", "bad-name", "😀", "\u{0301}name", "\\uD800", "\\u{110000}", "class", "\\u0063lass" }) |invalid| {
        try std.testing.expect(!try names.isBindingName(std.testing.allocator, invalid, Linker.isReservedName));
    }
}

test "PM plain import alias owned target roles reject invalid member inputs atomically" {
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    const original = try std.testing.allocator.dupe(u8, "owned");
    defer std.testing.allocator.free(original);
    try linker.putConsumerImportLocal(0, "value", original);
    const target = linker.getConsumerImportTarget(0, "value") orelse return error.MissingImportTarget;
    try std.testing.expect(target.role == .binding);
    try std.testing.expect(target.text.ptr != original.ptr);
    @memset(original, 0xaa);
    try std.testing.expectEqualStrings("owned", target.text);
    for ([_][]const u8{ "", "\xAA", "holder.field", "class", "\\u0063lass" }) |invalid| {
        try std.testing.expectError(error.InvalidConsumerImportMember, linker.putConsumerImportMember(0, "value", invalid, "key"));
        const restored = linker.getConsumerImportTarget(0, "value") orelse return error.MissingImportTarget;
        try std.testing.expect(restored.role == .binding and restored.text.ptr == target.text.ptr);
        try std.testing.expectEqualStrings("owned", restored.text);
    }
    try std.testing.expectError(error.InvalidConsumerImportMember, linker.putConsumerImportMember(0, "value", "holder", "\xAA"));
    try std.testing.expectEqualStrings("owned", linker.getConsumerImportLocal(0, "value").?);
    try linker.putConsumerImportMember(0, "value", "holder", "값");
    try std.testing.expect(linker.getConsumerImportTarget(0, "value").?.role == .namespace_member_expression);
    try std.testing.expectEqualStrings("holder.값", linker.getConsumerImportLocal(0, "value").?);
}
test "PM barrel import target actual source canonical selected export tuple" {
    const helper = @import("../test_helpers.zig");
    const fixture = @import("../bundler_test/plain_import_alias_fixtures.zig").candidates[7];
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helper.writeFile(tmp.dir, "entry.mjs", fixture.entry);
    try helper.writeFile(tmp.dir, "dep.mjs", fixture.dep);
    try helper.writeFile(tmp.dir, "barrel.mjs", fixture.barrel.?);
    const path = try helper.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.preserve_modules = true;
    try graph.build(std.testing.io, &.{path});
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = true });
    var cg = try chunk_mod.generatePreserveModulesChunks(std.testing.allocator, &graph, &.{path}, null);
    defer cg.deinit();
    linker.module_to_chunk = cg.module_to_chunk;
    defer linker.module_to_chunk = null;
    var entry: ?*const Module = null;
    var it = graph.modulesIterator();
    while (it.next()) |m| if (std.mem.eql(u8, m.path, path)) {
        entry = m;
        break;
    };
    const em = entry orelse return error.MissingBarrelEntry;
    try std.testing.expectEqual(@as(usize, 1), em.import_bindings.len);
    const source = em.import_bindings[0];
    const sid = source.local_symbol.semanticIndex() orelse return error.MissingBarrelSourceSID;
    const physical = em.import_records[source.import_record_index].resolved;
    const barrel = graph.getModule(physical) orelse return error.MissingPhysicalBarrel;
    const canonical = linker.resolveExportChain(physical, source.imported_name, 0) orelse return error.MissingBarrelCanonical;
    const provider = graph.getModule(canonical.module_index) orelse return error.MissingBarrelProvider;
    const eb = provider.findExportBinding(canonical.export_name) orelse return error.MissingBarrelProviderBinding;
    const provider_sid = provider.exportBindingSemanticIndex(eb.*) orelse return error.MissingBarrelProviderSID;
    const sym = chunk_mod.CrossChunkSym{ .canonical_module = canonical.module_index.toU32(), .name = canonical.export_name, .provider = try @import("../cross_chunk_export.zig").Provider.capture(&linker, canonical.module_index.toU32(), canonical.export_name, .ordinary_export) };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var natural: std.StringHashMapUnmanaged(void) = .empty;
    var aliases: std.ArrayList([]const u8) = .empty;
    const selected = try std.testing.allocator.dupe(u8, try deconflictedConsumerLocal(&linker, sym, try crossChunkBindingName(&linker, sym), linker.getCrossChunkGlobalName(sym.canonical_module, sym.name) != null, barrel.index.toU32(), a, &used, &natural, &aliases));
    defer std.testing.allocator.free(selected);
    const target = linker.getConsumerImportTarget(sym.canonical_module, sym.name) orelse return error.MissingBarrelSelected;
    var occupied: std.ArrayList([]const u8) = .empty;
    defer {
        for (occupied.items) |name| std.testing.allocator.free(name);
        occupied.deinit(std.testing.allocator);
    }
    try snapshotConsumerLocals(std.testing.allocator, &used, &occupied);
    used.clearRetainingCapacity();
    natural.clearRetainingCapacity();
    try linker.computeRenamesForModules(&.{barrel.index}, occupied.items);
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (owned.items) |s| std.testing.allocator.free(s);
        owned.deinit(std.testing.allocator);
    }
    const entries = (try linker.buildFinalExports(true, barrel.index.toU32(), barrel.export_bindings, &owned)) orelse return error.MissingBarrelFinalExports;
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    std.debug.print("PM barrel record kind={s} symbolTag={s} symbolModule={d} localCheckedSID={?d} localAnchor={?d} recordIndex={?d} providerTag={s} providerModule={d}\n", .{ @tagName(barrel.export_bindings[0].kind), @tagName(std.meta.activeTag(barrel.export_bindings[0].symbol)), barrel.export_bindings[0].symbol.moduleIndex().toU32(), barrel.exportBindingSemanticIndex(barrel.export_bindings[0]), if (barrel.export_bindings[0].local_symbol_node) |n| @as(?u32, @backingInt(n)) else null, barrel.export_bindings[0].import_record_index, @tagName(std.meta.activeTag(eb.symbol)), eb.symbol.moduleIndex().toU32() });
    const output = try @import("entry_exports.zig").emitCjsEntryExports(std.testing.allocator, entries, .auto, null, "__defProp", false);
    defer std.testing.allocator.free(output);
    std.debug.print("PM barrel tuple sourceModule={d} sourceSID={d} sourceAnchor={?d} physical={d}/{s} canonical={d}/{s} providerSID={d} barrelSourceImports={d} barrelExportSID={?d} selected={s} role={s} finalLocal={s} output={s}\n", .{ em.index.toU32(), sid, if (source.local_symbol_node) |n| @as(?u32, @backingInt(n)) else null, physical.toU32(), source.imported_name, canonical.module_index.toU32(), canonical.export_name, provider_sid, barrel.import_bindings.len, barrel.export_bindings[0].symbol.semanticIndex(), selected, @tagName(target.role), entries[0].local, output });
    try std.testing.expectEqualStrings(selected, entries[0].local);
    const valid_handle = linker.ordinaryCanonicalImportTarget(canonical) orelse return error.MissingBarrelOrdinaryHandle;
    const valid_pair = Linker.NsExportPair{ .exported = "default", .local = "unused-fallback", .canonical_import = valid_handle };
    try std.testing.expectEqualStrings(selected, (try linker.selectedFinalImportLocal(barrel.index.toU32(), valid_pair)).?);
    var foreign_graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer foreign_graph.deinit();
    foreign_graph.preserve_modules = true;
    try foreign_graph.build(std.testing.io, &.{path});
    var foreign_linker = Linker.init(std.testing.allocator, &foreign_graph, .cjs);
    defer foreign_linker.deinit();
    try foreign_linker.link();
    try foreign_linker.finalize(.{ .compute_renames = true, .compute_mangling = true });
    const foreign_handle = foreign_linker.ordinaryCanonicalImportTarget(canonical) orelse return error.MissingForeignOrdinaryHandle;
    try std.testing.expect(@import("../symbol.zig").SymbolRef.eql(foreign_handle.provider_symbol, valid_handle.provider_symbol));
    var foreign_pair = valid_pair;
    foreign_pair.canonical_import = foreign_handle;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), foreign_pair));
    var corrupt = valid_pair;
    corrupt.canonical_import.?.provider_symbol = source.local_symbol;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.canonical_import.?.canonical.module_index = barrel.index;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.canonical_import.?.canonical.export_name = "missing";
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.canonical_import.?.canonical.synthetic_member = "member";
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.canonical_import = null;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.canonical_import.?.provider_symbol = .invalid;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(provider.index.toU32(), valid_pair));
    corrupt = valid_pair;
    corrupt.exported = "missing";
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    try linker.putConsumerImportMember(sym.canonical_module, sym.name, "holder", "read");
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), valid_pair));
    try linker.putConsumerImportLocal(sym.canonical_module, sym.name, "invalid.member");
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), valid_pair));
    try linker.putConsumerImportLocal(sym.canonical_module, sym.name, selected);
    corrupt = valid_pair;
    corrupt.owned = true;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.cjs_interop = canonical;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    corrupt = valid_pair;
    corrupt.ns_target_mod = canonical.module_index.toU32();
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), corrupt));
    // The typed role remains authoritative even if its current text is a
    // valid lexical name. Grammar validation alone cannot replace it.
    const stored = linker.consumer_import_local.getPtr(sym.canonical_module).?.getPtr(sym.name).?;
    stored.role = .namespace_member_expression;
    try std.testing.expectEqual(@as(?[]const u8, null), try linker.selectedFinalImportLocal(barrel.index.toU32(), valid_pair));
    stored.role = .binding;
    try std.testing.expectEqualStrings(selected, (try linker.selectedFinalImportLocal(barrel.index.toU32(), valid_pair)).?);
    std.debug.print("PM barrel target hostile=14 restored=1 sourceSID={d} providerSID={d}\n", .{ sid, provider_sid });
}

test "PM barrel import target normalized reexport preserves source record provider roles" {
    const helper = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helper.writeFile(tmp.dir, "entry.mjs", "import Value,{Other}from'./dep.mjs';export{Value as default};export const own=3;");
    try helper.writeFile(tmp.dir, "dep.mjs", "export default class Provider{};export class Other{}");
    const path = try helper.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.preserve_modules = true;
    try graph.build(std.testing.io, &.{path});
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    var it = graph.modulesIterator();
    var entry: ?*const Module = null;
    while (it.next()) |m| if (std.mem.eql(u8, m.path, path)) {
        entry = m;
        break;
    };
    const m = entry orelse return error.MissingLocalBarrel;
    const actual = m.findExportBinding("default") orelse return error.MissingLocalBarrelExport;
    std.debug.print("PM local setup kind={s} tag={s} module={d} sid={?d} node={?d} imports={d} sourceKind={s}\n", .{ @tagName(actual.kind), @tagName(std.meta.activeTag(actual.symbol)), actual.symbol.moduleIndex().toU32(), m.exportBindingSemanticIndex(actual.*), if (actual.local_symbol_node) |n| @as(?u32, @backingInt(n)) else null, m.import_bindings.len, if (m.exportBindingSemanticIndex(actual.*)) |id| @tagName(m.semantic.?.symbols.items[id].kind) else "none" });
    for (m.import_bindings) |ib| std.debug.print("PM local import tag={s} module={d} sid={?d} node={?d}\n", .{ @tagName(std.meta.activeTag(ib.local_symbol)), ib.local_symbol.moduleIndex().toU32(), ib.local_symbol.semanticIndex(), if (ib.local_symbol_node) |n| @as(?u32, @backingInt(n)) else null });
    try std.testing.expect(actual.kind == .re_export);
    // This normalized record is a redirect, not a second source declaration.
    // Its source export leaf retains the actual import SID; the output role
    // below must be carried by the canonical provider's independently owned SID.
    try std.testing.expect(actual.symbol == .alias);
    try std.testing.expect(actual.symbol.moduleIndex() == m.index);
    try std.testing.expectEqual(@as(?u32, null), m.exportBindingSemanticIndex(actual.*));
    const source_export_leaf = actual.local_symbol_node orelse return error.MissingBarrelSourceLeaf;
    const record_sid = m.semantic.?.symbol_ids[@backingInt(source_export_leaf)] orelse return error.MissingBarrelSourceSID;
    try std.testing.expect(m.semantic.?.symbols.items[record_sid].kind == .import_binding);
    try std.testing.expectEqual(@as(usize, 2), m.import_bindings.len);
    for (m.import_bindings) |binding| {
        const source_sid = binding.local_symbol.semanticIndex() orelse return error.MissingBarrelImportSID;
        try std.testing.expect(binding.local_symbol.moduleIndex() == m.index);
        try std.testing.expect(m.semantic.?.symbols.items[source_sid].kind == .import_binding);
        const source_anchor = binding.local_symbol_node orelse return error.MissingBarrelImportAnchor;
        try std.testing.expectEqual(@as(?u32, source_sid), m.semantic.?.symbol_ids[@backingInt(source_anchor)]);
    }
    var pairs: std.ArrayList(Linker.NsExportPair) = .empty;
    defer {
        for (pairs.items) |pair| if (pair.owned) std.testing.allocator.free(pair.local);
        pairs.deinit(std.testing.allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(std.testing.allocator);
    try linker.collectExportsRecursive(&pairs, &seen, &visited, m.index, 0);
    var forwarded = false;
    var local_unchanged = false;
    for (pairs.items) |pair| {
        if (std.mem.eql(u8, pair.exported, "default")) {
            const handle = pair.canonical_import orelse return error.MissingNormalizedBarrelHandle;
            try std.testing.expect(!pair.owned and pair.cjs_interop == null and pair.ns_target_mod == null);
            try std.testing.expect(handle.provider_symbol.moduleIndex() != m.index);
            try std.testing.expect(handle.provider_symbol.semanticIndex() != null);
            try std.testing.expect(@import("../symbol.zig").SymbolRef.eql(handle.provider_symbol, pair.binding_symbol));
            forwarded = true;
        }
        if (std.mem.eql(u8, pair.exported, "own")) {
            try std.testing.expect(pair.canonical_import == null);
            try std.testing.expect(@import("../symbol.zig").SymbolRef.eql(pair.binding_symbol, m.findExportBinding("own").?.symbol));
            local_unchanged = true;
        }
    }
    try std.testing.expect(forwarded and local_unchanged);
    const source_import = m.import_bindings[0];
    try std.testing.expectEqual(source_import.local_symbol.semanticIndex(), @as(?u32, record_sid));
    // Execute the unchanged normalized barrel through its actual namespace and
    // default import consumers. Textual export shape is not the value oracle.
    try helper.writeFile(tmp.dir, "probe.mjs", "import Value,{own}from'./entry.mjs';import * as ns from'./entry.mjs';const d=Object.getOwnPropertyDescriptor(ns,'default');console.log(JSON.stringify([typeof Value,Value===ns.default,own,d.enumerable,typeof d.get==='function'||d.value===Value]));");
    const native_path = try helper.absPath(&tmp, "probe.mjs");
    defer std.testing.allocator.free(native_path);
    const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", native_path } });
    defer std.testing.allocator.free(native.stdout);
    defer std.testing.allocator.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings("[\"function\",true,3,true,true]\n", native.stdout);
    for ([_]bool{ false, true }) |minify| {
        var bundled = try helper.bundleEntry(std.testing.allocator, &tmp, "probe.mjs", .{ .platform = .node, .minify_identifiers = minify });
        defer bundled.deinit();
        try std.testing.expect(!bundled.result.hasErrors());
        try helper.writeFile(tmp.dir, "actual.cjs", bundled.code());
        const output_path = try helper.absPath(&tmp, "actual.cjs");
        defer std.testing.allocator.free(output_path);
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", output_path } });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        if (execution.term != .exited or execution.term.exited != 0) std.debug.print("PM normalized runtime min={any}: {s}\n{s}\n", .{ minify, execution.stderr, bundled.code() });
        try std.testing.expect(execution.term == .exited and execution.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, execution.stdout);
    }
    std.debug.print("PM barrel source imports=2 normalized-records=1 ordinary-provider=1 local-unchanged=1 native=1 writer=2\n", .{});
}

test "PM barrel import target excludes synthetic default namespace and CJS storage" {
    const helper = @import("../test_helpers.zig");
    const sources = [_]struct { source: []const u8, extension: []const u8, key: []const u8, ordinary: bool }{
        .{ .source = "export default function Named(){return 7}", .extension = "mjs", .key = "default", .ordinary = true },
        .{ .source = "export default function(){return 7}", .extension = "mjs", .key = "default", .ordinary = false },
        .{ .source = "const value=()=>7;export default value;", .extension = "mjs", .key = "default", .ordinary = false },
        .{ .source = "export*as ns from'./dep.mjs';", .extension = "mjs", .key = "ns", .ordinary = false },
        .{ .source = "module.exports=function(){return 7}", .extension = "cjs", .key = "default", .ordinary = false },
    };
    for (sources) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const filename = try std.fmt.allocPrint(std.testing.allocator, "entry.{s}", .{case.extension});
        defer std.testing.allocator.free(filename);
        try helper.writeFile(tmp.dir, filename, case.source);
        try helper.writeFile(tmp.dir, "dep.mjs", "export const read=7;");
        const path = try helper.absPath(&tmp, filename);
        defer std.testing.allocator.free(path);
        var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{path});
        var linker = Linker.init(std.testing.allocator, &graph, .cjs);
        defer linker.deinit();
        try linker.link();
        var it = graph.modulesIterator();
        var entry: ?*const Module = null;
        while (it.next()) |m| if (std.mem.eql(u8, m.path, path)) {
            entry = m;
            break;
        };
        const m = entry orelse return error.MissingBarrelStorageControl;
        const actual = linker.ordinaryCanonicalImportTarget(.{ .module_index = m.index, .export_name = case.key });
        try std.testing.expectEqual(case.ordinary, actual != null);
    }
    std.debug.print("PM barrel ordinary storage controls=5 syntheticDefaultNamespaceCJSExcluded=true\n", .{});
}

test "quoted ordinary cross chunk CJS writer preserves literal key role" {
    const cases = [_]struct { syntax: []const u8, expected: []const u8 }{
        .{ .syntax = "\"\\\\u0061\"", .expected = "exports[\"\\\\u0061\"] = known;\n" },
        .{ .syntax = "\"\\\"key\\\"\"", .expected = "exports[\"\\\"key\\\"\"] = known;\n" },
        .{ .syntax = "\"한글\"", .expected = "exports.한글 = known;\n" },
    };
    for (cases) |case| {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCjsExportBinding(std.testing.allocator, &output, case.syntax, case.syntax, "known", false, false);
        try std.testing.expectEqualStrings(case.expected, output.items);
    }
}

test "quoted ordinary consumer preserves no rename and rejects invalid override without name fallback" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "dep.mjs", "const value=7;export{value as \"한글\"};");
    const path = try helpers.absPath(&tmp, "dep.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    const module = graph.modules.at(0);
    const binding = module.export_bindings[0];
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    const symbol = chunk_mod.CrossChunkSym{ .canonical_module = module.index.toU32(), .name = binding.exported_name, .provider = try @import("../cross_chunk_export.zig").Provider.capture(&linker, module.index.toU32(), binding.exported_name, .ordinary_export) };
    try std.testing.expectEqualStrings("value", try crossChunkBindingName(&linker, symbol));
    const known = SymbolID.make(module.index, module.exportBindingSemanticIndex(binding).?);
    try linker.rename_table.put(std.testing.allocator, known, "\"not a binding\"");
    try std.testing.expectError(error.InvalidQuotedExportCanonical, crossChunkBindingName(&linker, symbol));
    try linker.rename_table.put(std.testing.allocator, known, "known_local");
    try std.testing.expectEqualStrings("known_local", try crossChunkBindingName(&linker, symbol));
}

test "cross chunk provider refuses unexported lexical names" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "const privateValue=41;export{privateValue as publicValue};");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    const module = graph.modules.at(0);
    const binding = module.export_bindings[0];
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    const known = SymbolID.make(module.index, module.exportBindingSemanticIndex(binding).?);
    try linker.rename_table.put(std.testing.allocator, known, "actual_private");
    const selected = try cross_export.Provider.capture(&linker, module.index.toU32(), "publicValue", .ordinary_export);
    try std.testing.expectEqualStrings("actual_private", (try selected.localName(&linker)).?);
    // A public export key selects its carrier. An unrelated lexical spelling
    // must never discover the private declaration through a scope-name lookup.
    try std.testing.expectError(error.InvalidCrossChunkExport, cross_export.Provider.capture(&linker, module.index.toU32(), "privateValue", .ordinary_export));
}

test "cross chunk provider refuses a foreign graph with matching scalar IDs" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "export const value=7;");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var foreign = ModuleGraph.init(std.testing.allocator, &cache);
    defer foreign.deinit();
    try graph.build(std.testing.io, &.{path});
    try foreign.build(std.testing.io, &.{path});
    const module = graph.modules.at(0);
    const other = foreign.modules.at(0);
    const binding = module.export_bindings[0];
    try std.testing.expect(module != other);
    try std.testing.expect(module.index == other.index);
    try std.testing.expect(binding.symbol.eql(other.export_bindings[0].symbol));
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    const known = SymbolID.make(module.index, module.exportBindingSemanticIndex(binding).?);
    try linker.rename_table.put(std.testing.allocator, known, "actual_owner");
    var selected = try cross_export.Provider.capture(&linker, module.index.toU32(), "value", .ordinary_export);
    try std.testing.expectEqualStrings("actual_owner", (try selected.localName(&linker)).?);
    var foreign_linker = Linker.init(std.testing.allocator, &foreign, .esm);
    defer foreign_linker.deinit();
    selected = try cross_export.Provider.capture(&foreign_linker, other.index.toU32(), "value", .ordinary_export);
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
}

test "cross chunk provider preserves the original export specifier authority" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "const first=7,second=9;export{first as one,second as two};");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    const module = graph.modules.at(0);
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    const one = @constCast(module.findExportBinding("one").?);
    const two = module.findExportBinding("two").?;
    const saved = one.*;
    defer one.* = saved;
    const selected = try cross_export.Provider.capture(&linker, module.index.toU32(), "one", .ordinary_export);
    try std.testing.expectEqualStrings("first", (try selected.localName(&linker)).?);
    one.local_symbol_node = two.local_symbol_node;
    one.symbol = two.symbol;
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
    try std.testing.expectError(error.InvalidCrossChunkExport, cross_export.Provider.capture(&linker, module.index.toU32(), "one", .ordinary_export));
    one.source_specifier_node = two.source_specifier_node;
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
    try std.testing.expectError(error.InvalidCrossChunkExport, cross_export.Provider.capture(&linker, module.index.toU32(), "one", .ordinary_export));
}

test "cross chunk namespace projection selects the actual import SID and source record" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "import*as other from'./other.mjs';import*as selected from'./selected.mjs';export{selected as ns};console.log(other.value);");
    try helpers.writeFile(tmp.dir, "other.mjs", "export const value=99;");
    try helpers.writeFile(tmp.dir, "selected.mjs", "export const value=7;");
    const path = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    var it = graph.modulesIterator();
    var entry: ?*const Module = null;
    while (it.next()) |m| if (std.mem.eql(u8, m.path, path)) {
        entry = m;
        break;
    };
    const m = @constCast(entry orelse return error.MissingNamespaceProjectionControl);
    linker.populateImportSymbols();
    try std.testing.expectEqual(@as(usize, 2), m.import_bindings.len);
    const first = &m.import_bindings[0];
    const selected = &m.import_bindings[1];
    const target = m.import_records[selected.import_record_index].resolved;
    try std.testing.expect(!target.isNone());
    try std.testing.expectEqual(target, chunk_mod.nsReExportTarget(&graph, m.index, "ns").?);
    const provider = try cross_export.Provider.capture(&linker, m.index.toU32(), "ns", .ordinary_export);
    try provider.validate(&linker);
    const first_name = first.local_name;
    defer first.local_name = first_name;
    first.local_name = selected.local_name;
    try std.testing.expectEqual(target, chunk_mod.nsReExportTarget(&graph, m.index, "ns").?);
    const selected_record = selected.import_record_index;
    defer selected.import_record_index = selected_record;
    selected.import_record_index = first.import_record_index;
    try std.testing.expectEqual(@as(?ModuleIndex, null), chunk_mod.nsReExportTarget(&graph, m.index, "ns"));
    try std.testing.expectError(error.InvalidCrossChunkExport, cross_export.Provider.capture(&linker, m.index.toU32(), "ns", .ordinary_export));
}

test "cross chunk provider retains source birth authority through later edits" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "const first=7,second=99;export{first as value,second as other};");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    const m = graph.modules.at(0);
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    const binding = @constCast(m.findExportBinding("value").?);
    const selected = try cross_export.Provider.capture(&linker, m.index.toU32(), "value", .ordinary_export);
    try std.testing.expectEqualStrings("first", (try selected.localName(&linker)).?);
    var copied_binding = binding.*;
    var forged = selected;
    forged.role.semantic.binding = &copied_binding;
    try std.testing.expectError(error.InvalidCrossChunkExport, forged.localName(&linker));
    const sem = &m.semantic.?;
    const owner_token = sem.owner_token;
    sem.owner_token = .unassigned;
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
    sem.owner_token = owner_token;
    const spelling = binding.local_name;
    binding.local_name = "unrelated";
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
    binding.local_name = spelling;
    const sid = binding.symbol.semanticIndex().?;
    const symbol = sem.symbols.items[sid];
    sem.symbols.items[sid].decl_flags.is_exported = !symbol.decl_flags.is_exported;
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
    sem.symbols.items[sid] = symbol;
    const anchor = @backingInt(binding.local_symbol_node.?);
    const attached = sem.symbol_ids[anchor];
    @constCast(sem.symbol_ids)[anchor] = null;
    try std.testing.expectError(error.InvalidCrossChunkExport, selected.localName(&linker));
    @constCast(sem.symbol_ids)[anchor] = attached;
    // Ref/write counts may legitimately change; the same source binding stays
    // authoritative and its canonical output name remains identity-selected.
    sem.symbols.items[sid].reference_count += 1;
    sem.symbols.items[sid].write_count += 1;
    try std.testing.expectEqualStrings("first", (try selected.localName(&linker)).?);
    sem.symbols.items[sid] = symbol;
    const id = SymbolID.make(m.index, sid);
    try linker.rename_table.put(std.testing.allocator, id, "valid_output");
    try std.testing.expectEqualStrings("valid_output", (try selected.localName(&linker)).?);
    for ([_][]const u8{ "not a binding", "return" }) |invalid| {
        try linker.rename_table.put(std.testing.allocator, id, invalid);
        try std.testing.expectError(error.InvalidCrossChunkLocalName, selected.localName(&linker));
    }
}

test "cross chunk default snapshots cannot claim a lowered named declaration reference" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "let value=()=>7;export default value;");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    const module = graph.modules.at(0);
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    const binding = @constCast(module.findExportBinding("default").?);
    const original = binding.*;
    defer binding.* = original;
    const selected = try cross_export.Provider.capture(&linker, module.index.toU32(), "default", .ordinary_export);
    try selected.validate(&linker);
    const wrapper = module.ast.?.getNode(binding.source_export_node.?);
    const operand = wrapper.data.unary.operand;
    const sid = module.semantic.?.symbol_ids[@backingInt(operand)].?;
    try std.testing.expect(sid != binding.symbol.semanticIndex().?);
    binding.symbol = @import("../symbol.zig").SymbolRef.makeSemantic(module.index, sid);
    binding.local_symbol_node = operand;
    binding.has_default_export_facade = false;
    try std.testing.expectError(error.InvalidCrossChunkExport, cross_export.Provider.capture(&linker, module.index.toU32(), "default", .ordinary_export));
}
test "shared namespace output consumer selects final alias by known output reference" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "export const a=3;export const b=7;");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer a.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    const module = graph.getModule(graph.path_to_module.get(path).?).?;
    const initial = try linker.ensureSharedNsVar(module.index);
    const reference = linker.sharedNamespaceOutputRef(module.index).?;
    const provider = try @import("../cross_chunk_export.zig").Provider.capture(&linker, module.index.toU32(), initial, .{ .shared_namespace = reference });
    const edge: chunk_mod.CrossChunkSym = .{ .canonical_module = module.index.toU32(), .name = initial, .provider = provider, .namespace_output = reference };
    try std.testing.expect(try linker.assignSharedNamespaceGlobalName(reference, "chosen_namespace_alias"));
    try std.testing.expect(linker.getCrossChunkGlobalName(module.index.toU32(), initial) == null);
    try std.testing.expectEqualStrings("chosen_namespace_alias", try crossChunkBindingName(&linker, edge));
    linker.clearCrossChunkGlobalNames();
    try std.testing.expectEqualStrings(initial, try crossChunkBindingName(&linker, edge));
    var missing = edge;
    missing.provider = null;
    try std.testing.expectError(error.MissingCrossChunkProvider, crossChunkBindingName(&linker, missing));
}

const PurityRedirect = enum { none, imported_name, resolved_source };

fn checkAliasedPurity(source: []const u8, expected_pure: bool, missing_import_sid: bool, redirect: PurityRedirect) !void {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const entry_source = if (redirect == .resolved_source)
        "import{visible}from'./provider.mjs';import'./safe.mjs';const decoy=0;visible();"
    else
        "import{visible}from'./provider.mjs';const decoy=0;visible();";
    try helpers.writeFile(tmp.dir, "entry.mjs", entry_source);
    try helpers.writeFile(tmp.dir, "provider.mjs", source);
    if (redirect == .resolved_source) {
        try helpers.writeFile(tmp.dir, "safe.mjs", "/* @__NO_SIDE_EFFECTS__ */ function visible(){return 7}export{visible};");
    }
    const path = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    linker.populateImportSymbols();
    var it = graph.modulesIterator();
    var entry: ?*const Module = null;
    while (it.next()) |m| if (std.mem.eql(u8, m.path, path)) {
        entry = m;
        break;
    };
    const m = @constCast(entry orelse return error.MissingPurityControl);
    const ast = &m.ast.?;
    const sem = &m.semantic.?;
    var saved_local: ?@import("../symbol.zig").SymbolRef = null;
    if (missing_import_sid) {
        const binding = for (m.import_bindings) |*candidate| {
            if (std.mem.eql(u8, candidate.local_name, "visible")) break candidate;
        } else return error.MissingPurityImportBinding;
        const exact_local = try m.checkedImportBindingSourceSymbol(binding.*);
        const local_sid = exact_local.semanticIndex() orelse return error.MissingPurityImportSymbol;
        const decoy_sid = sem.scope_maps[0].get("decoy") orelse return error.MissingPurityDecoy;
        try std.testing.expect(local_sid != decoy_sid);
        saved_local = binding.local_symbol;
        binding.local_symbol = .invalid;
        try @constCast(sem.scope_maps)[0].put(std.testing.allocator, "visible", decoy_sid);
    }
    if (redirect == .imported_name) {
        const binding = for (m.import_bindings) |*candidate| {
            if (std.mem.eql(u8, candidate.local_name, "visible")) break candidate;
        } else return error.MissingPurityImportBinding;
        if (binding.import_record_index >= m.import_records.len) return error.MissingPurityImportRecord;
        const source_module = linker.graph.getModule(m.import_records[binding.import_record_index].resolved) orelse return error.MissingPuritySource;
        const sibling = source_module.findExportBinding("safeSibling") orelse return error.MissingPuritySiblingExport;
        binding.imported_name = "safeSibling";
        binding.symbol = sibling.symbol;
    }
    if (redirect == .resolved_source) {
        const binding = for (m.import_bindings) |*candidate| {
            if (std.mem.eql(u8, candidate.local_name, "visible")) break candidate;
        } else return error.MissingPurityImportBinding;
        const safe_path = try helpers.absPath(&tmp, "safe.mjs");
        defer std.testing.allocator.free(safe_path);
        var modules = graph.modulesIterator();
        const safe = while (modules.next()) |candidate| {
            if (std.mem.eql(u8, candidate.path, safe_path)) break candidate;
        } else return error.MissingPuritySafeSource;
        if (binding.import_record_index >= m.import_records.len) return error.MissingPurityImportRecord;
        if (!binding.symbol.isValid()) return error.MissingPuritySourceSymbol;
        m.import_records[binding.import_record_index].resolved = safe.index;
    }
    var call_count: usize = 0;
    for (ast.nodes.items) |node| if (node.tag == .call_expression) {
        try std.testing.expect(ast.extra_data.items[node.data.extra + 3] & @import("../../parser/ast.zig").CallFlags.is_pure == 0);
        call_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), call_count);
    @import("tree_shake.zig").propagateCrossModulePurity(&linker, m, ast, sem.symbol_ids, std.testing.allocator);
    for (ast.nodes.items) |node| if (node.tag == .call_expression) {
        try std.testing.expectEqual(expected_pure, ast.extra_data.items[node.data.extra + 3] & @import("../../parser/ast.zig").CallFlags.is_pure != 0);
    };
    if (missing_import_sid) {
        const binding = for (m.import_bindings) |*candidate| {
            if (std.mem.eql(u8, candidate.local_name, "visible")) break candidate;
        } else return error.MissingPurityImportBinding;
        try std.testing.expect(!binding.local_symbol.isValid());
        binding.local_symbol = saved_local.?;
    }
}

test "cross module purity cannot borrow a sibling binding through an export key" {
    try checkAliasedPurity("/* @__NO_SIDE_EFFECTS__ */ function visible(){}function actual(){console.log('side')}export{actual as visible};", false, false, .none);
}

test "cross module purity follows the actual aliased export binding" {
    try checkAliasedPurity("function visible(){console.log('side')}/* @__NO_SIDE_EFFECTS__ */ function actual(){return 7}export{actual as visible};", true, false, .none);
}

test "cross module purity uses the exact source anchor when the cached import SID is missing" {
    try checkAliasedPurity("function visible(){console.log('side')}/* @__NO_SIDE_EFFECTS__ */ function actual(){return 7}export{actual as visible};", true, true, .none);
}

test "cross module purity rejects a source-property redirect even when its cached foreign SID is poisoned" {
    try checkAliasedPurity("function visible(){console.log('side')}/* @__NO_SIDE_EFFECTS__ */ function safeSibling(){return 7}export{visible,safeSibling};", false, false, .imported_name);
}

test "cross module purity rejects a resolved-source redirect to a pure sibling module" {
    try checkAliasedPurity("function visible(){console.log('side')}export{visible};", false, false, .resolved_source);
}

test "PM ordinary import target rejects a replaced source export carrier" {
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "const first=7,second=99;export{first as value,second as other};");
    const path = try helpers.absPath(&tmp, "provider.mjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{path});
    const module = graph.modules.at(0);
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    const canonical = @import("../linker.zig").SymbolRef{ .module_index = module.index, .export_name = "value" };
    try std.testing.expect(linker.ordinaryCanonicalImportTarget(canonical) != null);
    const selected = @constCast(module.findExportBinding("value").?);
    const other = module.findExportBinding("other").?;
    const original = selected.*;
    defer selected.* = original;
    selected.symbol = other.symbol;
    selected.local_symbol_node = other.local_symbol_node;
    try std.testing.expect(linker.ordinaryCanonicalImportTarget(canonical) == null);
}

test "public entry default-only PM facade preserves scalar and internal namespace ownership" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    const compat = @import("../../transformer/compat.zig");
    const providers = [_][]const u8{
        "globalThis.facadeRuns=(globalThis.facadeRuns||0)+1;export default 42;",
        "globalThis.facadeRuns=(globalThis.facadeRuns||0)+1;export default null;",
        "globalThis.facadeRuns=(globalThis.facadeRuns||0)+1;export default Object.freeze(function read(){return 42});",
        "await Promise.resolve();globalThis.facadeRuns=(globalThis.facadeRuns||0)+1;export default 42;",
        "import './consumer.mjs';globalThis.facadeRuns=(globalThis.facadeRuns||0)+1;export default function read(){return 42};",
        "await Promise.resolve();globalThis.facadeRuns=(globalThis.facadeRuns||0)+1;export default 42;",
    };
    for (providers, 0..) |source, scenario| for ([_]compat.ESTarget{ .es5, .esnext }) |target| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "nested/provider.mjs", source);
        try helpers.writeFile(tmp.dir, "nested/consumer.mjs", if (scenario == 5)
            "export default async function load(){const namespace=await import('./provider.mjs');return [Object.keys(namespace).sort(),namespace.default]};"
        else
            "import value from './provider.mjs';export default function read(){return typeof value==='function'?value():value};");
        const provider = try helpers.absPath(&tmp, "nested/provider.mjs");
        defer std.testing.allocator.free(provider);
        const consumer = try helpers.absPath(&tmp, "nested/consumer.mjs");
        defer std.testing.allocator.free(consumer);
        const root = try helpers.absPath(&tmp, ".");
        defer std.testing.allocator.free(root);
        const provider_uri = try std.json.Stringify.valueAlloc(a, try std.fmt.allocPrint(a, "file://{s}", .{provider}), .{});
        const consumer_uri = try std.json.Stringify.valueAlloc(a, try std.fmt.allocPrint(a, "file://{s}", .{consumer}), .{});
        const observe = "console.log(JSON.stringify({kind:value===null?'null':typeof value,value:typeof value==='function'?value():value,frozen:typeof value==='function'?Object.isFrozen(value):null,consumer:await read(),runs:globalThis.facadeRuns}));";
        const native_script = try std.fmt.allocPrint(a, "const read=(await import({s})).default;const value=(await import({s})).default;{s}", .{ consumer_uri, provider_uri, observe });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_script } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{ consumer, provider },
            .platform = .react_native,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = root,
            .unsupported = compat.fromESTarget(target),
            // Prove actual requested masks; the RN preset otherwise replaces
            // unsupported with the Hermes version-matrix feature mask.
            .rn_version_matrix = compat.fromESTarget(target),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
            .metafile = true,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        var public_count: usize = 0;
        var provider_bodies: usize = 0;
        var consumer_bodies: usize = 0;
        for (result.outputs orelse return error.TestUnexpectedResult) |file| {
            try helpers.writeFile(tmp.dir, file.path, file.contents);
            if (file.public_entry_facade) |facade| {
                public_count += 1;
                try std.testing.expect(!facade.module_index.isNone());
                try std.testing.expect(!facade.implementation_chunk.isNone());
                try std.testing.expectEqual(@as(usize, 0), file.module_ids.len);
                try std.testing.expectEqual(@as(usize, 1), file.imports.len);
                try std.testing.expect(!std.mem.eql(u8, file.path, file.imports[0]));
            }
            for (file.module_ids) |id| {
                if (std.mem.eql(u8, id, provider)) provider_bodies += 1;
                if (std.mem.eql(u8, id, consumer)) consumer_bodies += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), public_count);
        try std.testing.expectEqual(@as(usize, 1), provider_bodies);
        try std.testing.expectEqual(@as(usize, 1), consumer_bodies);
        const metafile = result.metafile_json orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, metafile, "\"entryPoint\"") != null);
        const provider_output = try helpers.absPath(&tmp, "nested/provider.js");
        defer std.testing.allocator.free(provider_output);
        const consumer_output = try helpers.absPath(&tmp, "nested/consumer.js");
        defer std.testing.allocator.free(consumer_output);
        const quoted_provider = try std.json.Stringify.valueAlloc(a, provider_output, .{});
        const quoted_consumer = try std.json.Stringify.valueAlloc(a, consumer_output, .{});
        const actual_script = try std.fmt.allocPrint(a, "(async function(){{const read=await require({s});const value=await require({s});{s}}})().catch(function(error){{console.error(error);process.exitCode=1}});", .{ quoted_consumer, quoted_provider, observe });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", actual_script } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, actual.stdout, native.stdout)) {
            std.debug.print("public default facade scenario={} target={s} minify={} native={s} actual={s} stderr={s}\n", .{ scenario, @tagName(target), minify, native.stdout, actual.stdout, actual.stderr });
            for (result.outputs.?) |file| std.debug.print("public default facade output {s}:\n{s}\n", .{ file.path, file.contents });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

// Test-only inspection of the complete raw output program. Its dead lexical
// annotations intentionally make it a multi-statement program, unlike the
// single host-value expression accepted by Program.hostExportValue/emitValue.
const RawFacadeProgramCheck = struct {
    const Program = @import("../compiler_output_program.zig").Program;
    const Kind = @import("../../lexer/token.zig").Kind;

    fn node(program: *const Program, index: NodeIndex, tag: ast_mod.Node.Tag) !ast_mod.Node {
        try std.testing.expect(!index.isNone() and @backingInt(index) < program.ast.nodes.items.len);
        const value = program.ast.getNode(index);
        try std.testing.expectEqual(tag, value.tag);
        return value;
    }
    fn unparen(program: *const Program, index: NodeIndex) NodeIndex {
        var current = index;
        while (program.ast.getNode(current).tag == .parenthesized_expression)
            current = program.ast.getNode(current).data.unary.operand;
        return current;
    }
    fn zero(program: *const Program, index: NodeIndex) !void {
        const value = try node(program, index, .numeric_literal);
        try std.testing.expectEqualStrings("0", program.ast.getText(value.span));
    }
    fn global(program: *const Program, index: NodeIndex, name: []const u8) !void {
        const value = try node(program, index, .identifier_reference);
        try std.testing.expectEqualStrings(name, program.ast.identifierNameText(value));
        try std.testing.expect(@backingInt(index) < program.analysis.symbol_ids.items.len);
        try std.testing.expect(program.analysis.symbol_ids.items[@backingInt(index)] == null);
    }
    fn member(program: *const Program, index: NodeIndex, computed: bool) ![2]NodeIndex {
        const value = try node(program, index, if (computed) .computed_member_expression else .static_member_expression);
        try std.testing.expect(program.ast.hasExtra(value.data.extra, 2));
        try std.testing.expectEqual(@as(u32, 0), program.ast.readExtra(value.data.extra, 2));
        return .{ program.ast.readExtraNode(value.data.extra, 0), program.ast.readExtraNode(value.data.extra, 1) };
    }
    fn host(program: *const Program, index: NodeIndex) !void {
        const parts = try member(program, index, false);
        try global(program, parts[0], "module");
        const key = try node(program, parts[1], .identifier_reference);
        try std.testing.expectEqualStrings("exports", program.ast.identifierNameText(key));
    }
    fn string(program: *const Program, allocator: std.mem.Allocator, index: NodeIndex, expected: []const u8) !void {
        _ = try node(program, index, .string_literal);
        const value = (try program.ast.staticKeyName(allocator, index)) orelse return error.TestUnexpectedResult;
        defer allocator.free(value);
        try std.testing.expectEqualStrings(expected, value);
    }
    fn assignment(program: *const Program, index: NodeIndex) !ast_mod.Node {
        const value = try node(program, unparen(program, index), .assignment_expression);
        try std.testing.expectEqual(@as(u32, @backingInt(Kind.eq)), value.data.binary.flags);
        return value;
    }
    fn requireCall(program: *const Program, allocator: std.mem.Allocator, index: NodeIndex, expected: []const u8) !void {
        const call = try node(program, index, .call_expression);
        try std.testing.expect(program.ast.hasExtra(call.data.extra, 3));
        try std.testing.expectEqual(@as(u32, 0), program.ast.readExtra(call.data.extra, 3));
        try global(program, program.ast.readExtraNode(call.data.extra, 0), "require");
        try std.testing.expectEqual(@as(u32, 1), program.ast.readExtra(call.data.extra, 2));
        const start = program.ast.readExtra(call.data.extra, 1);
        try std.testing.expect(start < program.ast.extra_data.items.len);
        try string(program, allocator, @fromBackingInt(program.ast.extra_data.items[start]), expected);
    }
    fn run(program: *const Program, allocator: std.mem.Allocator, facade: PublicEntryFacade, raw: RawFacadeKeys) !void {
        try program.validate();
        const root = try node(program, program.root, .program);
        try std.testing.expectEqual(@as(usize, 1) + raw.public_keys.len + raw.external_reexports.len, @as(usize, root.data.list.len));
        var statements = program.ast.iterateExtraList(root.data.list);
        const first = try node(program, statements.next() orelse return error.TestUnexpectedResult, .expression_statement);
        const exported = try assignment(program, first.data.unary.operand);
        try host(program, exported.data.binary.left);
        const invoke = try node(program, exported.data.binary.right, .call_expression);
        try std.testing.expect(program.ast.hasExtra(invoke.data.extra, 3));
        try std.testing.expectEqual(@as(u32, 0), program.ast.readExtra(invoke.data.extra, 2));
        try std.testing.expectEqual(@as(u32, 0), program.ast.readExtra(invoke.data.extra, 3));
        const callee = try node(program, unparen(program, program.ast.readExtraNode(invoke.data.extra, 0)), .sequence_expression);
        try std.testing.expectEqual(@as(u32, 2), callee.data.list.len);
        var sequence = program.ast.iterateExtraList(callee.data.list);
        try zero(program, sequence.next() orelse return error.TestUnexpectedResult);
        const thunk = try member(program, sequence.next() orelse return error.TestUnexpectedResult, true);
        const relative = try computeRelativePath(allocator, std.fs.path.dirname(facade.public_path) orelse "", facade.implementation_path, "");
        defer allocator.free(relative);
        try requireCall(program, allocator, thunk[0], relative);
        try string(program, allocator, thunk[1], facade.init_key);
        for (0..raw.public_keys.len + raw.external_reexports.len) |index| {
            const statement = try node(program, statements.next() orelse return error.TestUnexpectedResult, .expression_statement);
            const dead = try node(program, statement.data.unary.operand, .logical_expression);
            try std.testing.expectEqual(@as(u32, @backingInt(Kind.amp2)), dead.data.binary.flags);
            try zero(program, dead.data.binary.left);
            const value = try assignment(program, dead.data.binary.right);
            if (index < raw.public_keys.len) {
                const property = try member(program, value.data.binary.left, true);
                try host(program, property[0]);
                try string(program, allocator, property[1], raw.public_keys[index]);
                try zero(program, value.data.binary.right);
            } else {
                try host(program, value.data.binary.left);
                try requireCall(program, allocator, value.data.binary.right, raw.external_reexports[index - raw.public_keys.len]);
            }
        }
        try std.testing.expect(statements.next() == null);
    }
};

fn checkPublicFacadeOutputAllocation(allocator: std.mem.Allocator, facade: PublicEntryFacade, source_path: []const u8) !void {
    const output = try makePublicEntryFacadeOutput(allocator, facade, source_path, facade.implementation_path, null);
    defer output.deinit(allocator);
    try std.testing.expectEqualStrings(facade.public_path, output.path);
    try std.testing.expectEqualStrings(source_path, output.public_entry_facade.?.source_path);
    try std.testing.expectEqual(facade.module_index, output.public_entry_facade.?.module_index);
    try std.testing.expectEqual(facade.chunk_index, output.public_entry_facade.?.implementation_chunk);
    try std.testing.expectEqual(@as(usize, 0), output.module_ids.len);
    try std.testing.expectEqualStrings(facade.implementation_path, output.imports[0]);
    const raw_keys: []const []const u8 = switch (facade.projection) {
        .esm_default => &.{},
        .cjs_result => |raw| raw.public_keys,
    };
    try std.testing.expectEqual(raw_keys.len + 1, output.exports.len);
    try std.testing.expectEqualStrings("default", output.exports[0]);
    for (raw_keys, output.exports[1..]) |source_key, output_key| try std.testing.expectEqualStrings(source_key, output_key);
    const program = output.compiler_output_program orelse return error.MissingCompilerOutputProgram;
    switch (facade.projection) {
        .esm_default => {
            const value = try program.hostExportValue();
            try std.testing.expect(program.ast.getNode(value).tag == .call_expression);
        },
        .cjs_result => |raw| try RawFacadeProgramCheck.run(program, allocator, facade, raw),
    }
    const parameter_count: usize = switch (facade.projection) {
        .esm_default => 1,
        .cjs_result => 0,
    };
    try std.testing.expectEqual(parameter_count, program.locals.len);
    try std.testing.expectEqual(parameter_count, program.functions.len);
}

test "public entry facade owner rejects foreign roles and frees every artifact allocation" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "export default 42;");
    try helpers.writeFile(tmp.dir, "foreign.mjs", "export default 42;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const foreign_path = try helpers.absPath(&tmp, "foreign.mjs");
    defer a.free(foreign_path);
    const entries = [_][]const u8{ entry, foreign_path };
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    // Use the real wrap-all and wrapper-symbol birth producers, never attach
    // guessed SymbolIds to a fabricated namespace/initializer.
    graph.dev_mode = true;
    try graph.build(std.testing.io, &entries);
    var linker = Linker.init(a, &graph, .cjs);
    defer linker.deinit();
    try linker.link();
    var chunks = try chunk_mod.generatePreserveModulesChunks(a, &graph, &entries, null);
    defer chunks.deinit();
    const owner = graph.findModuleByPath(entry) orelse return error.TestUnexpectedResult;
    const foreign = graph.findModuleByPath(foreign_path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(WrapKind.esm, owner.wrap_kind);
    const init_identity = try owner.esmInitSymbol();
    const namespace_identity = try owner.esmNamespaceSymbol();
    const facade: PublicEntryFacade = .{
        .module_index = owner.index,
        .chunk_index = chunks.getModuleChunk(owner.index),
        .owner_token = owner.semantic.?.owner_token,
        .init_identity = init_identity,
        .projection = .{ .esm_default = .{
            .namespace_identity = namespace_identity,
            .namespace_key = try a.dupe(u8, try owner.esmWrapperName(namespace_identity, null)),
            .awaited = owner.in_async_cone,
        } },
        .init_key = try a.dupe(u8, try owner.esmWrapperName(init_identity, null)),
        .public_path = try a.dupe(u8, "nested/entry.js"),
        .implementation_path = try a.dupe(u8, "chunks/entry-body.js"),
    };
    defer facade.deinit(a);
    try std.testing.expect((try facade.checkedOwner(&graph, &chunks)) == owner);
    var poison = facade;
    poison.module_index = foreign.index;
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.chunk_index = chunks.getModuleChunk(foreign.index);
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.owner_token = foreign.semantic.?.owner_token;
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.init_identity = namespace_identity;
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.projection.esm_default.namespace_identity = init_identity;
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.projection.esm_default.namespace_key = "foreign_namespace";
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.projection.esm_default.awaited = !facade.isAwaited();
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    try checkPublicFacadeOutputAllocation(a, facade, owner.path);
    try std.testing.checkAllAllocationFailures(a, checkPublicFacadeOutputAllocation, .{ facade, owner.path });
    try std.testing.expect((try facade.checkedOwner(&graph, &chunks)) == owner);
}

test "public entry facade rejects implementation and public filename collisions" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    for ([_]bool{ false, true }) |public_collision| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import './provider.mjs';globalThis.entryEffects=1;export default 42;");
        try helpers.writeFile(tmp.dir, "provider.mjs", "globalThis.providerEffects=1;export default 43;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer a.free(entry);
        const provider = try helpers.absPath(&tmp, "provider.mjs");
        defer a.free(provider);
        const entries = [_][]const u8{ entry, provider };
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = &entries,
            .platform = .react_native,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .chunk_names = if (public_collision) "[name]" else "collision",
        });
        defer bundler.deinit();
        try std.testing.expectError(error.PublicEntryFacadePathCollision, bundler.bundle(std.testing.io));
    }
}

test "public entry facade owns one cyclic bootstrap in either public entry order" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const compat = @import("../../transformer/compat.zig");
    for ([_]bool{ false, true }) |reverse| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "provider.mjs", "import './consumer.mjs';(globalThis.__zntcFacadeEvents4746||(globalThis.__zntcFacadeEvents4746=[])).push('provider');export default function readProvider(){return 42};");
        try helpers.writeFile(tmp.dir, "consumer.mjs", "import readProvider from './provider.mjs';(globalThis.__zntcFacadeEvents4746||(globalThis.__zntcFacadeEvents4746=[])).push('consumer');export default function readConsumer(){return readProvider()};");
        const provider = try helpers.absPath(&tmp, "provider.mjs");
        defer a.free(provider);
        const consumer = try helpers.absPath(&tmp, "consumer.mjs");
        defer a.free(consumer);
        const entries = if (reverse) [_][]const u8{ provider, consumer } else [_][]const u8{ consumer, provider };
        var native_code: std.ArrayListUnmanaged(u8) = .empty;
        var actual_code: std.ArrayListUnmanaged(u8) = .empty;
        try actual_code.appendSlice(scratch, "(async function(){");
        for (entries) |entry| {
            const name = if (std.mem.eql(u8, entry, provider)) "provider" else "consumer";
            const uri = try std.json.Stringify.valueAlloc(scratch, try std.fmt.allocPrint(scratch, "file://{s}", .{entry}), .{});
            try native_code.print(scratch, "const {s}=(await import({s})).default;", .{ name, uri });
            const output_path = try std.fmt.allocPrint(scratch, "{s}/{s}.js", .{ std.fs.path.dirname(entry).?, name });
            const quoted = try std.json.Stringify.valueAlloc(scratch, output_path, .{});
            try actual_code.print(scratch, "const {s}=await require({s});", .{ name, quoted });
        }
        const observe = "console.log(JSON.stringify([provider(),consumer(),globalThis.__zntcFacadeEvents4746]));";
        try native_code.appendSlice(scratch, observe);
        try actual_code.appendSlice(scratch, observe);
        try actual_code.appendSlice(scratch, "})().catch(function(error){console.error(error);process.exitCode=1});");
        const native = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_code.items } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = &entries,
            .platform = .react_native,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = std.fs.path.dirname(provider),
            .unsupported = compat.fromESTarget(.es5),
            .rn_version_matrix = compat.fromESTarget(.es5),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        for (result.outputs.?) |output| try helpers.writeFile(tmp.dir, output.path, output.contents);
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "-e", actual_code.items } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
            std.debug.print("public facade cycle reverse={} minify={} native={s} actual={s} stderr={s}\n", .{ reverse, minify, native.stdout, actual.stdout, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "public entry facade guards a throwing initializer exactly once" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const compat = @import("../../transformer/compat.zig");
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "export default 42;globalThis.effects=(globalThis.effects||0)+1;throw Error('expected entry failure');");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer a.free(entry);
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = &.{entry},
            .platform = .react_native,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .entry_error_guard = true,
            .unsupported = compat.fromESTarget(.es5),
            .rn_version_matrix = compat.fromESTarget(.es5),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        for (result.outputs.?) |output| try helpers.writeFile(tmp.dir, output.path, output.contents);
        const output_path = try helpers.absPath(&tmp, "entry.js");
        defer a.free(output_path);
        const quoted = try std.json.Stringify.valueAlloc(scratch, output_path, .{});
        const script = try std.fmt.allocPrint(scratch, "let reports=0;globalThis.ErrorUtils={{reportFatalError(error){{if(error.message!=='expected entry failure')throw error;reports++}}}};const first=require({s});const second=require({s});console.log(JSON.stringify([first,second,globalThis.effects,reports]));", .{ quoted, quoted });
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
        if (actual.term != .exited or actual.term.exited != 0)
            std.debug.print("public facade guarded minify={} stderr={s}\n", .{ minify, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings("[42,42,1,1]\n", actual.stdout);
    }
}

test "public entry PM dynamic ESM selects exact namespace while raw CJS keeps its contract" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const compat = @import("../../transformer/compat.zig");
    for (0..6) |scenario| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const raw_cjs = scenario == 3;
        const provider_name = if (raw_cjs) "provider.cjs" else "provider.mjs";
        try helpers.writeFile(tmp.dir, provider_name, switch (scenario) {
            1 => "export const then=7;export default 42;",
            3 => "module.exports=42;",
            4 => "await Promise.resolve();throw Error('expected dependency');export default 42;",
            else => "export default 42;",
        });
        const source = try std.fmt.allocPrint(scratch, "{s}export default function load({s}){{return import('./{s}').then(function(namespace){{return {s};}})}};", .{
            if (scenario == 2) "const Promise={get tag(){globalThis.shadowReads=(globalThis.shadowReads||0)+1;return 7},resolve(){throw Error('used source Promise')}};" else "",
            if (scenario == 5) "require,module,Promise,__tlaReadyAll,__tlaNamespaceState,a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z" else "",
            provider_name,
            if (scenario == 5) "[namespace.default,[require,module,Promise,__tlaReadyAll,__tlaNamespaceState,a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z].reduce(function(sum,value){return sum+value},0)]" else if (raw_cjs) "[typeof namespace.default,namespace.default]" else if (scenario == 2) "[Object.keys(namespace).sort(),namespace.default,Promise.tag]" else "[Object.keys(namespace).sort(),namespace.default]",
        });
        try helpers.writeFile(tmp.dir, "consumer.mjs", source);
        const provider = try helpers.absPath(&tmp, provider_name);
        defer a.free(provider);
        const consumer = try helpers.absPath(&tmp, "consumer.mjs");
        defer a.free(consumer);
        const uri = try std.json.Stringify.valueAlloc(scratch, try std.fmt.allocPrint(scratch, "file://{s}", .{consumer}), .{});
        const observe = "let syncThrow=false,pending;try{pending=load.apply(null,Array(31).fill(7))}catch(error){syncThrow=true;pending=Promise.reject(error)}const value=await pending.then(function(result){return ['ok',result]},function(error){return ['error',error.message]});console.log(JSON.stringify([syncThrow,value,globalThis.shadowReads||0]));";
        const native_script = try std.fmt.allocPrint(scratch, "const load=(await import({s})).default;{s}", .{ uri, observe });
        const native = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_script } });
        if (native.term != .exited or native.term.exited != 0) std.debug.print("dynamic native scenario={} stderr={s}\n", .{ scenario, native.stderr });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        const entries = [_][]const u8{ consumer, provider };
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = if (raw_cjs) entries[0..1] else &entries,
            .platform = .react_native,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = std.fs.path.dirname(consumer),
            .unsupported = compat.fromESTarget(.es5),
            .rn_version_matrix = compat.fromESTarget(.es5),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        for (result.outputs.?) |output| try helpers.writeFile(tmp.dir, output.path, output.contents);
        const output_path = try helpers.absPath(&tmp, "consumer.js");
        defer a.free(output_path);
        const quoted = try std.json.Stringify.valueAlloc(scratch, output_path, .{});
        const actual_script = try std.fmt.allocPrint(scratch, "(async function(){{const load=await require({s});{s}}})().catch(function(error){{console.error(error);process.exitCode=1}});", .{ quoted, observe });
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "-e", actual_script } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            std.debug.print("PM dynamic namespace scenario={} minify={} native={s} actual={s} stderr={s}\n", .{ scenario, minify, native.stdout, actual.stdout, actual.stderr });
            for (result.outputs.?) |output| std.debug.print("PM dynamic output {s}:\n{s}\n", .{ output.path, output.contents });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "public entry PM native with and import attributes preserve their exact boundary" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const cases = [_]struct { filename: []const u8, source: []const u8 }{
        .{ .filename = "consumer.cjs", .source = "module.exports=function load(){with({require:7,module:7,Promise:7,__tlaReadyAll:7,__tlaNamespaceState:7}){return import('./provider.mjs').then(function(namespace){return namespace.default})}};" },
        .{ .filename = "consumer.mjs", .source = "export default function load(require){const options={get with(){globalThis.optionReads=(globalThis.optionReads||0)+1;return {}}};return import('./provider.mjs',options).then(namespace=>[namespace.default,globalThis.optionReads,require])}" },
        .{ .filename = "consumer.mjs", .source = "export default function load(require){const options={get with(){globalThis.optionReads=(globalThis.optionReads||0)+1;return {type:'json'}}};return import('./provider.mjs',options).then(()=>['unexpected'],error=>[error.code,globalThis.optionReads,require])}" },
        .{ .filename = "consumer.mjs", .source = "export default function load(){const options={get with(){globalThis.optionReads=(globalThis.optionReads||0)+1;return {type:'json'}}};return import('./data.json',options).then(namespace=>[namespace.default.answer,globalThis.optionReads])}" },
    };
    for (cases, 0..) |case, index| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "provider.mjs", "export default 42;");
        if (index == 3) try helpers.writeFile(tmp.dir, "data.json", "{\"answer\":42}");
        try helpers.writeFile(tmp.dir, case.filename, case.source);
        const entry = try helpers.absPath(&tmp, case.filename);
        defer a.free(entry);
        const uri = try std.json.Stringify.valueAlloc(scratch, try std.fmt.allocPrint(scratch, "file://{s}", .{entry}), .{});
        const native_script = try std.fmt.allocPrint(scratch, "const load=(await import({s})).default;console.log(JSON.stringify(await load(7)));", .{uri});
        const native = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_script } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = &.{entry},
            .platform = .react_native,
            .rn_version_matrix = @import("../../transformer/compat.zig").fromESTarget(.esnext),
            .entry_error_guard = false,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        var snippets: usize = 0;
        for (result.outputs.?) |output| {
            try helpers.writeFile(tmp.dir, output.path, output.contents);
            for (output.compiler_output_snippets) |program| {
                try program.validate();
                try std.testing.expectEqual(@as(usize, 1), program.locals.len);
                try std.testing.expectEqual(@as(usize, 2), program.functions.len);
                snippets += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, if (index == 3) 0 else 1), snippets);
        const output_path = try helpers.absPath(&tmp, "consumer.js");
        defer a.free(output_path);
        const quoted = try std.json.Stringify.valueAlloc(scratch, output_path, .{});
        const script = try std.fmt.allocPrint(scratch, "(async()=>console.log(JSON.stringify(await require({s})(7))))().catch(error=>{{console.error(error);process.exitCode=1}});", .{quoted});
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            std.debug.print("PM native boundary index={} minify={} native={s} actual={s} stderr={s}\n", .{ index, minify, native.stdout, actual.stdout, actual.stderr });
            for (result.outputs.?) |output| std.debug.print("PM native boundary output {s}:\n{s}\n", .{ output.path, output.contents });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        try std.testing.expectEqualStrings("", actual.stderr);
    };
}

test "public entry raw CJS facade preserves source values lexical keys and internal transport across all modes" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const compat = @import("../../transformer/compat.zig");
    const OutputExports = @import("../bundler.zig").OutputExports;
    const sources = [_][]const u8{
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;module.exports=42;",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;module.exports=null;",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;module.exports=Object.freeze(function answer(){return 42});",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;exports.answer=42;exports.update=function(){exports.answer=43};",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;Object.defineProperty(exports,'answer',{value:42,enumerable:true,configurable:false});",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;var answer=42;Object.defineProperty(exports,'answer',{get:function(){return answer},enumerable:true});exports.update=function(){answer=43};",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;Object.defineProperty(exports,'__proto__',{value:42,enumerable:true});Object.defineProperty(exports,'__esModule',{value:7,enumerable:true});exports.answer=42;",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;module.exports={answer:42,[\"__proto__\"]:42,__esModule:7};",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;module.exports=Object.freeze({answer:42});",
        "globalThis.__rawProviderEvaluations4746=(globalThis.__rawProviderEvaluations4746||0)+1;module.exports=Object.freeze([40,2]);",
    };
    const consumer_source = "module.exports=function load(){return import('./provider.cjs').then(function(namespace){const value=namespace.default;return [typeof value,value===null,typeof value==='function'?value():value&&value.answer===42?42:value,globalThis.__rawProviderEvaluations4746]})};";
    const observer = "import{createRequire}from'node:module';import{pathToFileURL}from'node:url';const require=createRequire(import.meta.url);function describe(value){const boxed=Object(value);return {type:typeof value,isNull:value===null,frozen:Object.isFrozen(value),call:typeof value==='function'?value():null,keys:Object.keys(boxed).sort(),arrayValues:Array.isArray(value)?Array.from(value):null,answer:boxed.answer===undefined?null:boxed.answer,protoOwn:Object.hasOwn(boxed,'__proto__'),protoValue:Object.hasOwn(boxed,'__proto__')?boxed.__proto__:null,markerOwn:Object.hasOwn(boxed,'__esModule'),markerValue:Object.hasOwn(boxed,'__esModule')?boxed.__esModule:null}};const value=require(process.argv[2]);const namespace=await import(pathToFileURL(process.argv[2]).href);const before=describe(value);if(typeof value?.update==='function')value.update();const after=describe(value);const load=require(process.argv[3]);const dynamic=await load();console.log(JSON.stringify({before,after,namespaceKeys:Object.keys(namespace).sort(),namespaceAnswer:namespace.answer??null,same:namespace.default===value,effects:globalThis.__rawProviderEvaluations4746,dynamic}));";
    for (sources, 0..) |source, scenario| for ([_]OutputExports{ .auto, .named, .default_, .none }) |mode| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "provider.cjs", source);
        try helpers.writeFile(tmp.dir, "consumer.cjs", consumer_source);
        try helpers.writeFile(tmp.dir, "observe.mjs", observer);
        const provider = try helpers.absPath(&tmp, "provider.cjs");
        defer a.free(provider);
        const consumer = try helpers.absPath(&tmp, "consumer.cjs");
        defer a.free(consumer);
        const observer_path = try helpers.absPath(&tmp, "observe.mjs");
        defer a.free(observer_path);
        const root = try helpers.absPath(&tmp, ".");
        defer a.free(root);
        const native = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", observer_path, provider, consumer } });
        if (native.term != .exited or native.term.exited != 0) std.debug.print("raw facade source scenario={} stderr={s}\n", .{ scenario, native.stderr });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = &.{ consumer, provider },
            .platform = .react_native,
            .format = .cjs,
            .output_exports = mode,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = root,
            .unsupported = compat.fromESTarget(.esnext),
            .rn_version_matrix = compat.fromESTarget(.esnext),
            .entry_error_guard = false,
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
            .metafile = true,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        var public_artifacts: usize = 0;
        var provider_bodies: usize = 0;
        for (result.outputs orelse return error.TestUnexpectedResult) |output| {
            try helpers.writeFile(tmp.dir, output.path, output.contents);
            if (output.public_entry_facade) |proof| {
                try std.testing.expect(output.module_ids.len == 0);
                try std.testing.expect(output.compiler_output_program != null);
                if (std.mem.eql(u8, proof.source_path, provider) or std.mem.eql(u8, proof.source_path, consumer)) public_artifacts += 1;
            }
            for (output.module_ids) |id| if (std.mem.eql(u8, id, provider)) {
                provider_bodies += 1;
            };
        }
        try std.testing.expectEqual(@as(usize, 2), public_artifacts);
        try std.testing.expectEqual(@as(usize, 1), provider_bodies);
        const actual_provider = try helpers.absPath(&tmp, "provider.js");
        defer a.free(actual_provider);
        const actual_consumer = try helpers.absPath(&tmp, "consumer.js");
        defer a.free(actual_consumer);
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", observer_path, actual_provider, actual_consumer } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            std.debug.print("raw facade scenario={} mode={s} minify={} native={s} actual={s} stderr={s}\n", .{ scenario, @tagName(mode), minify, native.stdout, actual.stdout, actual.stderr });
            for (result.outputs.?) |output| std.debug.print("raw facade output {s}:\n{s}\n", .{ output.path, output.contents });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "public entry raw CJS facade validates its actual wrapper owner and projection before allocation" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.cjs", "exports.answer=42;Object.defineProperty(exports,'__proto__',{value:7,enumerable:true});");
    try helpers.writeFile(tmp.dir, "foreign.cjs", "exports.answer=99;");
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer a.free(entry);
    const foreign_path = try helpers.absPath(&tmp, "foreign.cjs");
    defer a.free(foreign_path);
    const entries = [_][]const u8{ entry, foreign_path };
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    graph.dev_mode = true;
    graph.preserve_modules = true;
    try graph.build(std.testing.io, &entries);
    var linker = Linker.init(a, &graph, .cjs);
    defer linker.deinit();
    try linker.link();
    var chunks = try chunk_mod.generatePreserveModulesChunks(a, &graph, &entries, null);
    defer chunks.deinit();
    const owner = graph.findModuleByPath(entry) orelse return error.TestUnexpectedResult;
    const foreign = graph.findModuleByPath(foreign_path) orelse return error.TestUnexpectedResult;
    const require_id = owner.require_symbol orelse return error.TestUnexpectedResult;
    const facade: PublicEntryFacade = .{
        .module_index = owner.index,
        .chunk_index = chunks.getModuleChunk(owner.index),
        .owner_token = owner.semantic.?.owner_token,
        .init_identity = SymbolID.make(owner.index, @backingInt(require_id)),
        .init_key = try a.dupe(u8, owner.getRequireName(null) orelse return error.TestUnexpectedResult),
        .public_path = try a.dupe(u8, "entry.js"),
        .implementation_path = try a.dupe(u8, "chunks/entry-body.js"),
        .projection = .{ .cjs_result = try collectRawFacadeKeys(a, &graph, owner.index) },
    };
    defer facade.deinit(a);
    try std.testing.expect((try facade.checkedOwner(&graph, &chunks)) == owner);
    try std.testing.expectEqual(@as(usize, 2), facade.projection.cjs_result.public_keys.len);
    var poison = facade;
    poison.init_identity = SymbolID.make(foreign.index, @backingInt(foreign.require_symbol.?));
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.init_key = foreign.getRequireName(null).?;
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.owner_token = foreign.semantic.?.owner_token;
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.projection.cjs_result.public_keys = &.{"unrelated"};
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    poison = facade;
    poison.projection.cjs_result.external_reexports = &.{"node:fs"};
    try std.testing.expectError(error.InvalidPublicEntryFacadeOwner, poison.checkedOwner(&graph, &chunks));
    try checkPublicFacadeOutputAllocation(a, facade, owner.path);
    try std.testing.checkAllAllocationFailures(a, checkPublicFacadeOutputAllocation, .{ facade, owner.path });
    try std.testing.expect((try facade.checkedOwner(&graph, &chunks)) == owner);
}

test "public entry raw CJS facade retains cycle ordering and direct throw retry ownership" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const compat = @import("../../transformer/compat.zig");
    for ([_]bool{ false, true }) |throwing| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "provider.cjs", if (throwing)
            "globalThis.rawRuns=(globalThis.rawRuns||0)+1;throw Error('expected raw throw');"
        else
            "exports.before=40;const peer=require('./consumer.cjs');exports.answer=peer.read()+2;");
        try helpers.writeFile(tmp.dir, "consumer.cjs", if (throwing)
            "module.exports=7;"
        else
            "const provider=require('./provider.cjs');exports.read=function(){return provider.before};");
        const provider = try helpers.absPath(&tmp, "provider.cjs");
        defer a.free(provider);
        const consumer = try helpers.absPath(&tmp, "consumer.cjs");
        defer a.free(consumer);
        const root = try helpers.absPath(&tmp, ".");
        defer a.free(root);
        const quoted_source = try std.json.Stringify.valueAlloc(scratch, provider, .{});
        const observe = if (throwing)
            "globalThis.ErrorUtils={reportFatalError(){globalThis.swallowed=(globalThis.swallowed||0)+1}};let failures=[];for(let count=0;count<2;count++){try{require(PATH)}catch(error){failures.push(error.message)}}console.log(JSON.stringify([failures,globalThis.rawRuns,globalThis.swallowed||0]));"
        else
            "console.log(JSON.stringify(require(PATH).answer));";
        const source_script = try std.mem.replaceOwned(u8, scratch, observe, "PATH", quoted_source);
        const native = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "-e", source_script } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = @import("../bundler.zig").Bundler.init(a, .{
            .entry_points = &.{ provider, consumer },
            .platform = .react_native,
            .format = .cjs,
            .preserve_modules = true,
            .code_splitting = true,
            .preserve_modules_root = root,
            .unsupported = compat.fromESTarget(.es5),
            .rn_version_matrix = compat.fromESTarget(.es5),
            .entry_error_guard = true,
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        for (result.outputs orelse return error.TestUnexpectedResult) |output| try helpers.writeFile(tmp.dir, output.path, output.contents);
        const target = try helpers.absPath(&tmp, "provider.js");
        defer a.free(target);
        const quoted_target = try std.json.Stringify.valueAlloc(scratch, target, .{});
        const actual_script = try std.mem.replaceOwned(u8, scratch, observe, "PATH", quoted_target);
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "-e", actual_script } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            std.debug.print("raw CJS bootstrap throwing={} minify={} native={s} actual={s} stderr={s}\n", .{ throwing, minify, native.stdout, actual.stdout, actual.stderr });
            for (result.outputs.?) |output| std.debug.print("raw CJS bootstrap output {s}:\n{s}\n", .{ output.path, output.contents });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}
