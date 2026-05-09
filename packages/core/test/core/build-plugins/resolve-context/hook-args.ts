import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core build + plugins - require.context hook args', () => {
  test('onResolveContext: hook 호출 + args 전달 (dir/recursive/filter/flags/importer)', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-'));
    try {
      writeFileSync(
        join(entryDir, 'entry.ts'),
        "const ctx = require.context('./pages', true, /\\.tsx?$/, 'sync'); console.log(ctx);",
      );

      let captured: any = null;
      const plugin: ZntcPlugin = {
        name: 'rc-capture',
        setup(build) {
          build.onResolveContext({ filter: /.*/ }, (args) => {
            captured = args;
            return { context: ['./a.tsx', './b.tsx'] };
          });
        },
      };

      await build({
        entryPoints: [join(entryDir, 'entry.ts')],
        plugins: [plugin],
      });

      expect(captured).not.toBeNull();
      expect(captured.dir).toBe('./pages');
      expect(captured.recursive).toBe(true);
      expect(captured.filter).toBe('\\.tsx?$');
      expect(captured.importer).toContain('entry.ts');
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });
});
