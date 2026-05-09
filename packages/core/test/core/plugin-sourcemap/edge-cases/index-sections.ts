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

describe('@zntc/core plugin transform sourcemap chain > index map sections', () => {
  test('index map sections 입력의 section offset을 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-sections-'));
    try {
      const source = 'const SECTION_MAP_MARKER = 1;\nconsole.log(SECTION_MAP_MARKER);\n';
      writeFileSync(join(dir, 'entry.ts'), source);

      const plugin: ZntcPlugin = {
        name: 'sections-map',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
            code: 'const __sectionHeader = 0;\n' + args.code,
            map: {
              version: 3,
              sections: [
                {
                  offset: { line: 1, column: 0 },
                  map: {
                    version: 3,
                    sources: ['entry.ts'],
                    sourcesContent: [source],
                    mappings: lineOffsetMappings(0, 0, source.split('\n').length - 1),
                  },
                },
              ],
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
      expectMarkerMappedToSourceLine(result, 'SECTION_MAP_MARKER', 'entry.ts', 0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
