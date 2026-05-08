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

describe('Issue #1223 HMR perf - observability', () => {
  test('phase3: WatchRebuildEvent에 phaseDurations 필드가 노출되어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase3-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.phaseDurations).toBeDefined();
    expect(typeof event.phaseDurations.detect).toBe('number');
    expect(typeof event.phaseDurations.graph).toBe('number');
    expect(typeof event.phaseDurations.link).toBe('number');
    expect(typeof event.phaseDurations.shake).toBe('number');
    expect(typeof event.phaseDurations.emit).toBe('number');
    expect(typeof event.phaseDurations.delta).toBe('number');
    expect(typeof event.phaseDurations.total).toBe('number');
    expect(event.phaseDurations.total).toBeGreaterThan(0);
  }, 10000);

  // ---- Phase 1a: 워처 latency (목표 < 200ms, 현재 폴링 500ms) ----
});
