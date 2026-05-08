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

describe('watch() > source maps rebuilds > hmr swaps > graph change', () => {
  test('getHmrSourceMap — graph 변경 (모듈 추가) 후 새 모듈도 swap 에 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-graph-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'entry.ts'), "import { A } from './a';\nconsole.log(A);\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let seenGraphChange = false;
    let secondUpdates: Array<{ id: string }> | undefined;
    const { promise: secondP, resolve: secondDone } = Promise.withResolvers<void>();

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
        if (!seenGraphChange) {
          if (event.graphChanged) seenGraphChange = true;
        } else if (event.updates && event.updates.length > 0) {
          secondUpdates = event.updates;
          secondDone();
        }
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );
    await new Promise((r) => setTimeout(r, 500));
    expect(seenGraphChange).toBe(true);

    writeFileSync(join(dir, 'b.ts'), 'export const B = 999;\n');
    await secondP;

    const bId = secondUpdates!.find((u) => u.id.endsWith('b.ts'))?.id;
    expect(bId).toBeDefined();

    const mapB = handle.getHmrSourceMap(bId!);
    expect(mapB).not.toBeNull();
    expect(handle.getHmrSourceMap('absolutely/not/a/module.ts')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);
});
