//! 문자열 슬라이스 리스트 헬퍼 — 다중 plugin (emotion/styled-components/worklet) 에서
//! 공유. 짧은 list (1-N items) 의 linear 매칭에 최적.

const std = @import("std");

/// `needle` 이 `list` 에 정확히 등장하는지 (`std.mem.eql` equality).
pub fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}
