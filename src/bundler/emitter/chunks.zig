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
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../../codegen/sourcemap.zig");
const Linker = @import("../linker.zig").Linker;
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

const RunBeforeMainCrossImport = struct {
    source_chunk: ChunkIndex,
    name: []const u8,
};

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

pub fn emitChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    options: *const EmitOptions,
    linker: ?*Linker,
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
        const reg_ok = (options.format == .iife or options.format == .umd or options.format == .amd) and !options.preserve_modules;
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
    }

    var outputs: std.ArrayList(OutputFile) = .empty;
    errdefer {
        for (outputs.items) |o| {
            allocator.free(o.contents);
            allocator.free(o.path);
        }
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
            if (s.isReExportStarTarget(mi)) {
                allocator.free(computed[i].names);
                used_names_by_modidx[mi] = .{ .names = &.{}, .all_used = true };
            } else {
                used_names_by_modidx[mi] = computed[i];
            }
        }
    }

    // 청크를 exec_order 순으로 정렬하여 결정론적 출력 순서 보장.
    // 엔트리 청크가 먼저, 공통 청크가 나중에 오도록 정렬한다.
    const sorted_indices = try allocator.alloc(usize, chunk_graph.chunkCount());
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;

    // IIFE splitting(P3-B PR3): 런타임 레지스트리 활성화. 안정 모듈 ID 의
    // root = preserve_modules_root ?? 모든 entry-point 청크 모듈 절대경로의
    // 공통 조상(module_id, 결정적). 루프 1회 전 계산해 모든 청크가 공유.
    const reg_split = (options.format == .iife or options.format == .umd or options.format == .amd) and !options.preserve_modules;
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

    for (sorted_indices) |ci| {
        const chunk = &chunk_graph.chunks.items[ci];
        // PR-3b-i: restrict_to_chunk 면 그 청크 하나만 emit(force — lazy seed skip 우회).
        // 아니면 정상 skip predicate(emit 루프 ↔ resolveContentHashes 동일해야 outputs↔
        // sorted_indices 정렬 유지). 비워진 청크 + PR-3a-ii lazy seed 제외.
        if (chunkRestrictSkip(chunk, ci, options.restrict_to_chunk)) continue;

        var chunk_output: std.ArrayList(u8) = .empty;
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
        if (options.banner_js) |banner| {
            try chunk_output.appendSlice(allocator, banner);
            try chunk_output.append(allocator, '\n');
        }
        // intro: reg_split(IIFE/UMD/AMD self-register factory)면 factory IIFE 안 첫 줄로 옮겨
        // 모듈 본문이 closure scope 로 접근 + chunk 별 module-scope 중복 redeclare 회피. 그 외
        // (preserve_modules / cjs / esm) 는 기존 위치(banner 다음, wrapper 밖) 유지.
        if (!reg_split) {
            if (options.intro_js) |intro| {
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
                    try format_wrapper.emitFormatPrologue(&chunk_output, allocator, options.format, options.global_name, "", &.{}, &.{});
                // public_path 는 동적 청크 <script> src 접두사(런타임). 결정적
                // JSON 문자열(따옴표/역슬래시/개행 이스케이프).
                try chunk_output.appendSlice(allocator, "globalThis.__zntc_public_path=");
                try parent.appendJsStringLiteral(allocator, &chunk_output, options.public_path);
                try chunk_output.appendSlice(allocator, if (min) ";" else ";\n");
                // 해석 계층(__zntc_require + 브라우저 <script> 로더), 멱등.
                try rt.appendZntcResolveBrowser(&chunk_output, allocator, min);
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
        try emitChunkRuntimeHelpers(&chunk_output, allocator, chunk, graph, linker, options, null);

        // dev_split (RFC_LAZY_DEV_MODULE_HMR PR-2): 글로벌 __zntc_modules 등록 prelude.
        // emitChunkRuntimeHelpers 가 청크-로컬 __esm/__commonJS 를 정의한 *직후* 에 주입돼야
        // wrap 이 그 orig 를 캡처. entry 청크 = HMR_RUNTIME(register+core 전부, apply_update
        // 등 머신러리 1회), 비-entry(shared/dynamic) = HMR_CHUNK_REGISTER(글로벌 등록만).
        // 글로벌(__zntc_g.__zntc_modules ||)이라 청크 평가 순서 무관 → cross-chunk hot-replace.
        // reg_split(IIFE/UMD/AMD) 만: ESM 출력은 청크가 native import 라 등록 모델 비대상.
        if (dev_split_chunk) {
            const hmr_src = if (chunk_is_user_entry)
                (if (options.minify_whitespace) rt.HMR_RUNTIME_MIN else rt.HMR_RUNTIME)
            else
                rt.HMR_CHUNK_REGISTER;
            try chunk_output.appendSlice(allocator, hmr_src);
        }

        // ESM external imports (#1962): chunk 모듈들의 external import 를 dedup
        // 후 chunk top 에 단일 `import` 로 prepend. emitChunkExternalImports
        // 가 `is_esm` 아니면 자체 no-op(iife/umd/amd 는 seam·factory-param 으로
        // 완결 — ESM import 추가 시 reg_split factory 내 SyntaxError + 이중처리).
        {
            var chunk_mods: std.ArrayListUnmanaged(*const Module) = .empty;
            defer chunk_mods.deinit(allocator);
            try chunk_mods.ensureTotalCapacity(allocator, chunk.modules.items.len);
            for (chunk.modules.items) |mod_idx| {
                if (graph.getModule(mod_idx)) |m| chunk_mods.appendAssumeCapacity(m);
            }
            try external_imports.emitChunkExternalImports(
                &chunk_output,
                allocator,
                options.format == .esm,
                chunk_mods.items,
                linker,
                options.minify_whitespace,
            );
        }

        // 이 청크의 정의자 모듈에 속한 namespace object literal 만 inline.
        // referrer 청크가 자기 self-preamble 에 inline 하던 동작 (entry 에 vendor
        // 코드 누출) 을 정의자 청크 preamble 로 옮긴다.
        if (linker) |l| if (l.use_shared_ns_preamble) {
            var chunk_targets: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer chunk_targets.deinit(allocator);
            try chunk_targets.ensureTotalCapacity(allocator, @intCast(chunk.modules.items.len));
            for (chunk.modules.items) |mod_idx| {
                chunk_targets.putAssumeCapacity(@intFromEnum(mod_idx), {});
            }
            try l.appendSharedNamespacePreambleFiltered(&chunk_output, &chunk_targets);
        };

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
            );
        }

        // 크로스 청크 import deconfliction:
        // 여러 청크에서 같은 이름의 심볼을 import할 때 충돌 방지.
        // 1단계: 모든 청크로부터의 import 이름 출현 횟수 카운트
        // 2단계: 중복 이름은 `import { x as x$2 }` 형태로 alias 부여
        var name_total_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_total_count.deinit(allocator);
        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_ci = @intFromEnum(dep_chunk_idx);
            if (chunk.imports_from.get(dep_ci)) |syms| {
                for (syms.items) |name| {
                    const gop = try name_total_count.getOrPut(allocator, name);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }
        }

        // 2단계: import 문 생성 (중복 이름은 alias 부여)
        var name_seen_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_seen_count.deinit(allocator);

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
        try chunkPlaceholderStem(chunk, &importer_buf, allocator, options);
        const importer_dir = std.fs.path.dirname(importer_buf.items) orelse "";

        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_chunk = chunk_graph.getChunk(dep_chunk_idx);
            try chunkPlaceholderStem(dep_chunk, &dep_buf, allocator, options);
            const dep_stem = dep_buf.items;
            const dep_ci = @intFromEnum(dep_chunk_idx);

            // IIFE splitting: 청크 경계는 레지스트리 — 경로 대신 dep 청크의
            // 레지스트리 ID 로 `__zntc_require("<id>")`. resolved_path 불필요.
            const dep_id = if (reg_split) reg_ids[@intFromEnum(dep_chunk_idx)] else "";

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
                const src_path = chunk.rel_dir orelse "./";
                const dep_path = dep_chunk.rel_dir orelse "./";
                break :blk try computeRelativeImportPath(allocator, src_path, dep_path, ext, options.preserve_modules_root);
            } else blk: {
                break :blk try computeRelativePath(allocator, importer_dir, dep_stem, ext);
            };
            defer allocator.free(resolved_path);

            // 청크 경계 결합 형태: esm `import{}from""` / cjs `const{}=require("")`
            // / iife `const{}=__zntc_require("<id>")`. brace·alias 표기는 cjs 와
            // iife 가 동일(`const {` / `name: alias`) — reg_like 로 공유.
            const reg_like = cjs_require or reg_split;
            // iife 의 결합 인자는 dep_id, 그 외는 resolved_path.
            const bind_arg = if (reg_split) dep_id else resolved_path;

            // imports_from에서 이 청크→dep_chunk로 가져오는 심볼 목록 조회
            const symbols = chunk.imports_from.get(dep_ci);

            if (symbols != null and symbols.?.items.len > 0) {
                // 심볼 수준 import: import { a, b } from './chunk-xxx.js';
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, if (reg_like) "const { " else "import { ");
                } else {
                    try chunk_output.appendSlice(allocator, if (reg_like) "const{" else "import{");
                }
                // 결정론적 출력을 위해 심볼명 정렬
                std.mem.sort([]const u8, symbols.?.items, {}, types.stringLessThan);
                for (symbols.?.items, 0..) |name, si| {
                    const total = name_total_count.get(name) orelse 1;
                    const seen_gop = try name_seen_count.getOrPut(allocator, name);
                    if (!seen_gop.found_existing) seen_gop.value_ptr.* = 0;
                    seen_gop.value_ptr.* += 1;
                    const seen = seen_gop.value_ptr.*;

                    if (total > 1 and seen > 1) {
                        const alias = try std.fmt.allocPrint(allocator, "{s}${d}", .{ name, seen });
                        try alias_strs.append(allocator, alias);
                        try chunk_output.appendSlice(allocator, name);
                        try chunk_output.appendSlice(allocator, if (reg_like) ": " else " as ");
                        try chunk_output.appendSlice(allocator, alias);
                    } else {
                        try chunk_output.appendSlice(allocator, name);
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
            } else {
                // 심볼 정보 없음 → side-effect (실행/등록 순서 보장용)
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

        // 청크 내 모듈을 exec_index 순으로 정렬
        const sorted_mods = try allocator.alloc(ModuleIndex, chunk.modules.items.len);
        defer allocator.free(sorted_mods);
        @memcpy(sorted_mods, chunk.modules.items);

        const ModSortCtx = struct {
            graph: *const ModuleGraph,
            fn lessThan(ctx: @This(), a: ModuleIndex, b: ModuleIndex) bool {
                const a_exec = if (ctx.graph.getModule(a)) |ma| ma.exec_index else std.math.maxInt(u32);
                const b_exec = if (ctx.graph.getModule(b)) |mb| mb.exec_index else std.math.maxInt(u32);
                return a_exec < b_exec;
            }
        };
        std.mem.sort(ModuleIndex, sorted_mods, ModSortCtx{ .graph = graph }, ModSortCtx.lessThan);

        // cross-chunk import 이름 수집 — 점유 이름으로 등록하여 로컬과 충돌 방지.
        // alias가 부여된 이름(x$2 등)도 점유 이름에 포함하여 로컬 변수와의 충돌 방지.
        var occupied: std.ArrayList([]const u8) = .empty;
        defer occupied.deinit(allocator);
        {
            var ifit = chunk.imports_from.iterator();
            while (ifit.next()) |if_entry| {
                for (if_entry.value_ptr.items) |name| {
                    try occupied.append(allocator, name);
                }
            }
            // deconfliction alias 이름도 점유 목록에 추가
            for (alias_strs.items) |alias| {
                try occupied.append(allocator, alias);
            }
            for (rbm_cross_imports.items) |imp| {
                try occupied.append(allocator, imp.name);
            }
        }

        // per-chunk 리네임 계산: 각 청크는 독립된 네임스페이스이므로
        // 청크 내 모듈들만 대상으로 이름 충돌을 감지한다.
        if (linker) |l| {
            try l.computeRenamesForModules(sorted_mods, occupied.items);
        }

        // 엔트리 모듈 인덱스 (final exports용). manual/common 은 엔트리 모듈 없음.
        const entry_mod_idx: ?u32 = switch (chunk.kind) {
            .entry_point => |info| @intFromEnum(info.module),
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

        for (sorted_mods, 0..) |mod_idx, sorted_pos| {
            const mi = @intFromEnum(mod_idx);
            if (mi >= module_count) continue;
            const m = graph.getModule(mod_idx) orelse continue;

            const is_entry = if (entry_mod_idx) |ei| mi == ei else false;
            var module_mappings: ?[]const SourceMap.Mapping = null;
            defer if (module_mappings) |maps| allocator.free(maps);
            var module_names: []const []const u8 = &.{};
            defer {
                for (module_names) |n| allocator.free(n);
                if (module_names.len > 0) allocator.free(module_names);
            }
            var module_preamble_lines: u32 = 0;
            // IIFE splitting: emitModule 에 wrapped `return{}` 억제 플래그 전달
            // (factory 가 함수 스코프 제공, export 는 emitCjsEntryExports/
            // xchunk_exports 가 담당). iife_emit_opts 는 빌드당 1회 복사.
            const mod_used_names: ?[]const []const u8 = if (mi < used_names_by_modidx.len and !used_names_by_modidx[mi].all_used)
                used_names_by_modidx[mi].names
            else
                null;
            const raw_code = try emitModule(
                allocator,
                m,
                if (reg_split) &iife_emit_opts else options,
                linker,
                is_entry,
                mod_used_names,
                shaker,
                null,
                if (chunk_sm != null) &module_mappings else null,
                if (chunk_sm != null) &module_names else null,
                if (chunk_sm != null) &module_preamble_lines else null,
                null,
                null,
                null,
            ) orelse continue;
            defer allocator.free(raw_code);

            // 동적 import 경로 리라이트: import('./page') → import('./page.js')
            const code = try rewriteDynamicImports(allocator, raw_code, m, graph, chunk_graph, options.public_path, ext, options, reg_ids, linker);
            defer allocator.free(code);

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

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "//#region ");
                try chunk_output.appendSlice(allocator, std.fs.path.basename(m.path));
                try chunk_output.append(allocator, '\n');
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
                    .base_line = module_line.? - region_lines,
                    .preamble_lines = module_preamble_lines,
                    .sources_content = options.sourcemap.sources_content,
                    .indent_offset = false,
                    .pre_lines = region_lines,
                    .total_code_lines = stripped_lines,
                    .post_lines = endregion_lines,
                    .plugin_source_maps = m.plugin_source_maps,
                });
            };

            try chunk_output.appendSlice(allocator, stripped);
            if (module_line) |*ml| ml.* += stripped_lines;
            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "//#endregion\n");
                if (module_line) |*ml| ml.* += 1;
            }

            // dev+split per-module HMR code 수집 (RFC_LAZY_DEV_MODULE_HMR PR-1).
            // 단일 번들(emitter.zig)과 *동일* 형식(wrapDevModuleCode)으로 모은다 — HMR
            // client 가 두 경로 산출을 구분 없이 eval. concat 용 region marker 는 제외하고
            // rewriteDynamicImports 거친 `code` 를 wrap. PR-1 은 수집(인프라)만 — 글로벌
            // 레지스트리 부트스트랩/클라이언트 적용은 후속 PR. sourcemap 은 후속(PR 범위 축소).
            if (collect_dev_codes) {
                const mod_id = parent.makeModuleId(m.path, options.root_dir);
                const hmr_code = try parent.wrapDevModuleCode(allocator, code, mod_id, options.sourcemap.enable);
                errdefer allocator.free(hmr_code);
                const id_dup = try allocator.dupe(u8, mod_id);
                errdefer allocator.free(id_dup);
                try chunk_dev_codes.append(allocator, .{ .id = id_dup, .code = hmr_code });
            }
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
        if (options.run_before_main.len > 0) {
            try collectRunBeforeMainExportNames(
                allocator,
                &rbm_export_names,
                graph,
                chunk_graph,
                chunk,
                options.run_before_main,
                if (linker) |l| &l.rename_table else null,
            );
        }

        // dev_split (RFC_LAZY_DEV_MODULE_HMR PR-2): 비-entry 청크(shared/common)의 wrapped
        // 모듈 init 트리거. production 은 모듈이 wrap 안 돼 청크 factory 실행 = 즉시 init
        // 이지만, dev wrap-all 은 모듈을 `init_X = __esm({...})` 로 lazy wrap. 청크 factory
        // 가 init 을 안 부르면 아래 cross-chunk `exports.x = local` 이 init 전 값(undefined)을
        // 스냅샷 → cross-chunk 소비자가 `const {x} = __zntc_require(...)` 로 undefined 캡처
        // (s=undefined 버그). entry 청크는 935 블록이 처리하므로 여기선 비-entry 만. 반드시
        // cross-chunk exports emit *앞* 에서 호출해 local 값을 채운다. __esm memoize=중복 무해.
        if (dev_split_chunk and !chunk_is_user_entry) {
            for (sorted_mods) |mod_idx| {
                const mi = @intFromEnum(mod_idx);
                if (mi >= module_count) continue;
                const m = graph.getModule(mod_idx) orelse continue;
                const tla = m.wrap_kind == .esm and m.uses_top_level_await;
                if (m.wrap_kind.isWrapped() and !tla) {
                    try parent.appendModuleCall(&chunk_output, allocator, m, if (linker) |l| &l.rename_table else null);
                }
            }
        }

        // 크로스 청크 export: exports_to에 심볼이 있으면 export 문 생성.
        // 다른 청크가 이 청크에서 심볼을 가져가는 경우에만 출력.
        // preserve-modules에서는 모듈 자체의 export가 유지되므로 cross-chunk export 불필요.
        // linker가 심볼을 rename한 경우 export { local_name as export_name } 형태로 출력.
        // PR-3b-ii: lazy reg(IIFE/CJS) entry 청크는 소비자(동적 청크)가 시작 시 미파싱이라
        // exports_to 가 비어도 export-all 해야 하므로 별도로 진입한다.
        const lazy_reg_entry = graph.lazy_compilation and entry_mod_idx != null and (options.format == .cjs or reg_split);
        if ((chunk.exports_to.count() > 0 or rbm_export_names.items.len > 0 or lazy_reg_entry) and !options.preserve_modules) xchunk_exports: {
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
            if (reg_fmt and entry_mod_idx != null) {
                // PR-3b-ii: lazy 면 entry 청크가 hoisted 모듈 export 를 local name 으로 전부
                // 노출(export-all) — on-demand 동적 청크가 시작 시 미파싱 seed 라 어떤 export 를
                // 참조할지 몰라도 찾게 + demand-driven 이 아니라 결정론(seed force-parse 무관).
                // 그 외(eager)는 기존대로 break(emitCjsEntryExports 에 일임).
                if (graph.lazy_compilation) {
                    try emitLazyEntryExportAll(allocator, &chunk_output, graph, linker, sorted_mods, entry_mod_idx.?, module_count, options.minify_whitespace);
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
            if (!cjs_x) {
                if (entry_mod_idx) |ei| {
                    if (graph.getModule(ModuleIndex.fromUsize(@intCast(ei)))) |em| {
                        var w: usize = 0;
                        for (export_names.items) |nm| {
                            var entry_exported = false;
                            for (em.export_bindings) |eb| {
                                if (std.mem.eql(u8, eb.exported_name, nm)) {
                                    entry_exported = true;
                                    break;
                                }
                            }
                            if (!entry_exported) {
                                export_names.items[w] = nm;
                                w += 1;
                            }
                        }
                        export_names.shrinkRetainingCapacity(w);
                    }
                }
                if (export_names.items.len == 0) break :xchunk_exports;
            }

            if (!cjs_x) {
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "export { ");
                } else {
                    try chunk_output.appendSlice(allocator, "export{");
                }
            }
            for (export_names.items, 0..) |name, ni| {
                // export_name의 원본 심볼이 이 청크에서 rename되었는지 확인.
                // rename된 경우: export { local_name as export_name }
                // rename 안 된 경우: export { export_name }
                const local_name = if (linker) |l| blk: {
                    // exports_to의 이름은 canonical export name.
                    // 이 이름을 선언한 모듈을 찾아 linker의 canonical_names를 조회한다.
                    var found_local: ?[]const u8 = null;
                    for (sorted_mods) |mod_idx| {
                        const mi = @intFromEnum(mod_idx);
                        if (mi >= module_count) continue;
                        // namespace re-export(`export * as X` / `import * as X;
                        // export {X}`)는 로컬 심볼이 없거나 elided 라 canonical
                        // 조회가 빗나간다. 대상 청크에 materialize 된 shared ns
                        // 객체 변수가 곧 X 의 실제 값 — cross-chunk import 로
                        // 이 청크에 바인딩돼 있으므로 그 이름으로 export
                        // (`export { inner_ns as X }`) (#3321 후속).
                        if (chunk_mod.nsReExportTarget(graph, mod_idx, name)) |ns_t| {
                            // else |_|: ensureSharedNsVar OOM 은 canonical
                            // fallback 으로 진행 (getCanonicalName 패턴과 일관).
                            if (l.ensureSharedNsVar(ns_t)) |ns_var| {
                                found_local = ns_var;
                                break;
                            } else |_| {}
                        }
                        if (l.getCanonicalName(@intCast(mi), name)) |renamed| {
                            found_local = renamed;
                            break;
                        }
                        // export의 local_name이 다를 수 있으므로 export_map도 확인
                        if (l.getExportLocalName(@intCast(mi), name)) |local| {
                            if (l.getCanonicalName(@intCast(mi), local)) |renamed| {
                                found_local = renamed;
                                break;
                            }
                        }
                    }
                    break :blk found_local orelse name;
                } else name;

                if (cjs_x) {
                    // exports.<name> = <local>;  (min: 공백 제거, 형태 동일)
                    try chunk_output.appendSlice(allocator, "exports.");
                    try chunk_output.appendSlice(allocator, name);
                    try chunk_output.appendSlice(allocator, if (options.minify_whitespace) "=" else " = ");
                    try chunk_output.appendSlice(allocator, local_name);
                    try chunk_output.appendSlice(allocator, if (options.minify_whitespace) ";" else ";\n");
                    continue;
                }

                try chunk_output.appendSlice(allocator, local_name);
                // local_name과 export_name이 다르면 as 절 추가
                if (!std.mem.eql(u8, local_name, name)) {
                    try chunk_output.appendSlice(allocator, " as ");
                    try chunk_output.appendSlice(allocator, name);
                }
                if (ni + 1 < export_names.items.len) {
                    if (!options.minify_whitespace) {
                        try chunk_output.appendSlice(allocator, ", ");
                    } else {
                        try chunk_output.append(allocator, ',');
                    }
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

        // Wrapped entry 모듈은 factory body 안에서 명시적으로 호출해야 본문이 실행된다.
        // scope-hoist(.none) entry 는 인라인 실행되지만, require.context/CJS-interop 등으로
        // wrap 된 entry 는 `var require_X=__commonJS(...)`/`var init_X=__esm(...)` 정의만 되고
        // 호출 안 돼 본문 미실행이었다(issue #4039 / verifier BUG2). bootstrap 의
        // `__zntc_require("entry-chunk")` 는 factory 를 1회 실행하므로 여기서 wrapped entry
        // init 을 호출하면 정확히 1회 실행(__commonJS/__esm 가 memoize).
        if (reg_split and chunk_is_user_entry) {
            if (entry_mod_idx) |ei| {
                if (graph.getModule(@enumFromInt(ei))) |em| {
                    // TLA(.esm + top-level await) entry 는 appendModuleCall 이 `await init_X()`
                    // 를 내는데, reg_split 청크 factory 는 비-async `function(...)` 이라 top-level
                    // await = SyntaxError. TLA+reg_split entry 는 이 PR 이전에도 미실행이었으므로
                    // 여기서 제외(회귀 없음 — 무효 JS 생성 방지). 비-TLA wrapped entry 만 호출.
                    const tla_entry = em.wrap_kind == .esm and em.uses_top_level_await;
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
            try chunk_output.insertSlice(allocator, 0, hoisted_directives.items);
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

        try outputs.append(allocator, .{
            .path = filename,
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
) !void {
    var dep_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer dep_buf.deinit(allocator);
    // src_dir 는 importer chunk 의 *최종 stem* (baked-in slash 포함) 의 dirname.
    var importer_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer importer_buf.deinit(allocator);
    try chunkPlaceholderStem(current_chunk, &importer_buf, allocator, options);
    const importer_dir = std.fs.path.dirname(importer_buf.items) orelse "";
    for (imports) |imp| {
        const dep_chunk = chunk_graph.getChunk(imp.source_chunk);
        try chunkPlaceholderStem(dep_chunk, &dep_buf, allocator, options);
        const dep_stem = dep_buf.items;
        const resolved_path = if (options.preserve_modules) blk: {
            const src_path = current_chunk.rel_dir orelse "./";
            const dep_path = dep_chunk.rel_dir orelse "./";
            break :blk try computeRelativeImportPath(allocator, src_path, dep_path, ext, options.preserve_modules_root);
        } else if (dep_chunk.explicit_file_name) |efn|
            try computeRelativePath(allocator, importer_dir, efn, "")
        else blk: {
            break :blk try computeRelativePath(allocator, importer_dir, dep_stem, ext);
        };
        defer allocator.free(resolved_path);

        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "import { ");
            try output.appendSlice(allocator, imp.name);
            try output.appendSlice(allocator, " } from \"");
            try output.appendSlice(allocator, resolved_path);
            try output.appendSlice(allocator, "\";\n");
        } else {
            try output.appendSlice(allocator, "import{");
            try output.appendSlice(allocator, imp.name);
            try output.appendSlice(allocator, "}from\"");
            try output.appendSlice(allocator, resolved_path);
            try output.appendSlice(allocator, "\";");
        }
    }
}

fn collectRunBeforeMainExportNames(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
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
        if (containsName(out.items, name)) {
            allocator.free(name);
            continue;
        }
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
/// 반환값은 항상 allocator 소유 — 리라이트 여부와 무관하게 caller가 free해야 한다.
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
) ![]const u8 {
    // dynamic import가 없으면 그대로 복사해서 반환
    if (module.import_records.len == 0) {
        return try allocator.dupe(u8, code);
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
        try chunkPlaceholderStem(chunk_graph.getChunk(src_chunk_idx), &importer_stem_buf, allocator, emit_options);
        break :blk std.fs.path.dirname(importer_stem_buf.items) orelse "";
    };

    // 리라이트할 레코드가 있는지 먼저 확인 (불필요한 할당 방지)
    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.kind == .dynamic_import and rec.resolved != .none) {
            const target_chunk = chunk_graph.getModuleChunk(rec.resolved);
            if (target_chunk != .none) {
                has_dynamic = true;
                break;
            }
        }
    }
    if (!has_dynamic) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트 수행: 각 dynamic import specifier를 청크 파일명으로 교체.
    // import_records를 순회하면서 코드 내의 specifier 문자열을 찾아 교체한다.
    // codegen이 specifier를 원본 그대로 출력하므로 정확한 문자열 매칭이 가능.
    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    const source_chunk_idx = chunk_graph.getModuleChunk(module.index);

    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) continue;

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
                    break :blk try std.fmt.allocPrint(allocator, "Promise.resolve().then(()=>({s}(),{s}))", .{ init_name, exports_name });
                },
                .cjs => blk: {
                    const require_name = try target_mod.allocRequireName(allocator, if (linker) |l| &l.rename_table else null);
                    defer allocator.free(require_name);
                    break :blk try std.fmt.allocPrint(allocator, "Promise.resolve().then(()=>{s}())", .{require_name});
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
                        const local = if (linker) |l|
                            l.getCanonicalForExport(eb, tmi)
                        else
                            target_mod.exportBindingLocalName(eb);
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
        const reg_split = (emit_options.format == .iife or emit_options.format == .umd or emit_options.format == .amd) and !emit_options.preserve_modules;
        if (reg_split) {
            const target_id = reg_ids[@intFromEnum(target_chunk_idx)]; // borrow
            const chunkfile = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, out_ext });
            defer allocator.free(chunkfile);
            const wrapper = try std.fmt.allocPrint(allocator, "__zntc_load_chunk(\"{s}\").then(function(){{return __zntc_require(\"{s}\")}})", .{ chunkfile, target_id });
            defer allocator.free(wrapper);
            if (try rewriteImportCallToWrapper(allocator, result, rec.specifier, wrapper)) |new_result| {
                allocator.free(result);
                result = new_result;
            }
            continue;
        }

        const cjs_split = emit_options.format == .cjs and !emit_options.preserve_modules;
        if (cjs_split) {
            const wrapper = try std.fmt.allocPrint(allocator, "Promise.resolve().then(()=>require(\"{s}\"))", .{replacement});
            defer allocator.free(wrapper);
            if (try rewriteImportCallToWrapper(allocator, result, rec.specifier, wrapper)) |new_result| {
                allocator.free(result);
                result = new_result;
            }
            continue;
        }

        // 코드에서 원본 specifier를 찾아 교체
        if (std.mem.indexOf(u8, result, rec.specifier)) |pos| {
            const new_result = try std.mem.concat(allocator, u8, &.{
                result[0..pos],
                replacement,
                result[pos + rec.specifier.len ..],
            });
            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

/// `import("specifier")` 호출 전체를 미리 만들어진 expression 으로 교체.
/// 매칭 실패 시 null. codegen 출력 형태 (`import("./x")`) 만 처리 — import attributes
/// 같은 second-arg 폼은 미지원 (현재 codegen 이 emit 하지 않음).
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
    rename_tbl: ?*const RenameTable,
) ![]const u8 {
    if (module.import_records.len == 0) return try allocator.dupe(u8, code);
    if (!graph.inline_dynamic_imports) return try allocator.dupe(u8, code);

    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.kind == .dynamic_import and (rec.resolved != .none or lower_unresolved_dynamic_imports)) {
            has_dynamic = true;
            break;
        }
    }
    if (!has_dynamic) return try allocator.dupe(u8, code);

    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) {
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
                break :blk try std.fmt.allocPrint(allocator, "Promise.resolve().then(()=>({s}(),{s}))", .{ init_name, exports_name });
            },
            .cjs => blk: {
                const require_name = try target_mod.allocRequireName(allocator, rename_tbl);
                defer allocator.free(require_name);
                break :blk try std.fmt.allocPrint(allocator, "Promise.resolve().then(()=>{s}())", .{require_name});
            },
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

fn rewriteImportCallToWrapper(
    allocator: std.mem.Allocator,
    code: []const u8,
    specifier: []const u8,
    replacement: []const u8,
) !?[]u8 {
    const spec_pos = std.mem.indexOf(u8, code, specifier) orelse return null;
    // `import("` 또는 `import('` 가 specifier 앞에 와야 함.
    if (spec_pos < "import(\"".len) return null;
    const opener = code[spec_pos - "import(\"".len .. spec_pos];
    if (!std.mem.eql(u8, opener, "import(\"") and !std.mem.eql(u8, opener, "import('")) return null;
    const quote = code[spec_pos - 1];

    const after_spec = spec_pos + specifier.len;
    if (after_spec + 1 >= code.len) return null;
    if (code[after_spec] != quote) return null;
    if (code[after_spec + 1] != ')') return null;

    const call_start = spec_pos - "import(\"".len;
    const call_end = after_spec + 2; // include ')'

    return try std.mem.concat(allocator, u8, &.{ code[0..call_start], replacement, code[call_end..] });
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
    placeholder: [HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8,
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
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
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
            const dep_out = chunk_to_out[@intFromEnum(dep_ci)] orelse continue;
            try imps.append(allocator, try allocator.dupe(u8, outputs[dep_out].path));
        }
        outputs[oi].imports = try imps.toOwnedSlice(allocator);
    }
}

/// placeholder 해시 길이 (8자리 hex).
const HASH_PLACEHOLDER_LEN = 8;
/// placeholder 구분 문자열. 최종 출력에서 content hash로 치환된다.
/// 다른 코드에서 절대 등장하지 않을 문자열을 사용.
const HASH_PLACEHOLDER_PREFIX = "\x00ZH";

/// 청크의 인덱스 해시로 placeholder 바이트를 생성한다.
/// chunkPlaceholderStem과 resolveContentHashes에서 공용.
fn buildPlaceholder(chunk: *const Chunk, ph: *[HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8) void {
    @memcpy(ph[0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX);
    const idx_hash = chunkIndexHash(chunk);
    _ = std.fmt.bufPrint(ph[HASH_PLACEHOLDER_PREFIX.len..], "{x:0>8}", .{@as(u32, @truncate(idx_hash))}) catch unreachable;
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
/// entry 모듈 자신의 export 는 emitCjsEntryExports 담당 → 제외.
/// **한계(RFC §6.3, 후속)**: export-name 과 local name 이 다른 케이스(① 소비 모듈이 entry
/// 안에서 deconflict, ② `export { a as b }` 별칭, ③ re-export)는 소비자 imports_from 이
/// export-name 키라 mismatch — `export const`/`export function` 처럼 export-name==local-name
/// 인 일반 케이스만 정합(dev on-demand 의 대다수). mismatch 는 crash 가 아니라 미해결 참조.
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
    var locals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer locals.deinit(allocator);
    for (sorted_mods) |mod_idx| {
        const mi = @intFromEnum(mod_idx);
        if (mi >= module_count or mi == entry_mod_idx) continue;
        const m = graph.getModule(mod_idx) orelse continue;
        for (m.export_bindings) |eb| {
            // `export * from './m'`(re_export_star)는 노출 이름이 `*` 하나뿐인데 로컬
            // 심볼이 없어 `exports.* = *;`(invalid JS) 를 만든다. star 가 합치는 실제
            // 이름들은 소스 모듈의 자기 바인딩으로 이미 순회되므로(같은 청크 hoist 시)
            // 여기선 스킵한다. (`export * as ns`=re_export_namespace 는 실제 로컬 ns
            // 심볼이 있으므로 스킵 대상 아님.)
            if (eb.kind == .re_export_star) continue;
            const local = l.getCanonicalName(@intCast(mi), eb.exported_name) orelse m.exportBindingLocalName(eb);
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

fn chunkRestrictSkip(chunk: *const Chunk, ci: usize, restrict_to_chunk: ?usize) bool {
    if (restrict_to_chunk) |r| {
        if (ci != r) return true;
        return chunk.modules.items.len == 0;
    }
    return chunk.modules.items.len == 0 or chunk.is_lazy_seed;
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

    var hash_buf: [HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8 = undefined;
    buildPlaceholder(chunk, &hash_buf);

    try applyNamingPatternWithDir(out, allocator, pattern, base_name, &hash_buf, dir);
}

/// 모듈 인덱스 기반 해시 (placeholder 식별자용, content hash 아님).
fn chunkIndexHash(chunk: *const Chunk) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var sort_buf: [256]u32 = undefined;
    const mod_count = @min(chunk.modules.items.len, 256);
    for (chunk.modules.items[0..mod_count], sort_buf[0..mod_count]) |mod_idx, *sb| {
        sb.* = @intFromEnum(mod_idx);
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
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
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
    // placeholder_hash는 "\x00ZH" + 8hex, real_hash는 8hex
    // 치환 대상: placeholder_hash 전체 → real_hash
    const ph_len = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
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
            const target_i: u32 = @intFromEnum(target);
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
            const target_i: u32 = @intFromEnum(target);
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

            // 크로스-모듈 BFS 도달성
            if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                if (eb.symbol.semanticIndex()) |sym_idx| {
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
/// dep_stem: 대상 청크의 stem 이름 (fallback용)
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
    // root가 있으면 root 기준 상대 경로에서 계산
    if (root) |r| {
        const normalized_root = if (r.len > 0 and r[r.len - 1] == '/') r[0 .. r.len - 1] else r;

        const src_rel = stripRoot(src_abs, normalized_root);
        const dep_rel = stripRoot(dep_abs, normalized_root);

        if (src_rel != null and dep_rel != null) {
            // 둘 다 root 아래 → 상대 경로 계산
            const src_dir = std.fs.path.dirname(src_rel.?) orelse "";
            const dep_rel_no_ext = dep_rel.?[0 .. dep_rel.?.len - std.fs.path.extension(dep_rel.?).len];
            const rel = try computeRelativePath(allocator, src_dir, dep_rel_no_ext, ext);
            return rel;
        }
    }

    // root 없거나 매칭 실패 → 절대 경로 기준으로 computeRelativePath에 위임
    const src_dir = std.fs.path.dirname(src_abs) orelse "";
    const dep_no_ext = dep_abs[0 .. dep_abs.len - std.fs.path.extension(dep_abs).len];
    return computeRelativePath(allocator, src_dir, dep_no_ext, ext);
}

/// 절대 경로에서 root prefix를 제거한다.
/// 예: stripRoot("/a/b/c.ts", "/a/b") → "c.ts"
fn stripRoot(abs_path: []const u8, root: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, abs_path, root)) {
        var rel = abs_path[root.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        return rel;
    }
    return null;
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
