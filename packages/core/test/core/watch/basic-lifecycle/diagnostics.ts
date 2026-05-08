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

describe('watch() > basic lifecycle > diagnostics', () => {
  test('plugin lifecycle hooks: watch rebuild diagnostic 은 buildEnd error 후 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-diagnostic-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-diagnostic',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd((err) => {
          events.push(err ? 'buildEnd:error' : 'buildEnd');
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
      writeFileSync(join(dir, 'entry.ts'), "import value from './missing';\nconsole.log(value);");

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'onReady',
        'closeBundle',
        'buildStart',
        'buildEnd:error',
        'onRebuild:ok',
        'closeBundle',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
