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
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core build + plugins - transform tree-shaking', () => {
  test('#2038: onTransform이 추가한 sideEffects:false 패키지 import도 tree-shaking 입력이 됨', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-plugin-pkg-'));
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

    try {
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

  test.skipIf(!existsSync(join(ROOT_NODE_MODULES, 'lodash-es', 'package.json')))(
    '#2038: 실제 lodash-es import를 onTransform으로 주입해도 dead export가 새지 않음',
    async () => {
      const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-lodash-plugin-'));
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

      try {
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

  // ============================================================
  // require.context — onResolveContext hook (#1579 Phase 2.5)
  // ============================================================
});
