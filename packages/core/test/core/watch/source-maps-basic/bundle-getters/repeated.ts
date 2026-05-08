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

describe('watch() > source maps basic > bundle getters > repeated', () => {
  test('getBundleSourceMap — 반복 호출 시 동일 JSON 반환 (재진입 안전)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-repeat-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const j1 = handle.getBundleSourceMap();
    const j2 = handle.getBundleSourceMap();
    const j3 = handle.getBundleSourceMap();
    expect(j1).not.toBeNull();
    expect(j2).toBe(j1!);
    expect(j3).toBe(j1!);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
