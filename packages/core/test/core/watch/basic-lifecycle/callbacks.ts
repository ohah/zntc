import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('watch() > basic lifecycle > callbacks', () => {
  test('초기 빌드 후 onReady 콜백 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise, resolve: done } = Promise.withResolvers<{ files: number; bytes: number }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady(event) {
        done(event);
      },
    });

    const event = await promise;
    expect(event.files).toBeGreaterThan(0);
    expect(event.bytes).toBeGreaterThan(0);
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('파일 변경 시 onRebuild 콜백 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      bytes?: number;
    }>();

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

    // 파일 수정 (mtime polling 500ms 대기)
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

    const event = await rebuildP;
    expect(event.success).toBe(true);
    expect(event.bytes).toBeGreaterThan(0);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
