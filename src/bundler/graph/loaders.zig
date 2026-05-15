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
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

/// CSS 모듈을 파싱한다.
/// 파일을 읽어서 @import 규칙을 추출하고, import_records에 등록한다.
/// CSS 소스는 module.source에 보존하여 css_emitter에서 사용한다.
pub fn parseCssModule(self: *ModuleGraph, module: *Module) void {
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
        module.source = readModuleSourceWithMtime(self, module, arena_alloc, 100 * 1024 * 1024, .parse) orelse return;
    }

    // @import 규칙 추출 (arena에 할당)
    const raw_imports = css_scanner_mod.extractCssImports(arena_alloc, module.source);
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
            };
        }
        module.import_records = records;
    }

    const strip_end: u32 = if (import_count > 0) raw_imports[import_count - 1].span.end else 0;
    module.css_data = .{ .import_count = import_count, .strip_end = strip_end };
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
pub fn parseAssetModule(self: *ModuleGraph, module: *Module) void {
    module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
        module.state = .ready;
        return;
    };
    const arena_alloc = module.parse_arena.?.allocator();

    switch (module.loader) {
        .text, .dataurl, .base64, .binary => {
            // text/dataurl/base64/binary: 모두 raw bytes → JS 표현식 변환. assetSourceFromBytes
            // 헬퍼가 plugin onLoad 경로와 공유 (#2157).
            const raw = readModuleSourceWithMtime(self, module, arena_alloc, 100 * 1024 * 1024, .parse) orelse return;
            module.source = assetSourceFromBytes(arena_alloc, module.loader, raw, module.path, self.transform_options_base.minify_whitespace) orelse {
                module.state = .ready;
                return;
            };
        },
        .file, .copy => {
            // 파일 읽기 → content hash → 출력 경로 생성 → URL 문자열
            const raw = readModuleSourceWithMtime(self, module, arena_alloc, 100 * 1024 * 1024, .parse) orelse return;
            const hash = contentHash(raw);
            const ext = std.fs.path.extension(module.path);
            const basename = std.fs.path.basename(module.path);
            const name_without_ext = if (ext.len > 0 and basename.len > ext.len)
                basename[0 .. basename.len - ext.len]
            else
                basename;

            // [dir]: entry_dir 기준 상대 디렉토리 경로
            const dir = computeAssetDir(module.path, self.entry_dir);

            const output_name = applyAssetNamingPattern(arena_alloc, self.asset_names, name_without_ext, &hash, ext, dir) catch {
                module.state = .ready;
                return;
            };

            // RN scale variants (@2x, @3x): asset_registry 활성화 시에만 스캔.
            // 기본 URL 출력 모드에서는 variant가 의미 없음 (런타임이 해석 안 함).
            const scales_result = if (self.asset_registry != null)
                collectScaleVariants(arena_alloc, module.path, name_without_ext, ext, self.asset_names, dir) catch ScaleCollection{ .scales = &.{1}, .variants = &.{} }
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
                const emitted = emitAssetRegistryCall(arena_alloc, registry_path, module.path, raw, &hash, ext, name_without_ext, url, scales_result.scales, self.project_root) catch {
                    module.state = .ready;
                    return;
                };
                module.source = emitted.source;
                // metadata 를 graph allocator 로 dupe — BundleResult 가 string parse 없이
                // rn-asset-copy 에 직접 전달 (#3216 후속). loader arena 가 module 종료 시
                // 회수되어도 BundleResult lifetime 까지 살아남도록.
                if (graph_assets.cloneRnAssetMetadata(self.allocator, emitted.metadata)) |owned| {
                    self.rn_asset_metadata_mutex.lock();
                    self.rn_asset_metadata.append(self.allocator, owned) catch {
                        graph_assets.freeRnAssetMetadata(self.allocator, owned);
                    };
                    self.rn_asset_metadata_mutex.unlock();
                } else |_| {}
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
    module: *Module,
    alloc: std.mem.Allocator,
    max_bytes: usize,
    step: BundlerDiagnostic.Step,
) ?[]const u8 {
    const loaded = blk: {
        var scope = profile.begin(.graph_discover_pm_setup_read_file);
        defer scope.end();
        break :blk self.source_read_cache.readFile(self.allocator, alloc, module.path, max_bytes) catch {
            self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, step, "Cannot read file", null);
            module.state = .ready;
            return null;
        };
    };
    return loaded.contents;
}

pub fn readModuleSourceWithMtime(
    self: *ModuleGraph,
    module: *Module,
    alloc: std.mem.Allocator,
    max_bytes: usize,
    step: BundlerDiagnostic.Step,
) ?[]const u8 {
    if (module.mtime != 0) return readModuleSource(self, module, alloc, max_bytes, step);

    // Fresh build (CLI / 첫 빌드): module_store / compiled_cache / changed_files 모두
    // null 이므로 mtime 을 read 하는 caller 가 없다 — fstat 호출을 생략해 모듈당
    // 1 syscall 절감. incremental rebuild 에서는 cache invalidation 이 mtime 에
    // 의존하므로 stat 유지.
    if (!self.incremental_mode) {
        return readModuleSource(self, module, alloc, max_bytes, step);
    }

    const loaded = self.source_read_cache.readFileWithStat(self.allocator, alloc, module.path, max_bytes) catch {
        self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, step, "Cannot read file", null);
        module.state = .ready;
        return null;
    };
    module.mtime = loaded.stat.mtime;
    return loaded.loaded.contents;
}
