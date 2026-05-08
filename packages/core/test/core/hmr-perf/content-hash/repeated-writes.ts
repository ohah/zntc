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

describe('Issue #1223 HMR perf - content hash - repeated writes', () => {
  test('phase1e: 같은 파일 연속 touch 시 리빌드 1회만 발생', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1e-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

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

    for (let i = 0; i < 5; i++) {
      writeFileSync(entry, 'export const x = 2;');
      await new Promise((r) => setTimeout(r, 5));
    }
    await new Promise((r) => setTimeout(r, 1500));
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(rebuildCount).toBe(1);
  }, 10000);
});
