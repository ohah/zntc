const std = @import("std");
const assets_mod = @import("graph/assets.zig");

/// plugin `this.emitFile({ type: 'asset', fileName | name, source })` 로 emit 된 단일 asset.
/// 세 필드 모두 `EmitStore.allocator` 소유 — `EmitStore.deinit` 이 일괄 해제한다.
pub const EmittedAsset = struct {
    /// `this.emitFile` 이 plugin 에 돌려준 reference id ("asset-N").
    reference_id: []const u8,
    /// 출력 파일명. 명시 fileName 또는 name-only 시 source hash 로 자동 생성된 이름.
    file_name: []const u8,
    /// asset 내용 (binary-safe).
    source: []const u8,
};

/// plugin `this.emitFile({ type: 'chunk', id, name? })` 로 emit 된 chunk 요청 (#1880 PR7-2).
/// asset 과 달리 `id`(모듈 specifier)를 resolve→load→parse 해 새 entry chunk 로 graph 에 주입해야
/// 한다. **PR7-2a 는 요청 수집 자료구조만** — 실제 graph 주입/청킹은 PR7-2b, 파일명 lazy 확정은
/// PR7-2c. 두 필드 모두 `EmitStore.allocator` 소유.
pub const EmittedChunk = struct {
    /// `this.emitFile` 이 plugin 에 돌려준 reference id ("chunk-N").
    reference_id: []const u8,
    /// resolve 대상 모듈 specifier (entry 로 추가될 모듈).
    id: []const u8,
    /// chunk 이름(옵션) — 파일명 패턴 `[name]` 치환용. null 이면 id stem 기반.
    name: ?[]const u8 = null,
    /// 최종 출력 파일명 (#1880 PR7-2c). 명시 fileName 이면 emit 시 즉시 set(hash 없음);
    /// name/auto 면 청킹+렌더 후 bundler 가 back-fill([name]-[hash] 확정). getFileName 이 read.
    file_name: ?[]const u8 = null,
};

/// plugin `this.emitFile` 수집소 (#1880 PR5).
///
/// **메인 스레드에서만 write 되므로 동기화(mutex/atomic)가 불필요하다.** ZNTC 의 JS plugin hook
/// 본문은 worker 가 `callHookFull` 에서 condvar 로 block 한 채 main thread 의 `callJsCallback`
/// 이 직렬 실행한다(JS single-thread). 따라서 `emitFile` native 콜백이 두 worker 에서 동시에
/// 호출되는 일이 없다. rolldown 이 `DashMap`/`AtomicUsize` 를 쓰는 건 plugin 이 native 코드라
/// worker thread 에서 직접 FileEmitter 를 치기 때문이고, ZNTC=JS plugin 은 Rollup 의 단일-스레드
/// 모델과 동형이라 일반 ArrayList + 카운터로 충분하다.
///
/// MVP 한계(follow-up): ① 동일 source 중복 emit 의 dedup 없음(Rollup 은 combine) — 같은 asset 을
/// 두 번 emit 하면 동일 path OutputFile 2개. ② getFileName 은 *이미 등록된* reference id 만 조회
/// 가능 — 다른 모듈 transform 이 아직 emit 하지 않은 id 를 병렬로 조회하면 null(throw). 같은
/// hook 안에서 emit→getFileName 하는 일반 패턴은 메인 스레드 직렬이라 안전.
pub const EmitStore = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(EmittedAsset),
    /// chunk emit 요청 (#1880 PR7-2). PR7-2a 는 수집만 — graph 주입은 PR7-2b.
    chunks: std.ArrayList(EmittedChunk),
    /// reference id 생성용 단조 증가 카운터(asset/chunk 공유 → "asset-N"/"chunk-N" 모두 유니크).
    /// 메인 스레드 직렬이라 atomic 불필요.
    counter: usize = 0,
    /// name-only emit 의 hash 파일명 생성 패턴 (graph.asset_names, 예 "[name]-[hash]").
    /// file/copy loader 와 동일 규칙을 쓰도록 bundler 가 옵션에서 주입한다.
    asset_names: []const u8 = "[name]-[hash]",

    pub fn init(allocator: std.mem.Allocator, asset_names: []const u8) EmitStore {
        return .{ .allocator = allocator, .assets = .empty, .chunks = .empty, .asset_names = asset_names };
    }

    pub fn deinit(self: *EmitStore) void {
        for (self.assets.items) |a| {
            self.allocator.free(a.reference_id);
            self.allocator.free(a.file_name);
            self.allocator.free(a.source);
        }
        self.assets.deinit(self.allocator);
        for (self.chunks.items) |chk| {
            self.allocator.free(chk.reference_id);
            self.allocator.free(chk.id);
            if (chk.name) |n| self.allocator.free(n);
            if (chk.file_name) |f| self.allocator.free(f);
        }
        self.chunks.deinit(self.allocator);
    }

    /// asset 을 등록하고 reference id ("asset-N") 를 반환한다. file_name/source 는 dupe 로 소유.
    /// 반환 slice 는 store 소유 — caller(NAPI)는 napi string 으로 복사해 JS 에 돌려준다.
    pub fn emitAsset(self: *EmitStore, file_name: []const u8, source: []const u8) ![]const u8 {
        const reference_id = try std.fmt.allocPrint(self.allocator, "asset-{d}", .{self.counter});
        errdefer self.allocator.free(reference_id);
        const fname = try self.allocator.dupe(u8, file_name);
        errdefer self.allocator.free(fname);
        const src = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(src);
        try self.assets.append(self.allocator, .{
            .reference_id = reference_id,
            .file_name = fname,
            .source = src,
        });
        self.counter += 1;
        return reference_id;
    }

    /// name-only asset: 명시 fileName 없이 `name`(예 "logo.png") + source hash 로 파일명을 자동
    /// 생성한다(file/copy loader 와 동일한 `applyAssetNamingPattern`). hash 는 source 만으로 결정
    /// 되므로 emit 시점에 즉시 확정 가능 → getFileName 도 lazy 불필요(Rollup 은 chunk 때문에 lazy).
    pub fn emitAssetByName(self: *EmitStore, name: []const u8, source: []const u8) ![]const u8 {
        const hash = assets_mod.contentHash(source);
        // file/copy loader(graph/loaders.zig)와 동일하게 분리: [name]=basename(확장자 제거),
        // [dir]=디렉토리. dir 을 "" 로 넘기면 패턴에 [dir] 토큰이 있을 때 leading-slash 등
        // 깨진 경로가 나오므로 name 의 dirname 을 그대로 전달한다.
        const basename = std.fs.path.basename(name);
        const ext = std.fs.path.extension(basename); // ".png" 또는 ""
        const stem = if (ext.len > 0 and basename.len > ext.len) basename[0 .. basename.len - ext.len] else basename;
        const dir = std.fs.path.dirname(name) orelse "";
        const file_name = try assets_mod.applyAssetNamingPattern(self.allocator, self.asset_names, stem, &hash, ext, dir);
        defer self.allocator.free(file_name);
        return self.emitAsset(file_name, source);
    }

    /// reference id 로 등록된 asset/chunk 의 출력 파일명을 조회한다(Rollup `this.getFileName`).
    /// 메인 스레드 직렬이라 별도 동기화 없이 단순 스캔 — emit 수는 작다. chunk 는 명시 fileName 이면
    /// 즉시, name/auto 면 청킹 후 bundler 가 back-fill 한 file_name 을 반환(미확정이면 null → throw).
    pub fn getFileName(self: *const EmitStore, reference_id: []const u8) ?[]const u8 {
        for (self.assets.items) |a| {
            if (std.mem.eql(u8, a.reference_id, reference_id)) return a.file_name;
        }
        for (self.chunks.items) |c| {
            if (std.mem.eql(u8, c.reference_id, reference_id)) return c.file_name;
        }
        return null;
    }

    /// chunk emit 요청을 등록하고 reference id ("chunk-N") 를 반환한다 (#1880 PR7-2).
    /// id/name/file_name 은 dupe 로 소유. file_name 명시(fileName) 면 getFileName 즉시 가능;
    /// 미지정(name/auto)이면 bundler 가 청킹 후 `setChunkFileName` 으로 back-fill (PR7-2c).
    pub fn emitChunk(self: *EmitStore, id: []const u8, name: ?[]const u8, file_name: ?[]const u8) ![]const u8 {
        const reference_id = try std.fmt.allocPrint(self.allocator, "chunk-{d}", .{self.counter});
        errdefer self.allocator.free(reference_id);
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const name_owned: ?[]const u8 = if (name) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (name_owned) |n| self.allocator.free(n);
        const fname_owned: ?[]const u8 = if (file_name) |f| try self.allocator.dupe(u8, f) else null;
        errdefer if (fname_owned) |f| self.allocator.free(f);
        try self.chunks.append(self.allocator, .{
            .reference_id = reference_id,
            .id = id_owned,
            .name = name_owned,
            .file_name = fname_owned,
        });
        self.counter += 1;
        return reference_id;
    }

    /// 청킹+렌더 후 bundler 가 emit chunk(id 매칭)의 최종 파일명을 back-fill 한다 (PR7-2c).
    /// 이미 명시 fileName 으로 set 된 chunk 는 건드리지 않는다(plugin 지정 우선).
    pub fn setChunkFileName(self: *EmitStore, id: []const u8, file_name: []const u8) !void {
        for (self.chunks.items) |*c| {
            if (c.file_name != null) continue; // 명시 fileName 우선
            if (!std.mem.eql(u8, c.id, id)) continue;
            c.file_name = try self.allocator.dupe(u8, file_name);
        }
    }
};

test "emitAsset 은 고유 reference id 를 발급하고 내용을 소유한다" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator, "[name]-[hash]");
    defer store.deinit();

    const id0 = try store.emitAsset("a.css", "body{}");
    const id1 = try store.emitAsset("b.json", "{}");

    try testing.expectEqualStrings("asset-0", id0);
    try testing.expectEqualStrings("asset-1", id1);
    try testing.expectEqual(@as(usize, 2), store.assets.items.len);
    try testing.expectEqualStrings("a.css", store.assets.items[0].file_name);
    try testing.expectEqualStrings("body{}", store.assets.items[0].source);
    try testing.expectEqualStrings("b.json", store.assets.items[1].file_name);
}

test "emitAssetByName 은 source hash 로 파일명을 생성하고 getFileName 으로 조회된다" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator, "[name]-[hash]");
    defer store.deinit();

    const id = try store.emitAssetByName("logo.png", "PNGDATA");
    // [name]-[hash].png 형태 — stem=logo, ext=.png 보존, hash 8 hex.
    const fname = store.getFileName(id).?;
    try testing.expect(std.mem.startsWith(u8, fname, "logo-"));
    try testing.expect(std.mem.endsWith(u8, fname, ".png"));
    try testing.expectEqual(@as(usize, "logo-".len + 8 + ".png".len), fname.len);
    // 동일 source 는 동일 hash 파일명 (결정적).
    const id2 = try store.emitAssetByName("logo.png", "PNGDATA");
    try testing.expectEqualStrings(fname, store.getFileName(id2).?);
    // 미등록 reference id → null.
    try testing.expect(store.getFileName("asset-999") == null);
}

test "emitAssetByName 은 [dir] 패턴에서 name 의 디렉토리를 [dir] 로 넣는다 (loader parity)" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator, "[dir]/[name]-[hash]");
    defer store.deinit();

    // name="icons/logo.png" → stem=logo, dir=icons → "icons/logo-HASH.png" (leading-slash 없음).
    const id = try store.emitAssetByName("icons/logo.png", "DATA");
    const fname = store.getFileName(id).?;
    try testing.expect(std.mem.startsWith(u8, fname, "icons/logo-"));
    try testing.expect(std.mem.endsWith(u8, fname, ".png"));
    try testing.expect(!std.mem.startsWith(u8, fname, "/")); // dir="" 였다면 "/logo-..." 가 됐을 것
}

test "emitChunk 는 chunk-N reference id 를 발급하고 요청을 수집한다 (PR7-2a, graph 미주입)" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator, "[name]-[hash]");
    defer store.deinit();

    const c0 = try store.emitChunk("./worker.ts", null, null);
    const c1 = try store.emitChunk("./route.ts", "route", null);
    try testing.expectEqualStrings("chunk-0", c0);
    try testing.expectEqualStrings("chunk-1", c1);
    try testing.expectEqual(@as(usize, 2), store.chunks.items.len);
    try testing.expectEqualStrings("./worker.ts", store.chunks.items[0].id);
    try testing.expect(store.chunks.items[0].name == null);
    try testing.expectEqualStrings("route", store.chunks.items[1].name.?);
    // file_name 미지정(auto) → 청킹 전엔 getFileName null. back-fill 후 확정(PR7-2c).
    try testing.expect(store.getFileName(c0) == null);
}

test "emitChunk file_name: 명시 fileName 은 즉시 getFileName, auto 는 setChunkFileName back-fill" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator, "[name]-[hash]");
    defer store.deinit();

    // 명시 fileName → 즉시 조회 가능 (hash 없음).
    const c_explicit = try store.emitChunk("/abs/lib.ts", null, "lib.js");
    try testing.expectEqualStrings("lib.js", store.getFileName(c_explicit).?);

    // auto(name) → 청킹 전 null, back-fill 후 확정.
    const c_auto = try store.emitChunk("/abs/worker.ts", "worker", null);
    try testing.expect(store.getFileName(c_auto) == null);
    try store.setChunkFileName("/abs/worker.ts", "worker-abc12345.js");
    try testing.expectEqualStrings("worker-abc12345.js", store.getFileName(c_auto).?);

    // back-fill 은 명시 fileName chunk 를 덮어쓰지 않는다.
    try store.setChunkFileName("/abs/lib.ts", "OTHER.js");
    try testing.expectEqualStrings("lib.js", store.getFileName(c_explicit).?);
}

test "asset/chunk reference id 는 공유 카운터로 서로 유니크하다" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator, "[name]-[hash]");
    defer store.deinit();

    const a0 = try store.emitAsset("a.css", "x");
    const c1 = try store.emitChunk("./b.ts", null, null);
    const a2 = try store.emitAsset("c.css", "y");
    try testing.expectEqualStrings("asset-0", a0);
    try testing.expectEqualStrings("chunk-1", c1);
    try testing.expectEqualStrings("asset-2", a2);
}
