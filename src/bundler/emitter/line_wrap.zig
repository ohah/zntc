//! Line-limit wrapping and sourcemap adjustment helpers for bundler output.

const std = @import("std");
const SourceMap = @import("../../codegen/sourcemap.zig");

pub const WrapBreak = struct {
    line: u32,
    column: u32,
};

const WrapScanState = enum {
    normal,
    single_quote,
    double_quote,
    template,
    line_comment,
    block_comment,
};

fn isLineLimitBreakChar(c: u8) bool {
    return c == ';' or c == ',' or c == '{' or c == '}';
}

pub fn wrapLineLimit(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    limit: u32,
    breaks: *std.ArrayList(WrapBreak),
) !void {
    if (limit == 0 or output.items.len == 0) return;

    // 누적 출력 — 마지막 안전 break char 까지의 confirmed 바이트 + 그 이후의 pending 바이트.
    // pending 은 다음 안전 break 가 나오면 wrapped 로 flush 되고, limit 을 초과하면
    // pending 앞에 '\n' 을 삽입해 새 줄을 시작한다. 매 char 가 최대 두 번 (입력→pending,
    // pending→wrapped) 만 복사되므로 전체 O(N).
    var wrapped: std.ArrayList(u8) = .empty;
    errdefer wrapped.deinit(allocator);
    try wrapped.ensureTotalCapacity(allocator, output.items.len + output.items.len / limit + 1);

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    var state: WrapScanState = .normal;
    var escaped = false;
    var original_line: u32 = 0;
    var original_col: u32 = 0;
    var wrapped_col: u32 = 0;
    var last_safe_line: u32 = 0;
    var last_safe_col: u32 = 0;
    var have_safe = false;

    var i: usize = 0;
    while (i < output.items.len) : (i += 1) {
        const c = output.items[i];
        const next = if (i + 1 < output.items.len) output.items[i + 1] else 0;

        if (c == '\n') {
            try wrapped.appendSlice(allocator, pending.items);
            pending.clearRetainingCapacity();
            try wrapped.append(allocator, '\n');
            original_line += 1;
            original_col = 0;
            wrapped_col = 0;
            have_safe = false;
            if (state == .line_comment) state = .normal;
            escaped = false;
            continue;
        }

        const line_before = original_line;
        const col_before = original_col;
        original_col += 1;
        wrapped_col += 1;

        try pending.append(allocator, c);

        switch (state) {
            .normal => {
                if (c == '/' and next == '/') {
                    state = .line_comment;
                } else if (c == '/' and next == '*') {
                    state = .block_comment;
                } else if (c == '\'') {
                    state = .single_quote;
                    escaped = false;
                } else if (c == '"') {
                    state = .double_quote;
                    escaped = false;
                } else if (c == '`') {
                    state = .template;
                    escaped = false;
                } else if (isLineLimitBreakChar(c)) {
                    try wrapped.appendSlice(allocator, pending.items);
                    pending.clearRetainingCapacity();
                    last_safe_line = line_before;
                    last_safe_col = col_before;
                    have_safe = true;
                }
            },
            .single_quote => {
                if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '\'') state = .normal;
            },
            .double_quote => {
                if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') state = .normal;
            },
            .template => {
                if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '`') state = .normal;
            },
            .line_comment => {},
            .block_comment => {
                if (c == '*' and next == '/') state = .normal;
            },
        }

        if (state == .normal and wrapped_col >= limit and have_safe) {
            try wrapped.append(allocator, '\n');
            try breaks.append(allocator, .{ .line = last_safe_line, .column = last_safe_col });
            wrapped_col = @intCast(pending.items.len);
            have_safe = false;
        }
    }
    try wrapped.appendSlice(allocator, pending.items);

    // 기존 output 버퍼는 해제하고 wrapped 가 소유권을 인계 — 추가 memcpy 없이 swap.
    output.deinit(allocator);
    output.* = wrapped;
    wrapped = .empty;
}

/// breaks 는 wrapLineLimit 가 emit 순서대로 append — `(line, column)` 오름차순.
/// mappings 도 같은 순서로 정렬하면 두 배열을 한 번씩만 훑는 merge-style 스캔이 가능
/// (O(M log M) sort + O(M + B)). 정렬 후 line shift 는 monotonic 이므로 결과도 정렬
/// 상태를 유지하므로 builder 의 `is_sorted` 를 true 로 마킹해 encode 단계의 재정렬을
/// 생략한다 — vue/effect 같은 큰 번들에서 수백 ms~수 s 절감 (line-limit=40 기준).
pub fn adjustMappingsForLineWraps(sm: *SourceMap.SourceMapBuilder, breaks: []const WrapBreak) void {
    if (breaks.len == 0 or sm.mappings.items.len == 0) return;

    if (!sm.is_sorted) {
        std.mem.sort(SourceMap.Mapping, sm.mappings.items, {}, SourceMap.Mapping.lessThan);
        sm.is_sorted = true;
    }

    var break_idx: usize = 0;
    var lines_before: u32 = 0;
    var current_line: u32 = 0;
    // 같은 generated_line 위의 마지막 break col — 다음 mapping 도 같은 라인이면 그대로
    // 재사용 (break_idx 가 이미 해당 break 를 통과해도 sticky).
    var last_break_col_on_line: ?u32 = null;
    for (sm.mappings.items) |*mapping| {
        if (mapping.generated_line != current_line) {
            current_line = mapping.generated_line;
            last_break_col_on_line = null;
        }
        // mapping 의 (line, col) 직전까지 break 커서 전진. mappings 가 오름차순이므로
        // break_idx 는 절대 되감기지 않음.
        while (break_idx < breaks.len) {
            const br = breaks[break_idx];
            if (br.line < current_line) {
                lines_before += 1;
                break_idx += 1;
            } else if (br.line == current_line and br.column < mapping.generated_column) {
                lines_before += 1;
                last_break_col_on_line = br.column;
                break_idx += 1;
            } else break;
        }
        if (last_break_col_on_line) |col| {
            mapping.generated_column -= col + 1;
        }
        mapping.generated_line += lines_before;
    }
}
