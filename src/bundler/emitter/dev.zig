//! Dev mode 유틸리티.
//!
//! 활성 함수: addModuleMappings, makeModuleId — 프로덕션 경로에서도 사용.

const std = @import("std");
const Module = @import("../module.zig").Module;
const SourceMap = @import("../../codegen/sourcemap.zig");
const source_map_trace = @import("../../codegen/source_map_trace.zig");

/// `addModuleMappings` 입력. caller 가 named field 로 채워 호출 site 가 self-documenting.
/// `plugin_source_maps` 가 비어 있으면 identity 매핑, 아니면 plugin source map chain 을 trace.
pub const ModuleMappingArgs = struct {
    sm: *SourceMap.SourceMapBuilder,
    module_id: []const u8,
    source: []const u8,
    maps: []const SourceMap.Mapping,
    /// codegen builder 의 names 슬라이스. mapping.name_index 가 가리키는 식별자
    /// 원본 이름들 — chunk builder 로 옮길 때 module-local 인덱스를 chunk-global
    /// 인덱스로 재매핑.
    module_names: []const []const u8 = &.{},
    base_line: u32,
    preamble_lines: u32,
    sources_content: bool,
    /// dev 모드에서 tab 들여쓰기 보정이 필요하면 true
    indent_offset: bool,
    /// module wrapper 전 boilerplate line 수 (e.g. //#region, default 0)
    pre_lines: u32,
    /// wrap 적용 후 code 의 전체 \n 갯수
    total_code_lines: u32,
    /// module wrapper 후 boilerplate line 수 (e.g. //#endregion, default 0)
    post_lines: u32,
    /// plugin load/transform 이 반환한 Source Map V3 JSON chain. 비어 있으면 identity.
    plugin_source_maps: []const []const u8 = &.{},
};

/// 모듈의 소스맵 매핑을 번들 레벨 SourceMapBuilder에 추가한다.
/// sourcesContent 등록 + preamble/wrapper 오프셋 반영 + module 영역 안의
/// 매핑 누락 line (region/endregion marker, wrapper closing brace, 그리고
/// codegen body 내부의 mapping 없는 줄 = blank line / 다행 statement 의 중간
/// 줄 / esm_wrap merge 후 빈 줄 등) 을 직전 source line 으로 채움 (#2648, #2651).
///
/// **bundle 의 module 영역 layout**:
/// ```
/// [base_line]
///   pre_lines (예: //#region <basename>\n) — 미매핑 시 first source line 으로
///   preamble_lines (wrap 의 prefix — module wrapper 의 var X = __commonJS({...)
///   code_lines (codegen mapping + 내부 gap fill — body + closing brace)
///   post_lines (예: //#endregion\n) — 미매핑 시 last source line 으로
/// ```
///
/// `total_code_lines` — wrap 적용 후 code 의 전체 \\n 갯수. body 영역 안에서
/// codegen mapping 이 없는 모든 줄을 직전 mapping 의 original_line 으로 채움.
/// 마지막 mapping 이후 ~ total (= wrapper closing brace) 도 동일 처리.
/// 이게 없으면 RN LogBox stack frame 이 source 매핑 안 되고 bundle URL
/// 그대로 표시 (#2648). #2651: 내부 gap (statement 사이 빈 줄, 다행 statement
/// 중간 줄) 도 채워서 empty mapping 비율 31.5% → ~5% 미만으로.
///
/// **호출자 invariant**: `maps` 는 `generated_line` 오름차순으로 정렬되어 있어야
/// 한다. codegen / esm_wrap merge 둘 다 이 보장을 만족 (#2651 perf — 보장이
/// 깨지면 builder 의 `is_sorted=false` 가 플립되어 bundle 전역 sort 비용 발생).
pub fn addModuleMappings(args: ModuleMappingArgs) !void {
    if (args.maps.len == 0) return;

    var resolver = try MappingResolver.init(
        args.sm,
        args.module_id,
        args.source,
        args.plugin_source_maps,
        args.sources_content,
    );
    defer resolver.deinit();

    // 첫 mapping 으로 초기 source/orig 를 정해 pre_lines / 매핑 없는 line / post_lines 채움.
    const first = try resolver.resolve(args.maps[0]);

    // pre_lines (region marker) — module 의 first source line 으로 매핑.
    var i: u32 = 0;
    while (i < args.pre_lines) : (i += 1) {
        try args.sm.addMapping(.{
            .generated_line = args.base_line + i,
            .generated_column = 0,
            .source_index = first.source_idx,
            .original_line = first.line,
            .original_column = 0,
        });
    }

    // body 영역 single-pass: maps 의 mapping 을 정렬 순서로 emit + 매핑 없는
    // 줄은 직전 줄의 orig 로 채움. generated_line 단조 증가 보장 → builder 의
    // is_sorted 유지 (#2651 perf — 별도 sort pass 회피).
    var last = first;
    var maps_idx: usize = 0;
    var line: u32 = 0;
    while (line < args.total_code_lines) : (line += 1) {
        var line_had_mapping = false;
        while (maps_idx < args.maps.len and args.maps[maps_idx].generated_line == line) : (maps_idx += 1) {
            last = try emitResolvedMapping(args, &resolver, args.maps[maps_idx]);
            line_had_mapping = true;
        }
        if (!line_had_mapping) {
            try args.sm.addMapping(.{
                .generated_line = args.base_line + args.pre_lines + args.preamble_lines + line,
                .generated_column = 0,
                .source_index = last.source_idx,
                .original_line = last.line,
                .original_column = 0,
            });
        }
    }

    // total_code_lines 초과 mapping (안전망 — caller 가 잘못된 total 을 넘기면
    // 발생). 정렬 invariant 유지를 위해 post_lines 전에 emit.
    while (maps_idx < args.maps.len) : (maps_idx += 1) {
        last = try emitResolvedMapping(args, &resolver, args.maps[maps_idx]);
    }

    // post_lines (endregion marker) — last source line 으로 매핑.
    i = 0;
    while (i < args.post_lines) : (i += 1) {
        try args.sm.addMapping(.{
            .generated_line = args.base_line + args.pre_lines + args.preamble_lines + args.total_code_lines + i,
            .generated_column = 0,
            .source_index = last.source_idx,
            .original_line = last.line,
            .original_column = 0,
        });
    }
}

/// codegen mapping 한 개를 resolve → addMapping 로 emit. body 와 tail loop 에서 공유.
inline fn emitResolvedMapping(
    args: ModuleMappingArgs,
    resolver: *MappingResolver,
    m: SourceMap.Mapping,
) !ResolvedMapping {
    const r = try resolver.resolve(m);
    // module-local name_index → chunk-global 재매핑. mangler rename 발생 시
    // codegen 이 module builder 의 names 에 등록한 원본 이름을 chunk builder 로
    // 옮겨 Sentry / DevTools 가 minified 식별자의 원본 복원 가능.
    const chunk_name_idx: ?u32 = blk: {
        const local = m.name_index orelse break :blk null;
        if (local >= args.module_names.len) break :blk null;
        break :blk try args.sm.addName(args.module_names[local]);
    };
    try args.sm.addMapping(.{
        .generated_line = args.base_line + args.pre_lines + args.preamble_lines + m.generated_line,
        .generated_column = if (args.indent_offset and m.generated_line != 0)
            m.generated_column + 1
        else
            m.generated_column,
        .source_index = r.source_idx,
        .original_line = r.line,
        .original_column = r.column,
        .name_index = chunk_name_idx,
    });
    return r;
}

/// `addModuleMappings` 가 매 mapping 마다 source_idx + 원본 line/column 을 결정할 때 쓰는
/// resolver. plugin source map 이 없으면 identity (mapping 의 값 그대로), 있으면
/// chain 을 타고 trace.
const ResolvedMapping = struct {
    source_idx: u32,
    line: u32,
    column: u32,
};

const MappingResolver = union(enum) {
    identity: u32,
    traced: TraceResolver,

    fn init(
        sm: *SourceMap.SourceMapBuilder,
        module_id: []const u8,
        source: []const u8,
        plugin_source_maps: []const []const u8,
        sources_content: bool,
    ) !MappingResolver {
        if (plugin_source_maps.len == 0) {
            const idx = try sm.addSource(module_id);
            if (sources_content and source.len > 0) {
                try sm.addSourceContent(source);
            }
            return .{ .identity = idx };
        }
        return .{ .traced = try TraceResolver.init(sm, module_id, source, plugin_source_maps, sources_content) };
    }

    fn deinit(self: *MappingResolver) void {
        switch (self.*) {
            .identity => {},
            .traced => |*tr| tr.deinit(),
        }
    }

    fn resolve(self: *MappingResolver, m: SourceMap.Mapping) !ResolvedMapping {
        switch (self.*) {
            .identity => |idx| return .{ .source_idx = idx, .line = m.original_line, .column = m.original_column },
            .traced => |*tr| return tr.resolve(m),
        }
    }
};

const TraceResolver = struct {
    sm: *SourceMap.SourceMapBuilder,
    module_id: []const u8,
    fallback_source: []const u8,
    parsed_maps: std.ArrayList(source_map_trace.ParsedMap),
    source_cache: std.StringHashMap(u32),
    sources_content: bool,

    fn init(
        sm: *SourceMap.SourceMapBuilder,
        module_id: []const u8,
        source: []const u8,
        plugin_source_maps: []const []const u8,
        sources_content: bool,
    ) !TraceResolver {
        var parsed_maps: std.ArrayList(source_map_trace.ParsedMap) = .empty;
        errdefer {
            for (parsed_maps.items) |*parsed| parsed.deinit();
            parsed_maps.deinit(sm.allocator);
        }
        for (plugin_source_maps) |source_map_json| {
            try parsed_maps.append(sm.allocator, try source_map_trace.parse(sm.allocator, source_map_json));
        }
        return .{
            .sm = sm,
            .module_id = module_id,
            .fallback_source = source,
            .parsed_maps = parsed_maps,
            .source_cache = std.StringHashMap(u32).init(sm.allocator),
            .sources_content = sources_content,
        };
    }

    fn deinit(self: *TraceResolver) void {
        for (self.parsed_maps.items) |*parsed| parsed.deinit();
        self.parsed_maps.deinit(self.sm.allocator);
        self.source_cache.deinit();
    }

    fn resolve(self: *TraceResolver, m: SourceMap.Mapping) !ResolvedMapping {
        if (source_map_trace.trace(self.parsed_maps.items, m.original_line, m.original_column)) |hit| {
            const idx = try self.ensureSource(hit.source, hit.source_content);
            return .{ .source_idx = idx, .line = hit.line, .column = hit.column };
        }
        const idx = try self.ensureSource(self.module_id, self.fallback_source);
        return .{ .source_idx = idx, .line = m.original_line, .column = m.original_column };
    }

    /// `source_name` 첫 등장 시 `sm.addSource` + (옵션) sourcesContent 등록 + cache. 이후엔 cache hit.
    fn ensureSource(self: *TraceResolver, source_name: []const u8, source_content: ?[]const u8) !u32 {
        if (self.source_cache.get(source_name)) |idx| return idx;
        const idx = try self.sm.addSource(source_name);
        if (self.sources_content) {
            try self.sm.addSourceContent(source_content orelse "");
        }
        try self.source_cache.put(source_name, idx);
        return idx;
    }
};

/// 모듈 경로를 dev bundle용 ID로 변환.
/// root_dir이 있으면 상대 경로, 없으면 절대 경로 그대로 사용.
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "addModuleMappings: codegen body 의 내부 빈 줄 (gap) 도 직전 orig 로 채워진다 (#2651)" {
    var sm = SourceMap.SourceMapBuilder.init(testing.allocator);
    defer sm.deinit();

    // codegen output 6 줄 가정. 줄 0,2,5 만 mapping 존재 (1,3,4 = blank).
    const maps = [_]SourceMap.Mapping{
        .{ .generated_line = 0, .generated_column = 0, .original_line = 10, .original_column = 0 },
        .{ .generated_line = 2, .generated_column = 0, .original_line = 12, .original_column = 0 },
        .{ .generated_line = 5, .generated_column = 0, .original_line = 15, .original_column = 0 },
    };

    try addModuleMappings(.{
        .sm = &sm,
        .module_id = "src/foo.ts",
        .source = "// dummy source",
        .maps = &maps,
        .base_line = 100,
        .preamble_lines = 0,
        .sources_content = false,
        .indent_offset = false,
        .pre_lines = 0,
        .total_code_lines = 6,
        .post_lines = 0,
    });

    // generated_line 100~105 (base + 0~5) 모두 mapping 존재해야 함.
    var has_line = std.AutoHashMap(u32, u32).init(testing.allocator);
    defer has_line.deinit();
    for (sm.mappings.items) |m| {
        try has_line.put(m.generated_line, m.original_line);
    }
    try testing.expectEqual(@as(u32, 10), has_line.get(100).?);
    try testing.expectEqual(@as(u32, 10), has_line.get(101).?); // gap, prev = 10
    try testing.expectEqual(@as(u32, 12), has_line.get(102).?);
    try testing.expectEqual(@as(u32, 12), has_line.get(103).?); // gap, prev = 12
    try testing.expectEqual(@as(u32, 12), has_line.get(104).?); // gap, prev = 12
    try testing.expectEqual(@as(u32, 15), has_line.get(105).?);
}

test "addModuleMappings: 첫 매핑 이전의 wrap header 줄들도 first_orig 로 채워진다 (#2651)" {
    var sm = SourceMap.SourceMapBuilder.init(testing.allocator);
    defer sm.deinit();

    // 줄 0,1 = wrap header (no codegen mapping). 줄 2 부터 mapping 시작.
    const maps = [_]SourceMap.Mapping{
        .{ .generated_line = 2, .generated_column = 0, .original_line = 5, .original_column = 0 },
        .{ .generated_line = 3, .generated_column = 0, .original_line = 6, .original_column = 0 },
    };

    try addModuleMappings(.{
        .sm = &sm,
        .module_id = "src/foo.ts",
        .source = "",
        .maps = &maps,
        .base_line = 0,
        .preamble_lines = 0,
        .sources_content = false,
        .indent_offset = false,
        .pre_lines = 0,
        .total_code_lines = 4, // wrap header 2 + body 2
        .post_lines = 0,
    });

    var has_line = std.AutoHashMap(u32, u32).init(testing.allocator);
    defer has_line.deinit();
    for (sm.mappings.items) |m| {
        try has_line.put(m.generated_line, m.original_line);
    }
    try testing.expectEqual(@as(u32, 5), has_line.get(0).?); // header → first_orig
    try testing.expectEqual(@as(u32, 5), has_line.get(1).?); // header → first_orig
    try testing.expectEqual(@as(u32, 5), has_line.get(2).?);
    try testing.expectEqual(@as(u32, 6), has_line.get(3).?);
}

test "addModuleMappings: tail (마지막 mapping 이후 wrap closing brace) 영역도 채워진다 (#2648 + #2651)" {
    var sm = SourceMap.SourceMapBuilder.init(testing.allocator);
    defer sm.deinit();

    // 줄 0 만 mapping. 줄 1,2,3 = wrap closing brace 등 boilerplate.
    const maps = [_]SourceMap.Mapping{
        .{ .generated_line = 0, .generated_column = 0, .original_line = 7, .original_column = 0 },
    };

    try addModuleMappings(.{
        .sm = &sm,
        .module_id = "src/foo.ts",
        .source = "",
        .maps = &maps,
        .base_line = 0,
        .preamble_lines = 0,
        .sources_content = false,
        .indent_offset = false,
        .pre_lines = 0,
        .total_code_lines = 4,
        .post_lines = 0,
    });

    var has_line = std.AutoHashMap(u32, u32).init(testing.allocator);
    defer has_line.deinit();
    for (sm.mappings.items) |m| {
        try has_line.put(m.generated_line, m.original_line);
    }
    try testing.expectEqual(@as(u32, 7), has_line.get(0).?);
    try testing.expectEqual(@as(u32, 7), has_line.get(1).?); // tail
    try testing.expectEqual(@as(u32, 7), has_line.get(2).?); // tail
    try testing.expectEqual(@as(u32, 7), has_line.get(3).?); // tail
}

test "addModuleMappings: pre/post (region/endregion marker) + 내부 gap 동시 cover" {
    var sm = SourceMap.SourceMapBuilder.init(testing.allocator);
    defer sm.deinit();

    // layout:
    //   line 0      = //#region marker (pre_lines=1)
    //   line 1,2,3  = body. line 1,3 mapped. line 2 gap.
    //   line 4      = //#endregion marker (post_lines=1)
    const maps = [_]SourceMap.Mapping{
        .{ .generated_line = 0, .generated_column = 0, .original_line = 20, .original_column = 0 },
        .{ .generated_line = 2, .generated_column = 0, .original_line = 22, .original_column = 0 },
    };

    try addModuleMappings(.{
        .sm = &sm,
        .module_id = "src/foo.ts",
        .source = "",
        .maps = &maps,
        .base_line = 0,
        .preamble_lines = 0,
        .sources_content = false,
        .indent_offset = false,
        .pre_lines = 1, // region marker
        .total_code_lines = 3, // body
        .post_lines = 1, // endregion marker
    });

    var has_line = std.AutoHashMap(u32, u32).init(testing.allocator);
    defer has_line.deinit();
    for (sm.mappings.items) |m| {
        try has_line.put(m.generated_line, m.original_line);
    }
    // generated_line 0 = pre_lines region → first_orig = 20
    try testing.expectEqual(@as(u32, 20), has_line.get(0).?);
    // generated_line 1 = body line 0 (offset by pre_lines=1) → mapping[0] = 20
    try testing.expectEqual(@as(u32, 20), has_line.get(1).?);
    // generated_line 2 = body line 1 → gap, prev = 20
    try testing.expectEqual(@as(u32, 20), has_line.get(2).?);
    // generated_line 3 = body line 2 → mapping[1] = 22
    try testing.expectEqual(@as(u32, 22), has_line.get(3).?);
    // generated_line 4 = post_lines endregion → last_orig = 22
    try testing.expectEqual(@as(u32, 22), has_line.get(4).?);
}

test "addModuleMappings: maps 가 비어있으면 아무 mapping 도 추가 안 됨" {
    var sm = SourceMap.SourceMapBuilder.init(testing.allocator);
    defer sm.deinit();

    try addModuleMappings(.{
        .sm = &sm,
        .module_id = "src/foo.ts",
        .source = "",
        .maps = &.{}, // empty maps
        .base_line = 0,
        .preamble_lines = 0,
        .sources_content = false,
        .indent_offset = false,
        .pre_lines = 1,
        .total_code_lines = 5,
        .post_lines = 1,
    });

    // empty mapping 입력은 source 등록도 하지 않고 빠져나간다.
    try testing.expectEqual(@as(usize, 0), sm.mappings.items.len);
}
