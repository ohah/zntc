//! NAPI export ↔ TS `NativeModule` interface parity 검증.
//!
//! `packages/core/src/napi_entry.zig` 의 `napi_register_module_v1` 가 `exports`
//! 에 set 하는 함수 이름과, `packages/core/index.ts` 의 `interface NativeModule`
//! 멤버가 1:1 로 일치해야 한다. 두 사이트는 별개 파일에 hand-maintain 되므로
//! 한쪽만 수정하면 컴파일은 통과하고 **runtime 에서만** `TypeError:
//! ensureNative().X is not a function` 으로 터진다.
//!
//! 본 테스트는 두 파일을 파싱해 양쪽 집합이 일치하는지 검증.
//!
//! 검증 원칙:
//!   - NAPI 측에서 export 한 이름은 전부 TS NativeModule 에 존재해야 함.
//!   - TS NativeModule 멤버는 전부 NAPI 측에서 export 돼야 함.
//!   - 예외는 allowlist 에 등록.
//!
//! 파일 경로는 저장소 루트 기준. CI 외 환경에서는 SkipZigTest.

const std = @import("std");

/// TS NativeModule 에만 있고 NAPI 측에 없는 멤버 — 현재는 없음. 의도된 추가 시
/// 여기 등록.
const ts_only_allowlist = [_][]const u8{};

/// NAPI 측에서만 export 하고 TS NativeModule 에 없는 이름 — 현재는 없음. 의도된
/// 추가 시 (e.g. 내부 전용 helper) 여기 등록.
const napi_only_allowlist = [_][]const u8{};

/// `napi_register_module_v1` 본문에서 `napi_set_named_property(env, exports, "X", ...)`
/// 패턴의 `X` 들을 추출. 단순 substring 스캔 — comment / string literal 안의 매칭은
/// 발생 안 함 (zig source 에 동일 패턴이 자연스럽게 나올 일 없음).
fn parseNapiExports(
    source: []const u8,
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const marker = "napi_set_named_property(env, exports, \"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, marker)) |hit| {
        const name_start = hit + marker.len;
        const name_end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse return error.MalformedExport;
        try list.append(allocator, source[name_start..name_end]);
        i = name_end + 1;
    }
}

/// TS interface 본문에서 멤버 이름을 추출. `interface NativeModule {` 본문 안에서
/// 각 줄의 첫 식별자가 `:` / `(` / `?:` / `?(` 로 끝나면 멤버.
/// 주석 (`//`, `/**`, `*`) 과 빈 줄은 스킵. nested object literal 의 inner 필드는
/// depth 추적으로 무시 (NativeModule 의 method 만 잡음).
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
    var body_end = body_start;
    while (i < source.len and depth > 0) : (i += 1) {
        switch (source[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) body_end = i;
            },
            else => {},
        }
    }
    const body = source[body_start..body_end];

    // 줄 단위 + brace/paren depth 추적으로 top-level 멤버만 잡음.
    // `transpile(source: string)` 같은 멤버는 `(` 가 그 줄 끝까지 안 닫히면
    // 다음 줄들 (`source: string,`) 은 line_depth>0 으로 잡혀 무시됨.
    var line_depth: i32 = 0;
    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const indent_depth = line_depth;
        for (raw_line) |ch| {
            switch (ch) {
                '{', '(' => line_depth += 1,
                '}', ')' => line_depth -= 1,
                else => {},
            }
        }
        if (indent_depth != 0) continue; // nested 안 — 무시
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "*")) continue;
        if (std.mem.startsWith(u8, line, "/*")) continue;
        if (std.mem.startsWith(u8, line, "}")) continue;

        // 식별자 추출.
        var end: usize = 0;
        while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
        if (end == 0) continue;
        const name = line[0..end];
        const after = line[end..];
        // `method(` 또는 `prop?(` 또는 `prop:` / `prop?:` 형태.
        const is_member = std.mem.startsWith(u8, after, "(") or
            std.mem.startsWith(u8, after, "?(") or
            std.mem.startsWith(u8, after, ":") or
            std.mem.startsWith(u8, after, "?:");
        if (!is_member) continue;

        // 중복 방지 (overload signature 같은 경우).
        var dup = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                dup = true;
                break;
            }
        }
        if (!dup) try list.append(allocator, name);
    }
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

test "schema diff: NAPI exports == TS NativeModule members" {
    const allocator = std.testing.allocator;

    const napi_source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/core/src/napi_entry.zig",
        allocator,
        std.Io.Limit.limited(2 * 1024 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(napi_source);

    const ts_source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/core/index.ts",
        allocator,
        std.Io.Limit.limited(2 * 1024 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(ts_source);

    var napi_names: std.ArrayList([]const u8) = .empty;
    defer napi_names.deinit(allocator);
    try parseNapiExports(napi_source, &napi_names, allocator);
    try std.testing.expect(napi_names.items.len > 0);

    var ts_names: std.ArrayList([]const u8) = .empty;
    defer ts_names.deinit(allocator);
    try parseTsInterface(ts_source, "NativeModule", &ts_names, allocator);
    try std.testing.expect(ts_names.items.len > 0);

    // 1. NAPI export 가 TS NativeModule 에 모두 존재해야 함.
    for (napi_names.items) |napi_name| {
        if (contains(ts_names.items, napi_name)) continue;
        if (contains(&ts_only_allowlist, napi_name)) continue;
        if (contains(&napi_only_allowlist, napi_name)) continue;
        std.debug.print(
            "\n[NativeModule parity drift] NAPI export '{s}' is not declared in TS `interface NativeModule` " ++
                "(packages/core/index.ts). " ++
                "Add the method signature there, or register '{s}' in napi_only_allowlist if intentional.\n",
            .{ napi_name, napi_name },
        );
        return error.NapiExportMissingFromTs;
    }

    // 2. TS NativeModule 멤버가 NAPI export 에 모두 존재해야 함.
    for (ts_names.items) |ts_name| {
        if (contains(napi_names.items, ts_name)) continue;
        if (contains(&ts_only_allowlist, ts_name)) continue;
        std.debug.print(
            "\n[NativeModule parity drift] TS NativeModule.{s} has no matching NAPI export in " ++
                "packages/core/src/napi_entry.zig. " ++
                "Add the `napi_set_named_property(env, exports, \"{s}\", ...)` call, " ++
                "or add '{s}' to ts_only_allowlist if intentional.\n",
            .{ ts_name, ts_name, ts_name },
        );
        return error.TsMemberMissingFromNapi;
    }
}

test "parseNapiExports: basic extraction" {
    const source =
        \\    _ = c.napi_create_function(env, "foo", "foo".len, foo_fn, null, &fn_value);
        \\    _ = c.napi_set_named_property(env, exports, "foo", fn_value);
        \\    _ = c.napi_set_named_property(env, exports, "bar", bar_fn);
    ;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseNapiExports(source, &list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("foo", list.items[0]);
    try std.testing.expectEqualStrings("bar", list.items[1]);
}

test "parseTsInterface: basic extraction with methods and nested object" {
    const source =
        \\interface Other { x: number }
        \\interface NativeModule {
        \\  /** doc */
        \\  transpile(source: string): void;
        \\  tokenize(source: string): TokenizeToken[];
        \\  benchmark(opts: Record<string, unknown>): {
        \\    phases: Record<string, { samples: number }>;
        \\  };
        \\  // inline comment
        \\  watch(opts: Record<string, unknown>): NativeWatchHandle;
        \\}
    ;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseTsInterface(source, "NativeModule", &list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("transpile", list.items[0]);
    try std.testing.expectEqualStrings("tokenize", list.items[1]);
    try std.testing.expectEqualStrings("benchmark", list.items[2]);
    try std.testing.expectEqualStrings("watch", list.items[3]);
}
