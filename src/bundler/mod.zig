//! ZTS Bundler
//!
//! 여러 JS/TS 파일을 하나의 번들로 합치는 모듈 번들러.
//! Phase 6 — resolver, 모듈 그래프, 스코프 호이스팅, tree-shaking, code splitting.
//!
//! 설계:
//!   - D056: 품질 먼저 → 속도 추가 (Rolldown 전략)
//!   - D057: 모듈 그래프가 모든 기능의 기반
//!   - D081: 3계층 resolver (resolver + cache + plugin)
//!
//! 사용법:
//!   const bundler = @import("bundler/mod.zig");
//!   // (Phase B1 완성 후)
//!   // var b = bundler.Bundler.init(allocator, options);
//!   // const result = try b.bundle();

pub const types = @import("types.zig");
pub const import_scanner = @import("import_scanner.zig");
pub const resolver = @import("resolver.zig");
pub const package_json = @import("package_json.zig");
pub const resolve_cache = @import("resolve_cache.zig");
pub const module = @import("module.zig");
pub const graph = @import("graph.zig");
pub const emitter = @import("emitter.zig");
pub const binding_scanner = @import("binding_scanner.zig");
pub const linker = @import("linker.zig");
pub const tree_shaker = @import("tree_shaker.zig");
pub const statement_shaker = @import("statement_shaker.zig");
pub const purity = @import("purity.zig");
pub const stmt_info = @import("stmt_info.zig");
pub const chunk = @import("chunk.zig");
pub const runtime_helpers = @import("runtime_helpers.zig");
pub const bundler_core = @import("bundler.zig");
pub const mpsc_channel = @import("mpsc_channel.zig");
pub const json_to_esm = @import("json_to_esm.zig");
pub const plugin = @import("plugin.zig");
pub const module_store = @import("module_store.zig");
pub const css_scanner = @import("css_scanner.zig");
pub const css_emitter = @import("css_emitter.zig");
pub const symbol = @import("symbol.zig");
pub const asset_meta = @import("asset_meta.zig");
pub const block_list = @import("block_list.zig");

// 공개 타입 re-export
pub const ModuleIndex = types.ModuleIndex;
pub const ImportKind = types.ImportKind;
pub const ModuleType = types.ModuleType;
pub const ImportRecord = types.ImportRecord;
pub const BundlerDiagnostic = types.BundlerDiagnostic;
pub const extractImports = import_scanner.extractImports;
pub const Resolver = resolver.Resolver;
pub const ResolveResult = resolver.ResolveResult;
pub const ResolveCache = resolve_cache.ResolveCache;
pub const Platform = resolve_cache.Platform;
pub const Module = module.Module;
pub const ModuleGraph = graph.ModuleGraph;
pub const Linker = linker.Linker;
pub const LinkingMetadata = linker.LinkingMetadata;
pub const TreeShaker = tree_shaker.TreeShaker;
pub const ChunkIndex = types.ChunkIndex;
pub const BitSet = chunk.BitSet;
pub const Chunk = chunk.Chunk;
pub const ChunkKind = chunk.ChunkKind;
pub const ChunkGraph = chunk.ChunkGraph;
pub const Bundler = bundler_core.Bundler;
pub const BundleOptions = bundler_core.BundleOptions;
pub const BundleResult = bundler_core.BundleResult;
pub const RN_BOOL_PRESET = bundler_core.RN_BOOL_PRESET;
pub const RN_DEFAULT_ASSET_REGISTRY = bundler_core.RN_DEFAULT_ASSET_REGISTRY;
pub const RN_DEFAULT_BLOCK_LIST = bundler_core.RN_DEFAULT_BLOCK_LIST;
pub const Plugin = plugin.Plugin;
pub const PluginRunner = plugin.PluginRunner;
pub const PersistentModuleStore = module_store.PersistentModuleStore;
pub const SymbolId = symbol.SymbolId;
pub const SymbolRef = symbol.SymbolRef;
pub const SymbolKind = symbol.SymbolKind;
pub const AliasTable = symbol.AliasTable;
pub const incremental = @import("incremental.zig");
pub const IncrementalBundler = incremental.IncrementalBundler;

test {
    _ = types;
    _ = import_scanner;
    _ = resolver;
    _ = package_json;
    _ = resolve_cache;
    _ = module;
    _ = graph;
    _ = emitter;
    _ = binding_scanner;
    _ = linker;
    _ = tree_shaker;
    _ = purity;
    _ = stmt_info;
    _ = chunk;
    _ = runtime_helpers;
    _ = bundler_core;
    _ = plugin;
    _ = module_store;
    _ = symbol;

    // test files
    _ = @import("bundler_test.zig");
    _ = @import("tree_shaker_test.zig");
    _ = @import("linker_test.zig");
    _ = @import("emitter_test.zig");
    _ = @import("chunk_test.zig");
    _ = @import("statement_shaker_test.zig");
    _ = @import("graph_test.zig");
    _ = @import("resolver_test.zig");
    _ = @import("package_json_test.zig");
    _ = @import("binding_scanner_test.zig");
    _ = @import("purity_test.zig");
    _ = @import("import_scanner_test.zig");
    _ = @import("stmt_info_test.zig");
    _ = @import("resolve_cache_test.zig");
    _ = @import("types_test.zig");
    _ = @import("module_test.zig");
    _ = @import("plugin_test.zig");
    _ = asset_meta;
    _ = block_list;
    _ = incremental;
    _ = @import("incremental_test.zig");
}
