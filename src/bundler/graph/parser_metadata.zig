//! Parser scan result materialization helpers for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const Module = @import("../module.zig").Module;
const Parser = @import("../../parser/parser.zig").Parser;
const profile = @import("../../profile.zig");
const import_scanner = @import("../import_scanner.zig");
const binding_scanner = @import("../binding_scanner.zig");
const graph_parse_helpers = @import("parse_helpers.zig");
const graph_synthetic_imports = @import("synthetic_imports.zig");
const ImportKind = types.ImportKind;
const ImportRecord = types.ImportRecord;

const determineExportsKind = graph_parse_helpers.determineExportsKind;
const projectExportedNames = graph_parse_helpers.projectExportedNames;
const injectJsxRuntimeImports = graph_synthetic_imports.injectJsxRuntimeImports;
const injectFlowEnumRuntimeImport = graph_synthetic_imports.injectFlowEnumRuntimeImport;
const createJsxImportBindings = graph_synthetic_imports.createJsxImportBindings;

pub fn materialize(
    self: anytype,
    module: *Module,
    parser: *Parser,
    arena_alloc: std.mem.Allocator,
) bool {
    // Parser scan records -> bundler ImportRecord.
    {
        var records_scope = profile.begin(.graph_discover_pm_post_records);
        defer records_scope.end();

        const scan_records = parser.scan_import_records.items;
        const records = arena_alloc.alloc(ImportRecord, scan_records.len) catch {
            module.state = .ready;
            return false;
        };
        for (scan_records, 0..) |sr, i| {
            const ik: ImportKind = @enumFromInt(@intFromEnum(sr.kind));
            const ctx_mode: types.RequireContextMode = @enumFromInt(@intFromEnum(sr.context_mode));
            records[i] = .{
                .specifier = sr.specifier,
                .kind = ik,
                .span = sr.span,
                .url_span = sr.url_span,
                .glob_eager = sr.glob_eager,
                .glob_import_name = sr.glob_import_name,
                .context_recursive = sr.context_recursive,
                .context_filter = sr.context_filter,
                .context_filter_flags = sr.context_filter_flags,
                .context_mode = ctx_mode,
                .context_invalid_reason = sr.context_invalid_reason,
            };
        }
        module.import_records = records;

        // Parser scan import bindings -> bundler ImportBinding.
        const scan_ibindings = parser.scan_import_bindings.items;
        if (arena_alloc.alloc(binding_scanner.ImportBinding, scan_ibindings.len)) |ibindings| {
            for (scan_ibindings, 0..) |sb, i| {
                const ib_kind: binding_scanner.ImportBinding.Kind = @enumFromInt(@intFromEnum(sb.kind));
                ibindings[i] = .{
                    .kind = ib_kind,
                    .local_name = sb.local_name,
                    .imported_name = sb.imported_name,
                    .local_span = sb.local_span,
                    .import_record_index = sb.import_record_index,
                };
            }
            module.import_bindings = ibindings;
        } else |_| {}

        // Parser scan export bindings -> bundler ExportBinding.
        const scan_ebindings = parser.scan_export_bindings.items;
        if (arena_alloc.alloc(binding_scanner.ExportBinding, scan_ebindings.len)) |ebindings| {
            for (scan_ebindings, 0..) |sb, i| {
                const eb_kind: binding_scanner.ExportBinding.Kind = @enumFromInt(@intFromEnum(sb.kind));
                ebindings[i] = .{
                    .exported_name = sb.exported_name,
                    .local_name = sb.local_name,
                    .local_span = sb.local_span,
                    .kind = eb_kind,
                    .import_record_index = sb.import_record_index,
                };
            }
            module.export_bindings = ebindings;
            module.exported_names = projectExportedNames(arena_alloc, ebindings);
            // wrapper-barrel detection 캐시 (export_bindings 가 final 인 시점에 한 번 계산).
            module.is_wrapper_barrel = @import("requested_exports.zig").computeIsWrapperBarrel(module);
        } else |_| {}
    }

    // OOM 시 silent skip 하면 optional require 가 hard error 로 회귀하므로 module 을
    // ready 로 끝내고 graph 진행 중단 (1108줄 extractImports 와 동일 패턴).
    {
        var optional_scope = profile.begin(.graph_discover_pm_post_optional_requires);
        defer optional_scope.end();
        import_scanner.markPostScanFlags(arena_alloc, &(module.ast.?), module.import_records) catch {
            module.state = .ready;
            return false;
        };
    }

    if (parser.ast.has_flow_enum_declaration) {
        module.import_records = injectFlowEnumRuntimeImport(
            arena_alloc,
            module.import_records,
        ) catch module.import_records;
    }

    // namespace access 수집은 별도 AST walk 필요
    {
        var namespace_scope = profile.begin(.graph_discover_pm_post_namespace_access);
        defer namespace_scope.end();
        binding_scanner.collectNamespaceAccesses(arena_alloc, &parser.ast, module.import_bindings) catch {};
    }

    // Phase 1-3b (#1328): 합성 심볼 테이블 초기화 + re_export_alias 등록
    // + semantic 공간에 synthetic_default 등록.
    {
        var synthetic_scope = profile.begin(.graph_discover_pm_post_synthetic_symbols);
        defer synthetic_scope.end();
        module.ensureAliasTable(self.allocator);
        if (module.semantic) |*sem| {
            const scope0: ?std.StringHashMap(usize) =
                if (sem.scope_maps.len > 0) sem.scope_maps[0] else null;
            binding_scanner.populateSyntheticSymbols(
                &module.alias_table.?,
                module.index,
                module.export_bindings,
                &sem.symbols,
                arena_alloc,
                scope0,
            ) catch {};
        }
    }

    const scan_result = import_scanner.ScanResult{
        .records = module.import_records,
        .has_esm_syntax = parser.scan_result.has_esm_syntax or parser.has_module_syntax,
        .has_cjs_require = parser.scan_result.has_cjs_require,
        .has_module_exports = parser.scan_result.has_module_exports,
        .has_exports_dot = parser.scan_result.has_exports_dot,
        .has_esmodule_marker = parser.scan_result.has_esmodule_marker,
    };

    var jsx_injected = false;
    var react_injected = false;
    var jsx_inject_base: u32 = 0;
    // `react` 는 key-after-spread 때만 주입한다. 모든 JSX 모듈에 넣으면
    // `createElement 미노출` 회귀 테스트가 깨진다.
    {
        var jsx_scope = profile.begin(.graph_discover_pm_post_jsx_imports);
        defer jsx_scope.end();
        if (self.jsx_runtime != .classic and parser.ast.has_jsx) {
            if (self.jsx_specifier_cache == null) {
                const is_dev = self.jsx_runtime == .automatic_dev;
                self.jsx_specifier_cache = std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}",
                    .{ self.jsx_import_source, if (is_dev) "jsx-dev-runtime" else "jsx-runtime" },
                ) catch null;
            }
            if (self.jsx_specifier_cache) |specifier| {
                var specs_buf: [2][]const u8 = undefined;
                specs_buf[0] = specifier;
                var n: usize = 1;
                if (parser.ast.has_jsx_key_after_spread) {
                    specs_buf[n] = self.jsx_import_source;
                    n += 1;
                }
                jsx_inject_base = @intCast(module.import_records.len);
                module.import_records = injectJsxRuntimeImports(
                    specs_buf[0..n],
                    arena_alloc,
                    module.import_records,
                ) catch module.import_records;
                jsx_injected = (module.import_records.len > jsx_inject_base);
                react_injected = (n == 2) and jsx_injected;
            }
        }
    }

    module.exports_kind = determineExportsKind(scan_result, module.path);
    module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;
    module.has_cjs_export_signal = scan_result.has_module_exports or scan_result.has_exports_dot;
    module.can_skip_cjs_default_interop = Module.computeCanSkipCjsDefaultInterop(
        module.wrap_kind == .cjs,
        scan_result.has_module_exports,
        scan_result.has_exports_dot,
        scan_result.has_esmodule_marker,
    );

    if (jsx_injected) {
        const jsx_record_idx: u32 = jsx_inject_base;
        const react_record_idx: ?u32 = if (react_injected) jsx_record_idx + 1 else null;
        module.import_bindings = createJsxImportBindings(
            self.jsx_runtime,
            arena_alloc,
            module.import_bindings,
            jsx_record_idx,
            react_record_idx,
        ) catch module.import_bindings;
    }
    return true;
}
