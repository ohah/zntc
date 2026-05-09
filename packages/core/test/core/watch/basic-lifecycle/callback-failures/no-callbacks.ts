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
import type { ZntcPlugin } from '../helpers';

describe('watch() > basic lifecycle > callback failures without user callbacks', () => {
  test('plugin lifecycle hooks: watch 사용자 콜백이 없어도 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-no-callback-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-no-callback',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd(() => events.push('buildEnd'));
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'closeBundle',
        'buildStart',
        'buildEnd',
        'closeBundle',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
