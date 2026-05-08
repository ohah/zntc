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

describe('Issue #1223 HMR perf - content hash - large file', () => {
  test('phase1h: 대형 파일(15MB)에서도 크래시 없이 리빌드 트리거', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1h-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'import "./big.json"; export const x = 1;');
    const big = '[' + '0,'.repeat(3_000_000) + '0]';
    writeFileSync(join(dir, 'big.json'), big);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [entry],
      loader: { '.json': 'json' },
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(entry, 'import "./big.json"; export const x = 2;');
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.success).toBe(true);
  }, 20000);
});
