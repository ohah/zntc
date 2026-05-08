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

describe('watch() > source maps basic > bundle getters > initial', () => {
  test('getBundleSourceMap — sourcemap + devMode 시 초기 빌드 후 V3 JSON 반환', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 1;\nconsole.log(x);\n');

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

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');
    expect(json).toContain('"mappings"');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
