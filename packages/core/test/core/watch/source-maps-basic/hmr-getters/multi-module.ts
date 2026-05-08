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

describe('watch() > source maps basic > hmr getters > multi module', () => {
  test('getHmrSourceMap — multi-module rebuild 에서 모든 모듈 id 로 조회 가능', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-multi-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 999;\n');
    const event = await rebuildP;

    expect(event.updates).toBeDefined();
    const u = event.updates![0];
    const mapA = handle.getHmrSourceMap(u.id);
    expect(mapA).not.toBeNull();
    expect(u.id.endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);
});
