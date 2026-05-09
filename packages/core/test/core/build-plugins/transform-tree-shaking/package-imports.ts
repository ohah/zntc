import {
  build,
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core build + plugins - transform tree-shaking package imports', () => {
  test('#2038: onTransform이 추가한 sideEffects:false 패키지 import도 tree-shaking 입력이 됨', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-plugin-pkg-'));
    try {
      writeFileSync(join(entryDir, 'main.ts'), "console.log('__ORIGINAL_2038__');");
      mkdirSync(join(entryDir, 'node_modules', 'pure-lib-2038'), { recursive: true });
      writeFileSync(
        join(entryDir, 'node_modules', 'pure-lib-2038', 'package.json'),
        '{"name":"pure-lib-2038","main":"index.js","sideEffects":false}',
      );
      writeFileSync(
        join(entryDir, 'node_modules', 'pure-lib-2038', 'index.js'),
        [
          'export const used = "core-plugin-used-2038";',
          'export const unused = "core-plugin-unused-2038";',
        ].join('\n'),
      );

      const transformPlugin: ZntcPlugin = {
        name: 'transform-adds-package-import',
        setup(build) {
          build.onTransform({ filter: /main\.ts$/ }, () => ({
            code: 'import { used } from "pure-lib-2038";\nconsole.log(used);',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(entryDir, 'main.ts')],
        treeShaking: true,
        plugins: [transformPlugin],
      });
      expect(result.errors.length).toBe(0);
      const text = result.outputFiles[0].text;
      expect(text).toContain('core-plugin-used-2038');
      expect(text).not.toContain('core-plugin-unused-2038');
      expect(text).not.toContain('__ORIGINAL_2038__');
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });
});
