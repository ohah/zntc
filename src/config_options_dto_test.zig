//! `ConfigOptionsDto` (Zig) ↔ `TranspileOptions` (TS) 필드 동기화 검증.
//!
//! #1446에서 Zig struct가 JSON schema의 단일 소스가 됐지만, TS 쪽의
//! `TranspileOptions` interface는 JSDoc/union 유지를 위해 handwritten으로
//! 남았다. 두 표현이 드리프트하지 않도록 CI에서 자동 검증한다.
//!
//! 검증 원칙:
//!   - Zig DTO 필드는 전부 TS interface에 존재해야 함 (WASM/NAPI로 전달되려면
//!     TS 사용자가 해당 필드를 쓸 수 있어야 함).
//!   - TS에만 있고 Zig에 없는 필드는 allowlist에 있어야 함 (JS 래퍼가
//!     자체 처리하는 필드들 — filename/browserslist/minify 등).

const std = @import("std");
const ConfigOptionsDto = @import("transpile.zig").ConfigOptionsDto;

/// TS `TranspileOptions`에만 있는 (Zig로 전달되지 않거나 JS 래퍼가 해석하는)
/// 필드. 리스트에 없는 TS-only 필드가 발견되면 테스트 실패 — 의도된 추가라면
/// 이 리스트에 등록할 것.
const ts_only_allowlist = [_][]const u8{
    "filename", // CLI/API의 별도 인자로 전달, 옵션 DTO에 안 들어감
    "browserslist", // JS 쪽에서 unsupported bitmask로 해석 후 주입
    "minify", // minifyWhitespace/Identifiers/Syntax all-in-one alias
};

/// `bundler_only_fields` 와 `pure_zig_only_fields` 의 union — `TranspileOptions`
/// 에 없어도 schema drift 로 간주 안 함.
const zig_only_allowlist = pure_zig_only_fields ++ bundler_only_fields;

/// 순수 Zig 내부 필드 (BuildOptions 와도 무관, JS 래퍼가 자체 처리).
const pure_zig_only_fields = [_][]const u8{
    "unsupported", // JS wrapper가 browserslist 해석 후 주입. 사용자가 직접 쓸 일 없음.
};

/// #2105 bundler-only 필드. `TranspileOptions` 가 아닌 `BuildOptions` 의
/// 일부 — TS 공개 API 는 `packages/core/index.ts:BuildOptionsCommon` 에 있다.
/// Zig CLI 의 `applyZntcConfigJson` 이 한 번에 파싱하기 위해 같은 DTO 에 모음.
///
/// `BuildOptionsCommon` 검증 테스트가 이 리스트의 모든 필드가 거기에도 있는지
/// (그리고 그 역도) 확인 — #2112 schema sync.
const bundler_only_fields = [_][]const u8{
    "external",
    "alias",
    "aliasExact",
    "loader",
    "conditions",
    "resolveExtensions",
    "mainFields",
    "banner",
    "footer",
    "intro",
    "outro",
    "assetNames",
    "chunkNames",
    "cssNames",
    "entryNames",
    "preserveModules",
    "preserveModulesRoot",
    "inlineDynamicImports",
    "minChunkSize",
    "manualChunks",
    // D105 PR-A: lazy on-demand 프리미티브 (build()/watch() 전용, dev 서버 오케스트레이션).
    "lazyCompilation",
    "lazyForceParse",
    "sourcemapMode",
    "outputExports",
    "mf", // Module Federation config 블록 (#3318 P1-0)
};

/// TS interface 본문에서 필드명을 추출한다. 간단 파서: `interface <name> {` 블록
/// 본문의 각 줄에서 첫 식별자(optional `?` 직전의 `:`까지)를 긁는다.
/// 주석(`//`, `/**`)과 빈 줄은 스킵.
fn parseTsInterface(
    source: []const u8,
    interface_name: []const u8,
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    var marker_buf: [128]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "interface {s} {{", .{interface_name});
    const body_start = (std.mem.indexOf(u8, source, marker) orelse return error.InterfaceNotFound) + marker.len;
    var depth: usize = 1;
    var i: usize = body_start;
    while (i < source.len and depth > 0) : (i += 1) {
        switch (source[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    const body = source[body_start .. i - 1];

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "*")) continue;
        if (std.mem.startsWith(u8, line, "/*")) continue;

        // `fieldName?:` 또는 `fieldName:` 패턴. 첫 non-identifier 문자까지가 필드명.
        var end: usize = 0;
        while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
        if (end == 0) continue;
        const name = line[0..end];
        // `:` 또는 `?:`가 이어져야 필드 선언.
        const after = line[end..];
        if (!std.mem.startsWith(u8, after, ":") and !std.mem.startsWith(u8, after, "?:")) continue;
        try list.append(allocator, name);
    }
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    @setEvalBranchQuota(5000);
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

test "schema diff: Zig DTO fields are covered by TS TranspileOptions" {
    // DTO 필드 × allowlist 엔트리 수가 늘어나며 comptime 분기 한도 초과.
    @setEvalBranchQuota(8000);
    const allocator = std.testing.allocator;

    // 저장소 루트에서 테스트 실행 가정 (zig build test 기본).
    const ts_source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/shared/index.ts", allocator, std.Io.Limit.limited(1 * 1024 * 1024)) catch |err| {
        // CI 외 환경에서 경로가 다를 수 있음 → skip 처리
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(ts_source);

    var ts_fields: std.ArrayList([]const u8) = .empty;
    defer ts_fields.deinit(allocator);
    try parseTsInterface(ts_source, "TranspileOptions", &ts_fields, allocator);
    try std.testing.expect(ts_fields.items.len > 0);

    // 1. Zig DTO 필드가 TS에 모두 있는지 (internal 필드는 zig_only_allowlist에서 제외)
    const zig_fields = @typeInfo(ConfigOptionsDto).@"struct".fields;
    inline for (zig_fields) |f| {
        const is_internal = comptime contains(&zig_only_allowlist, f.name);
        if (!is_internal and !contains(ts_fields.items, f.name)) {
            std.debug.print(
                "\n[schema drift] Zig ConfigOptionsDto.{s} is missing from TS TranspileOptions in packages/shared/index.ts\n",
                .{f.name},
            );
            return error.ZigFieldMissingFromTs;
        }
    }

    // 2. TS에만 있는 필드는 allowlist에 있어야 함
    for (ts_fields.items) |ts_name| {
        // Zig에 있으면 OK
        var found = false;
        inline for (zig_fields) |f| {
            if (std.mem.eql(u8, f.name, ts_name)) found = true;
        }
        if (found) continue;
        if (contains(&ts_only_allowlist, ts_name)) continue;
        std.debug.print(
            "\n[schema drift] TS TranspileOptions.{s} is not in Zig DTO — add to ts_only_allowlist if intentional\n",
            .{ts_name},
        );
        return error.TsFieldNotAllowlisted;
    }
}

test "parseTsInterface: basic extraction" {
    const source =
        \\export interface Other { x: number }
        \\export interface TranspileOptions {
        \\  /** Filename */
        \\  filename?: string;
        \\  sourcemap?: boolean;
        \\  // inline comment
        \\  target?: Target;
        \\  nested?: { inner: string };
        \\}
    ;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseTsInterface(source, "TranspileOptions", &list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("filename", list.items[0]);
    try std.testing.expectEqualStrings("sourcemap", list.items[1]);
    try std.testing.expectEqualStrings("target", list.items[2]);
    try std.testing.expectEqualStrings("nested", list.items[3]);
}

// ─── #2112 BuildOptions schema sync ──────────────────────────────────────────

/// Zig 의 `bundler_only_fields` 가 `BuildOptionsCommon` 에 노출돼야 사용자가
/// `zntc.config.{ts,json}` 에서 IDE 자동완성을 받을 수 있다.
///
/// CLI 에만 있고 사용자에게 노출 안 하는 필드 (예: `tsconfigPath` 는 별도 alias).
const ts_buildoptions_only_allowlist = [_][]const u8{
    // BuildOptions 가 가진 필드 중 Zig DTO 에 없는 것 — 모두 알려진 의도.
    "entryPoints", // CLI positional / config
    "outdir", // CLI -o/--outdir
    "outfile",
    "outbase",
    "output", // multi-format sugar (PR-I) — JS-level dispatch, native 로 전달 안 함
    "outputsByFormat", // BuildResult only — write 시점에 BundleResult 안 가지만 schema test 가 BuildOptions 만 검사
    "globalName", // IIFE/UMD only
    "publicPath",
    "splitting", // bundler 옵션, DTO 에 모음
    "treeShaking",
    "metafile",
    "keepNames",
    "shimMissingExports",
    "drop",
    "dropLabels",
    "pure",
    "inject",
    "intro",
    "outro",
    "legalComments",
    "logLevel",
    "logLimit",
    "lineLimit",
    "ignoreAnnotations",
    "watchDelay",
    "jobs",
    "globals",
    "packagesExternal",
    "platform", // discriminated union 으로 처리됨
    "target",
    "browserslist",
    "runtimePolyfills", // JS wrapper가 core-js compat 후보를 native graph plan 으로 전달
    "coreJs", // runtimePolyfills 전용 core-js 버전 힌트
    "plugins",
    "compiler", // 1st-party transform 네임스페이스 (compiler.styledComponents/emotion).
    // 현재 stub — Zig transformer 가 아직 인식하지 않음. 후속 PR 에서 styled-components /
    // emotion transform 도입 시 Zig DTO 로 옮김.
    "jsxSideEffects",
    "assetRegistry", // RN asset_registry 모듈 처리
    "scopeHoist", // bundler 옵션 (#1389)
    "workletTransform", // RN reanimated worklet
    "codegenTransform", // RN view config codegen (#2348)
    "moduleSpecifierMap", // cherry-pick import 분해 (#2393)
    "strictExecutionOrder", // 모듈 실행 순서 보장
    "experimentalCodeCache", // persistent cache 실험
    "watch", // CLI flag, BuildOptions 노출 안 함이 정석이지만 일부 wrapper 가 노출
    "extends", // config-only
    "server", // config-only dev server defaults

    // ─── BuildOptions / NAPI 전용 — Zig DTO 미노출이 의도된 것들 ──────────────
    // 사용자 코드가 NAPI 또는 build() JS API 로 직접 전달. CLI / config 경로는 미사용.
    "allowOverwrite", // 출력 디렉토리 덮어쓰기 허용
    "analyze", // metafile 분석 출력
    "blockList", // RN resolver block list
    "collectModuleCodes", // NAPI 만 사용 (HMR module codes)
    "codegenTransform", // BuildOptions 전용 codegen transform hook
    "preserveSafePlugins", // PR-3: HMR 위상 보존 plugin 게이트 완화 신호 (RN preset opt-in, NAPI 전용)
    "configurableExports", // RN configurable __toESM
    "devMode", // dev mode flag
    "emitDiskSourcemap", // sourcemap 디스크 emit
    "entryErrorGuard", // RN entry error guard
    "fallback", // resolve fallback (Metro 호환)
    "globalIdentifiers", // RN polyfill 식별자
    "nodePaths", // NODE_PATH 등가
    "onReady", // NAPI build 콜백
    "onRebuild", // NAPI watch 콜백
    "outExtension", // 출력 확장자 매핑
    "polyfills", // 명시 polyfill 주입
    "preserveSymlinks", // resolver 옵션
    "resolveSymlinkSiblings", // resolver fallback to realpath sibling node_modules
    "disableHierarchicalLookup", // Metro resolver.disableHierarchicalLookup 호환
    "profile", // 프로파일링 enable
    "profileFormat", // 프로파일 출력 format
    "profileLevel", // 프로파일 verbosity
    "reactRefresh", // dev 모드 react-refresh
    "rootDir", // 프로젝트 root
    "runBeforeMain", // entry 전 실행 코드
    "silentConsoleErrorPatterns", // RN log 필터
    "skipInitialOutput", // #3779 follow-up — watch 의 initial 빌드 outdir 출력 skip
    "watchExclude", // watch 제외 glob
    "watchFolders", // watch 추가 디렉토리 (Metro 호환)
    "watchInclude", // watch 포함 glob
    "workletPluginVersion", // worklet plugin 버전
    "write", // 디스크 emit on/off
};

test "schema diff: bundler_only_fields are all in TS BuildOptionsCommon" {
    @setEvalBranchQuota(8000);
    const allocator = std.testing.allocator;

    const ts_source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/core/index.ts", allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(ts_source);

    var ts_fields: std.ArrayList([]const u8) = .empty;
    defer ts_fields.deinit(allocator);
    try parseTsInterface(ts_source, "BuildOptionsCommon", &ts_fields, allocator);
    try std.testing.expect(ts_fields.items.len > 0);

    // 1. bundler_only_fields 의 모든 키가 BuildOptionsCommon 에 존재해야 함.
    for (bundler_only_fields) |zig_name| {
        if (!contains(ts_fields.items, zig_name)) {
            std.debug.print(
                "\n[schema drift] Zig bundler_only_fields.{s} is missing from TS BuildOptionsCommon in packages/core/index.ts — IDE 자동완성 안 됨\n",
                .{zig_name},
            );
            return error.ZigFieldMissingFromBuildOptions;
        }
    }

    // 2. BuildOptionsCommon 의 키는 (a) bundler_only_fields 또는 (b) TranspileOptions 또는
    //    (c) ts_buildoptions_only_allowlist 중 하나에 있어야 함.
    const transpile_source = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/shared/index.ts", allocator, std.Io.Limit.limited(1 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(transpile_source);

    var transpile_fields: std.ArrayList([]const u8) = .empty;
    defer transpile_fields.deinit(allocator);
    try parseTsInterface(transpile_source, "TranspileOptions", &transpile_fields, allocator);

    for (ts_fields.items) |build_name| {
        if (contains(&bundler_only_fields, build_name)) continue;
        if (contains(transpile_fields.items, build_name)) continue;
        if (contains(&ts_buildoptions_only_allowlist, build_name)) continue;
        std.debug.print(
            "\n[schema drift] TS BuildOptionsCommon.{s} is not in Zig bundler_only_fields nor TranspileOptions — add to bundler_only_fields (Zig DTO) or ts_buildoptions_only_allowlist (intentional CLI-only)\n",
            .{build_name},
        );
        return error.TsBuildOptionMissingFromZig;
    }
}

test "AliasDto / ManualChunkDto 는 bundler/types entry 타입의 alias — drift 차단" {
    const transpile = @import("transpile.zig");
    const bundler_types_mod = @import("bundler/types.zig");

    // type 자체가 같아야 — 한 정의 변경 시 다른 곳 자동 반영. drift 차단.
    try std.testing.expect(transpile.AliasDto == bundler_types_mod.AliasEntry);
    try std.testing.expect(transpile.ManualChunkDto == bundler_types_mod.ManualChunkEntry);
}
