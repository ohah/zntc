import {
  build,
  describe,
  expect,
  expectMarkerMappedToSourceLine,
  join,
  lineOffsetMappings,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core plugin transform sourcemap chain > load source maps', () => {
  test('onLoad map을 최종 sourcemap에 합성', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-load-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'import "./virtual";\n');
      const virtualPath = join(dir, 'virtual.ts');
      const source = 'const LOAD_MAP_MARKER = 1;\nconsole.log(LOAD_MAP_MARKER);\n';

      const plugin: ZntcPlugin = {
        name: 'load-map',
        setup(build) {
          build.onResolve({ filter: /^\.\/virtual$/ }, () => ({ path: virtualPath }));
          build.onLoad({ filter: /virtual\.ts$/ }, () => ({
            contents: 'const __loadHeader = 0;\n' + source,
            map: {
              version: 3,
              sources: ['virtual-original.ts'],
              sourcesContent: [source],
              mappings: lineOffsetMappings(1, 0, source.split('\n').length - 1),
            },
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        sourcemap: true,
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expectMarkerMappedToSourceLine(result, 'LOAD_MAP_MARKER', 'virtual-original.ts', 0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
