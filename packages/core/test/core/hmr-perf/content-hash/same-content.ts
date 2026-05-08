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

describe('Issue #1223 HMR perf - content hash - same content', () => {
  test('phase1b: 내용이 동일하면 onRebuild가 호출되지 않아야 함 (content hash)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1b-'));
    const entry = join(dir, 'entry.ts');
    const src = 'export const x = 1;';
    writeFileSync(entry, src);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;

    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(entry, src);
    await new Promise((r) => setTimeout(r, 1500));

    handle.stop();
    rmSync(dir, { recursive: true });

    expect(rebuildCount).toBe(0);
  }, 10000);
});
