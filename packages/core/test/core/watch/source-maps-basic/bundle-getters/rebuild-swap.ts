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

describe('watch() > source maps basic > bundle getters > rebuild swap', () => {
  test('getBundleSourceMap — rebuild 후 swap 이 반영되고 이전 mappings 와 달라짐', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-swap-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const x = 1;\nexport const y = 2;\nexport const z = 3;\n',
    );
    await rebuildP;

    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    const m1 = JSON.parse(before!);
    const m2 = JSON.parse(after!);
    expect(m2.mappings.length).toBeGreaterThan(m1.mappings.length);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);
});
