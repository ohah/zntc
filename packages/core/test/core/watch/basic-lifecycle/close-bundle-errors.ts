import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('watch() > basic lifecycle > closeBundle errors', () => {
  test('plugin lifecycle hooks: watch closeBundle throw 는 다른 plugin 과 watch 를 막지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-close-throw-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let trackingCloseCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const throwingPlugin: ZntcPlugin = {
      name: 'watch-close-thrower',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('throwing-close');
          throw new Error('close failed');
        });
      },
    };
    const trackingPlugin: ZntcPlugin = {
      name: 'watch-close-tracker',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('tracking-close');
          trackingCloseCount++;
          if (trackingCloseCount === 1) initialCloseDone();
          if (trackingCloseCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [throwingPlugin, trackingPlugin],
      });

      await initialCloseP;
      expect(events).toEqual(['throwing-close', 'tracking-close']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'throwing-close',
        'tracking-close',
        'throwing-close',
        'tracking-close',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
