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

describe('@zntc/core build + plugins - transform hooks', () => {
  test('onTransform 플러그인 (코드 변환)', async () => {
    const transformPlugin: ZntcPlugin = {
      name: 'transform-plugin',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({
          code: args.code.replace('console.log', 'console.warn'),
        }));
      },
    };

    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-transform-'));
    try {
      writeFileSync(join(entryDir, 'main.ts'), 'console.log("hello");');

      const result = await build({
        entryPoints: [join(entryDir, 'main.ts')],
        plugins: [transformPlugin],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('console.warn');
      expect(result.outputFiles[0].text).not.toContain('console.log');
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });
});
