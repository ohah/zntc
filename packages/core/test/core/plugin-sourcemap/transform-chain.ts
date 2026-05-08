import {
  describe,
  test,
  expect,
  build,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
  lineOffsetMappings,
  expectMarkerMappedToSourceLine,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin transform sourcemap chain > transform chain', () => {
  test('2단 onTransform map chain을 원본 위치까지 역추적', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-chain-'));
    const source = 'const CHAIN_MAP_MARKER = 1;\nconsole.log(CHAIN_MAP_MARKER);\n';
    writeFileSync(join(dir, 'entry.ts'), source);
    const stage1 = 'const __stageOne = 1;\n' + source;

    const stage1Plugin: ZntcPlugin = {
      name: 'stage-one-map',
      setup(build) {
        build.onTransform({ filter: /entry\.ts$/ }, () => ({
          code: stage1,
          map: {
            version: 3,
            sources: ['entry.ts'],
            sourcesContent: [source],
            mappings: lineOffsetMappings(1, 0, source.split('\n').length - 1),
          },
        }));
      },
    };
    const stage2Plugin: ZntcPlugin = {
      name: 'stage-two-map',
      setup(build) {
        build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
          code: 'const __stageTwo = 2;\n' + args.code,
          map: {
            version: 3,
            sources: ['stage1.js'],
            sourcesContent: [stage1],
            mappings: lineOffsetMappings(1, 0, stage1.split('\n').length - 1),
          },
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
      plugins: [stage1Plugin, stage2Plugin],
    });
    expect(result.errors.length).toBe(0);
    expectMarkerMappedToSourceLine(result, 'CHAIN_MAP_MARKER', 'entry.ts', 0);
    rmSync(dir, { recursive: true, force: true });
  });
});
