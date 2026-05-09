import {
  build,
  describe,
  existsSync,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  ROOT_NODE_MODULES,
  symlinkSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core build + plugins - transform tree-shaking real libraries', () => {
  test.skipIf(!existsSync(join(ROOT_NODE_MODULES, 'lodash-es', 'package.json')))(
    '#2038: 실제 lodash-es import를 onTransform으로 주입해도 dead export가 새지 않음',
    async () => {
      const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-lodash-plugin-'));
      try {
        writeFileSync(join(entryDir, 'main.ts'), "console.log('__ORIGINAL_LODASH_2038__');");
        mkdirSync(join(entryDir, 'node_modules'), { recursive: true });
        symlinkSync(
          join(ROOT_NODE_MODULES, 'lodash-es'),
          join(entryDir, 'node_modules', 'lodash-es'),
        );

        const transformPlugin: ZntcPlugin = {
          name: 'transform-adds-lodash-import',
          setup(build) {
            build.onTransform({ filter: /main\.ts$/ }, () => ({
              code: 'import { uniq } from "lodash-es";\nconsole.log(uniq([1,2,2,3]).join(","));',
            }));
          },
        };

        const result = await build({
          entryPoints: [join(entryDir, 'main.ts')],
          platform: 'node',
          treeShaking: true,
          plugins: [transformPlugin],
        });
        expect(result.errors.length).toBe(0);
        const text = result.outputFiles[0].text;
        expect(text).toContain('uniq');
        expect(text).not.toContain('__ORIGINAL_LODASH_2038__');
        for (const dead of ['groupBy', 'orderBy', 'mapValues', 'debounce', 'throttle']) {
          expect(
            new RegExp(`(^|\\n)(function|const|var|let)\\s+${dead}\\b`, 'm').test(text),
            `dead lodash-es identifier "${dead}" leaked to transform-added bundle`,
          ).toBe(false);
        }
      } finally {
        rmSync(entryDir, { recursive: true, force: true });
      }
    },
  );
});
