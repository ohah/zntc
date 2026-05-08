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

describe('Issue #1223 HMR perf - content hash - empty file', () => {
  test('phase1g: 빈 파일도 해시되어 리빌드 동작 정상', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1g-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, '');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entry, 'export const x = 1;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.success).toBe(true);
  }, 10000);
});
