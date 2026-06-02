const std = @import("std");

/// Multi-Producer Single-Consumer 채널.
/// 여러 워커 스레드가 send()로 결과를 보내고, 메인 스레드가 recv()로 하나씩 수신.
/// 내부적으로 Mutex + Condition 기반, 큐 깊이는 스레드 풀 크기에 바운드되어 작음.
///
/// ## inline-async 안전성 불변식 (왜 0.16 group.async 의 inline-fallback 에도 hang 없는가)
/// 0.16 `std.Io.Group.async` 는 busy_count ≥ async_limit 이면 태스크를 **호출 스레드에서
/// 동기(inline) 실행**한다(Threaded.zig groupAsyncEager). producer 가 소비자 스레드 위에서
/// 동기 실행될 수 있다는 뜻이라, 잘못 쓰면 #26027 류 hang(태스크가 못 도는 형제 태스크를 대기)
/// 이 가능하다. 이 채널 기반 producer/consumer 가 안전한 근거는 다음 셋이며, 하나라도 깨지면
/// hang 위험이 생긴다:
///   (1) **단일 소비자** — recv 는 메인(디스패치) 스레드 하나에서만 호출. (recv 의
///       `consumer_thread_id` assert 로 runtime_safety 빌드에서 강제.)
///   (2) **dispatch-before-recv** — 메인은 group.async 로 워커를 *먼저* 모두 dispatch 한 뒤
///       recv 한다(build_flow.zig:123,132 의 dispatchPendingChunked → 126 의 recv 루프).
///       inline 으로 실행된 워커는 group.async 호출 도중 동기로 send 를 끝내므로, recv 가
///       '아직 실행 안 된 inline 태스크의 결과' 를 기다리며 막히는 일이 없다.
///   (3) **형제 비대기** — 워커(scanRangeWorker/scanWorker)는 다른 태스크의 완료를 기다리지
///       않는다(서로 독립, .state 미참조 #1779). inline 실행돼도 sibling-wait 데드락 불가.
pub fn MpscChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        // 0.16: std.Thread.Mutex/Condition 제거 → std.Io.Mutex/Condition (lock/wait 가 io 요구).
        // ZNTC 는 Threaded io 백엔드라 OS 프리미티브로 동작. 내부 채널이라 cancellation 불필요
        // → lockUncancelable/waitUncancelable (구 non-erroring lock/wait 의미 보존).
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        /// 큐 저장소. send()가 뒤에 append, recv()가 앞에서 꺼냄.
        queue: std.ArrayListUnmanaged(T) = .empty,
        allocator: std.mem.Allocator,
        /// #4009: send 의 큐 append 가 OOM 으로 결과를 drop 했음을 메인(recv)에 알리는 플래그.
        /// 예전엔 `append catch return` 으로 결과를 조용히 버려, recv 가 안 오는 결과를 무한
        /// 대기(deadlock/hang)했다. recv 가 이 플래그를 보고 error.SendFailed 를 반환해 빌드가
        /// graceful 하게 실패하도록 한다(panic 은 NAPI in-process 에서 호스트 프로세스 abort 라
        /// 부적합 — 빌드 OOM 은 JS throw/CLI 에러 종료로 전파돼야 함). set/read 모두 mutex 보호.
        send_failed: bool = false,
        /// 단일 소비자(Single-Consumer) 불변식 검증용. 첫 recv 호출 스레드를 기록하고 이후
        /// 동일 스레드인지 assert (위 "inline-async 안전성" (1)). runtime_safety 빌드에서만
        /// 존재 — ReleaseFast 에선 void 라 필드/검사 모두 0비용. mutex 보호 하에서만 접근.
        consumer_thread_id: if (std.debug.runtime_safety) ?std.Thread.Id else void =
            if (std.debug.runtime_safety) null else {},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
        }

        /// 워커 스레드에서 호출. 결과를 큐에 추가하고 메인 스레드에 시그널.
        pub fn send(self: *Self, io: std.Io, item: T) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            // append OOM 시 item 은 drop 되지만 send_failed 로 표시(아래 field doc 참조, #4009).
            self.queue.append(self.allocator, item) catch {
                self.send_failed = true;
            };
            self.cond.signal(io); // 성공/실패 모두 발행 — recv 를 깨워 소비 or send_failed 확인.
        }

        pub const RecvError = error{
            /// 워커의 send 가 OOM 으로 결과를 drop 함 — 이 결과는 영영 오지 않으므로 hang
            /// 대신 호출자가 빌드를 실패시켜야 한다(#4009).
            SendFailed,
        };

        /// 메인 스레드에서 호출. 큐가 비어있으면 워커가 send할 때까지 블로킹 대기.
        /// send 가 OOM 으로 결과를 drop 한 뒤 큐가 비면 error.SendFailed 반환(무한 대기 방지).
        pub fn recv(self: *Self, io: std.Io) RecvError!T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            // 단일 소비자 불변식 강제 (위 "inline-async 안전성" (1)). 워커가 recv 를 호출하면
            // group.async inline-fallback 와 맞물려 #26027 류 hang 가능 → 디버그서 즉시 fail.
            // mutex 보유 중이라 consumer_thread_id 접근은 race-free.
            if (std.debug.runtime_safety) {
                const tid = std.Thread.getCurrentId();
                if (self.consumer_thread_id) |owner| {
                    std.debug.assert(owner == tid);
                } else {
                    self.consumer_thread_id = tid;
                }
            }
            while (self.queue.items.len == 0) {
                if (self.send_failed) return error.SendFailed;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            return self.queue.swapRemove(0);
        }

        /// recv 의 batch 버전: 현재 큐에 쌓인 결과를 **lock 1회**로 전부 `out` 으로 옮기고
        /// 옮긴 개수를 반환. 큐가 비어있으면 recv 와 동일하게 최소 1개가 올 때까지(또는
        /// send_failed) 대기한다. `out` 과 내부 큐의 backing storage 를 swap 하므로 per-item
        /// 복사·재할당이 없어 **OOM 불가**(recv 의 swapRemove 와 동일하게 RecvError 만).
        ///
        /// 호출자는 `out` 을 비워 넘길 필요가 없다 — recvBatch 가 swap 직전 `out` 을 내부에서
        /// clearRetainingCapacity 한다. 따라서 같은 `out` 을 매 호출 재사용하면 두 버퍼가
        /// ping-pong 하며 capacity 가 보존된다(steady-state alloc 0). `out` 에 남아있던
        /// **소비 안 한** 내용은 버려지므로(누수 가능), 호출자는 직전 batch 를 소비한 뒤 호출할 것.
        ///
        /// 왜 batch 인가 (#4003 0.16 std.Io 회귀 fix): fan-out(깊고 좁은) 그래프에서
        /// "recv 1개 → 즉시 dispatch" 는 pending tail 이 모듈당 1~5 라 chunkSize 가 1 로
        /// degrade → 모듈당 group.async 1회(0.16 per-task: 힙alloc + 전역락 + status atomic +
        /// condSignal)를 그대로 치른다(#4007 청킹 무력화). 큐를 한꺼번에 비우면 형제 결과가
        /// 합류해 pending 구간이 parallelism*4 를 넘어 chunkSize 가 묶이고 dispatch 수가
        /// N→수백으로 떨어진다. 소비 순서는 여전히 비보장(swap 이라 FIFO 도 아님)이며 출력
        /// determinism 은 renumber(#3564)라 채널 순서와 무관.
        ///
        /// 단일 소비자 불변식은 recv 와 동일(메인 디스패치 스레드 전용, dispatch-before-recv).
        ///
        /// 불변식: `out` 은 **채널과 동일한 allocator** 로 관리돼야 한다(swap 후 큐가 out 의
        /// 버퍼를, out 이 큐의 버퍼를 갖고 각자 자기 allocator 로 deinit 하므로). build_flow
        /// 는 둘 다 `self.allocator`.
        pub fn recvBatch(self: *Self, io: std.Io, out: *std.ArrayListUnmanaged(T)) RecvError!usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (std.debug.runtime_safety) {
                const tid = std.Thread.getCurrentId();
                if (self.consumer_thread_id) |owner| {
                    std.debug.assert(owner == tid);
                } else {
                    self.consumer_thread_id = tid;
                }
            }
            while (self.queue.items.len == 0) {
                if (self.send_failed) return error.SendFailed;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            // out 을 내부에서 비운 뒤(직전 소비분의 빈 버퍼 재사용) backing swap → 큐의 결과
            // 전체가 out 으로, out 의 빈 버퍼가 큐로 간다(다음 send 가 재사용). 사전조건 없이
            // 오용(소비 안 한 out)해도 큐를 오염시키지 않고 그 내용만 버려진다(corruption 불가).
            out.clearRetainingCapacity();
            const n = self.queue.items.len;
            std.mem.swap(std.ArrayListUnmanaged(T), &self.queue, out);
            return n;
        }
    };
}

test "MpscChannel: 정상 send 후 전부 recv (소비 순서는 비보장 — recv 는 swapRemove)" {
    // recv 는 swapRemove(0) 라 3개 이상서 FIFO 가 아니다(소비처 applyScanResult 가 result.module_idx
    // 로 적용 + determinism 은 renumber/#3564 라 채널 순서 무관). 2개라 우연히 7,8 순.
    const io = std.testing.io;
    var ch = MpscChannel(u32).init(std.testing.allocator);
    defer ch.deinit();
    ch.send(io, 7);
    ch.send(io, 8);
    try std.testing.expectEqual(@as(u32, 7), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 8), try ch.recv(io));
}

test "MpscChannel: send OOM 시 recv 가 error.SendFailed 반환 (무한 hang 방지, #4009)" {
    const io = std.testing.io;
    // 첫 alloc(큐 성장)을 실패시켜 send 가 결과를 drop 하게 한다.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ch = MpscChannel(u32).init(failing.allocator());
    defer ch.deinit();
    ch.send(io, 42); // append OOM → send_failed=true (예전엔 silent drop → recv 무한 대기)
    try std.testing.expectError(error.SendFailed, ch.recv(io));
}

test "MpscChannel.recvBatch: 쌓인 결과를 한 번에 전부 drain (#4003 fan-out fix)" {
    const io = std.testing.io;
    var ch = MpscChannel(u32).init(std.testing.allocator);
    defer ch.deinit();
    var batch: std.ArrayListUnmanaged(u32) = .empty;
    defer batch.deinit(std.testing.allocator);

    ch.send(io, 10);
    ch.send(io, 20);
    ch.send(io, 30);
    // recv 였다면 3회 호출이 필요하지만 recvBatch 는 1회로 3개 모두 가져온다.
    const n = try ch.recvBatch(io, &batch);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 3), batch.items.len);
    // 합(순서 비보장이라 정렬 후 비교)으로 내용 확인.
    std.mem.sort(u32, batch.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, batch.items);
}

test "MpscChannel.recvBatch: 사전 clear 없이 재사용 (내부 clear + 버퍼 ping-pong)" {
    const io = std.testing.io;
    var ch = MpscChannel(u32).init(std.testing.allocator);
    defer ch.deinit();
    var batch: std.ArrayListUnmanaged(u32) = .empty;
    defer batch.deinit(std.testing.allocator);

    ch.send(io, 1);
    _ = try ch.recvBatch(io, &batch); // batch=[1]

    // 호출자가 batch 를 비우지 않고 그대로 재호출 — recvBatch 가 내부에서 clear 후 swap 하므로
    // 직전 내용([1])은 누적되지 않고 새 결과만 남아야 한다(이전 항목은 소비됐다고 가정).
    ch.send(io, 2);
    ch.send(io, 3);
    const n = try ch.recvBatch(io, &batch);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 2), batch.items.len); // 1 이 누적되지 않음
    std.mem.sort(u32, batch.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, batch.items);
}

test "MpscChannel.recvBatch: send OOM 으로 빈 큐 + send_failed 면 error.SendFailed (#4009)" {
    const io = std.testing.io;
    // 첫 append(큐 성장)를 실패시켜 큐가 빈 채 send_failed=true 가 되게 한다(recv 의 OOM
    // 테스트와 동일 구성). 큐가 비어 swap 전에 error 반환 → batch 는 건드리지 않음.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ch = MpscChannel(u32).init(failing.allocator());
    defer ch.deinit();
    var batch: std.ArrayListUnmanaged(u32) = .empty;
    defer batch.deinit(failing.allocator());

    ch.send(io, 42); // append OOM → send_failed=true, 큐 비어있음
    // 큐가 비고 send_failed → hang 대신 error 로 빌드 실패 전파.
    try std.testing.expectError(error.SendFailed, ch.recvBatch(io, &batch));
}

test "MpscChannel: 별도 워커 스레드 send + 메인 recv (단일 소비자 불변식 정상 경로)" {
    // 실제 cross-thread producer 를 띄워 send → 메인(테스트) 스레드가 유일 소비자로 recv.
    // consumer_thread_id 추적/assert 가 정상 single-consumer 사용에서 막지 않음을 확인.
    const io = std.testing.io;
    var ch = MpscChannel(u32).init(std.testing.allocator);
    defer ch.deinit();
    const Worker = struct {
        fn run(c: *MpscChannel(u32), w_io: std.Io) void {
            c.send(w_io, 99);
        }
    };
    var t = try std.Thread.spawn(.{}, Worker.run, .{ &ch, io });
    const got = try ch.recv(io); // 메인 스레드 = 소비자 (불변식 만족)
    t.join();
    try std.testing.expectEqual(@as(u32, 99), got);
}
