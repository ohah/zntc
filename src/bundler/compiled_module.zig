//! ZTS Bundler — Compiled module output
//!
//! 모듈 컴파일 결과 (Transformer → Codegen 산출물) 를 표현한다.
//! emit 병렬 결과 수집 (emitter.zig) 및 HMR/watch compiled output cache 의
//! 공용 값 타입.

const std = @import("std");
const RuntimeHelpers = @import("../transformer/transformer.zig").RuntimeHelpers;
const SourceMap = @import("../codegen/sourcemap.zig");

/// 모듈 단위 컴파일 결과. 동일 입력 해시로 재사용 시 cache hit 로 활용된다.
pub const CompiledModule = struct {
    /// 생성 코드. null = emit 실패/skip.
    code: ?[]const u8 = null,
    /// 이 모듈이 요구하는 런타임 헬퍼 집합.
    helpers: RuntimeHelpers = .{},
    /// codegen 이 생성한 매핑 (bundle SourceMap 빌더에 병합).
    mappings: ?[]const SourceMap.Mapping = null,
    /// preamble/래퍼 헤더로 codegen 매핑과 어긋나는 줄 수.
    preamble_lines: u32 = 0,
    /// per-source function map JSON. null = 비활성/함수 없음.
    fn_map_json: ?[]const u8 = null,

    /// 모듈 소유 자원 해제 (code/mappings/fn_map_json).
    pub fn deinit(self: CompiledModule, allocator: std.mem.Allocator) void {
        if (self.code) |c| allocator.free(c);
        if (self.mappings) |m| allocator.free(m);
        if (self.fn_map_json) |j| allocator.free(j);
    }

    /// 모든 slice 자원을 `allocator` 로 복사한 새 CompiledModule 반환.
    /// cache hit 결과를 호출자 소유로 옮길 때 사용 (ownership 전이를 단순화).
    pub fn dupe(self: CompiledModule, allocator: std.mem.Allocator) !CompiledModule {
        const code = if (self.code) |c| try allocator.dupe(u8, c) else null;
        errdefer if (code) |c| allocator.free(c);
        const mappings = if (self.mappings) |m| try allocator.dupe(SourceMap.Mapping, m) else null;
        errdefer if (mappings) |m| allocator.free(m);
        const fn_map = if (self.fn_map_json) |j| try allocator.dupe(u8, j) else null;
        return .{
            .code = code,
            .helpers = self.helpers,
            .mappings = mappings,
            .preamble_lines = self.preamble_lines,
            .fn_map_json = fn_map,
        };
    }
};
