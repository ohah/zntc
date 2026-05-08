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
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { RollupPlugin } from './helpers';

describe('vitePlugin 어댑터 - sourcemap', () => {
  test('vitePlugin: transform이 { code, map } 반환 시 최종 sourcemap에 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-map-'));
    const source = 'const VITE_MAP_MARKER = 1;\nconsole.log(VITE_MAP_MARKER);\n';
    writeFileSync(join(dir, 'index.ts'), source);

    const plugin: RollupPlugin = {
      name: 'with-map',
      transform(code) {
        return {
          code: 'const __viteHeader = 0;\n' + code,
          map: {
            version: 3,
            sources: ['index.ts'],
            sourcesContent: [source],
            mappings: lineOffsetMappings(1, 0, source.split('\n').length - 1),
          },
        };
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      sourcemap: true,
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expectMarkerMappedToSourceLine(result, 'VITE_MAP_MARKER', 'index.ts', 0);
    rmSync(dir, { recursive: true, force: true });
  });
});
