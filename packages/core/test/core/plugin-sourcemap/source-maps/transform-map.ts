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

describe('@zntc/core plugin transform sourcemap chain > transform source maps', () => {
  test('단일 onTransform map을 최종 sourcemap에 합성', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-single-'));
    try {
      const source = 'const SINGLE_MAP_MARKER = 1;\nconsole.log(SINGLE_MAP_MARKER);\n';
      writeFileSync(join(dir, 'entry.ts'), source);

      const plugin: ZntcPlugin = {
        name: 'single-map',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
            code: 'const __singleHeader = 0;\n' + args.code,
            map: {
              version: 3,
              sources: ['entry.ts'],
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
      expectMarkerMappedToSourceLine(result, 'SINGLE_MAP_MARKER', 'entry.ts', 0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('onTransform map만 반환해도 최종 sourcemap에 합성', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-only-'));
    try {
      const source = 'const MAP_ONLY_MARKER = 1;\nconsole.log(MAP_ONLY_MARKER);\n';
      const original = '\n\n\n\n\n' + source;
      writeFileSync(join(dir, 'entry.ts'), source);

      const plugin: ZntcPlugin = {
        name: 'map-only',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
            code: args.code,
            map: {
              version: 3,
              sources: ['original.ts'],
              sourcesContent: [original],
              mappings: lineOffsetMappings(0, 5, source.split('\n').length - 1),
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
      expectMarkerMappedToSourceLine(result, 'MAP_ONLY_MARKER', 'original.ts', 5);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
