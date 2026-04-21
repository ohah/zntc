//! ZTS Bundler — Compiled output cache
//!
//! 모듈 단위 Transformer→Codegen 결과 (`CompiledModule`) 를 input hash 로 키잉하여
//! HMR/watch rebuild 시 변경되지 않은 모듈의 emit 을 스킵한다.
//!
//! ### input_hash 구성 (in-memory cache 한정)
//! `mtime_ns + options_hash(수동) + used_names_hash + import_records_hash`.
//! `options_hash` 는 emit 영향 필드만 수동 집계 — slice 필드 (`plugins` /
//! `define` / `drop_labels` / `polyfills` / `run_before_main`) 때문에 comptime
//! reflection (`autoHash`) 은 부적합.
//!
//! ### 장기 확장 포인트 (persistent disk cache 도입 시 반드시 추가)
//! 현재 구성은 동일 binary 프로세스 내에서만 정확하다. 디스크 캐시/크로스프로세스
//! 공유로 확장할 때는 아래 차원이 누락되면 stale output 이 발생한다:
//!
//! 1. `compiler_build_hash` — ZTS binary rebuild 시 semantic/transformer 로직이
//!    바뀌어 동일 source 여도 emit 결과 다름. in-memory 에서는 restart 로 대체
//!    되지만 disk cache 에서는 필수. Bazel/Turborepo 의 `tool_version` 과 동일
//!    개념 (build.zig 에서 git SHA / timestamp 주입).
//! 2. Merkle DAG — `import_records_hash` 가 specifier + resolved id 만 다루므로
//!    imported 모듈의 mangle/export rename 을 놓친다. 각 모듈의
//!    `final_hash = local + Σ(dep.final_hash)` 로 확장.
//! 3. `plugin_version` — 포인터 identity 는 process 내 한정. user plugin 저자가
//!    명시하는 version 필드 도입 (AST plugin epic 이후 재평가).

const std = @import("std");
const Module = @import("module.zig").Module;
const emitter = @import("emitter.zig");
const EmitOptions = emitter.EmitOptions;
const CompiledModule = @import("compiled_module.zig").CompiledModule;
const SourceMap = @import("../codegen/sourcemap.zig");

// ===========================================================================
// InputHasher — Wyhash 기반 순차 update 빌더
// ===========================================================================

/// cache key 구성 전용 해시 빌더. 길이 prefix 로 boundary 충돌 방지.
pub const InputHasher = struct {
    inner: std.hash.Wyhash,

    pub fn init(seed: u64) InputHasher {
        return .{ .inner = std.hash.Wyhash.init(seed) };
    }

    pub fn addU64(self: *InputHasher, v: u64) void {
        self.inner.update(std.mem.asBytes(&v));
    }

    pub fn addU32(self: *InputHasher, v: u32) void {
        self.inner.update(std.mem.asBytes(&v));
    }

    pub fn addI128(self: *InputHasher, v: i128) void {
        self.inner.update(std.mem.asBytes(&v));
    }

    pub fn addBool(self: *InputHasher, v: bool) void {
        self.inner.update(&[_]u8{if (v) 1 else 0});
    }

    /// 길이 prefix 로 "ab"+"cd" 와 "abc"+"d" 의 boundary 충돌을 방지한다.
    pub fn addStr(self: *InputHasher, s: []const u8) void {
        self.addU64(s.len);
        self.inner.update(s);
    }

    pub fn addOptStr(self: *InputHasher, s: ?[]const u8) void {
        if (s) |v| {
            self.addBool(true);
            self.addStr(v);
        } else self.addBool(false);
    }

    pub fn addStrList(self: *InputHasher, list: []const []const u8) void {
        self.addU64(list.len);
        for (list) |s| self.addStr(s);
    }

    pub fn final(self: *InputHasher) u64 {
        return self.inner.final();
    }
};

// ===========================================================================
// hashEmitOptions — 수동 options_hash (emit 영향 필드만)
// ===========================================================================

/// `EmitOptions` 필드 개수. 구조체가 바뀌면 이 값을 갱신하고 hashEmitOptions
/// 에 새 필드를 반영해야 한다 — comptime 에 필드 누락을 감지하는 fail-stop.
/// 누락이 invisible bug (stale cache) 로 번지므로 이 barrier 는 load-bearing.
const expected_emit_options_field_count: usize = 47;

comptime {
    const actual = @typeInfo(EmitOptions).@"struct".fields.len;
    if (actual != expected_emit_options_field_count) {
        @compileError(std.fmt.comptimePrint(
            "EmitOptions 필드 개수 변경 감지 (expected {d}, actual {d}). " ++
                "compiled_cache.zig hashEmitOptions 를 업데이트 후 expected 값을 맞추세요.",
            .{ expected_emit_options_field_count, actual },
        ));
    }
}

/// EmitOptions 의 emit 결과에 영향을 주는 모든 필드를 순차 hash.
pub fn hashEmitOptions(h: *InputHasher, options: EmitOptions) void {
    h.addU32(@intFromEnum(options.format));
    h.addBool(options.minify_whitespace);
    h.addBool(options.minify_syntax);
    h.addBool(options.minify_identifiers);
    h.addBool(options.sourcemap);
    h.addBool(options.sourcemap_debug_ids);
    h.addBool(options.sourcemap_function_map);
    h.addBool(options.dev_mode);
    h.addOptStr(options.root_dir);
    h.addBool(options.react_refresh);
    h.addBool(options.worklet_transform);
    h.addOptStr(options.worklet_plugin_version);
    h.addBool(options.collect_module_codes);

    h.addU64(options.define.len);
    for (options.define) |d| {
        h.addStr(d.key);
        h.addStr(d.value);
    }

    h.addBool(options.experimental_decorators);
    h.addBool(options.emit_decorator_metadata);
    h.addBool(options.use_define_for_class_fields);
    h.addBool(options.verbatim_module_syntax);
    // UnsupportedFeatures 는 packed struct → asBytes 로 일괄 hash
    h.inner.update(std.mem.asBytes(&options.unsupported));
    h.addU32(@intFromEnum(options.platform));
    h.addStr(options.public_path);
    h.addOptStr(options.banner_js);
    h.addOptStr(options.footer_js);
    h.addOptStr(options.global_name);
    h.addOptStr(options.out_extension_js);
    h.addStr(options.output_filename);
    h.addOptStr(options.source_root);
    h.addBool(options.sources_content);
    h.addBool(options.charset_utf8);
    h.addStr(options.entry_names);
    h.addStr(options.chunk_names);
    h.addStr(options.asset_names);
    h.addU32(@intFromEnum(options.legal_comments));
    h.addBool(options.keep_names);
    h.addStrList(options.drop_labels);
    h.addU32(@intFromEnum(options.jsx_runtime));
    h.addStr(options.jsx_factory);
    h.addStr(options.jsx_fragment);
    h.addStr(options.jsx_import_source);

    // plugins: in-memory cache 한정 — name + 훅 함수 포인터 identity 로 식별.
    // disk cache 로 가면 plugin_version 필드 도입 필요 (파일 상단 장기 확장 포인트 3).
    h.addU64(options.plugins.len);
    for (options.plugins) |p| {
        h.addStr(p.name);
        h.addU64(@intFromPtr(p.context));
        // 훅 포인터 집합도 plugin identity 의 일부 (동일 name 의 다른 구현 구분)
        h.addU64(if (p.resolveId) |f| @intFromPtr(f) else 0);
        h.addU64(if (p.load) |f| @intFromPtr(f) else 0);
        h.addU64(if (p.transform) |f| @intFromPtr(f) else 0);
        h.addU64(if (p.renderChunk) |f| @intFromPtr(f) else 0);
        h.addU64(if (p.generateBundle) |f| @intFromPtr(f) else 0);
    }

    h.addU64(options.polyfills.len);
    for (options.polyfills) |poly| {
        h.addStr(poly.name);
        h.addStr(poly.content);
    }

    h.addStrList(options.run_before_main);
    h.addBool(options.configurable_exports);
    h.addBool(options.strict_execution_order);
    h.addBool(options.preserve_modules);
    h.addOptStr(options.preserve_modules_root);
}

/// 전체 emit 에 1회만 계산하면 되는 options_hash 를 캐싱용으로 반환.
pub fn computeOptionsHash(options: EmitOptions) u64 {
    var h = InputHasher.init(0);
    hashEmitOptions(&h, options);
    return h.final();
}

// ===========================================================================
// computeInputHash — 모듈별 최종 hash
// ===========================================================================

/// 모듈 emit 결과에 영향을 주는 모든 외부 상태를 결합.
/// `used_export_names == null` = "모두 사용" sentinel (tree-shaking 미적용).
/// `options_hash` 는 caller 가 computeOptionsHash 로 1회 계산한 값 재사용.
/// `modules` 는 `ModuleIndex` → path 조회용. `ModuleIndex` 자체는 빌드 간
/// 재할당되므로 path 로 hash 해야 initial/rebuild 간 input_hash 가 안정적.
pub fn computeInputHash(
    module: *const Module,
    options_hash: u64,
    used_export_names: ?[]const []const u8,
    modules: []const Module,
) u64 {
    var h = InputHasher.init(0);
    h.addI128(module.mtime);
    h.addU64(options_hash);

    if (used_export_names) |names| {
        h.addBool(true);
        h.addStrList(names);
    } else h.addBool(false);

    h.addU64(module.import_records.len);
    for (module.import_records) |rec| {
        h.addStr(rec.specifier);
        h.addBool(rec.is_external);
        h.addU32(@intFromEnum(rec.kind));
        // resolved 는 `modules[index].path` 로 hash — ModuleIndex 는 빌드 간
        // 재할당되므로 path 가 안정적. external/unresolved 는 specifier 만.
        if (rec.is_external or rec.resolved.isNone()) {
            h.addBool(false);
        } else {
            h.addBool(true);
            const idx = rec.resolved.toU32();
            if (idx < modules.len) {
                h.addStr(modules[idx].path);
            } else {
                // 방어: 범위 밖이면 stable sentinel 로 hash (극히 이례적).
                h.addStr("");
            }
        }
    }

    return h.final();
}

// ===========================================================================
// CompiledOutputCache — path → (hash, compiled)
// ===========================================================================

/// HMR/watch 경로에서 변경 안 된 모듈의 emit 을 스킵하기 위한 in-memory cache.
/// 스레드 안전성: 호출자가 serialize 해서 사용 (emit 병렬 루프 진입 전 lookup,
/// 이후 순차 put 패턴). emit loop 내부에서 병렬로 put/tryHit 하지 않는다.
pub const CompiledOutputCache = struct {
    allocator: std.mem.Allocator,
    /// absolute path → entry. key 는 cache 가 owning.
    entries: std.StringHashMap(Entry),
    /// 디버그: 실측용 hit/miss 카운터. emit 루프 밖에서 주기적으로 읽어 리셋.
    hits: u64 = 0,
    misses: u64 = 0,
    skipped_no_mtime: u64 = 0,

    pub const Entry = struct {
        input_hash: u64,
        compiled: CompiledModule,
    };

    pub fn init(allocator: std.mem.Allocator) CompiledOutputCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub const Stats = struct { hits: u64, misses: u64, skipped: u64 };

    /// 현재 카운터를 snapshot 으로 반환하고 0 으로 리셋.
    pub fn takeStats(self: *CompiledOutputCache) Stats {
        const s: Stats = .{ .hits = self.hits, .misses = self.misses, .skipped = self.skipped_no_mtime };
        self.hits = 0;
        self.misses = 0;
        self.skipped_no_mtime = 0;
        return s;
    }

    pub fn deinit(self: *CompiledOutputCache) void {
        self.clear();
        self.entries.deinit();
    }

    /// 모든 엔트리 해제 (key + CompiledModule 소유 자원).
    pub fn clear(self: *CompiledOutputCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.compiled.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    /// `input_hash` 일치 시 cache 소유의 compiled 포인터 반환 (borrow, 호출자 free 금지).
    pub fn tryHit(self: *CompiledOutputCache, path: []const u8, input_hash: u64) ?*const CompiledModule {
        const ptr = self.entries.getPtr(path) orelse {
            self.misses += 1;
            return null;
        };
        if (ptr.input_hash != input_hash) {
            self.misses += 1;
            return null;
        }
        self.hits += 1;
        return &ptr.compiled;
    }

    /// emit 결과를 cache 에 저장. `compiled` 의 slice 들은 cache allocator 로 dupe.
    /// 기존 엔트리가 있으면 해제 후 교체.
    pub fn put(
        self: *CompiledOutputCache,
        path: []const u8,
        input_hash: u64,
        compiled: CompiledModule,
    ) !void {
        const owned = try compiled.dupe(self.allocator);
        errdefer owned.deinit(self.allocator);

        if (self.entries.getPtr(path)) |existing| {
            existing.compiled.deinit(self.allocator);
            existing.* = .{ .input_hash = input_hash, .compiled = owned };
            return;
        }

        const owned_key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_key);
        try self.entries.put(owned_key, .{ .input_hash = input_hash, .compiled = owned });
    }

    /// 디버그 로그에 hit/miss stats 출력 + 카운터 리셋. `ZTS_DEBUG=compiled_cache`
    /// 비활성 시 takeStats 호출도 스킵 — counter 부작용 없음.
    /// `prefix` 는 caller 가 추가할 선행 키 (예: "first=true "). 빈 문자열이면 prefix 없음.
    pub fn logStats(self: *CompiledOutputCache, prefix: []const u8) void {
        const debug_log = @import("../debug_log.zig");
        if (!debug_log.enabled(.compiled_cache)) return;
        const stats = self.takeStats();
        debug_log.print(
            .compiled_cache,
            "{s}hits={d} misses={d} no_mtime_skipped={d} (entries={d})\n",
            .{ prefix, stats.hits, stats.misses, stats.skipped, self.entries.count() },
        );
    }

    /// 특정 경로 엔트리를 무효화 (파일 삭제/graph 변경 시).
    pub fn invalidate(self: *CompiledOutputCache, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            var compiled = kv.value.compiled;
            compiled.deinit(self.allocator);
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "InputHasher: boundary prefix 로 concat 충돌 방지" {
    var a = InputHasher.init(0);
    a.addStr("ab");
    a.addStr("cd");

    var b = InputHasher.init(0);
    b.addStr("abc");
    b.addStr("d");

    try std.testing.expect(a.final() != b.final());
}

test "InputHasher: 동일 입력은 동일 해시" {
    var a = InputHasher.init(0);
    a.addU64(42);
    a.addStr("foo");
    a.addStrList(&.{ "x", "yy" });

    var b = InputHasher.init(0);
    b.addU64(42);
    b.addStr("foo");
    b.addStrList(&.{ "x", "yy" });

    try std.testing.expectEqual(a.final(), b.final());
}

test "CompiledOutputCache: put → tryHit 성공" {
    const alloc = std.testing.allocator;
    var cache = CompiledOutputCache.init(alloc);
    defer cache.deinit();

    const code = try alloc.dupe(u8, "const x = 1;");
    const compiled: CompiledModule = .{ .code = code };

    try cache.put("/path/a.ts", 0xDEADBEEF, compiled);
    // put 내부에서 dupe — caller 소유 slice 는 별도로 해제해야 함
    alloc.free(code);

    const hit = cache.tryHit("/path/a.ts", 0xDEADBEEF);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.code != null);
    try std.testing.expectEqualStrings("const x = 1;", hit.?.code.?);
}

test "CompiledOutputCache: tryHit 은 hash 불일치 시 null" {
    const alloc = std.testing.allocator;
    var cache = CompiledOutputCache.init(alloc);
    defer cache.deinit();

    const code = try alloc.dupe(u8, "x");
    defer alloc.free(code);
    try cache.put("/path/a.ts", 1, .{ .code = code });

    try std.testing.expect(cache.tryHit("/path/a.ts", 2) == null);
    try std.testing.expect(cache.tryHit("/path/b.ts", 1) == null);
}

test "CompiledOutputCache: invalidate 는 엔트리 제거" {
    const alloc = std.testing.allocator;
    var cache = CompiledOutputCache.init(alloc);
    defer cache.deinit();

    const code = try alloc.dupe(u8, "x");
    defer alloc.free(code);
    try cache.put("/path/a.ts", 1, .{ .code = code });

    cache.invalidate("/path/a.ts");
    try std.testing.expect(cache.tryHit("/path/a.ts", 1) == null);
}
