//! ZTS tsconfig.json Reader
//!
//! tsconfig.json 파일을 파싱하여 ZTS가 사용하는 컴파일러 옵션을 추출한다.
//! - JSONC (주석 포함 JSON) 지원: 파싱 전에 주석을 제거
//! - "extends" 필드를 통한 설정 상속 지원
//! - 누락된 필드는 기본값 사용
//!
//! 참고:
//! - TypeScript 공식 tsconfig 스펙: https://www.typescriptlang.org/tsconfig
//! - std.json.parseFromSlice: Zig 0.14 JSON 파싱 API

const std = @import("std");

/// tsconfig.json에서 파싱한 컴파일러 옵션을 담는 구조체.
///
/// 모든 필드는 옵셔널이거나 기본값이 있다.
/// CLI 옵션이 tsconfig 옵션보다 우선한다.
pub const TsConfig = struct {
    /// "target": 출력 JavaScript 버전 (예: "es5", "es2015", "esnext")
    target: ?[]const u8 = null,
    /// "module": 모듈 시스템 (예: "commonjs", "es2015", "esnext")
    module: ?[]const u8 = null,
    /// "jsx": JSX 처리 모드 (예: "react", "react-jsx", "preserve")
    jsx: ?[]const u8 = null,
    /// "jsxFactory": JSX 팩토리 함수 (기본: "React.createElement")
    jsx_factory: []const u8 = "React.createElement",
    /// "jsxFragmentFactory": JSX Fragment 팩토리 (기본: "React.Fragment")
    jsx_fragment_factory: []const u8 = "React.Fragment",
    /// "jsxImportSource": automatic 모드 import source (기본: "react")
    jsx_import_source: []const u8 = "react",
    /// "outDir": 출력 디렉토리 경로
    out_dir: ?[]const u8 = null,
    /// "rootDir": 소스 루트 디렉토리 경로
    root_dir: ?[]const u8 = null,
    /// "sourceMap": 소스맵 생성 여부
    source_map: bool = false,
    /// "declaration": .d.ts 선언 파일 생성 여부
    declaration: bool = false,
    /// "strict": strict 모드 활성화 여부
    strict: bool = false,
    /// "experimentalDecorators": 레거시 데코레이터 지원 여부
    experimental_decorators: bool = false,
    /// "emitDecoratorMetadata": 데코레이터 메타데이터 emit 여부
    emit_decorator_metadata: bool = false,
    /// "useDefineForClassFields": class field를 define(ES 표준) 또는 assign(legacy) semantics로 처리.
    /// null = 설정 안 됨 (기본값은 target에 따라 결정: ES2022+ → true, 이전 → false).
    /// ZTS에서는 명시적으로 false로 설정한 경우에만 assign semantics 적용.
    use_define_for_class_fields: ?bool = null,
    /// "verbatimModuleSyntax" (TS 5.0+): true면 값 import를 elide하지 않는다.
    /// esbuild/vite/swc(isolatedModules) 의 표준 동작과 동일.
    verbatim_module_syntax: bool = false,

    /// "baseUrl": paths 해석의 기준 경로 (tsconfig.json 위치 기준 상대).
    /// null 이면 tsconfig 디렉토리 자체가 기본.
    base_url: ?[]const u8 = null,

    /// "paths": `{ "@/*": ["./src/*", "./vendor/*"], "@utils": ["./utils/index.ts"] }` 매핑.
    /// TS 공식 스펙:
    /// - key 는 한 개의 `*` 를 위치 자유롭게 가질 수 있다 (prefix/middle/suffix 모두).
    /// - value 배열의 각 후보는 key 와 동일한 `*` 유무를 가져야 함 (비대칭은 ts(5063) 에러).
    /// - 다중 후보는 선언 순서대로 시도하여 첫 resolvable 파일을 사용.
    paths: []const PathEntry = &.{},

    /// allocator로 할당된 문자열들을 해제하기 위한 참조.
    /// load()에서 내부적으로 사용하며, deinit() 시 해제된다.
    _allocator: ?std.mem.Allocator = null,
    /// 할당된 문자열 목록. deinit() 시 모두 free된다.
    _allocated_strings: ?std.ArrayList([]const u8) = null,

    /// `paths` 1 항목. key 는 `*` 기준으로 prefix/suffix 로 분리, targets 는 후보 목록.
    /// `has_wildcard = false` 이면 exact-match (key_prefix = 전체 key, key_suffix 빈 문자열).
    pub const PathEntry = struct {
        key_prefix: []const u8,
        key_suffix: []const u8,
        has_wildcard: bool,
        targets: []const Target,

        /// value 배열의 한 항목. key 가 wildcard 면 target 도 대응하는 `*` 에서 분리됨.
        pub const Target = struct {
            prefix: []const u8,
            suffix: []const u8,
        };
    };

    /// TsConfig가 소유한 동적 메모리를 해제한다.
    /// load()로 생성한 TsConfig는 반드시 deinit()을 호출해야 한다.
    pub fn deinit(self: *TsConfig) void {
        if (self._allocator) |allocator| {
            if (self._allocated_strings) |*list| {
                for (list.items) |s| {
                    allocator.free(s);
                }
                list.deinit(allocator);
            }
            // paths 슬라이스 + 각 entry.targets 슬라이스는 allocator 에 별도 할당. 내부 문자열은
            // _allocated_strings 가 소유하므로 여기서는 컨테이너만 해제.
            for (self.paths) |p| if (p.targets.len > 0) allocator.free(p.targets);
            if (self.paths.len > 0) allocator.free(self.paths);
        }
        self.paths = &.{};
        self._allocated_strings = null;
        self._allocator = null;
    }

    /// 주어진 디렉토리에서 tsconfig.json을 찾아 파싱한다.
    ///
    /// 동작:
    /// 1. dir_path/tsconfig.json 파일을 읽는다.
    /// 2. JSONC 주석을 제거한다.
    /// 3. "extends" 필드가 있으면 base config를 먼저 로드하고 merge한다.
    /// 4. compilerOptions에서 ZTS가 사용하는 필드를 추출한다.
    ///
    /// tsconfig.json이 없으면 기본값 TsConfig를 반환한다 (에러 아님).
    /// 파일 내용이 유효하지 않은 JSON이면 에러를 반환한다.
    pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) !TsConfig {
        return loadFile(allocator, dir_path, "tsconfig.json", 0);
    }

    /// 파일 경로 또는 디렉토리 경로에서 tsconfig를 로드한다.
    /// 경로 끝이 `.json`이면 파일로 취급, 아니면 디렉토리로 취급해 그 안의 `tsconfig.json`을 읽는다.
    /// NAPI/빌드 API 에서 사용자가 "./tsconfig.json" 또는 "./project-dir" 어느 쪽을 줘도 동작.
    pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !TsConfig {
        if (std.mem.endsWith(u8, path, ".json")) {
            const dir = std.fs.path.dirname(path) orelse ".";
            const file = std.fs.path.basename(path);
            return loadFile(allocator, dir, file, 0);
        }
        return loadFile(allocator, path, "tsconfig.json", 0);
    }

    /// 특정 파일명으로 tsconfig를 로드한다 (extends 체인에서 사용).
    /// depth: extends 재귀 깊이 (무한 루프 방지, 최대 10단계)
    fn loadFile(
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        file_name: []const u8,
        depth: u32,
    ) !TsConfig {
        // 무한 extends 체인 방지
        if (depth > 10) {
            return error.TsConfigExtendsDepthExceeded;
        }

        // 파일 경로 구성
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
        defer allocator.free(file_path);

        // 파일 읽기 (없으면 기본값 반환)
        const raw_source = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                return TsConfig{};
            }
            return err;
        };
        defer allocator.free(raw_source);

        // JSONC → JSON: 주석 제거
        const source = try stripJsonComments(allocator, raw_source);
        defer allocator.free(source);

        // JSON 파싱.
        // std.json.parseFromSlice는 Zig 0.14의 표준 JSON 파서이다.
        // .allocate = .alloc_always: 문자열을 allocator로 복사
        //   (원본 source가 defer로 해제되므로 복사가 필요함)
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            source,
            .{ .allocate = .alloc_always },
        ) catch {
            return error.TsConfigParseError;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return error.TsConfigParseError;
        }

        // 결과 TsConfig 초기화
        var config = TsConfig{
            ._allocator = allocator,
            ._allocated_strings = .empty,
        };
        errdefer config.deinit();

        // "extends" 처리: base config를 먼저 로드하고 merge
        if (root.object.get("extends")) |extends_val| {
            if (extends_val == .string) {
                const extends_path = extends_val.string;

                // extends 경로에서 디렉토리와 파일명 분리.
                // 예: "./base.json" → dir_path + "base.json"
                // 예: "../shared/tsconfig.base.json" → resolve relative to dir_path
                const resolved = try std.fs.path.join(allocator, &.{ dir_path, extends_path });
                defer allocator.free(resolved);

                // resolved가 디렉토리인지 파일인지 확인
                // 파일이면 그대로 사용, 디렉토리면 tsconfig.json 추가
                const base_dir = std.fs.path.dirname(resolved) orelse dir_path;
                const base_file = std.fs.path.basename(resolved);

                var base_config = try loadFile(allocator, base_dir, base_file, depth + 1);
                defer base_config.deinit();

                // base의 값을 config에 복사 (현재 config는 아직 기본값)
                try mergeFrom(&config, &base_config, allocator);
            }
        }

        // compilerOptions 추출
        if (root.object.get("compilerOptions")) |co_val| {
            if (co_val == .object) {
                const co = co_val.object;

                // 문자열 옵션 추출
                // JSON에서 가져온 문자열은 parsed가 소유하므로,
                // config가 오래 살기 위해 allocator로 복사(dupe)한다.
                // 키가 JSON에 있을 때만 덮어씀 — extends로 merge된 값을 보존.
                if (try dupeJsonString(co, "target", allocator, &config._allocated_strings.?)) |v| config.target = v;
                if (try dupeJsonString(co, "module", allocator, &config._allocated_strings.?)) |v| config.module = v;
                if (try dupeJsonString(co, "jsx", allocator, &config._allocated_strings.?)) |v| config.jsx = v;
                if (try dupeJsonString(co, "jsxFactory", allocator, &config._allocated_strings.?)) |v| config.jsx_factory = v;
                if (try dupeJsonString(co, "jsxFragmentFactory", allocator, &config._allocated_strings.?)) |v| config.jsx_fragment_factory = v;
                if (try dupeJsonString(co, "jsxImportSource", allocator, &config._allocated_strings.?)) |v| config.jsx_import_source = v;
                if (try dupeJsonString(co, "outDir", allocator, &config._allocated_strings.?)) |v| config.out_dir = v;
                if (try dupeJsonString(co, "rootDir", allocator, &config._allocated_strings.?)) |v| config.root_dir = v;
                if (try dupeJsonString(co, "baseUrl", allocator, &config._allocated_strings.?)) |v| config.base_url = v;

                // paths: {"@/*": ["./src/*"], ...} → []PathEntry
                if (co.get("paths")) |v| {
                    if (v == .object) {
                        const entries = try parsePathsObject(v.object, allocator, &config._allocated_strings.?);
                        config.paths = entries;
                    }
                }

                // bool 옵션 추출
                if (co.get("sourceMap")) |v| {
                    if (v == .bool) config.source_map = v.bool;
                }
                if (co.get("declaration")) |v| {
                    if (v == .bool) config.declaration = v.bool;
                }
                if (co.get("strict")) |v| {
                    if (v == .bool) config.strict = v.bool;
                }
                if (co.get("experimentalDecorators")) |v| {
                    if (v == .bool) config.experimental_decorators = v.bool;
                }
                if (co.get("emitDecoratorMetadata")) |v| {
                    if (v == .bool) config.emit_decorator_metadata = v.bool;
                }
                if (co.get("useDefineForClassFields")) |v| {
                    if (v == .bool) config.use_define_for_class_fields = v.bool;
                }
                if (co.get("verbatimModuleSyntax")) |v| {
                    if (v == .bool) config.verbatim_module_syntax = v.bool;
                }
            }
        }

        return config;
    }

    /// base config의 값을 target config에 merge한다.
    /// 이미 target에 설정된 값은 덮어쓰지 않는다 (자식이 우선).
    /// 단, 이 함수는 target이 아직 기본값일 때 호출되므로,
    /// base의 non-default 값을 모두 복사한다.
    fn mergeFrom(
        target: *TsConfig,
        base: *const TsConfig,
        allocator: std.mem.Allocator,
    ) !void {
        // 문자열 옵션: base에 값이 있고 target이 null이면 복사
        target.target = try mergeOptionalString(target.target, base.target, allocator, &target._allocated_strings.?);
        target.module = try mergeOptionalString(target.module, base.module, allocator, &target._allocated_strings.?);
        target.jsx = try mergeOptionalString(target.jsx, base.jsx, allocator, &target._allocated_strings.?);
        target.out_dir = try mergeOptionalString(target.out_dir, base.out_dir, allocator, &target._allocated_strings.?);
        target.root_dir = try mergeOptionalString(target.root_dir, base.root_dir, allocator, &target._allocated_strings.?);

        // 문자열 (non-optional) 필드: base가 기본값이 아니면 복사
        if (!std.mem.eql(u8, base.jsx_factory, "React.createElement")) {
            if (std.mem.eql(u8, target.jsx_factory, "React.createElement")) {
                const duped = try allocator.dupe(u8, base.jsx_factory);
                try target._allocated_strings.?.append(allocator, duped);
                target.jsx_factory = duped;
            }
        }
        if (!std.mem.eql(u8, base.jsx_fragment_factory, "React.Fragment")) {
            if (std.mem.eql(u8, target.jsx_fragment_factory, "React.Fragment")) {
                const duped = try allocator.dupe(u8, base.jsx_fragment_factory);
                try target._allocated_strings.?.append(allocator, duped);
                target.jsx_fragment_factory = duped;
            }
        }
        if (!std.mem.eql(u8, base.jsx_import_source, "react")) {
            if (std.mem.eql(u8, target.jsx_import_source, "react")) {
                const duped = try allocator.dupe(u8, base.jsx_import_source);
                try target._allocated_strings.?.append(allocator, duped);
                target.jsx_import_source = duped;
            }
        }

        // bool 옵션: base에서 true인 것만 복사 (false는 기본값이므로 구분 불가)
        // tsconfig extends에서는 보통 base의 설정이 그대로 상속됨
        if (base.source_map) target.source_map = true;
        if (base.declaration) target.declaration = true;
        if (base.strict) target.strict = true;
        if (base.experimental_decorators) target.experimental_decorators = true;
        if (base.emit_decorator_metadata) target.emit_decorator_metadata = true;
        if (base.verbatim_module_syntax) target.verbatim_module_syntax = true;
        // optional bool: target이 null이면 base에서 상속
        if (target.use_define_for_class_fields == null) {
            target.use_define_for_class_fields = base.use_define_for_class_fields;
        }

        // baseUrl / paths: target 에 없을 때만 base 값 승계. 동시 설정 시 target 전체가 이김.
        if (target.base_url == null) {
            target.base_url = try mergeOptionalString(null, base.base_url, allocator, &target._allocated_strings.?);
        }
        if (target.paths.len == 0 and base.paths.len > 0) {
            const duped = try allocator.alloc(TsConfig.PathEntry, base.paths.len);
            for (base.paths, 0..) |e, i| {
                const kp = try dupeAndTrack(allocator, e.key_prefix, &target._allocated_strings.?);
                const ks = try dupeAndTrack(allocator, e.key_suffix, &target._allocated_strings.?);
                const targets = try allocator.alloc(TsConfig.PathEntry.Target, e.targets.len);
                for (e.targets, 0..) |t, j| {
                    const tp = try dupeAndTrack(allocator, t.prefix, &target._allocated_strings.?);
                    const ts = try dupeAndTrack(allocator, t.suffix, &target._allocated_strings.?);
                    targets[j] = .{ .prefix = tp, .suffix = ts };
                }
                duped[i] = .{ .key_prefix = kp, .key_suffix = ks, .has_wildcard = e.has_wildcard, .targets = targets };
            }
            target.paths = duped;
        }
    }
};

/// tsconfig 파일 경로 판별 접미사 (디렉토리 인지 파일인지 구분).
pub const TSCONFIG_FILE_EXT = ".json";

/// Resolver 에 주입할 수 있도록 target prefix 를 절대 경로로 만든 형태.
/// `tsconfig_dir` + `base_url` + target.prefix 를 `std.fs.path.resolve` 로 조인.
/// entry 구조는 `TsConfig.PathEntry` 와 동일 — 해석(matching) 코드는 양쪽에 재사용 가능.
pub const ResolvedPaths = struct {
    entries: []const TsConfig.PathEntry,
    owned_strings: [][]const u8,

    pub fn deinit(self: *ResolvedPaths, allocator: std.mem.Allocator) void {
        for (self.entries) |e| if (e.targets.len > 0) allocator.free(e.targets);
        allocator.free(self.entries);
        for (self.owned_strings) |s| allocator.free(s);
        allocator.free(self.owned_strings);
    }
};

/// tsconfig 의 paths 를 resolver 용 절대 경로 형태로 정규화한다.
/// - target.prefix 는 `<tsconfig_dir>/<baseUrl>/<prefix>` 를 `std.fs.path.resolve` 로 정리
/// - target.suffix 는 suffix 그대로 유지 (wildcard capture 뒤에 concat 되므로 절대화하지 않음)
/// - entry 의 key_prefix/suffix/has_wildcard 는 그대로 복사
pub fn resolveTsPaths(
    allocator: std.mem.Allocator,
    tsconfig_dir: []const u8,
    tsconfig: *const TsConfig,
) error{OutOfMemory}!ResolvedPaths {
    var out_entries: std.ArrayList(TsConfig.PathEntry) = .empty;
    errdefer out_entries.deinit(allocator);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    for (tsconfig.paths) |p| {
        var targets: std.ArrayList(TsConfig.PathEntry.Target) = .empty;
        errdefer targets.deinit(allocator);

        for (p.targets) |t| {
            // `path.resolve` 를 여기서 쓰면 target.prefix 끝의 `/` 가 날아가 capture 와
            // 붙을 때 경로 세그먼트 경계가 사라진다 (`"/foo/src/" + "greet"` → `"/foo/srcgreet"`).
            // → `path.join` 으로 절대화만 하고, 최종 candidate 는 resolver 가 합치며 normalize.
            const abs_prefix = if (tsconfig.base_url) |b|
                try std.fs.path.join(allocator, &.{ tsconfig_dir, b, t.prefix })
            else
                try std.fs.path.join(allocator, &.{ tsconfig_dir, t.prefix });
            try owned.append(allocator, abs_prefix);
            // t.suffix 도 dupe — TsConfig 원본 subspan 을 참조하면 TsConfig.deinit 후 dangle.
            const suffix_owned = try allocator.dupe(u8, t.suffix);
            try owned.append(allocator, suffix_owned);
            try targets.append(allocator, .{ .prefix = abs_prefix, .suffix = suffix_owned });
        }

        // key_prefix/suffix 도 TsConfig 의 문자열이므로 독립 수명으로 dupe.
        const kp_owned = try allocator.dupe(u8, p.key_prefix);
        try owned.append(allocator, kp_owned);
        const ks_owned = try allocator.dupe(u8, p.key_suffix);
        try owned.append(allocator, ks_owned);

        try out_entries.append(allocator, .{
            .key_prefix = kp_owned,
            .key_suffix = ks_owned,
            .has_wildcard = p.has_wildcard,
            .targets = try targets.toOwnedSlice(allocator),
        });
    }

    return .{
        .entries = try out_entries.toOwnedSlice(allocator),
        .owned_strings = try owned.toOwnedSlice(allocator),
    };
}

/// 경로가 `.json` 파일이면 상위 디렉토리를, 아니면 경로 자체를 반환한다.
/// CLI/NAPI 가 `-p`/`tsconfigPath` 로 파일과 디렉토리 둘 다 받을 때 공용으로 사용.
pub fn tsconfigDirFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, TSCONFIG_FILE_EXT))
        return std.fs.path.dirname(path) orelse ".";
    return path;
}

/// `compilerOptions.paths` JSON 객체 → `[]TsConfig.PathEntry`.
/// TS 스펙:
/// - key 는 `*` 한 개를 아무 위치에나 가질 수 있다. 둘 이상의 `*` 는 skip (ts(5073)).
/// - value 는 배열. 각 후보는 key 와 동일한 wildcard 유무를 가져야 함. 비대칭 후보는 skip.
/// - 후보 배열의 선언 순서가 resolver 의 시도 순서.
fn parsePathsObject(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
    allocated_strings: *std.ArrayList([]const u8),
) ![]const TsConfig.PathEntry {
    var list: std.ArrayList(TsConfig.PathEntry) = .empty;
    errdefer list.deinit(allocator);

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .array or val.array.items.len == 0) continue;

        const parsed_key = splitWildcard(key) orelse continue; // `*` 2 개 이상이면 null → skip
        const key_prefix_d = try dupeAndTrack(allocator, parsed_key.prefix, allocated_strings);
        const key_suffix_d = try dupeAndTrack(allocator, parsed_key.suffix, allocated_strings);

        var targets: std.ArrayList(TsConfig.PathEntry.Target) = .empty;
        errdefer targets.deinit(allocator);
        for (val.array.items) |v| {
            if (v != .string) continue;
            const parsed_t = splitWildcard(v.string) orelse continue;
            // key 와 wildcard 유무가 다르면 ts(5063) 에 해당 — 해당 후보만 skip.
            if (parsed_t.has_wildcard != parsed_key.has_wildcard) continue;
            const tp = try dupeAndTrack(allocator, parsed_t.prefix, allocated_strings);
            const ts = try dupeAndTrack(allocator, parsed_t.suffix, allocated_strings);
            try targets.append(allocator, .{ .prefix = tp, .suffix = ts });
        }
        if (targets.items.len == 0) {
            targets.deinit(allocator);
            continue;
        }

        try list.append(allocator, .{
            .key_prefix = key_prefix_d,
            .key_suffix = key_suffix_d,
            .has_wildcard = parsed_key.has_wildcard,
            .targets = try targets.toOwnedSlice(allocator),
        });
    }

    return list.toOwnedSlice(allocator);
}

/// 패턴을 첫 `*` 기준으로 prefix/suffix 로 나눈다. `*` 이 없으면 prefix = 전체, suffix = "".
/// `*` 이 둘 이상이면 null (ts(5073): "Pattern '...' can have at most one '*' character.").
fn splitWildcard(pattern: []const u8) ?struct {
    prefix: []const u8,
    suffix: []const u8,
    has_wildcard: bool,
} {
    const first_star = std.mem.indexOfScalar(u8, pattern, '*') orelse
        return .{ .prefix = pattern, .suffix = "", .has_wildcard = false };
    if (std.mem.indexOfScalarPos(u8, pattern, first_star + 1, '*') != null) return null;
    return .{
        .prefix = pattern[0..first_star],
        .suffix = pattern[first_star + 1 ..],
        .has_wildcard = true,
    };
}

/// 문자열을 dupe 하고 `allocated_strings` 에 등록해 나중에 일괄 해제되게 한다.
fn dupeAndTrack(
    allocator: std.mem.Allocator,
    s: []const u8,
    allocated_strings: *std.ArrayList([]const u8),
) ![]const u8 {
    const duped = try allocator.dupe(u8, s);
    try allocated_strings.append(allocator, duped);
    return duped;
}

/// JSON 객체에서 문자열 값을 복사(dupe)하여 반환한다.
/// 키가 없거나 값이 문자열이 아니면 null을 반환한다.
/// 복사된 문자열은 allocated_strings에 등록되어 deinit() 시 해제된다.
fn dupeJsonString(
    co: std.json.ObjectMap,
    key: []const u8,
    allocator: std.mem.Allocator,
    allocated_strings: *std.ArrayList([]const u8),
) !?[]const u8 {
    const v = co.get(key) orelse return null;
    if (v != .string) return null;
    return try dupeAndTrack(allocator, v.string, allocated_strings);
}

/// optional 문자열 merge: target이 null이고 base에 값이 있으면 복사.
/// extends 상속에서 사용.
fn mergeOptionalString(
    target_val: ?[]const u8,
    base_val: ?[]const u8,
    allocator: std.mem.Allocator,
    allocated_strings: *std.ArrayList([]const u8),
) !?[]const u8 {
    if (target_val != null) return target_val;
    const v = base_val orelse return null;
    const duped = try allocator.dupe(u8, v);
    try allocated_strings.append(allocator, duped);
    return duped;
}

/// JSONC (JSON with Comments)에서 주석을 제거한다.
///
/// tsconfig.json은 공식적으로 주석을 허용하는 JSONC 형식이다.
/// 지원하는 주석:
/// - 한 줄 주석: // ...
/// - 여러 줄 주석: /* ... */
///
/// 주석 영역을 공백으로 대체하여 원본과 동일한 길이를 유지한다.
/// (에러 위치 계산에 유용)
///
/// 반환된 슬라이스는 allocator로 할당되었으므로 호출자가 free해야 한다.
pub fn stripJsonComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // 입력을 복사한 후 주석 부분만 공백으로 대체한다.
    const output = try allocator.dupe(u8, input);
    errdefer allocator.free(output);

    var i: usize = 0;
    while (i < output.len) {
        // 문자열 안의 내용은 건너뛴다
        if (output[i] == '"') {
            i += 1; // opening quote
            while (i < output.len) {
                if (output[i] == '\\') {
                    i += 2; // escape sequence 건너뜀
                    continue;
                }
                if (output[i] == '"') {
                    i += 1; // closing quote
                    break;
                }
                i += 1;
            }
            continue;
        }

        // 한 줄 주석: // ... \n
        if (i + 1 < output.len and output[i] == '/' and output[i + 1] == '/') {
            while (i < output.len and output[i] != '\n') {
                output[i] = ' ';
                i += 1;
            }
            continue;
        }

        // 여러 줄 주석: /* ... */
        if (i + 1 < output.len and output[i] == '/' and output[i + 1] == '*') {
            output[i] = ' ';
            i += 1;
            output[i] = ' ';
            i += 1;
            while (i < output.len) {
                if (i + 1 < output.len and output[i] == '*' and output[i + 1] == '/') {
                    output[i] = ' ';
                    i += 1;
                    output[i] = ' ';
                    i += 1;
                    break;
                }
                // 개행 문자는 보존 (줄 번호 유지)
                if (output[i] != '\n' and output[i] != '\r') {
                    output[i] = ' ';
                }
                i += 1;
            }
            continue;
        }

        // trailing comma 제거: JSON은 trailing comma를 허용하지 않지만 tsconfig는 허용함
        // 간단한 처리: ,] 또는 ,} 패턴을 찾아 콤마를 공백으로 대체
        if (output[i] == ',') {
            // 콤마 뒤에 공백/개행을 건너뛴 후 ] 또는 }가 오면 trailing comma
            var j = i + 1;
            while (j < output.len and (output[j] == ' ' or output[j] == '\t' or output[j] == '\n' or output[j] == '\r')) {
                j += 1;
            }
            if (j < output.len and (output[j] == ']' or output[j] == '}')) {
                output[i] = ' '; // trailing comma를 공백으로
            }
        }

        i += 1;
    }

    return output;
}
