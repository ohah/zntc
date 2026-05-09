import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from '../helpers';
import type { RollupPlugin } from '../helpers';

describe('@zntc/core plugin lifecycle > vite adapter', () => {
  test('vitePlugin 어댑터: Rollup plugin 의 buildStart / buildEnd / closeBundle 을 ZNTC build 에서 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-vite-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

      let buildStartCalled = false;
      let buildEndCalled = false;
      let closeBundleCalled = false;
      const rollupPlugin: RollupPlugin = {
        name: 'rollup-lifecycle',
        buildStart() {
          buildStartCalled = true;
        },
        buildEnd() {
          buildEndCalled = true;
        },
        closeBundle() {
          closeBundleCalled = true;
        },
      };
      await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [vitePlugin(rollupPlugin)] });
      expect(buildStartCalled).toBe(true);
      expect(buildEndCalled).toBe(true);
      expect(closeBundleCalled).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
