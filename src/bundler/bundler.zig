//! ZTS Bundler — Orchestrator
//!
//! 번들러의 최상위 공개 API. ResolveCache → ModuleGraph → Emitter 파이프라인을 조율.
//!
//! 사용법:
//!   var bundler = Bundler.init(allocator, .{
//!       .entry_points = &.{"src/index.ts"},
//!       .format = .esm,
//!   });
//!   defer bundler.deinit();
//!   const result = try bundler.bundle();
//!   defer result.deinit(allocator);

const std = @import("std");
const types = @import("types.zig");
const BundlerDiagnostic = types.BundlerDiagnostic;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const Platform = @import("resolve_cache.zig").Platform;
const emitter = @import("emitter.zig");
const EmitOptions = emitter.EmitOptions;
const OutputFile = emitter.OutputFile;
const chunk_mod = @import("chunk.zig");
const Linker = @import("linker.zig").Linker;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;

pub const BundleOptions = struct {
    entry_points: []const []const u8,
    format: EmitOptions.Format = .esm,
    platform: Platform = .browser,
    external: []const []const u8 = &.{},
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    /// 스코프 호이스팅 활성화 (import/export 제거 + 변수 리네임). false면 기존 동작.
    scope_hoist: bool = true,
    /// tree-shaking 활성화 (미사용 export/모듈 제거). scope_hoist가 true일 때만 동작.
    tree_shaking: bool = true,
    /// code splitting 활성화. true이면 dynamic import 경계에서 청크를 분리하고
    /// 공유 모듈을 공통 청크로 추출한다. 결과는 BundleResult.outputs에 다중 파일로 반환.
    code_splitting: bool = false,
    /// dev mode: 각 모듈을 __zts_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// define 글로벌 치환 (--define:KEY=VALUE)
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    /// legacy decorator 변환 (--experimental-decorators / tsconfig)
    experimental_decorators: bool = false,
    /// useDefineForClassFields=false (tsconfig)
    use_define_for_class_fields: bool = true,
    /// ES 타겟 레벨
    target: @import("../transformer/transformer.zig").TransformOptions.Target = .esnext,
    /// package.json exports 커스텀 조건 (--conditions, esbuild 호환)
    conditions: []const []const u8 = &.{},
};

pub const BundleResult = struct {
    /// 번들 출력 내용 (단일 파일). code_splitting=false일 때 사용. allocator 소유.
    output: []const u8,
    /// 소스맵 JSON (V3). null이면 소스맵 미생성. allocator 소유.
    sourcemap: ?[]const u8 = null,
    /// 다중 출력 파일. code_splitting=true일 때 사용. allocator 소유.
    /// null이면 단일 파일 모드 (output 필드 사용).
    outputs: ?[]OutputFile = null,
    /// 빌드 중 발생한 진단 메시지들. deep copy — 내부 문자열도 allocator 소유.
    diagnostics: ?[]OwnedDiagnostic,
    /// 번들에 포함된 모든 모듈의 절대 경로. allocator 소유. dev server watch용.
    module_paths: ?[]const []const u8 = null,
    /// dev mode: JS 모듈별 __zts_register(...) 코드. HMR 모듈 단위 업데이트용.
    /// id로 매칭 (module_paths와 인덱스 대응 아님). allocator 소유.
    module_dev_codes: ?[]const ModuleDevCode = null,

    /// dev mode에서 모듈별 HMR 업데이트 코드.
    pub const ModuleDevCode = struct {
        /// 모듈 ID (dev bundle에서 사용하는 경로)
        id: []const u8,
        /// __zts_register("id", function(...) { ... }); 코드
        code: []const u8,

        /// ModuleDevCode 배열을 해제한다.
        pub fn freeAll(codes: []const ModuleDevCode, allocator: std.mem.Allocator) void {
            for (codes) |c| {
                allocator.free(c.id);
                allocator.free(c.code);
            }
            allocator.free(codes);
        }
    };

    /// 문자열 필드를 소유하는 diagnostic (graph 해제 후에도 유효).
    pub const OwnedDiagnostic = struct {
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        message: []const u8,
        file_path: []const u8,
        step: BundlerDiagnostic.Step,
        suggestion: ?[]const u8,
    };

    pub fn deinit(self: *const BundleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.sourcemap) |sm| allocator.free(sm);
        if (self.outputs) |outs| {
            for (outs) |o| {
                allocator.free(o.path);
                allocator.free(o.contents);
            }
            allocator.free(outs);
        }
        if (self.diagnostics) |diags| {
            for (diags) |d| {
                allocator.free(d.message);
                allocator.free(d.file_path);
                if (d.suggestion) |s| allocator.free(s);
            }
            allocator.free(diags);
        }
        if (self.module_paths) |paths| {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        if (self.module_dev_codes) |codes| {
            ModuleDevCode.freeAll(codes, allocator);
        }
    }

    pub fn hasErrors(self: *const BundleResult) bool {
        const diags = self.diagnostics orelse return false;
        for (diags) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn getDiagnostics(self: *const BundleResult) []const OwnedDiagnostic {
        return self.diagnostics orelse &[_]OwnedDiagnostic{};
    }
};

pub const Bundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,
    resolve_cache: ResolveCache,

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) Bundler {
        return .{
            .allocator = allocator,
            .options = options,
            .resolve_cache = ResolveCache.init(allocator, options.platform, options.external, options.conditions),
        };
    }

    pub fn deinit(self: *Bundler) void {
        self.resolve_cache.deinit();
    }

    /// 번들 파이프라인 실행: resolve → graph → emit.
    /// graph는 함수 내에서 생성+해제. &self.resolve_cache 포인터는 self가 살아있는 동안 유효.
    pub fn bundle(self: *Bundler) !BundleResult {
        // 1. 모듈 그래프 구축
        // graph가 &self.resolve_cache를 참조 — self가 move되지 않으므로 포인터 안전.
        var graph = ModuleGraph.init(self.allocator, &self.resolve_cache);
        defer graph.deinit();

        try graph.build(self.options.entry_points);

        // 2. 링킹 (scope hoisting)
        // dev_mode: link()만 실행 (import→export 바인딩 해석), rename은 스킵.
        //           dev mode는 모듈별 스코프 유지이므로 변수 이름 충돌 해결 불필요.
        // code_splitting=true일 때는 글로벌 computeRenames를 건너뛴다.
        // 각 청크가 독립된 네임스페이스이므로 emitChunks에서 per-chunk로 처리.
        var linker: ?Linker = if (self.options.scope_hoist or self.options.dev_mode) blk: {
            var l = Linker.init(self.allocator, graph.modules.items);
            try l.link();
            if (!self.options.dev_mode and !self.options.code_splitting) {
                try l.computeRenames();
                if (self.options.minify_identifiers) {
                    try l.computeMangling();
                }
            }
            break :blk l;
        } else null;
        defer if (linker) |*l| l.deinit();

        // 2.5. Tree-shaking (scope_hoist + tree_shaking 둘 다 켜져 있을 때)
        // dev_mode에서는 tree-shaking 스킵 (개발 중 모든 코드 필요)
        var shaker: ?TreeShaker = if (!self.options.dev_mode and self.options.scope_hoist and self.options.tree_shaking) blk: {
            var s = try TreeShaker.init(self.allocator, graph.modules.items, &(linker.?));
            try s.analyze(self.options.entry_points);
            break :blk s;
        } else null;
        defer if (shaker) |*s| s.deinit();

        // 3. 번들 출력 생성
        var output: []const u8 = "";
        var outputs: ?[]OutputFile = null;

        // dev mode용 per-module codes + sourcemap (emitDevBundle에서 한 번의 패스로 생성)
        var module_dev_codes_from_emit: ?[]const emitter.DevBundleResult.ModuleDevCode = null;
        var dev_sourcemap: ?[]const u8 = null;

        if (self.options.dev_mode) {
            // Dev mode: 모듈 래핑 + HMR 런타임 주입 + per-module codes + 소스맵 동시 생성
            const dev_result = try emitter.emitDevBundle(
                self.allocator,
                &graph,
                .{
                    .format = self.options.format,
                    .minify_whitespace = self.options.minify_whitespace,
                    .sourcemap = true, // dev mode에서는 항상 소스맵 생성
                    .dev_mode = true,
                    .root_dir = self.options.root_dir,
                    .react_refresh = self.options.react_refresh,
                    .define = self.options.define,
                    .platform = self.options.platform,
                    .experimental_decorators = self.options.experimental_decorators,
                    .use_define_for_class_fields = self.options.use_define_for_class_fields,
                    .target = self.options.target,
                },
                if (linker) |*l| l else null,
            );
            output = dev_result.output;
            module_dev_codes_from_emit = dev_result.module_codes;
            dev_sourcemap = dev_result.sourcemap;
        } else if (self.options.code_splitting) {
            // Code splitting 경로: 청크 그래프 생성 → 다중 파일 출력
            var chunk_graph = try chunk_mod.generateChunks(
                self.allocator,
                graph.modules.items,
                self.options.entry_points,
                if (shaker) |*s| s else null,
            );
            defer chunk_graph.deinit();

            try chunk_mod.computeCrossChunkLinks(&chunk_graph, graph.modules.items, self.allocator, if (linker) |*l| l else null);

            outputs = try emitter.emitChunks(
                self.allocator,
                graph.modules.items,
                &chunk_graph,
                .{
                    .format = self.options.format,
                    .minify_whitespace = self.options.minify_whitespace,
                    .define = self.options.define,
                    .platform = self.options.platform,
                    .experimental_decorators = self.options.experimental_decorators,
                    .use_define_for_class_fields = self.options.use_define_for_class_fields,
                    .target = self.options.target,
                },
                if (linker) |*l| l else null,
            );
            errdefer if (outputs) |outs| {
                for (outs) |o| {
                    self.allocator.free(o.path);
                    self.allocator.free(o.contents);
                }
                self.allocator.free(outs);
            };

            // output은 빈 문자열 — code splitting 시 outputs를 사용
            output = try self.allocator.dupe(u8, "");
        } else {
            // 기존 단일 파일 경로 (변경 없음)
            output = try emitter.emitWithTreeShaking(
                self.allocator,
                &graph,
                .{
                    .format = self.options.format,
                    .minify_whitespace = self.options.minify_whitespace,
                    .define = self.options.define,
                    .platform = self.options.platform,
                    .experimental_decorators = self.options.experimental_decorators,
                    .use_define_for_class_fields = self.options.use_define_for_class_fields,
                    .target = self.options.target,
                },
                if (linker) |*l| l else null,
                if (shaker) |*s| s else null,
            );
        }
        errdefer self.allocator.free(output);

        // 4. 진단 메시지 deep copy (graph.deinit 후에도 문자열 유효하도록)
        const diagnostics: ?[]BundleResult.OwnedDiagnostic = if (graph.diagnostics.items.len > 0) blk: {
            const diags = try self.allocator.alloc(BundleResult.OwnedDiagnostic, graph.diagnostics.items.len);
            errdefer self.allocator.free(diags);
            // M1 수정: 부분 할당 후 OOM 시 이미 복사한 문자열 해제
            var filled: usize = 0;
            errdefer for (diags[0..filled]) |d| {
                self.allocator.free(d.message);
                self.allocator.free(d.file_path);
                if (d.suggestion) |s| self.allocator.free(s);
            };
            for (graph.diagnostics.items, 0..) |d, i| {
                diags[i] = .{
                    .code = d.code,
                    .severity = d.severity,
                    .message = try self.allocator.dupe(u8, d.message),
                    .file_path = try self.allocator.dupe(u8, d.file_path),
                    .step = d.step,
                    .suggestion = if (d.suggestion) |s| try self.allocator.dupe(u8, s) else null,
                };
                filled = i + 1;
            }
            break :blk diags;
        } else null;

        // 5. 모듈 경로 수집 (dev server watch용)
        const module_paths: ?[]const []const u8 = if (graph.modules.items.len > 0) blk: {
            const paths = try self.allocator.alloc([]const u8, graph.modules.items.len);
            errdefer self.allocator.free(paths);
            var path_count: usize = 0;
            errdefer for (paths[0..path_count]) |p| self.allocator.free(p);
            for (graph.modules.items) |m| {
                paths[path_count] = try self.allocator.dupe(u8, m.path);
                path_count += 1;
            }
            break :blk paths;
        } else null;

        // 6. Dev mode: emitDevBundle에서 이미 생성된 per-module codes를 BundleResult 타입으로 변환
        const module_dev_codes: ?[]const BundleResult.ModuleDevCode = if (module_dev_codes_from_emit) |emit_codes| blk: {
            // emitter.DevBundleResult.ModuleDevCode → BundleResult.ModuleDevCode
            // 필드가 동일하므로 메모리 레이아웃이 같지만 타입이 다르므로 변환
            const result_codes = try self.allocator.alloc(BundleResult.ModuleDevCode, emit_codes.len);
            for (emit_codes, 0..) |ec, i| {
                result_codes[i] = .{ .id = ec.id, .code = ec.code };
            }
            // emit_codes 배열 자체만 해제 (내부 문자열은 result_codes로 소유권 이전)
            self.allocator.free(emit_codes);
            break :blk result_codes;
        } else null;

        return .{
            .output = output,
            .sourcemap = dev_sourcemap,
            .outputs = outputs,
            .diagnostics = diagnostics,
            .module_paths = module_paths,
            .module_dev_codes = module_dev_codes,
        };
    }
};

