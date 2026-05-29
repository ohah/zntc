//! Loader-specific parse helpers and source reads for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("../module.zig").Module;
const module_mod = @import("../module.zig");
const fs = @import("../fs.zig");
const css_scanner_mod = @import("../css_scanner.zig");
const profile = @import("../../profile.zig");
const Span = @import("../../lexer/token.zig").Span;
const graph_assets = @import("assets.zig");
const contentHash = graph_assets.contentHash;
const applyAssetNamingPattern = graph_assets.applyAssetNamingPattern;
const emitAssetRegistryCall = graph_assets.emitAssetRegistryCall;
const ScaleCollection = graph_assets.ScaleCollection;
const collectScaleVariants = graph_assets.collectScaleVariants;
const computeAssetDir = graph_assets.computeAssetDir;
const assetSourceFromBytes = graph_assets.sourceFromBytes;
const parseScaleSuffix = graph_assets.parseScaleSuffix;
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

/// CSS 모듈을 파싱한다.
/// 파일을 읽어서 @import 규칙을 추출하고, import_records에 등록한다.
/// CSS 소스는 module.source에 보존하여 css_emitter에서 사용한다.
pub fn parseCssModule(self: *ModuleGraph, io: std.Io, module: *Module) void {
    if (std.mem.endsWith(u8, std.fs.path.basename(module.path), ".module.css")) {
        self.addDiag(.no_loader, .@"error", module.path, Span.EMPTY, .parse, "CSS Modules (.module.css) are not supported by the native CSS pipeline yet", "Use plain CSS, or transform CSS Modules through a plugin before ZNTC bundles the app");
        module.state = .ready;
        return;
    }

    module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
        module.state = .ready;
        return;
    };
    const arena_alloc = module.parse_arena.?.allocator();

    // 파일 읽기
    if (module.source.len == 0) {
        module.source = readModuleSourceWithMtime(self, io, module, arena_alloc, 100 * 1024 * 1024, .parse) orelse return;
    }

    // @import 규칙 + @charset / @layer prefix 선언 추출 (arena 에 할당, #3747)
    const scan_result = css_scanner_mod.extractCssImportsWithPrefixes(arena_alloc, module.source);
    const raw_imports = scan_result.imports;
    const import_count: u32 = @intCast(raw_imports.len);

    if (import_count > 0) {
        // import_records 생성
        const records = arena_alloc.alloc(types.ImportRecord, import_count) catch {
            module.state = .ready;
            return;
        };
        for (raw_imports, 0..) |imp, i| {
            records[i] = .{
                .specifier = imp.specifier,
                .kind = .side_effect,
                .span = imp.span,
                // External URL (`http:`/`https:`/`//`/`data:`) — resolver 가 skip
                // 하고 emitter 가 출력 CSS 상단에 보존 (esbuild parity, #3321 P0-3).
                .is_external = imp.is_external,
                // media-query/layer/supports tail 보존 — external 재emit 시 사용.
                .css_condition_tail = imp.condition_tail,
            };
        }
        module.import_records = records;
    }

    // strip_end = max(last @import end, last prefix decl end + `;`) — 캡처되어
    // emitter 가 별도 보존 emit 하는 모든 영역을 본문 source 에서 제외해 double
    // emit 회피. prefix decl 의 `text` 슬라이스가 source slice 이므로 pointer
    // 산술로 end offset 복원 (text + `;` 분 1 추가).
    var strip_end: u32 = if (import_count > 0) raw_imports[import_count - 1].span.end else 0;
    for (scan_result.prefix_decls) |pd| {
        const text_end_offset: usize = @intFromPtr(pd.text.ptr) - @intFromPtr(module.source.ptr) + pd.text.len;
        // `;` 다음까지 포함 (text 는 `;` 미포함 — emitter 가 따로 부착)
        const decl_end: u32 = @intCast(@min(text_end_offset + 1, module.source.len));
        if (decl_end > strip_end) strip_end = decl_end;
    }
    module.css_data = .{
        .import_count = import_count,
        .strip_end = strip_end,
        .prefix_decls = scan_result.prefix_decls,
    };
    module.exports_kind = .esm; // CSS는 ESM side-effect import로 처리
    module.side_effects = true; // CSS는 항상 side-effect
    module.state = .parsed;
}

/// Asset 로더 모듈을 파싱한다.
/// 파일을 읽어서 로더 타입에 따라 fake JS 소스를 생성하고,
/// module_type을 .js로 바꿔서 기존 JS 파이프라인을 그대로 탄다.
///
/// asset_registry 모드의 .file/.copy는 loader를 .javascript로 바꿔 fall-through
/// 신호를 보내고, 호출자가 일반 JS 파이프라인을 이어 실행한다.
pub fn parseAssetModule(self: *ModuleGraph, io: std.Io, module: *Module) void {
    module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
        module.state = .ready;
        return;
    };
    const arena_alloc = module.parse_arena.?.allocator();

    switch (module.loader) {
        .text, .dataurl, .base64, .binary => {
            // text/dataurl/base64/binary: 모두 raw bytes → JS 표현식 변환. assetSourceFromBytes
            // 헬퍼가 plugin onLoad 경로와 공유 (#2157).
            const raw = readModuleSourceWithMtime(self, io, module, arena_alloc, 100 * 1024 * 1024, .parse) orelse return;
            module.source = assetSourceFromBytes(arena_alloc, module.loader, raw, module.path, self.transform_options_base.minify_whitespace) orelse {
                module.state = .ready;
                return;
            };
        },
        .file, .copy => {
            // 파일 읽기 → content hash → 출력 경로 생성 → URL 문자열
            const raw = readModuleSourceWithMtime(self, io, module, arena_alloc, 100 * 1024 * 1024, .parse) orelse return;
            const hash = contentHash(raw);
            const ext = std.fs.path.extension(module.path);
            const basename = std.fs.path.basename(module.path);
            const name_without_ext = if (ext.len > 0 and basename.len > ext.len)
                basename[0 .. basename.len - ext.len]
            else
                basename;
            const scale_info = parseScaleSuffix(name_without_ext);
            const logical_name_without_ext = if (scale_info) |info| info.logical_name else name_without_ext;
            const primary_scale = if (scale_info) |info| info.scale else 1;

            // [dir]: entry_dir 기준 상대 디렉토리 경로
            const dir = computeAssetDir(module.path, self.entry_dir);

            const output_name = applyAssetNamingPattern(arena_alloc, self.asset_names, name_without_ext, &hash, ext, dir) catch {
                module.state = .ready;
                return;
            };

            // RN scale variants (@2x, @3x): asset_registry 활성화 시에만 스캔.
            // 기본 URL 출력 모드에서는 variant가 의미 없음 (런타임이 해석 안 함).
            const scales_result = if (self.asset_registry != null)
                collectScaleVariants(arena_alloc, module.path, logical_name_without_ext, ext, self.asset_names, dir, primary_scale) catch ScaleCollection{ .scales = &.{1}, .variants = &.{} }
            else
                ScaleCollection{ .scales = &.{1}, .variants = &.{} };

            module.asset_data = .{
                .raw_content = raw,
                .content_hash = hash,
                .output_name = output_name,
                .ext = ext,
                .scales = scales_result.scales,
                .scale_variants = scales_result.variants,
            };

            const url = if (self.public_path.len > 0)
                std.fmt.allocPrint(arena_alloc, "{s}{s}", .{ self.public_path, output_name }) catch {
                    module.state = .ready;
                    return;
                }
            else
                std.fmt.allocPrint(arena_alloc, "./{s}", .{output_name}) catch {
                    module.state = .ready;
                    return;
                };

            if (self.asset_registry) |registry_path| {
                // loader=.javascript는 호출자의 fall-through 신호.
                // import_scanner가 source의 require()를 ImportRecord로 추출하고
                // wrap_kind/exports_kind를 .cjs로 자동 결정한다.
                // 첫 인자가 metadata_alloc (long-lived, graph), 두번째가 source_alloc
                // (short-lived, parse_arena) — fs.RealReadFileCache.readFile 컨벤션.
                const emitted = emitAssetRegistryCall(self.allocator, arena_alloc, .{
                    .registry_path = registry_path,
                    .abs_path = module.path,
                    .bytes = raw,
                    .ext = ext,
                    .name_without_ext = logical_name_without_ext,
                    .url = url,
                    .scales = scales_result.scales,
                    .primary_scale = primary_scale,
                    .project_root = self.project_root,
                }) catch {
                    module.state = .ready;
                    return;
                };
                module.source = emitted.source;
                self.rn_asset_metadata_mutex.lock();
                defer self.rn_asset_metadata_mutex.unlock();
                self.rn_asset_metadata.append(self.allocator, emitted.metadata) catch {
                    graph_assets.freeRnAssetMetadata(self.allocator, emitted.metadata);
                };
                module.module_type = .js;
                module.loader = .javascript;
                return;
            }

            module.source = std.fmt.allocPrint(arena_alloc, "\"{s}\"", .{url}) catch {
                module.state = .ready;
                return;
            };
        },
        .empty => {
            module.source = "undefined";
        },
        else => {
            module.state = .ready;
            return;
        },
    }

    // JSON 모듈과 동일한 CJS wrap 패턴: linker가 import 바인딩을 자동으로 연결.
    // source에는 값 표현식만 저장되고, emitter가 var/module.exports 형태로 출력.
    module.module_type = .js;
    module.exports_kind = .commonjs;
    module.wrap_kind = .cjs;
    module.side_effects = false;
    module.state = .ready;
}

/// stat 없는 source read — dir-fd cache 경유 (path lookup 비용 절감) + EOF 까지
/// dynamic grow read. mtime 이 필요한 caller (incremental rebuild) 가 없을 때만
/// 사용 — 모듈당 fstat 1 syscall 절감.
fn readModuleSource(
    self: *ModuleGraph,
    io: std.Io,
    module: *Module,
    alloc: std.mem.Allocator,
    max_bytes: usize,
    step: BundlerDiagnostic.Step,
) ?[]const u8 {
    const loaded = blk: {
        var scope = profile.begin(.graph_discover_pm_setup_read_file);
        defer scope.end();
        break :blk self.source_read_cache.readFile(io, self.allocator, alloc, module.path, max_bytes) catch {
            self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, step, "Cannot read file", null);
            module.state = .ready;
            return null;
        };
    };
    return loaded.contents;
}

pub fn readModuleSourceWithMtime(
    self: *ModuleGraph,
    io: std.Io,
    module: *Module,
    alloc: std.mem.Allocator,
    max_bytes: usize,
    step: BundlerDiagnostic.Step,
) ?[]const u8 {
    if (module.mtime != 0) return readModuleSource(self, io, module, alloc, max_bytes, step);

    // Fresh build (CLI / 첫 빌드): module_store / compiled_cache / changed_files 모두
    // null 이므로 mtime 을 read 하는 caller 가 없다 — fstat 호출을 생략해 모듈당
    // 1 syscall 절감. incremental rebuild 에서는 cache invalidation 이 mtime 에
    // 의존하므로 stat 유지.
    if (!self.incremental_mode) {
        return readModuleSource(self, io, module, alloc, max_bytes, step);
    }

    const loaded = self.source_read_cache.readFileWithStat(io, self.allocator, alloc, module.path, max_bytes) catch {
        self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, step, "Cannot read file", null);
        module.state = .ready;
        return null;
    };
    module.mtime = loaded.stat.mtime;
    return loaded.loaded.contents;
}
