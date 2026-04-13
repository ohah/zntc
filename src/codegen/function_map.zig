//! Metro-compatible Function Map encoder (`x_facebook_sources` 확장).
//!
//! Metro 소스맵의 `x_facebook_sources[i]` 는 `sources[i]` 의 함수 이름 맵이다.
//! 각 항목은 `{names: string[], mappings: string}` — generated position → name index.
//!
//! Hermes 스택트레이스 심볼리케이션에서 라인/컬럼뿐 아니라 enclosing function
//! 이름까지 복원할 때 사용한다.
//!
//! VLQ 포맷 (Metro `MappingEncoder` 와 동일):
//!   - 라인 첫 세그먼트: `[col_delta, name_delta, line_delta]` (3필드)
//!   - 이후 세그먼트:    `[col_delta, name_delta]` (2필드)
//!   - 라인 구분은 세미콜론 1개 (실제 라인 차이는 line_delta로 표현)
//!   - 라인은 메모리상 1-based (초기값 1), 컬럼은 0-based
//!
//! 참고: references/metro/packages/metro-source-map/src/generateFunctionMap.js
//!       references/metro/packages/metro-source-map/src/B64Builder.js

const std = @import("std");
const sourcemap = @import("sourcemap.zig");

/// 단일 이름 매핑 엔트리 (raw form).
/// `line` 은 1-based, `column` 은 0-based.
pub const RangeMapping = struct {
    name: []const u8,
    line: u32,
    column: u32,
};

/// Function map 빌더.
///
/// Metro `MappingEncoder` 의 Zig 포팅. 이름을 중복 제거하며 `push()` 호출이
/// 증가 순서 (line asc, then column asc) 임을 가정한다 — Metro도 동일.
///
/// 소유권: `push()`에 전달하는 `name` 슬라이스는 빌더 생존 기간 동안
/// 호출자가 소유해야 한다. 빌더는 이름을 복사하지 않고 참조만 저장한다.
pub const FunctionMapBuilder = struct {
    allocator: std.mem.Allocator,
    /// 등장 순 이름 목록.
    names: std.ArrayList([]const u8) = .empty,
    /// 이름 → names 인덱스 (중복 제거). 키는 외부 소유 슬라이스 참조.
    names_map: std.StringHashMapUnmanaged(u32) = .empty,
    /// VLQ mappings 버퍼.
    mappings: std.ArrayList(u8) = .empty,

    // RelativeValue 들 — 상대값 인코딩용.
    last_line: i32 = 1, // Metro: new RelativeValue(1)
    last_column: i32 = 0,
    last_name_index: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) FunctionMapBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FunctionMapBuilder) void {
        self.names.deinit(self.allocator);
        self.names_map.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
    }

    /// 이름과 시작 위치로 매핑을 추가한다.
    ///
    /// `line` 1-based, `column` 0-based. 호출은 position 증가 순이어야 한다.
    /// 같은 위치에 동일 이름을 연속으로 push 하는 호출은 호출자가 미리 필터링해야 한다
    /// (Metro 도 top-of-stack name 비교로 중복을 막는다).
    pub fn push(self: *FunctionMapBuilder, mapping: RangeMapping) !void {
        const name_index = try self.internName(mapping.name);

        const new_line: i32 = @intCast(mapping.line);
        const line_delta: i32 = new_line - self.last_line;
        self.last_line = new_line;

        // 첫 세그먼트이거나 라인이 바뀐 경우 — first-of-line (3필드 인코딩).
        const first_of_line = self.mappings.items.len == 0 or line_delta > 0;

        if (line_delta > 0) {
            // 세미콜론 1개 — 실제 라인 차이는 line_delta 필드로 전달.
            try self.mappings.append(self.allocator, ';');
            self.last_column = 0;
        } else if (!first_of_line) {
            try self.mappings.append(self.allocator, ',');
        }

        const new_column: i32 = @intCast(mapping.column);
        const col_delta = new_column - self.last_column;
        self.last_column = new_column;

        const new_name_index: i32 = @intCast(name_index);
        const name_delta = new_name_index - self.last_name_index;
        self.last_name_index = new_name_index;

        try sourcemap.encodeVLQ(self.allocator, &self.mappings, col_delta);
        try sourcemap.encodeVLQ(self.allocator, &self.mappings, name_delta);

        if (first_of_line) {
            try sourcemap.encodeVLQ(self.allocator, &self.mappings, line_delta);
        }
    }

    /// 현재까지의 mappings 를 반환. 소유권은 빌더에 남는다.
    pub fn mappingsSlice(self: *const FunctionMapBuilder) []const u8 {
        return self.mappings.items;
    }

    /// 이름 목록을 반환. 순서는 등장 순 (VLQ name_index 참조).
    pub fn namesSlice(self: *const FunctionMapBuilder) []const []const u8 {
        return self.names.items;
    }

    /// JSON 직렬화: `{"names":[...],"mappings":"..."}` 를 `buf` 에 추가한다.
    /// sources 배열 외부 구조 (x_facebook_sources 전체 배열) 는 호출자가 감싼다.
    pub fn appendJson(self: *const FunctionMapBuilder, buf: *std.ArrayList(u8)) !void {
        try buf.appendSlice(self.allocator, "{\"names\":[");
        for (self.names.items, 0..) |n, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try sourcemap.appendJsonStringTo(self.allocator, buf, n);
        }
        try buf.appendSlice(self.allocator, "],\"mappings\":\"");
        try buf.appendSlice(self.allocator, self.mappings.items);
        try buf.appendSlice(self.allocator, "\"}");
    }

    fn internName(self: *FunctionMapBuilder, name: []const u8) !u32 {
        const gop = try self.names_map.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            const idx: u32 = @intCast(self.names.items.len);
            gop.value_ptr.* = idx;
            try self.names.append(self.allocator, name);
        }
        return gop.value_ptr.*;
    }
};

// ============================================================
// Tests — Metro MappingEncoder 의 동작을 trace 하여 기대값 고정.
// ============================================================

test "empty builder produces empty mappings and names" {
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqualStrings("", b.mappingsSlice());
    try std.testing.expectEqual(@as(usize, 0), b.namesSlice().len);
}

test "first push on line 1 col 0 — AAA (col=0, name=0, line_delta=0)" {
    // Metro RelativeValue 초기: line=1, col=0, name=0.
    // push(line=1) → line_delta=0, first_of_line(len==0) → 3필드
    // VLQ(0)+VLQ(0)+VLQ(0) = "AAA"
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "<global>", .line = 1, .column = 0 });
    try std.testing.expectEqualStrings("AAA", b.mappingsSlice());
    try std.testing.expectEqualStrings("<global>", b.namesSlice()[0]);
}

test "two segments same line — AAA,UC" {
    // push(<global>,1,0) → "AAA"
    // push(foo,1,10): line_delta=0, not first → "," + VLQ(10)="U" + VLQ(1)="C"
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "<global>", .line = 1, .column = 0 });
    try b.push(.{ .name = "foo", .line = 1, .column = 10 });
    try std.testing.expectEqualStrings("AAA,UC", b.mappingsSlice());
    const names = b.namesSlice();
    try std.testing.expectEqualStrings("<global>", names[0]);
    try std.testing.expectEqualStrings("foo", names[1]);
}

test "name dedup — second push of same name reuses index" {
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "foo", .line = 1, .column = 0 });
    try b.push(.{ .name = "foo", .line = 1, .column = 5 });
    try std.testing.expectEqual(@as(usize, 1), b.namesSlice().len);
    // name_delta=0 → "AAA" + "," + VLQ(5)="K" + VLQ(0)="A" = "AAA,KA"
    try std.testing.expectEqualStrings("AAA,KA", b.mappingsSlice());
}

test "new line — semicolon + 3-field with line_delta" {
    // push(<global>,1,0) → "AAA"
    // push(foo,3,2): line_delta=2 → ";" + VLQ(2)="E" + VLQ(1)="C" + VLQ(2)="E"
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "<global>", .line = 1, .column = 0 });
    try b.push(.{ .name = "foo", .line = 3, .column = 2 });
    try std.testing.expectEqualStrings("AAA;ECE", b.mappingsSlice());
}

test "new line resets column delta base to 0" {
    // push(<global>,1,0) → "AAA"
    // push(foo,2,5): line_delta=1, col resets → col_delta=5
    //   → ";" + VLQ(5)="K" + VLQ(1)="C" + VLQ(1)="C" = ";KCC"
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "<global>", .line = 1, .column = 0 });
    try b.push(.{ .name = "foo", .line = 2, .column = 5 });
    try std.testing.expectEqualStrings("AAA;KCC", b.mappingsSlice());
}

test "appendJson serializes names and mappings" {
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "<global>", .line = 1, .column = 0 });
    try b.push(.{ .name = "foo", .line = 1, .column = 10 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try b.appendJson(&buf);
    try std.testing.expectEqualStrings(
        "{\"names\":[\"<global>\",\"foo\"],\"mappings\":\"AAA,UC\"}",
        buf.items,
    );
}

test "appendJson escapes special characters in names" {
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "a\"b", .line = 1, .column = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try b.appendJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"a\\\"b\"") != null);
}

test "multiple lines with multiple segments" {
    // push(<global>,1,0) → "AAA"
    // push(foo,1,5): same line → ",KC"  (col=5→VLQ"K", name+1→VLQ"C")
    // push(bar,2,0): new line → last_column 리셋 0, col_delta=0
    //   → ";" + VLQ(0)="A" + VLQ(1)="C" + VLQ(1)="C" = ";ACC"
    var b = FunctionMapBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.push(.{ .name = "<global>", .line = 1, .column = 0 });
    try b.push(.{ .name = "foo", .line = 1, .column = 5 });
    try b.push(.{ .name = "bar", .line = 2, .column = 0 });
    try std.testing.expectEqualStrings("AAA,KC;ACC", b.mappingsSlice());
}
