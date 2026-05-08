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

describe('Issue #1223 HMR perf - latency and debounce - latency', () => {
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
});
