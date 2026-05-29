//! Test262 러너 실행 파일
//!
//! tests/test262/test/language/ 하위 카테고리별 파서 통과율을 측정한다.
//! 사용법:
//!   zig build test262-run              # 전체 카테고리
//!   zig build test262-run -- expressions  # 특정 카테고리만

const std = @import("std");
const zntc = @import("zntc_lib");
const runner = zntc.test262.runner;

pub fn main(init: std.process.Init) !void {
    // Zig 0.16: juicy main — io / args 를 Init 에서 받는다 (argsAlloc/GPA 제거).
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 0.16: deprecatedWriter 제거 → File.writer(io, buffer). length-0 buffer = unbuffered.
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;

    // 프로젝트 루트 기준 test262 경로
    // 실행 파일 위치에서 상대 경로로 찾기
    const base_dir = "tests/test262/test/language";

    // 절대 경로로 변환 (0.16: cwd().realpath 제거 → realPathFileAlloc).
    const abs_path = std.Io.Dir.cwd().realPathFileAlloc(io, base_dir, allocator) catch |err| {
        try stdout.print("Error: cannot find {s}: {}\n", .{ base_dir, err });
        try stdout.print("Make sure test262 submodule is initialized:\n", .{});
        try stdout.print("  git submodule update --init\n", .{});
        return;
    };
    defer allocator.free(abs_path);

    // CLI 인자: 특정 카테고리만 실행 (0.16: argsAlloc 제거 → Init.minimal.args 이터레이터).
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    var args_buf: std.ArrayList([]const u8) = .empty;
    defer args_buf.deinit(allocator);
    while (arg_it.next()) |a| try args_buf.append(allocator, a);
    const args = args_buf.items;

    if (args.len > 1) {
        // 특정 카테고리 실행
        var had_failures = false;
        for (args[1..]) |cat_name| {
            const cat_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_path, cat_name });
            defer allocator.free(cat_path);

            try stdout.print("\n=== {s} ===\n", .{cat_name});
            const summary = runner.runDirectory(allocator, io, cat_path, true) catch |err| {
                try stdout.print("Error: {}\n", .{err});
                had_failures = true;
                continue;
            };
            try summary.print(stdout);
            if (summary.failed > 0) had_failures = true;
        }
        if (had_failures) std.process.exit(1);
    } else {
        // 전체 카테고리별 실행
        try stdout.print("Running Test262 parser tests...\n", .{});
        try stdout.print("Base: {s}\n\n", .{abs_path});

        const categories = try runner.runCategories(allocator, io, abs_path);
        defer {
            for (categories) |cat| allocator.free(cat.name);
            allocator.free(categories);
        }

        // 이름순 정렬
        std.mem.sort(runner.CategorySummary, categories, {}, struct {
            pub fn lessThan(_: void, a: runner.CategorySummary, b: runner.CategorySummary) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        var total = runner.TestSummary{};
        try stdout.print("{s:<30} {s:>6} {s:>6} {s:>6} {s:>6} {s:>8}\n", .{ "Category", "Total", "Pass", "Fail", "Skip", "Rate" });
        try stdout.print("{s}\n", .{"-" ** 70});

        for (categories) |cat| {
            const s = cat.summary;
            try stdout.print("{s:<30} {d:>6} {d:>6} {d:>6} {d:>6} {d:>7.1}%\n", .{
                cat.name, s.total, s.passed, s.failed, s.skipped, s.passRate(),
            });
            total.total += s.total;
            total.passed += s.passed;
            total.failed += s.failed;
            total.skipped += s.skipped;
        }

        try stdout.print("{s}\n", .{"-" ** 70});
        try stdout.print("{s:<30} {d:>6} {d:>6} {d:>6} {d:>6} {d:>7.1}%\n", .{
            "TOTAL", total.total, total.passed, total.failed, total.skipped, total.passRate(),
        });
        if (total.failed > 0) std.process.exit(1);
    }
}
