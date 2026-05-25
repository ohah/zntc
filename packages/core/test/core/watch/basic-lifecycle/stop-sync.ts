// #3806 회귀 가드 — `WatchHandle.stop()` 가 fire-and-forget 이 아니라 worker thread
// 종료까지 sync wait. pre-#3806 의 fire-and-forget 패턴 에서는 stop() 후 worker 가 polling
// cycle 까지 살아있어 즉시 새 watch handle 띄우면 fs watcher / outdir write race 가능.
//
// 단순 invariant 가드:
// - stop() 가 deadlock 없이 합리적 시간 안 (5초 timedWait timeout) 안에 return.
// - stop() return 후 같은 entry 로 새 watch handle 띄우면 onReady 정상 도착 — 옛 worker 가
//   같은 자원 (fs watcher, persistent module store) 잡고 있으면 새 watch initial 빌드 실패
//   또는 hang 가능. fixed 면 깔끔하게 종료 → 새 watch 정상.

import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  watch,
  writeFileSync,
} from './helpers';

describe('watch() > basic lifecycle > stop() 동기성', () => {
  test('stop() 후 같은 entry 로 즉시 새 watch — 둘 다 onReady 정상 (#3806)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-stop-sync-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    // 1차 watch — onReady 받자마자 stop
    const { promise: ready1P, resolve: ready1Done } = Promise.withResolvers<void>();
    const handle1 = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        ready1Done();
      },
    });
    await ready1P;

    const stopStart = Date.now();
    handle1.stop();
    const stopElapsed = Date.now() - stopStart;
    // 5초 timedWait 의 절반 안엔 return (정상 worker 는 polling cycle 50-500ms 안 종료)
    expect(stopElapsed).toBeLessThan(2500);

    // 2차 watch — 같은 entry. 옛 worker 가 살아있어 자원 lock 잡고 있으면 hang 또는 fail.
    const { promise: ready2P, resolve: ready2Done } = Promise.withResolvers<void>();
    const handle2 = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        ready2Done();
      },
    });
    // 5초 timeout 안에 onReady 도착해야 — pre-fix 에서는 hang 또는 reject 가능
    const ready2Win = await Promise.race([
      ready2P.then(() => 'ok' as const),
      new Promise<'timeout'>((r) => setTimeout(() => r('timeout'), 5000)),
    ]);
    handle2.stop();
    expect(ready2Win).toBe('ok');

    rmSync(dir, { recursive: true });
  });
});
