//! Dev mode 유틸리티.
//!
//! 활성 함수: addModuleMappings, makeModuleId — 프로덕션 경로에서도 사용.

const std = @import("std");
const Module = @import("../module.zig").Module;
const SourceMap = @import("../../codegen/sourcemap.zig");

/// 모듈 경로를 dev bundle용 ID로 변환.
/// root_dir이 있으면 상대 경로, 없으면 절대 경로 그대로 사용.
/// 모듈의 소스맵 매핑을 번들 레벨 SourceMapBuilder에 추가한다.
/// sourcesContent 등록 + preamble/wrapper 오프셋 반영 + module 영역 안의
/// 매핑 누락 line (region/endregion marker, wrapper closing brace 등) 을
/// module 의 first/last source line 으로 채움 (#2648).
///
/// **bundle 의 module 영역 layout**:
/// ```
/// [base_line]
///   pre_lines (예: //#region <basename>\n) — 미매핑 시 first source line 으로
///   preamble_lines (wrap 의 prefix — module wrapper 의 var X = __commonJS({...)
///   code_lines (codegen mapping 으로 cover — body) + closing brace
///   post_lines (예: //#endregion\n) — 미매핑 시 last source line 으로
/// ```
///
/// `total_code_lines` — wrap 적용 후 code 의 전체 \\n 갯수. codegen 의 마지막
/// mapping 이후 ~ total 까지 (= wrapper closing brace) 를 last source line 으로
/// 채움. 이게 없으면 RN LogBox stack frame 이 source 매핑 안 되고 bundle URL
/// 그대로 표시 (#2648).
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
    /// module wrapper 전 boilerplate line 수 (e.g. //#region, default 0)
    pre_lines: u32,
    /// wrap 적용 후 code 의 전체 \\n 갯수
    total_code_lines: u32,
    /// module wrapper 후 boilerplate line 수 (e.g. //#endregion, default 0)
    post_lines: u32,
) !void {
    const source_idx = try sm.addSource(module_id);
    if (sources_content and source.len > 0) {
        try sm.addSourceContent(source);
    }
    var max_gen_line: u32 = 0;
    var max_orig_line: u32 = 0;
    var first_orig_line: u32 = 0;
    var has_mapping: bool = false;
    for (maps) |mapping| {
        try sm.addMapping(.{
            .generated_line = base_line + pre_lines + preamble_lines + mapping.generated_line,
            .generated_column = if (indent_offset and mapping.generated_line != 0)
                mapping.generated_column + 1
            else
                mapping.generated_column,
            .source_index = source_idx,
            .original_line = mapping.original_line,
            .original_column = mapping.original_column,
        });
        if (!has_mapping) {
            first_orig_line = mapping.original_line;
            has_mapping = true;
        }
        if (mapping.generated_line >= max_gen_line) {
            max_gen_line = mapping.generated_line;
            max_orig_line = mapping.original_line;
        }
    }
    if (!has_mapping) return;
    // pre_lines (region marker) — module 의 first source line 으로 매핑.
    var i: u32 = 0;
    while (i < pre_lines) : (i += 1) {
        try sm.addMapping(.{
            .generated_line = base_line + i,
            .generated_column = 0,
            .source_index = source_idx,
            .original_line = first_orig_line,
            .original_column = 0,
        });
    }
    // codegen 마지막 mapping 이후 ~ total_code_lines (wrap closing brace 영역)
    // — last source line 으로 매핑.
    var gen_line: u32 = max_gen_line + 1;
    while (gen_line < total_code_lines) : (gen_line += 1) {
        try sm.addMapping(.{
            .generated_line = base_line + pre_lines + preamble_lines + gen_line,
            .generated_column = 0,
            .source_index = source_idx,
            .original_line = max_orig_line,
            .original_column = 0,
        });
    }
    // post_lines (endregion marker) — last source line 으로 매핑.
    i = 0;
    while (i < post_lines) : (i += 1) {
        try sm.addMapping(.{
            .generated_line = base_line + pre_lines + preamble_lines + total_code_lines + i,
            .generated_column = 0,
            .source_index = source_idx,
            .original_line = max_orig_line,
            .original_column = 0,
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
