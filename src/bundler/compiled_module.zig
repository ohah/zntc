//! ZNTC Bundler — Compiled module output
//!
//! 모듈 컴파일 결과 (Transformer → Codegen 산출물) 를 표현한다.
//! emit 병렬 결과 수집 (emitter.zig) 및 HMR/watch compiled output cache 의
//! 공용 값 타입.

const std = @import("std");
const RuntimeHelpers = @import("../transformer/runtime_helper_bits.zig").RuntimeHelpers;
const SourceMap = @import("../codegen/sourcemap.zig");

/// 모듈 단위 컴파일 결과. 동일 입력 해시로 재사용 시 cache hit 로 활용된다.
pub const CompiledModule = struct {
    /// 생성 코드. null = emit 실패/skip.
    code: ?[]const u8 = null,
    /// 이 모듈이 요구하는 런타임 헬퍼 집합.
    helpers: RuntimeHelpers = .{},
    /// codegen 이 생성한 매핑 (bundle SourceMap 빌더에 병합).
    mappings: ?[]const SourceMap.Mapping = null,
    /// codegen builder 의 names 배열 (mangler rename 발생 시 원본 식별자 이름).
    /// `mappings[i].name_index` 가 가리키는 module-local 인덱스. bundle 머지 시
    /// chunk builder 로 옮길 때 chunk-global 인덱스로 재매핑.
    names: []const []const u8 = &.{},
    /// preamble/래퍼 헤더로 codegen 매핑과 어긋나는 줄 수.
    preamble_lines: u32 = 0,
    /// per-source function map JSON. null = 비활성/함수 없음.
    fn_map_json: ?[]const u8 = null,
    /// `entry_error_guard` 활성 + entry 모듈의 runBeforeMain 호출을 factory body 와
    /// 분리해 emitter 가 별 top-level statement 로 unroll. entry dependency chain은
    /// Metro처럼 entry factory 내부 nested require로 남겨 throw 전파를 보존한다.
    entry_chain: ?[]const u8 = null,
    /// 이 module code 가 참조하는 shared namespace object 선언 목록.
    /// compiled output cache hit 시 linker 의 bundle preamble registry 를 복원하는 데 사용.
    shared_ns_decls: []const SharedNsDecl = &.{},

    pub const SharedNsDecl = struct {
        target_path: []const u8,
        var_name: []const u8,
        object_literal: []const u8,
    };

    /// 모듈 소유 자원 해제 (code/mappings/fn_map_json/entry_chain).
    pub fn deinit(self: CompiledModule, allocator: std.mem.Allocator) void {
        if (self.code) |c| allocator.free(c);
        if (self.mappings) |m| allocator.free(m);
        for (self.names) |n| allocator.free(n);
        if (self.names.len > 0) allocator.free(self.names);
        if (self.fn_map_json) |j| allocator.free(j);
        if (self.entry_chain) |c| allocator.free(c);
        for (self.shared_ns_decls) |d| {
            allocator.free(d.target_path);
            allocator.free(d.var_name);
            allocator.free(d.object_literal);
        }
        if (self.shared_ns_decls.len > 0) allocator.free(self.shared_ns_decls);
    }

    /// 모든 slice 자원을 `allocator` 로 복사한 새 CompiledModule 반환.
    /// cache hit 결과를 호출자 소유로 옮길 때 사용 (ownership 전이를 단순화).
    pub fn dupe(self: CompiledModule, allocator: std.mem.Allocator) !CompiledModule {
        const code = if (self.code) |c| try allocator.dupe(u8, c) else null;
        errdefer if (code) |c| allocator.free(c);
        const mappings = if (self.mappings) |m| try allocator.dupe(SourceMap.Mapping, m) else null;
        errdefer if (mappings) |m| allocator.free(m);
        const names = try allocator.alloc([]const u8, self.names.len);
        errdefer allocator.free(names);
        var names_filled: usize = 0;
        errdefer for (names[0..names_filled]) |n| allocator.free(n);
        for (self.names, 0..) |n, i| {
            names[i] = try allocator.dupe(u8, n);
            names_filled = i + 1;
        }
        const fn_map = if (self.fn_map_json) |j| try allocator.dupe(u8, j) else null;
        errdefer if (fn_map) |j| allocator.free(j);
        const ec = if (self.entry_chain) |c| try allocator.dupe(u8, c) else null;
        errdefer if (ec) |c| allocator.free(c);
        const shared = try allocator.alloc(SharedNsDecl, self.shared_ns_decls.len);
        errdefer allocator.free(shared);
        for (self.shared_ns_decls, 0..) |decl, i| {
            const target_path = try allocator.dupe(u8, decl.target_path);
            errdefer allocator.free(target_path);
            const var_name = try allocator.dupe(u8, decl.var_name);
            errdefer allocator.free(var_name);
            const object_literal = try allocator.dupe(u8, decl.object_literal);
            errdefer allocator.free(object_literal);
            shared[i] = .{
                .target_path = target_path,
                .var_name = var_name,
                .object_literal = object_literal,
            };
        }
        return .{
            .code = code,
            .helpers = self.helpers,
            .mappings = mappings,
            .names = names,
            .preamble_lines = self.preamble_lines,
            .fn_map_json = fn_map,
            .entry_chain = ec,
            .shared_ns_decls = shared,
        };
    }
};
