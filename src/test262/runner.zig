const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

/// Test262 테스트 파일의 YAML 메타데이터
/// 각 .js 파일 상단의 /*--- ... ---*/ 블록을 파싱한 결과
pub const TestMetadata = struct {
    /// 파싱 단계에서 에러가 나야 하는 테스트인지
    /// negative.phase == "parse" && negative.type == "SyntaxError"이면 true
    is_negative_parse: bool = false,

    /// 에러 타입 (SyntaxError, ReferenceError 등)
    negative_type: ?[]const u8 = null,

    /// module 모드로 파싱해야 하는지
    is_module: bool = false,

    /// strict mode 관련 플래그
    is_only_strict: bool = false,
    is_no_strict: bool = false,

    /// 이 테스트가 요구하는 feature 목록
    /// (아직 미구현 feature면 스킵 판단에 사용)
    features: []const []const u8 = &.{},
};

/// Test262 테스트 하나의 실행 결과
pub const TestResult = enum {
    pass,
    fail,
    skip, // 아직 미지원 feature 등으로 스킵
};

/// Test262 전체 실행 결과 요약
pub const TestSummary = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn passRate(self: TestSummary) f64 {
        const effective = self.total - self.skipped;
        if (effective == 0) return 0.0;
        return @as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(effective)) * 100.0;
    }

    pub fn print(self: TestSummary, writer: anytype) !void {
        try writer.print(
            \\
            \\=== Test262 Results ===
            \\Total:   {d}
            \\Passed:  {d}
            \\Failed:  {d}
            \\Skipped: {d}
            \\Pass Rate: {d:.1}%
            \\
        , .{ self.total, self.passed, self.failed, self.skipped, self.passRate() });
    }
};

/// Test262 YAML frontmatter를 파싱한다.
///
/// 파일 내용에서 /*--- 와 ---*/ 사이의 YAML을 읽어
/// TestMetadata를 반환한다.
///
/// 예시:
/// ```
/// /*---
/// negative:
///   phase: parse
///   type: SyntaxError
/// flags: [module, onlyStrict]
/// ---*/
/// ```
pub fn parseMetadata(source: []const u8) TestMetadata {
    var meta = TestMetadata{};

    // /*--- 와 ---*/ 사이 추출
    const start_marker = "/*---";
    const end_marker = "---*/";

    const start_idx = mem.indexOf(u8, source, start_marker) orelse return meta;
    const after_start = start_idx + start_marker.len;
    const end_idx = mem.indexOf(u8, source[after_start..], end_marker) orelse return meta;
    const yaml_block = source[after_start .. after_start + end_idx];

    // 간이 YAML 파싱 (line-by-line)
    // 정식 YAML 파서가 아니라 Test262 메타데이터에 필요한 최소한만 파싱
    var in_negative = false;
    var in_flags = false;
    var lines = mem.splitScalar(u8, yaml_block, '\n');

    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");

        // negative: 블록 진입
        if (mem.startsWith(u8, trimmed, "negative:")) {
            in_negative = true;
            in_flags = false;
            continue;
        }

        // negative 블록 내부
        if (in_negative) {
            if (mem.startsWith(u8, trimmed, "phase:")) {
                const value = mem.trim(u8, trimmed["phase:".len..], " \t");
                // parse + early 통합 (D055): 둘 다 "파싱/분석 시 에러가 나야 하는 테스트"
                if (mem.eql(u8, value, "parse") or mem.eql(u8, value, "early")) {
                    meta.is_negative_parse = true;
                }
            } else if (mem.startsWith(u8, trimmed, "type:")) {
                meta.negative_type = mem.trim(u8, trimmed["type:".len..], " \t");
            }
            // 들여쓰기가 없으면 negative 블록 탈출
            if (trimmed.len > 0 and !mem.startsWith(u8, line, " ") and !mem.startsWith(u8, line, "\t")) {
                if (!mem.startsWith(u8, trimmed, "phase:") and !mem.startsWith(u8, trimmed, "type:")) {
                    in_negative = false;
                }
            }
            if (mem.startsWith(u8, trimmed, "phase:") or mem.startsWith(u8, trimmed, "type:")) {
                continue;
            }
        }

        // flags: [module], flags: [onlyStrict], flags: [noStrict]
        // YAML 다중행도 지원: `flags:\n  - module\n  - noStrict`
        if (mem.startsWith(u8, trimmed, "flags:")) {
            in_flags = true;
            if (mem.indexOf(u8, trimmed, "module") != null) {
                meta.is_module = true;
            }
            if (mem.indexOf(u8, trimmed, "onlyStrict") != null) {
                meta.is_only_strict = true;
            }
            if (mem.indexOf(u8, trimmed, "noStrict") != null) {
                meta.is_no_strict = true;
            }
            in_negative = false;
        } else if (in_flags) {
            // YAML 리스트 항목: `  - module`, `  - noStrict` 등
            if (mem.startsWith(u8, trimmed, "- ") or mem.startsWith(u8, trimmed, "-\t")) {
                const flag_value = mem.trim(u8, trimmed[1..], " \t-");
                if (mem.eql(u8, flag_value, "module")) {
                    meta.is_module = true;
                } else if (mem.eql(u8, flag_value, "onlyStrict")) {
                    meta.is_only_strict = true;
                } else if (mem.eql(u8, flag_value, "noStrict")) {
                    meta.is_no_strict = true;
                }
            } else {
                in_flags = false;
            }
        }
    }

    return meta;
}

/// 단일 Test262 테스트를 실행한다.
///
/// Scanner + Parser를 사용하여 소스를 파싱하고, 에러 발생 여부로 pass/fail을 판정.
///
/// 판정 로직:
/// - is_negative_parse == true → 파서/렉서가 에러를 발생시키면 pass
/// - is_negative_parse == false → 에러 없이 파싱 완료되면 pass
pub fn runTest(allocator: mem.Allocator, source: []const u8, meta: TestMetadata, verbose: bool) TestResult {
    // 파일당 Arena: Scanner/Parser/Analyzer 모두 arena에서 할당.
    // 함수 종료 시 arena.deinit()으로 일괄 해제.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Scanner → Parser로 파싱
    var scanner = Scanner.init(arena_alloc, source) catch {
        return .skip; // OOM은 인프라 문제 → skip
    };

    var parser = Parser.init(arena_alloc, &scanner);

    // module 모드 설정 — module은 항상 strict mode (D054)
    if (meta.is_module) {
        parser.is_module = true;
        scanner.is_module = true;
    }

    // onlyStrict 플래그 — strict mode로 파싱
    if (meta.is_only_strict) {
        parser.is_strict_mode = true;
    }

    // parse()는 OOM 시 error 반환, 파싱 에러는 parser.errors에 누적
    _ = parser.parse() catch {
        // OOM은 테스트 실패가 아니라 인프라 문제 → skip 처리
        return .skip;
    };

    // Semantic analysis (D038): 파서 에러가 없을 때만 실행
    var semantic_error_count: usize = 0;
    if (scanner.token.kind != .syntax_error and parser.errors.items.len == 0) {
        var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = parser.is_ts;
        analyzer.is_flow = parser.is_flow;
        analyzer.analyze() catch {
            semantic_error_count = 1; // OOM during analysis — treat as error
        };
        if (semantic_error_count == 0)
            semantic_error_count = analyzer.errors.items.len;
    }

    // 렉서 에러 + 파서 에러 + semantic 에러 모두 체크
    const had_error = scanner.token.kind == .syntax_error or parser.errors.items.len > 0 or semantic_error_count > 0;

    const result: TestResult = if (meta.is_negative_parse)
        (if (had_error) .pass else .fail)
    else
        (if (had_error) .fail else .pass);

    // verbose 모드: 양성 테스트가 에러로 실패한 경우 첫 에러 출력 + 에러 위치의 토큰
    if (verbose and result == .fail and !meta.is_negative_parse and parser.errors.items.len > 0) {
        const err = parser.errors.items[0];
        const stderr = std.fs.File.stderr().deprecatedWriter();
        // 에러 위치 앞 20자 + 뒤 30자
        const before_start = if (err.span.start > 20) err.span.start - 20 else 0;
        const ctx_end = @min(err.span.start + 30, @as(u32, @intCast(source.len)));
        const snippet = source[before_start..ctx_end];
        // 개행 전까지만 (에러 위치부터)
        var line_end: usize = err.span.start - before_start;
        while (line_end < snippet.len and snippet[line_end] != '\n') : (line_end += 1) {}
        stderr.print("    error@{d}: {s} | ...{s}\n", .{ err.span.start, err.message, snippet[0..line_end] }) catch {}; // stderr 출력 실패 무시
    }

    return result;
}

/// 카테고리별 통과율 (디렉토리 단위)
pub const CategorySummary = struct {
    name: []const u8,
    summary: TestSummary,
};

/// 디렉토리 내 모든 .js 파일을 재귀적으로 찾아 테스트를 실행한다.
/// show_failures가 true이면 실패한 파일 목록을 stderr에 출력한다.
pub fn runDirectory(allocator: mem.Allocator, dir_path: []const u8, show_failures: bool) !TestSummary {
    var summary = TestSummary{};
    var failed_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (failed_list.items) |path| allocator.free(path);
        failed_list.deinit(allocator);
    }

    var dir = try fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".js")) continue;

        // _FIXTURE 파일은 스킵 (Test262 컨벤션: 헬퍼 파일)
        if (mem.indexOf(u8, entry.path, "_FIXTURE") != null) continue;

        // 파일 읽기
        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();
        const source = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(source);

        // 메타데이터 파싱 & 테스트 실행
        const meta = parseMetadata(source);
        const result = runTest(allocator, source, meta, show_failures);

        summary.total += 1;
        switch (result) {
            .pass => summary.passed += 1,
            .fail => {
                summary.failed += 1;
                if (show_failures) {
                    try failed_list.append(allocator, try allocator.dupe(u8, entry.path));
                }
            },
            .skip => summary.skipped += 1,
        }
    }

    // 실패 목록 출력
    if (show_failures and failed_list.items.len > 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("\n--- Failed Tests ({d}) ---\n", .{failed_list.items.len});
        for (failed_list.items) |path| {
            try stderr.print("  FAIL: {s}\n", .{path});
        }
    }

    return summary;
}

/// 여러 카테고리(서브디렉토리)를 순회하며 각각의 통과율을 계산한다.
pub fn runCategories(allocator: mem.Allocator, base_dir_path: []const u8) ![]CategorySummary {
    var categories: std.ArrayList(CategorySummary) = .empty;

    var dir = try fs.openDirAbsolute(base_dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        // 절대 경로 조합
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir_path, entry.name });
        defer allocator.free(sub_path);

        const summary = runDirectory(allocator, sub_path, false) catch continue;
        if (summary.total == 0) continue;

        try categories.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .summary = summary,
        });
    }

    return categories.toOwnedSlice(allocator);
}
