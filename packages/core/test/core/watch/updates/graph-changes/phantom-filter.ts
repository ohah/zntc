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

describe('watch() > rebuild updates > phantom graph changes', () => {
  test('Issue #1682: 충돌 rename 모듈은 cache-hit 시 HMR updates 에서 제외 (phantom filter)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-phantom-'));
    let handle: ReturnType<typeof watch> | undefined;
    try {
      writeFileSync(join(dir, 'a.ts'), 'export const count = 1;\n');
      writeFileSync(join(dir, 'b.ts'), 'export const count = 2;\n');
      writeFileSync(
        join(dir, 'entry.ts'),
        "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B);\n",
      );

      const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
      const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
        updates?: Array<{ id: string }>;
        graphChanged?: boolean;
      }>();

      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        devMode: true,
        collectModuleCodes: true,
        onReady: () => readyDone(),
        onRebuild: (e) => rebuildDone(e),
      });

      await readyP;
      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(
        join(dir, 'entry.ts'),
        "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B, 1);\n",
      );

      const event = await rebuildP;
      expect(event.graphChanged).toBeFalsy();
      expect(event.updates).toBeDefined();
      const ids = event.updates!.map((u) => u.id);
      expect(ids.some((id) => id.endsWith('entry.ts'))).toBe(true);
      expect(ids.some((id) => id.endsWith('a.ts'))).toBe(false);
      expect(ids.some((id) => id.endsWith('b.ts'))).toBe(false);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
