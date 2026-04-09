//! Dev mode 유틸리티.
//!
//! 활성 함수: addModuleMappings, makeModuleId — 프로덕션 경로에서도 사용.

const std = @import("std");
const Module = @import("../module.zig").Module;
const SourceMap = @import("../../codegen/sourcemap.zig");

/// 모듈 경로를 dev bundle용 ID로 변환.
/// root_dir이 있으면 상대 경로, 없으면 절대 경로 그대로 사용.
/// 모듈의 소스맵 매핑을 번들 레벨 SourceMapBuilder에 추가한다.
/// sourcesContent 등록 + preamble/wrapper 오프셋 반영을 한 곳에서 처리.
pub fn addModuleMappings(
    sm: *SourceMap.SourceMapBuilder,
    module_id: []const u8,
    source: []const u8,
    maps: []const SourceMap.Mapping,
    base_line: u32,
    preamble_lines: u32,
    sources_content: bool,
    /// dev 모드에서 tab 들여쓰기 보정이 필요하면 true
    indent_offset: bool,
) !void {
    const source_idx = try sm.addSource(module_id);
    if (sources_content and source.len > 0) {
        try sm.addSourceContent(source);
    }
    for (maps) |mapping| {
        try sm.addMapping(.{
            .generated_line = base_line + preamble_lines + mapping.generated_line,
            .generated_column = if (indent_offset and mapping.generated_line != 0)
                mapping.generated_column + 1
            else
                mapping.generated_column,
            .source_index = source_idx,
            .original_line = mapping.original_line,
            .original_column = mapping.original_column,
        });
    }
}

pub fn makeModuleId(path: []const u8, root_dir: ?[]const u8) []const u8 {
    const root = root_dir orelse return path;
    if (root.len == 0) return path;

    // root_dir prefix를 제거하여 상대 경로 생성
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        // 선행 '/' 제거
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len > 0) return rel;
    }

    // root_dir 밖의 경로 (monorepo node_modules 등):
    // 공통 prefix를 찾아 ../로 시작하는 상대 경로 생성 대신,
    // 절대 경로에서 node_modules 이후 부분만 추출
    if (std.mem.indexOf(u8, path, "/node_modules/")) |nm_pos| {
        return path[nm_pos + 1 ..]; // "node_modules/..." 반환
    }

    return path;
}
