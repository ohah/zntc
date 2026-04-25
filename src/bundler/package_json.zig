//! ZTS Bundler — package.json 파서
//!
//! node_modules 패키지의 package.json을 파싱하여
//! 모듈 해석에 필요한 필드를 추출한다.
//!
//! 지원 필드:
//!   - name: 패키지 이름
//!   - main: CJS 엔트리포인트
//!   - module: ESM 엔트리포인트
//!   - exports: 조건부 exports (D064)
//!   - sideEffects: tree-shaking 힌트 (D063)
//!   - type: "module" | "commonjs"
//!
//! exports 필드 지원 범위 (Node.js 스펙 준수):
//!   - 문자열: "exports": "./index.js"
//!   - 조건 객체: "exports": { "import": "./esm.js", "require": "./cjs.js", "default": "./index.js" }
//!   - 서브패스: "exports": { ".": "./index.js", "./utils": "./utils.js" }
//!   - 와일드카드: "exports": { "./*": "./src/*.js" }
//!   - 중첩 조건: "exports": { ".": { "import": "./esm.js", "default": "./cjs.js" } }
//!
//! 참고:
//!   - https://nodejs.org/api/packages.html#conditional-exports
//!   - references/bun/src/resolver/package_json.zig
//!   - references/rolldown/crates/rolldown_resolver/src/resolver_config.rs

const std = @import("std");
const fs = @import("fs.zig");

/// package.json 필드명 / exports conditions 문자열 상수.
/// main_fields 순서 지정과 conditional exports 해석 양쪽에서 재사용된다.
/// 타입이 아닌 값이 typo되어도 컴파일 에러가 나지 않는 문제를 방지하기 위해
/// 리터럴 대신 이 상수를 쓴다.
pub const field = struct {
    pub const name: []const u8 = "name";
    pub const main: []const u8 = "main";
    pub const module: []const u8 = "module";
    pub const browser: []const u8 = "browser";
    pub const react_native: []const u8 = "react-native";
    pub const type_: []const u8 = "type";
    pub const exports_: []const u8 = "exports";
    pub const imports_: []const u8 = "imports";
};

pub const condition = struct {
    pub const import: []const u8 = "import";
    pub const require: []const u8 = "require";
    pub const default: []const u8 = "default";
    pub const node: []const u8 = "node";
    pub const browser: []const u8 = "browser";
    pub const module: []const u8 = "module";
    pub const react_native: []const u8 = "react-native";
};

pub const PackageJson = struct {
    name: ?[]const u8 = null,
    main: ?[]const u8 = null,
    module: ?[]const u8 = null,
    type_field: ?[]const u8 = null,
    exports: ?std.json.Value = null,
    imports: ?std.json.Value = null,
    /// "browser" 필드 (object 형태). 키: 상대 경로, 값: false 또는 대체 경로.
    /// platform=browser에서 파일 교체/비활성화에 사용.
    /// https://github.com/defunctzombie/package-browser-field-spec
    browser_map: ?std.json.Value = null,
    side_effects: SideEffects = .unknown,

    pub const SideEffects = union(enum) {
        unknown,
        all: bool,
        patterns: []const []const u8,

        /// allocator로 dupe된 패턴 문자열 해제. .all/.unknown은 no-op.
        pub fn deinit(self: SideEffects, allocator: std.mem.Allocator) void {
            switch (self) {
                .patterns => |patterns| {
                    for (patterns) |p| allocator.free(p);
                    allocator.free(patterns);
                },
                else => {},
            }
        }
    };

    /// package.json이 ESM 패키지인지 판별.
    pub fn isModule(self: *const PackageJson) bool {
        if (self.type_field) |t| {
            return std.mem.eql(u8, t, field.module);
        }
        return false;
    }
};

/// package.json 파일을 읽고 파싱한다.
/// 반환된 PackageJson의 문자열은 parsed JSON이 소유하므로
/// Parsed를 유지해야 한다 (caller가 deinit 관리).
pub const ParsedPackageJson = struct {
    pkg: PackageJson,
    parsed: std.json.Parsed(std.json.Value),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedPackageJson) void {
        self.pkg.side_effects.deinit(self.allocator);
        self.parsed.deinit();
    }
};

/// `pkg_dir_path` 디렉토리의 package.json 을 읽고 파싱한다. path 기반 시그니처로
/// fs.zig 추상화 통과 — std.fs.Dir 핸들 의존 제거 (#1921, #1885 Phase 1 완성).
pub fn parsePackageJson(allocator: std.mem.Allocator, pkg_dir_path: []const u8) !ParsedPackageJson {
    const json_path = try std.fs.path.join(allocator, &.{ pkg_dir_path, "package.json" });
    defer allocator.free(json_path);

    const loaded = fs.readFile(allocator, json_path, 1024 * 1024) catch |err| switch (err) {
        fs.FsError.NotFound => return error.FileNotFound,
        fs.FsError.OutOfMemory => return error.OutOfMemory,
        // PermissionDenied / IoError / NotDirectory / IsDirectory 모두 IoError 로 통합 —
        // caller (resolver/graph) 는 이미 catch 후 null 반환 패턴이라 silent fallback. 단
        // OutOfMemory 만은 분리해 silent swallow 방지.
        else => return error.IoError,
    };
    defer allocator.free(loaded.contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, loaded.contents, .{}) catch
        return error.JsonParseError;

    const root = parsed.value;
    if (root != .object) {
        var p = parsed;
        p.deinit();
        return error.JsonParseError;
    }

    const obj = root.object;

    // "browser" 필드: object 형태만 browser_map으로 저장 (경로별 매핑/비활성화용).
    // string 형태("browser": "lib/browser.js")는 main 대체로 사용 — resolveByMainFields가
    // main_fields 순서에 따라 getStr(obj, field.browser)로 읽으므로 별도 필드 저장 불필요.
    const browser_map: ?std.json.Value = if (obj.get(field.browser)) |b| switch (b) {
        .object => b,
        else => null,
    } else null;

    return .{
        .pkg = .{
            .name = getStr(obj, field.name),
            .main = getStr(obj, field.main),
            .module = getStr(obj, field.module),
            .type_field = getStr(obj, field.type_),
            .exports = obj.get(field.exports_),
            .imports = obj.get(field.imports_),
            .browser_map = browser_map,
            .side_effects = parseSideEffects(obj, allocator),
        },
        .parsed = parsed,
        .allocator = allocator,
    };
}

/// exports 필드에서 조건에 맞는 경로를 찾는다.
/// subpath: "." (패키지 루트) 또는 "./utils" 등
/// conditions: ["import", "default"] 등 (D064)
/// exports 필드에서 조건에 맞는 경로를 찾는다.
/// 와일드카드 치환이 필요한 경우 allocator로 새 문자열을 할당.
/// 반환된 문자열이 allocated인지 여부는 caller가 판별해야 함 — allocated_result로 반환.
pub const ExportsResult = struct {
    path: []const u8,
    allocated: bool,
};

pub fn resolveExports(
    allocator: std.mem.Allocator,
    exports: std.json.Value,
    subpath: []const u8,
    conditions: []const []const u8,
) ?ExportsResult {
    switch (exports) {
        .string => |s| {
            if (std.mem.eql(u8, subpath, ".")) return .{ .path = s, .allocated = false };
            return null;
        },
        .object => |obj| {
            if (isSubpathMap(obj)) {
                return resolveSubpathMap(allocator, obj, subpath, conditions);
            }
            if (std.mem.eql(u8, subpath, ".")) {
                if (resolveConditions(exports, conditions)) |path| {
                    return .{ .path = path, .allocated = false };
                }
            }
            return null;
        },
        else => return null,
    }
}

/// imports 필드에서 `#specifier`에 맞는 경로를 찾는다.
/// Node.js subpath imports: package.json "imports" 필드로 패키지 내부 import 매핑.
/// 정확한 매칭 + 와일드카드는 resolveSubpathMap과 동일 로직 (재사용).
/// https://nodejs.org/api/packages.html#subpath-imports
pub fn resolveImports(
    allocator: std.mem.Allocator,
    imports: std.json.Value,
    specifier: []const u8,
    conditions: []const []const u8,
) ?ExportsResult {
    switch (imports) {
        .object => |obj| return resolveSubpathMap(allocator, obj, specifier, conditions),
        else => return null,
    }
}

/// 서브패스 맵에서 매칭되는 엔트리를 찾는다.
/// 정확한 매칭 먼저, 와일드카드 매칭 나중.
fn resolveSubpathMap(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    subpath: []const u8,
    conditions: []const []const u8,
) ?ExportsResult {
    // 1. 정확한 매칭
    if (obj.get(subpath)) |value| {
        if (resolveConditions(value, conditions)) |path| {
            return .{ .path = path, .allocated = false };
        }
    }

    // 2. 와일드카드 매칭 (./* 패턴)
    var it = obj.iterator();
    while (it.next()) |entry| {
        const pattern = entry.key_ptr.*;
        if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
            const prefix = pattern[0..star_pos];
            const suffix = pattern[star_pos + 1 ..];

            if (subpath.len >= prefix.len + suffix.len and
                std.mem.startsWith(u8, subpath, prefix) and
                std.mem.endsWith(u8, subpath, suffix))
            {
                const matched = subpath[prefix.len .. subpath.len - suffix.len];
                const resolved = resolveConditions(entry.value_ptr.*, conditions) orelse continue;

                // 결과에서 * 를 매칭된 부분으로 치환
                if (std.mem.indexOf(u8, resolved, "*")) |res_star| {
                    const before = resolved[0..res_star];
                    const after = resolved[res_star + 1 ..];
                    const substituted = std.mem.concat(allocator, u8, &.{ before, matched, after }) catch return null;
                    return .{ .path = substituted, .allocated = true };
                }
                return .{ .path = resolved, .allocated = false };
            }
        }
    }

    return null;
}

/// 조건 객체, 문자열, 또는 폴백 배열에서 매칭되는 경로를 찾는다.
/// conditions 순서대로 매칭 (첫 번째 매칭이 승리).
/// 배열(fallback array)은 Node.js 스펙에서 지원하며, 순서대로 시도하여 첫 번째 성공을 반환한다.
/// 예: "./shams": [{"types":"./shams.d.ts","default":"./shams.js"}, "./shams.js"]
fn resolveConditions(value: std.json.Value, conditions: []const []const u8) ?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .object => |obj| {
            // Node.js 스펙: exports 객체의 key 순서로 탐색하고,
            // 각 key가 conditions set에 포함되는지 확인한다.
            // (이전: conditions 배열 순서로 탐색 → tslib import.node 오매칭)
            for (obj.keys()) |key| {
                if (std.mem.eql(u8, key, "default")) continue; // default는 마지막
                for (conditions) |cond| {
                    if (std.mem.eql(u8, key, cond)) {
                        if (resolveConditions(obj.get(key).?, conditions)) |result| {
                            return result;
                        }
                        break;
                    }
                }
            }
            // "default"는 항상 마지막 폴백 (Node.js 스펙)
            if (obj.get("default")) |v| {
                return resolveConditions(v, conditions);
            }
            return null;
        },
        .array => |arr| {
            // 폴백 배열: 각 요소를 순서대로 시도, 첫 번째 매칭 반환
            for (arr.items) |item| {
                if (resolveConditions(item, conditions)) |result| {
                    return result;
                }
            }
            return null;
        },
        else => return null,
    }
}

/// exports 맵의 키가 "."으로 시작하는지 확인 (서브패스 맵 판별).
pub fn isSubpathMap(obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    if (it.next()) |entry| {
        return std.mem.startsWith(u8, entry.key_ptr.*, ".");
    }
    return false;
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn parseSideEffects(obj: std.json.ObjectMap, allocator: std.mem.Allocator) PackageJson.SideEffects {
    const val = obj.get("sideEffects") orelse return .unknown;
    switch (val) {
        .bool => |b| return .{ .all = b },
        .array => |arr| {
            // ["*.css", "./src/polyfill.js"] — 문자열 배열.
            // 빈 배열은 sideEffects: false와 동일.
            if (arr.items.len == 0) return .{ .all = false };
            // allocator로 패턴을 dupe — JSON parse tree 해제 후에도 유효.
            const patterns = allocator.alloc([]const u8, arr.items.len) catch return .unknown;
            for (arr.items, 0..) |item, i| {
                if (item != .string) {
                    for (patterns[0..i]) |p| allocator.free(p);
                    allocator.free(patterns);
                    return .unknown;
                }
                patterns[i] = allocator.dupe(u8, item.string) catch {
                    for (patterns[0..i]) |p| allocator.free(p);
                    allocator.free(patterns);
                    return .unknown;
                };
            }
            return .{ .patterns = patterns };
        },
        else => return .unknown,
    }
}

pub const Error = error{
    FileNotFound,
    JsonParseError,
    OutOfMemory,
};
