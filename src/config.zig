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

    /// "paths": `{ "@/*": ["./src/*"], "@utils": ["./utils/index.ts"] }` 형태의 매핑.
    /// 값 배열의 첫 항목만 사용 (TS 공식: 여러 후보는 순차 시도. ZTS 는 v1 에서 단일).
    /// wildcard `*` 는 prefix 매칭으로 변환되어 resolver 에 전달됨.
    paths: []const PathEntry = &.{},

    /// allocator로 할당된 문자열들을 해제하기 위한 참조.
    /// load()에서 내부적으로 사용하며, deinit() 시 해제된다.
    _allocator: ?std.mem.Allocator = null,
    /// 할당된 문자열 목록. deinit() 시 모두 free된다.
    _allocated_strings: ?std.ArrayList([]const u8) = null,

    /// "paths" 1 개 항목: key → 후보 경로 (첫 번째만 사용).
    pub const PathEntry = struct {
        from: []const u8,
        to: []const u8,
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
            // paths 슬라이스 자체는 allocator.alloc 으로 잡은 별도 메모리 (내부 문자열은
            // _allocated_strings 가 소유).
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
                const from_d = try allocator.dupe(u8, e.from);
                try target._allocated_strings.?.append(allocator, from_d);
                const to_d = try allocator.dupe(u8, e.to);
                try target._allocated_strings.?.append(allocator, to_d);
                duped[i] = .{ .from = from_d, .to = to_d };
            }
            target.paths = duped;
        }
    }
};

/// tsconfig `paths` 항목의 wildcard 를 prefix alias 로 정규화한다.
/// - `"@/*": "./src/*"` → `{from="@", to="./src"}` (prefix 매칭)
/// - `"@utils": "./utils"` → `{from="@utils", to="./utils"}` (정확 매칭)
/// - 한쪽만 wildcard 이거나 중간 wildcard 는 v1 에서 skip.
///
/// baseUrl 이 주어지면 상대경로 value 를 `<baseUrl>/<value>` 로 join 한다.
/// 반환된 슬라이스는 `allocator` 에 새로 할당됨 — caller 가 해제.
pub const NormalizedPaths = struct {
    entries: []const TsConfig.PathEntry,
    owned_strings: [][]const u8,

    pub fn deinit(self: *NormalizedPaths, allocator: std.mem.Allocator) void {
        for (self.owned_strings) |s| allocator.free(s);
        allocator.free(self.owned_strings);
        allocator.free(self.entries);
    }
};

pub fn normalizePathsToAliases(
    allocator: std.mem.Allocator,
    tsconfig_dir: []const u8,
    raw_paths: []const TsConfig.PathEntry,
    base_url: ?[]const u8,
) error{OutOfMemory}!NormalizedPaths {
    var out: std.ArrayList(TsConfig.PathEntry) = .empty;
    errdefer out.deinit(allocator);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    for (raw_paths) |p| {
        var from_src = p.from;
        var to_src = p.to;
        const from_wild = std.mem.endsWith(u8, from_src, "/*");
        const to_wild = std.mem.endsWith(u8, to_src, "/*");
        if (from_wild != to_wild) continue; // 불일치 wildcard 는 스킵
        if (from_wild) {
            from_src = from_src[0 .. from_src.len - 2];
            to_src = to_src[0 .. to_src.len - 2];
        }

        // from 문자열은 원본 TsConfig 의 subspan 이라 TsConfig 가 먼저 deinit 되면 dangle 된다.
        // owned_strings 로 복사해 alias 수명을 독립시킴.
        const from_owned = try allocator.dupe(u8, from_src);
        try owned.append(allocator, from_owned);

        // baseUrl 적용: to 가 상대경로면 <tsconfig_dir>/<baseUrl>/<to>.
        const resolved_to: []const u8 = if (std.fs.path.isAbsolute(to_src)) blk_abs: {
            // 절대 경로도 TsConfig subspan 이므로 복사.
            const abs_owned = try allocator.dupe(u8, to_src);
            try owned.append(allocator, abs_owned);
            break :blk_abs abs_owned;
        } else blk: {
            const base_dir = if (base_url) |b|
                try std.fs.path.join(allocator, &.{ tsconfig_dir, b })
            else
                try allocator.dupe(u8, tsconfig_dir);
            defer allocator.free(base_dir);
            const joined = try std.fs.path.join(allocator, &.{ base_dir, to_src });
            try owned.append(allocator, joined);
            break :blk joined;
        };

        try out.append(allocator, .{ .from = from_owned, .to = resolved_to });
    }

    return .{
        .entries = try out.toOwnedSlice(allocator),
        .owned_strings = try owned.toOwnedSlice(allocator),
    };
}

/// `compilerOptions.paths` JSON 객체 → `[]TsConfig.PathEntry`.
/// 값 배열의 첫 항목만 사용한다 (TS 공식은 여러 후보 순차 시도이나 ZTS v1 은 단일).
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
        const first = val.array.items[0];
        if (first != .string) continue;

        const key_d = try allocator.dupe(u8, key);
        try allocated_strings.append(allocator, key_d);
        const val_d = try allocator.dupe(u8, first.string);
        try allocated_strings.append(allocator, val_d);
        try list.append(allocator, .{ .from = key_d, .to = val_d });
    }

    return list.toOwnedSlice(allocator);
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
    const duped = try allocator.dupe(u8, v.string);
    try allocated_strings.append(allocator, duped);
    return duped;
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
