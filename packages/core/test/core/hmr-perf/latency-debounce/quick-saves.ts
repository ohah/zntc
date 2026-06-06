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
} from '../helpers';

describe('Issue #1223 HMR perf - latency and debounce - quick saves', () => {
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
      // 기본 디바운스가 16ms 로 낮아져(RN HMR 단일편집 latency 절감), 10ms 간격 두 저장의
      // 병합을 검증하려면 윈도우를 명시한다. watchDelay 옵션이 native debounce_ms 로 전달되는지도 함께 검증.
      watchDelay: 50,
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

    writeFileSync(entry, 'export const x = 2;');
    await firstRebuildP;
    expect(rebuildCount).toBe(1);

    writeFileSync(entry, 'export const x = 3;');
    await new Promise((r) => setTimeout(r, 10));
    writeFileSync(entry, 'export const x = 4;');

    await new Promise((r) => setTimeout(r, 2000));
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(rebuildCount).toBe(2);
  }, 15000);
});
