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

describe('watch() > source maps rebuilds > failure cache', () => {
  test('getBundleSourceMap — rebuild 실패 후 이전 JSON 이 캐시로 유지된다', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-err-'));
    let handle: ReturnType<typeof watch> | undefined;
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

      const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
      let rebuildResolved = false;
      const { promise: errP, resolve: errDone } = Promise.withResolvers<{ success: boolean }>();
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        outfile: join(dir, 'bundle.js'),
        sourcemap: true,
        devMode: true,
        emitDiskSourcemap: false,
        onReady() {
          readyDone();
        },
        onRebuild(event) {
          if (!rebuildResolved) {
            rebuildResolved = true;
            errDone(event);
          }
        },
      });
      await readyP;

      const before = handle.getBundleSourceMap();
      expect(before).not.toBeNull();

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x: = = =;;;\n');
      await errP;

      const after = handle.getBundleSourceMap();
      expect(after).not.toBeNull();
      const m = JSON.parse(after!);
      expect(m.version).toBe(3);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 15000);
});
