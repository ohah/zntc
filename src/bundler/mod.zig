//! ZNTC Bundler
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
pub const graph_plugins = @import("graph/plugins.zig");
pub const emitter = @import("emitter.zig");
pub const binding_scanner = @import("binding_scanner.zig");
pub const linker = @import("linker.zig");
pub const tree_shaker = @import("tree_shaker.zig");
pub const statement_shaker = @import("statement_shaker.zig");
pub const purity = @import("purity.zig");
pub const stmt_info = @import("stmt_info.zig");
pub const chunk = @import("chunk.zig");
pub const module_id = @import("module_id.zig");
pub const runtime_helpers = @import("runtime_helpers.zig");
pub const runtime_polyfills = @import("runtime_polyfills.zig");
pub const bundler_core = @import("bundler.zig");
pub const mpsc_channel = @import("mpsc_channel.zig");
pub const json_to_esm = @import("json_to_esm.zig");
pub const plugin = @import("plugin.zig");
pub const module_store = @import("module_store.zig");
pub const semantic_codec = @import("semantic_codec.zig");
pub const module_codec = @import("module_codec.zig");
pub const disk_cache = @import("disk_cache.zig");
pub const cache_key = @import("cache_key.zig");
pub const css_scanner = @import("css_scanner.zig");
pub const css_emitter = @import("css_emitter.zig");
pub const symbol = @import("symbol.zig");
pub const asset_meta = @import("asset_meta.zig");
pub const block_list = @import("block_list.zig");
pub const fs = @import("fs.zig");

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
pub const EmitStore = @import("emit_store.zig").EmitStore;
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
pub const asyncLimitForJobs = bundler_core.asyncLimitForJobs;
pub const MfBundleConfig = types.MfBundleConfig; // #3318 P1-1
pub const federation = @import("federation.zig"); // #3318 (mfSharedGlobalName 단일 소스)
pub const mf_options = @import("mf_options.zig"); // #3318 mf DTO→Bundle + seam 단일 소스(CLI·NAPI 공용)
pub const OutputExports = bundler_core.OutputExports;
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
pub const compiled_cache = @import("compiled_cache.zig");
pub const CompiledOutputCache = compiled_cache.CompiledOutputCache;
pub const chunk_emit_cache = @import("chunk_emit_cache.zig");
pub const ChunkEmitCache = chunk_emit_cache.ChunkEmitCache;

test {
    _ = types;
    _ = import_scanner;
    _ = resolver;
    _ = package_json;
    _ = resolve_cache;
    _ = module;
    _ = mpsc_channel; // #4009 send OOM → recv error.SendFailed 회귀 가드
    _ = graph;
    _ = emitter;
    _ = binding_scanner;
    _ = linker;
    _ = tree_shaker;
    _ = purity;
    _ = stmt_info;
    _ = chunk;
    _ = module_id;
    _ = runtime_helpers;
    _ = runtime_polyfills;
    _ = bundler_core;
    _ = plugin;
    _ = module_store;
    _ = symbol;
    _ = chunk_emit_cache; // RFC_EMIT_INCREMENTAL Sub-PR-C.1 — 인라인 test 발견

    // emitter/ 하위 파일 (dev.zig 등) 의 인라인 test 블록을 test 빌드가
    // 발견하도록 명시적으로 reference. emitter.zig 는 dev 를 사용하지만
    // `pub const` 가 아닌 file-private const 로만 import → 다른 파일이
    // dev 를 직접 reference 안 하면 test reachability 안 잡힘.
    _ = @import("emitter/dev.zig");
    _ = @import("emitter/chunks.zig"); // inline test (rewriteImportSpecifier 등)

    // test files
    _ = @import("bundler_test.zig");
    _ = @import("semantic_codec_test.zig");
    _ = @import("module_codec_test.zig");
    _ = @import("disk_cache_test.zig");
    _ = @import("cache_key_test.zig");
    _ = @import("tree_shaker_test.zig");
    _ = @import("linker_test.zig");
    _ = @import("emitter_test.zig");
    _ = @import("chunk_test.zig");
    _ = @import("mf_integrity.zig"); // #3422 inline test (computeSri)
    _ = @import("mf_contract.zig"); // #3435 P3-0 inline test (parseContract)
    _ = @import("mf_options.zig"); // #3318 inline test (fromDto/seam 단일소스)
    _ = @import("semver.zig"); // #3437 P3-2 inline test (satisfies)
    _ = @import("federation_emit.zig"); // #3436/#3437 P3-1/2 inline test (verifyHostContract)
    _ = @import("statement_shaker_test.zig");
    _ = @import("graph_test.zig");
    _ = @import("graph/project_root.zig");
    _ = @import("graph/glob.zig");
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
    _ = @import("require_context_resolve_test.zig");
    _ = asset_meta;
    _ = block_list;
    _ = incremental;
    _ = fs;
    _ = @import("incremental_test.zig");
    _ = @import("fs_test.zig");
}
