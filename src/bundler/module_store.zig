//! 모듈 파싱 캐시 — 증분 빌드용
//!
//! 변경 안 된 모듈의 파싱 결과(AST, semantic, import_records 등)를
//! 빌드 간 보존하여 재파싱을 스킵한다.
//! Module.parse_arena가 데이터를 소유하므로, arena 소유권 이전으로 캐시를 구현.

const std = @import("std");
const Module = @import("module.zig").Module;
const types = @import("types.zig");

pub const PersistentModuleStore = struct {
    allocator: std.mem.Allocator,
    /// 절대 경로 → 캐시된 모듈. 경로 키는 store allocator 소유.
    modules: std.StringHashMap(CachedModule),

    pub const CachedModule = struct {
        /// 캐싱 시점의 파일 mtime (i128 나노초)
        mtime: i128,
        /// Module 구조체. parse_arena 포함.
        /// store가 소유 — graph에 주입 시 parse_arena 소유권을 이전하고 null로 설정.
        module: Module,
        /// import specifier 목록 (store allocator 소유). import 변경 감지용.
        import_specifiers: []const []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) PersistentModuleStore {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(CachedModule).init(allocator),
        };
    }

    pub fn deinit(self: *PersistentModuleStore) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.freeCachedModule(entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.modules.deinit();
    }

    fn freeCachedModule(self: *PersistentModuleStore, cached: *CachedModule) void {
        // parse_arena가 아직 store에 있으면 해제
        if (cached.module.parse_arena) |*arena| arena.deinit();
        // dependencies/importers/dynamic_imports ArrayList 해제
        cached.module.dependencies.deinit(self.allocator);
        cached.module.importers.deinit(self.allocator);
        cached.module.dynamic_imports.deinit(self.allocator);
        // import_specifiers 해제
        for (cached.import_specifiers) |s| self.allocator.free(s);
        self.allocator.free(cached.import_specifiers);
    }

    /// 캐시에서 모듈을 조회. mtime이 일치하면 캐시 히트.
    pub fn getIfFresh(self: *PersistentModuleStore, path: []const u8, current_mtime: i128) ?*CachedModule {
        const cached = self.modules.getPtr(path) orelse return null;
        if (cached.mtime != current_mtime) return null;
        return cached;
    }

    /// 빌드 완료 후 모듈을 캐시에 저장.
    /// Module의 parse_arena 소유권을 store로 이전 (Module.parse_arena = null 설정).
    pub fn putModule(self: *PersistentModuleStore, path: []const u8, module: *Module, mtime: i128) void {
        // import specifiers 복제 (store allocator 소유)
        const specs = self.extractImportSpecifiers(module) catch return;

        // 기존 캐시가 있으면 제거
        const had_existing = self.modules.contains(path);
        if (had_existing) {
            if (self.modules.getPtr(path)) |old| {
                self.freeCachedModule(old);
            }
        }

        // Module 복사 — parse_arena 소유권 이전
        var cached_module = module.*;
        // dependencies/importers/dynamic_imports를 빈 상태로 — graph deinit에서 원본이 해제되므로
        cached_module.dependencies = .empty;
        cached_module.importers = .empty;
        cached_module.dynamic_imports = .empty;

        // parse_arena 소유권 이전: module → store
        module.parse_arena = null;

        if (had_existing) {
            // 기존 키 재사용 — put은 값만 업데이트
            self.modules.put(path, .{
                .mtime = mtime,
                .module = cached_module,
                .import_specifiers = specs,
            }) catch {
                if (cached_module.parse_arena) |*a| a.deinit();
                for (specs) |s| self.allocator.free(s);
                self.allocator.free(specs);
            };
        } else {
            const key = self.allocator.dupe(u8, path) catch {
                if (cached_module.parse_arena) |*a| a.deinit();
                for (specs) |s| self.allocator.free(s);
                self.allocator.free(specs);
                return;
            };

            self.modules.put(key, .{
                .mtime = mtime,
                .module = cached_module,
                .import_specifiers = specs,
            }) catch {
                self.allocator.free(key);
                if (cached_module.parse_arena) |*a| a.deinit();
                for (specs) |s| self.allocator.free(s);
                self.allocator.free(specs);
            };
        }
    }

    fn extractImportSpecifiers(self: *PersistentModuleStore, module: *const Module) ![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| self.allocator.free(s);
            list.deinit(self.allocator);
        }
        for (module.import_records) |rec| {
            const dupe = try self.allocator.dupe(u8, rec.specifier);
            try list.append(self.allocator, dupe);
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// 캐시된 모듈의 import specifiers가 새 모듈과 동일한지 확인.
    pub fn importsChanged(_: *const PersistentModuleStore, cached: *const CachedModule, new_module: *const Module) bool {
        if (cached.import_specifiers.len != new_module.import_records.len) return true;
        for (cached.import_specifiers, new_module.import_records) |old_spec, new_rec| {
            if (!std.mem.eql(u8, old_spec, new_rec.specifier)) return true;
        }
        return false;
    }
};
