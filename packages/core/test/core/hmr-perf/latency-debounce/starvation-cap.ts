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

describe('Issue #1223 HMR perf - latency and debounce - starvation cap', () => {
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

    expect(elapsed).toBeLessThan(1500);
  }, 10000);
});
