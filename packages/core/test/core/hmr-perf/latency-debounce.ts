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

describe('Issue #1223 HMR perf - latency and debounce', () => {
  test('phase1a: 변경 감지부터 onRebuild까지 200ms 이내여야 함 (현재 500ms 폴링)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1a-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 50));

    const t0 = performance.now();
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');
    await rebuildP;
    const elapsed = performance.now() - t0;

    handle.stop();
    rmSync(dir, { recursive: true });

    expect(elapsed).toBeLessThan(200);
  }, 10000);

  // ---- Phase 1b: content hash (mtime만 갱신, 내용 동일 → 알림 없음) ----

  test('phase1c: 첫 리빌드 후 50ms 내 두 번 저장은 한 번으로 병합되어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1c-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;
    let firstRebuildResolve: (() => void) | null = null;
    const firstRebuildP = new Promise<void>((r) => {
      firstRebuildResolve = r;
    });

    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
        if (rebuildCount === 1) firstRebuildResolve!();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 첫 저장 → 첫 리빌드 완료까지 대기
    writeFileSync(entry, 'export const x = 2;');
    await firstRebuildP;
    expect(rebuildCount).toBe(1);

    // idle 상태에서 50ms 내에 두 번 빠르게 저장
    writeFileSync(entry, 'export const x = 3;');
    await new Promise((r) => setTimeout(r, 10));
    writeFileSync(entry, 'export const x = 4;');

    // 디바운스(50ms) + 빌드 시간 충분히 대기
    await new Promise((r) => setTimeout(r, 2000));
    handle.stop();
    rmSync(dir, { recursive: true });

    // 현재: 폴링으로 두 번 모두 감지 → rebuildCount=3
    // 목표: 디바운스로 병합 → rebuildCount=2
    expect(rebuildCount).toBe(2);
  }, 15000);

  // ---- Phase 2: 증분 그래프 (1개 변경 → 1개만 재파싱) ----

  test('phase1f: 디바운스 윈도우를 계속 갱신해도 500ms 상한 내 리빌드 발생', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1f-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 50));

    // 20ms마다 파일 수정 — 매번 debounce window(50ms) 내에 새 이벤트.
    // starvation cap(500ms)이 없으면 영영 리빌드 안 됨.
    let counter = 0;
    const interval = setInterval(() => {
      counter++;
      writeFileSync(entry, `export const x = ${counter};`);
    }, 20);

    const t0 = performance.now();
    await rebuildP;
    const elapsed = performance.now() - t0;
    clearInterval(interval);
    handle.stop();
    rmSync(dir, { recursive: true });

    // 500ms cap + 빌드 시간 여유 포함하여 상한 검증
    expect(elapsed).toBeLessThan(1500);
  }, 10000);

  // ---- phase1g: 경계 — 빈 파일 해시 ----
});
