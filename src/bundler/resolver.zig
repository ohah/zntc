//! ZTS Bundler — Module Resolver
//!
//! import 경로를 절대 파일 경로로 해석한다 (D081 Layer 1).
//! 상대 경로(`./`, `../`)와 절대 경로를 처리.
//! bare specifier (node_modules)는 PR #4에서 추가.
//!
//! 해석 알고리즘 (D064):
//!   1. 경로 조합 (source_dir + specifier)
//!   2. 정확한 파일 존재 확인
//!   3. 확장자 추가: .ts, .tsx, .js, .jsx, .json
//!   4. TS 확장자 매핑: .js → .ts/.tsx (Rolldown 방식)
//!   5. 디렉토리 index: dir/index.ts, dir/index.tsx, dir/index.js
//!   6. 없으면 ModuleNotFound
//!
//! 참고:
//!   - references/esbuild/internal/resolver/resolver.go
//!   - references/rolldown/crates/rolldown_resolver/src/resolver.rs
//!   - references/bun/src/resolver/resolver.zig

const std = @import("std");
const types = @import("types.zig");
const ModuleType = types.ModuleType;
const pkg_json = @import("package_json.zig");
const PackageJson = pkg_json.PackageJson;

pub const ResolveResult = struct {
    /// 해석된 절대 파일 경로
    path: []const u8,
    /// 확장자에서 추론한 모듈 타입
    module_type: ModuleType,
    /// package.json "browser" 필드에서 false로 매핑된 파일.
    /// platform=browser에서 빈 CJS 모듈로 대체한다 (esbuild "(disabled)" 방식).
    disabled: bool = false,
    /// package.json "module" 필드를 통해 resolve된 파일.
    /// .js 확장자라도 ESM으로 파싱해야 함.
    is_module_field: bool = false,
};

pub const ResolveError = error{
    ModuleNotFound,
    OutOfMemory,
};

/// 기본 확장자 탐색 순서.
/// TypeScript 확장자가 먼저 (TS 프로젝트에서 .ts가 .js보다 우선).
/// .mts/.cts는 ESM/CJS 모듈 전용 TypeScript 확장자.
const default_extensions: []const []const u8 = &.{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".json" };

/// TS 확장자 매핑 (D064).
/// import './foo.js'가 실제로 ./foo.ts를 가리킬 수 있음.
const ts_extension_map: []const struct { from: []const u8, to: []const []const u8 } = &.{
    .{ .from = ".js", .to = &.{ ".ts", ".tsx" } },
    .{ .from = ".jsx", .to = &.{".tsx"} },
    .{ .from = ".mjs", .to = &.{".mts"} },
    .{ .from = ".cjs", .to = &.{".cts"} },
};

/// index 파일 탐색 순서 (디렉토리 해석 시).
const index_files: []const []const u8 = &.{ "index.ts", "index.tsx", "index.js", "index.jsx" };

pub const AliasEntry = types.AliasEntry;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    /// 조건 세트 (D064: import kind별로 다를 수 있음).
    /// ResolveCache.conditionsFor()에서 platform+kind별로 설정.
    /// 기본값은 테스트용 (브라우저 ESM).
    conditions: []const []const u8 = &.{ "import", "module", "browser", "default" },
    /// symlink를 따라가지 않고 링크 자체 경로로 해석 (--preserve-symlinks).
    /// true이면 makeResult()에서 realpathAlloc 대신 allocator.dupe 사용.
    preserve_symlinks: bool = false,
    /// import 경로 별칭 (--alias:K=V). resolve 시 specifier 앞부분을 치환.
    /// 정확 매칭: "react" → "preact/compat"
    /// 접두사 매칭: "react/hooks" → "preact/compat/hooks"
    alias: []const AliasEntry = &.{},
    /// 커스텀 확장자 탐색 순서 (--resolve-extensions). 비어있으면 default_extensions 사용.
    /// RN 예: .ios.ts, .ios.tsx, .native.ts, .native.tsx, .ts, .tsx, .js, .jsx, .json
    custom_extensions: []const []const u8 = &.{},
    /// package.json 필드 해석 순서 (--main-fields). 비어있으면 기본 순서 (module → main).
    /// RN 예: react-native, browser, main, module
    main_fields: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    /// alias 규칙을 specifier에 적용한다.
    /// 정확 매칭: specifier == entry.from → entry.to
    /// 접두사 매칭: specifier가 entry.from + "/" 로 시작 → entry.to + 나머지
    /// 매칭 없으면 null 반환. 반환값은 allocator 소유 (호출자가 해제).
    pub fn applyAlias(allocator: std.mem.Allocator, alias_entries: []const AliasEntry, specifier: []const u8) error{OutOfMemory}!?[]const u8 {
        for (alias_entries) |entry| {
            // 정확 매칭
            if (std.mem.eql(u8, specifier, entry.from)) {
                return try allocator.dupe(u8, entry.to);
            }
            // 접두사 매칭: specifier가 "from/" 로 시작
            if (specifier.len > entry.from.len and
                std.mem.startsWith(u8, specifier, entry.from) and
                specifier[entry.from.len] == '/')
            {
                const suffix = specifier[entry.from.len..]; // "/hooks" 등
                var result = try allocator.alloc(u8, entry.to.len + suffix.len);
                @memcpy(result[0..entry.to.len], entry.to);
                @memcpy(result[entry.to.len..], suffix);
                return result;
            }
        }
        return null;
    }

    pub fn resolve(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // alias 치환 (resolve 맨 처음에 적용, esbuild 동작과 동일)
        const effective_specifier = if (self.alias.len > 0)
            (applyAlias(self.allocator, self.alias, specifier) catch return error.OutOfMemory) orelse specifier
        else
            specifier;
        defer if (self.alias.len > 0 and effective_specifier.ptr != specifier.ptr)
            self.allocator.free(effective_specifier);

        // #specifier → package.json "imports" 필드 (Node.js subpath imports)
        if (effective_specifier.len > 0 and effective_specifier[0] == '#') {
            return self.resolveSubpathImports(source_dir, effective_specifier);
        }

        // bare specifier → node_modules 탐색
        if (!isRelativeOrAbsolute(effective_specifier)) {
            return self.resolveNodeModules(source_dir, effective_specifier);
        }

        // 경로 조합
        const joined = std.fs.path.resolve(self.allocator, &.{ source_dir, effective_specifier }) catch
            return error.OutOfMemory;
        defer self.allocator.free(joined);

        // 1. 정확한 경로가 파일로 존재하는지
        if (self.fileExists(joined)) {
            return (try self.makeResult(joined)).?;
        }

        // 2. 확장자 추가 탐색 (.ts, .tsx, .js, .jsx, .json)
        if (try self.tryExtensions(joined)) |result| {
            return result;
        }

        // 3. TS 확장자 매핑 (./foo.js → ./foo.ts, ./foo.tsx)
        if (try self.tryTsExtensionMapping(joined)) |result| {
            return result;
        }

        // 4. 디렉토리 index 탐색 (./dir → ./dir/index.ts)
        if (try self.tryDirectoryIndex(joined)) |result| {
            return result;
        }

        return error.ModuleNotFound;
    }

    /// 확장자를 하나씩 붙여서 존재하는 파일을 찾는다.
    /// custom_extensions가 설정되어 있으면 그것을 사용, 아니면 default_extensions.
    fn tryExtensions(self: *Resolver, base: []const u8) ResolveError!?ResolveResult {
        const extensions = if (self.custom_extensions.len > 0) self.custom_extensions else default_extensions;
        for (extensions) |ext| {
            const path = std.mem.concat(self.allocator, u8, &.{ base, ext }) catch
                return error.OutOfMemory;
            defer self.allocator.free(path);

            if (self.fileExists(path)) {
                return self.makeResult(path);
            }
        }
        return null;
    }

    /// TS 확장자 매핑: .js → .ts/.tsx 등.
    /// import './foo.js' 했는데 foo.js는 없고 foo.ts가 있으면 foo.ts로 해석.
    fn tryTsExtensionMapping(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        const ext = std.fs.path.extension(path);
        for (ts_extension_map) |mapping| {
            if (std.mem.eql(u8, ext, mapping.from)) {
                // 확장자를 벗기고 대체 확장자를 붙임
                const base = path[0 .. path.len - ext.len];
                for (mapping.to) |to_ext| {
                    const mapped = std.mem.concat(self.allocator, u8, &.{ base, to_ext }) catch
                        return error.OutOfMemory;
                    defer self.allocator.free(mapped);

                    if (self.fileExists(mapped)) {
                        return self.makeResult(mapped);
                    }
                }
                break;
            }
        }
        return null;
    }

    /// 디렉토리인 경우 index 파일을 탐색한다.
    fn tryDirectoryIndex(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        // path가 디렉토리인지 확인
        if (!self.dirExists(path)) return null;

        // 디렉토리 내 package.json의 main/module 필드 확인 (서브패스 package.json 패턴)
        // 예: fp-ts/function/package.json → { "main": "../lib/function.js", "module": "../es6/function.js" }
        if (try self.tryDirectoryPackageJson(path)) |result| return result;

        const extensions = if (self.custom_extensions.len > 0) self.custom_extensions else default_extensions;
        for (extensions) |ext| {
            const index_name = std.mem.concat(self.allocator, u8, &.{ "index", ext }) catch
                return error.OutOfMemory;
            defer self.allocator.free(index_name);
            const index_path = std.fs.path.resolve(self.allocator, &.{ path, index_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(index_path);
            if (self.fileExists(index_path)) return self.makeResult(index_path);
        }
        return null;
    }

    /// 디렉토리 내 package.json에서 module/main 필드를 읽어 resolve 시도.
    /// fp-ts 등에서 사용하는 서브패스 package.json 패턴 지원.
    fn tryDirectoryPackageJson(self: *Resolver, dir_path: []const u8) ResolveError!?ResolveResult {
        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return null;
        defer dir.close();

        var parsed = pkg_json.parsePackageJson(self.allocator, dir) catch return null;
        defer parsed.deinit();

        return self.resolveByMainFields(&parsed, dir_path);
    }

    /// package.json의 main_fields 또는 기본 순서(module → main)로 엔트리포인트를 찾는다.
    /// resolvePackage와 tryDirectoryPackageJson에서 공용.
    fn resolveByMainFields(self: *Resolver, parsed: *pkg_json.ParsedPackageJson, base_dir: []const u8) ResolveError!?ResolveResult {
        if (self.main_fields.len > 0) {
            const obj = parsed.parsed.value.object;
            for (self.main_fields) |field| {
                if (pkg_json.getStr(obj, field)) |value| {
                    const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, value }) catch
                        return error.OutOfMemory;
                    defer self.allocator.free(abs_path);
                    if (self.fileExists(abs_path)) {
                        var result = (try self.makeResult(abs_path)) orelse return null;
                        result.is_module_field = std.mem.eql(u8, field, "module");
                        return result;
                    }
                    if (try self.tryExtensions(abs_path)) |result| return result;
                }
            }
        } else {
            const pkg = &parsed.pkg;
            if (pkg.module) |mod| {
                const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, mod }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);
                if (self.fileExists(abs_path)) {
                    var result = (try self.makeResult(abs_path)) orelse return null;
                    result.is_module_field = true;
                    return result;
                }
            }
            if (pkg.main) |main| {
                const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, main }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);
                if (self.fileExists(abs_path)) return self.makeResult(abs_path);
                if (try self.tryExtensions(abs_path)) |result| return result;
            }
        }

        return null;
    }

    /// bare specifier를 node_modules에서 탐색한다.
    /// source_dir에서 시작하여 상위 디렉토리로 올라가며 node_modules/<pkg>를 찾는다.
    fn resolveNodeModules(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // 패키지 이름과 서브패스 분리: "@scope/pkg/utils" → ("@scope/pkg", "./utils")
        const split = splitBareSpecifier(specifier);
        const pkg_name = split.pkg_name;
        const subpath = split.subpath;

        // 상위 디렉토리로 올라가며 node_modules 탐색
        var current_dir = source_dir;
        while (true) {
            // node_modules/<pkg>/package.json 시도
            const pkg_dir_path = std.fs.path.resolve(self.allocator, &.{ current_dir, "node_modules", pkg_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(pkg_dir_path);

            if (self.dirExists(pkg_dir_path)) {
                if (try self.resolvePackage(pkg_dir_path, subpath)) |result| {
                    return result;
                }
            }

            // 상위 디렉토리로 이동
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break; // 루트 도달
            current_dir = parent;
        }

        return error.ModuleNotFound;
    }

    /// 패키지 디렉토리에서 엔트리포인트를 해석한다.
    /// 우선순위: exports → module → main → index 파일
    fn resolvePackage(self: *Resolver, pkg_dir_path: []const u8, subpath: []const u8) ResolveError!?ResolveResult {
        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return null;
        defer pkg_dir.close();

        // package.json 파싱 시도
        var parsed = pkg_json.parsePackageJson(self.allocator, pkg_dir) catch |err| switch (err) {
            error.FileNotFound => {
                // package.json 없으면 index 파일 탐색
                return self.tryDirectoryIndex(pkg_dir_path);
            },
            else => return null,
        };
        defer parsed.deinit();

        const pkg = &parsed.pkg;

        // 1. exports 필드 (D064)
        // subpath: "." 또는 "/sub" → exports 매칭용 "." 또는 "./sub"
        const allocated_subpath: ?[]const u8 = if (std.mem.eql(u8, subpath, "."))
            null
        else
            std.mem.concat(self.allocator, u8, &.{ ".", subpath }) catch return error.OutOfMemory;
        defer if (allocated_subpath) |buf| self.allocator.free(buf);
        const exports_subpath = allocated_subpath orelse subpath;

        if (pkg.exports) |exports| {
            if (pkg_json.resolveExports(self.allocator, exports, exports_subpath, self.conditions)) |exports_result| {
                defer if (exports_result.allocated) self.allocator.free(exports_result.path);
                const abs_path = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, exports_result.path }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);

                if (self.fileExists(abs_path)) {
                    return self.makeResult(abs_path);
                }
                // exports가 가리키는 파일이 없으면 확장자 탐색
                if (try self.tryExtensions(abs_path)) |result| return result;
            }
            // exports가 있는데 매칭 안 되면 다른 필드로 폴백하지 않음 (Node.js 스펙)
            if (!std.mem.eql(u8, subpath, ".")) return null;
        }

        // 서브패스가 있으면 패키지 내부 파일 직접 해석
        // subpath는 "/shams" 형태 (leading /) — resolve()는 절대 경로로 취급하므로
        // leading /를 제거하여 상대 경로로 만든다.
        if (!std.mem.eql(u8, subpath, ".")) {
            const relative_subpath = if (subpath.len > 0 and subpath[0] == '/') subpath[1..] else subpath;
            const sub_file = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, relative_subpath }) catch
                return error.OutOfMemory;
            defer self.allocator.free(sub_file);

            if (self.fileExists(sub_file)) return self.makeResult(sub_file);
            if (try self.tryExtensions(sub_file)) |result| return result;
            if (try self.tryTsExtensionMapping(sub_file)) |result| return result;
            if (try self.tryDirectoryIndex(sub_file)) |result| return result;
            return null;
        }

        if (try self.resolveByMainFields(&parsed, pkg_dir_path)) |result| return result;

        // 4. index 파일 폴백
        return self.tryDirectoryIndex(pkg_dir_path);
    }

    /// Node.js subpath imports: `#specifier`를 package.json "imports" 필드에서 해석한다.
    /// source_dir에서 시작하여 상위 디렉토리로 올라가며 "imports" 필드가 있는 package.json을 찾는다.
    /// https://nodejs.org/api/packages.html#subpath-imports
    fn resolveSubpathImports(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        var current_dir = source_dir;
        while (true) {
            // package.json 찾기
            var dir = std.fs.cwd().openDir(current_dir, .{}) catch break;
            defer dir.close();

            if (pkg_json.parsePackageJson(self.allocator, dir)) |*parsed_result| {
                var parsed = parsed_result.*;
                defer parsed.deinit();

                if (parsed.pkg.imports) |imports| {
                    if (pkg_json.resolveImports(self.allocator, imports, specifier, self.conditions)) |imports_result| {
                        defer if (imports_result.allocated) self.allocator.free(imports_result.path);

                        // imports 결과는 패키지 디렉토리 기준 상대 경로
                        const abs_path = std.fs.path.resolve(self.allocator, &.{ current_dir, imports_result.path }) catch
                            return error.OutOfMemory;
                        defer self.allocator.free(abs_path);

                        if (self.fileExists(abs_path)) {
                            return (try self.makeResult(abs_path)).?;
                        }
                        // 확장자 탐색
                        if (try self.tryExtensions(abs_path)) |result| return result;
                        if (try self.tryTsExtensionMapping(abs_path)) |result| return result;
                        if (try self.tryDirectoryIndex(abs_path)) |result| return result;
                    }
                }
            } else |_| {}

            // 상위 디렉토리로 이동
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break;
            current_dir = parent;
        }

        return error.ModuleNotFound;
    }

    fn makeResult(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        // preserve_symlinks=true이면 symlink를 따라가지 않고 경로 그대로 사용.
        // 기본(false)이면 bun(.bun/)과 pnpm(.pnpm/)의 symlink를 realpath로 해석하여
        // 중첩 node_modules 탐색이 올바른 계층에서 동작하도록 한다.
        const resolved = if (self.preserve_symlinks)
            self.allocator.dupe(u8, path) catch return error.OutOfMemory
        else
            std.fs.cwd().realpathAlloc(self.allocator, path) catch
                self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        const ext = std.fs.path.extension(resolved);
        return .{
            .path = resolved,
            .module_type = ModuleType.fromExtension(ext),
        };
    }

    fn fileExists(_: *const Resolver, path: []const u8) bool {
        const stat = std.fs.cwd().statFile(path) catch return false;
        return stat.kind == .file;
    }

    fn dirExists(_: *const Resolver, path: []const u8) bool {
        var dir = std.fs.cwd().openDir(path, .{}) catch return false;
        dir.close();
        return true;
    }
};

/// specifier가 상대 경로(`./`, `../`) 또는 절대 경로(`/`)인지 판별.
pub fn isRelativeOrAbsolute(specifier: []const u8) bool {
    if (specifier.len == 0) return false;
    if (specifier[0] == '/') return true;
    // "./" — 현재 디렉토리 상대
    if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '/') return true;
    // "../" — 상위 디렉토리 상대. ".." 뒤에 / 또는 끝이어야 함 ("..foo"는 bare specifier)
    if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '.') {
        if (specifier.len == 2) return true; // ".." 그 자체
        if (specifier[2] == '/') return true; // "../..."
    }
    return false;
}

/// bare specifier를 패키지 이름과 서브패스로 분리한다.
/// "react" → ("react", ".")
/// "react/jsx-runtime" → ("react", "./jsx-runtime")
/// "@mui/material" → ("@mui/material", ".")
/// "@mui/material/Button" → ("@mui/material", "./Button")
const BareSpecifierSplit = struct {
    pkg_name: []const u8,
    subpath: []const u8,
};

pub fn splitBareSpecifier(specifier: []const u8) BareSpecifierSplit {
    if (specifier.len == 0) return .{ .pkg_name = specifier, .subpath = "." };

    // scoped package: @scope/name/subpath
    if (specifier[0] == '@') {
        if (std.mem.indexOfScalar(u8, specifier, '/')) |first_slash| {
            // 두 번째 / 를 찾으면 그 뒤가 서브패스
            if (std.mem.indexOfScalarPos(u8, specifier, first_slash + 1, '/')) |second_slash| {
                return .{
                    .pkg_name = specifier[0..second_slash],
                    .subpath = specifier[second_slash..],
                };
            }
        }
        return .{ .pkg_name = specifier, .subpath = "." };
    }

    // 일반 패키지: name/subpath
    if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| {
        return .{
            .pkg_name = specifier[0..slash],
            .subpath = specifier[slash..],
        };
    }

    return .{ .pkg_name = specifier, .subpath = "." };
}
