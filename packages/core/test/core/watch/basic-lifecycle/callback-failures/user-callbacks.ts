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

describe('watch() > basic lifecycle > callback failures from user callbacks', () => {
  test('plugin lifecycle hooks: watch 사용자 콜백 실패 후에도 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-error',
      setup(build) {
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
        onReady() {
          events.push('onReady');
          throw new Error('ready failed');
        },
        async onRebuild() {
          events.push('onRebuild');
          throw new Error('rebuild failed');
        },
      });

      await initialCloseP;
      expect(events).toEqual(['onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual(['onReady', 'closeBundle', 'onRebuild', 'closeBundle']);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
