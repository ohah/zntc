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
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('watch() > basic lifecycle > native plugin order', () => {
  test('plugin lifecycle hooks: 초기 build 와 rebuild 마다 buildStart → buildEnd → callback → closeBundle 순서', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle',
      setup(build) {
        build.onBuildStart(() => {
          events.push('buildStart');
        });
        build.onBuildEnd((err) => {
          events.push(err ? `buildEnd:${err.message}` : 'buildEnd');
        });
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
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'onReady',
        'closeBundle',
        'buildStart',
        'buildEnd',
        'onRebuild:ok',
        'closeBundle',
      ]);
      expect(events.filter((event) => event === 'buildStart').length).toBe(2);
      expect(events.filter((event) => event === 'buildEnd').length).toBe(2);
      expect(events.filter((event) => event === 'closeBundle').length).toBe(2);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
