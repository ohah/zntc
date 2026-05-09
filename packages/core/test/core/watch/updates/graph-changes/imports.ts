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

describe('watch() > rebuild updates > import graph changes', () => {
  test('새 import 추가 시 graphChanged 감지', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    let handle: ReturnType<typeof watch> | undefined;
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

      const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
      const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
        graphChanged?: boolean;
      }>();

      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        devMode: true,
        collectModuleCodes: true,
        onReady() {
          readyDone();
        },
        onRebuild(event) {
          rebuildDone(event);
        },
      });

      await readyP;
      writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');
      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');

      const event = await rebuildP;
      expect(event.graphChanged).toBe(true);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
