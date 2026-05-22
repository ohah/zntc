const std = @import("std");

/// plugin `this.emitFile({ type: 'asset', fileName, source })` 로 emit 된 단일 asset.
/// 세 필드 모두 `EmitStore.allocator` 소유 — `EmitStore.deinit` 이 일괄 해제한다.
pub const EmittedAsset = struct {
    /// `this.emitFile` 이 plugin 에 돌려준 reference id ("asset-N").
    reference_id: []const u8,
    /// 출력 파일명 (MVP 는 명시 fileName 만 — name-only hash 파일명은 follow-up).
    file_name: []const u8,
    /// asset 내용 (binary-safe).
    source: []const u8,
};

/// plugin `this.emitFile` 수집소 (#1880 PR5).
///
/// **메인 스레드에서만 write 되므로 동기화(mutex/atomic)가 불필요하다.** ZNTC 의 JS plugin hook
/// 본문은 worker 가 `callHookFull` 에서 condvar 로 block 한 채 main thread 의 `callJsCallback`
/// 이 직렬 실행한다(JS single-thread). 따라서 `emitFile` native 콜백이 두 worker 에서 동시에
/// 호출되는 일이 없다. rolldown 이 `DashMap`/`AtomicUsize` 를 쓰는 건 plugin 이 native 코드라
/// worker thread 에서 직접 FileEmitter 를 치기 때문이고, ZNTC=JS plugin 은 Rollup 의 단일-스레드
/// 모델과 동형이라 일반 ArrayList + 카운터로 충분하다.
pub const EmitStore = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(EmittedAsset),
    /// reference id 생성용 단조 증가 카운터. 메인 스레드 직렬이라 atomic 불필요.
    counter: usize = 0,

    pub fn init(allocator: std.mem.Allocator) EmitStore {
        return .{ .allocator = allocator, .assets = .empty };
    }

    pub fn deinit(self: *EmitStore) void {
        for (self.assets.items) |a| {
            self.allocator.free(a.reference_id);
            self.allocator.free(a.file_name);
            self.allocator.free(a.source);
        }
        self.assets.deinit(self.allocator);
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
};

test "emitAsset 은 고유 reference id 를 발급하고 내용을 소유한다" {
    const testing = std.testing;
    var store = EmitStore.init(testing.allocator);
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
