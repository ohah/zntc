import {
  describe,
  test,
  expect,
  build,
  watch,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
  lineOffsetMappings,
  parseBundleMap,
  expectMarkerMappedToSourceLine,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin transform sourcemap chain > lazy parity', () => {
  test('plugin transform map은 eager/lazy sourcemap JSON에서 동일하게 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-lazy-'));
    const source = 'const LAZY_MAP_MARKER = 1;\nconsole.log(LAZY_MAP_MARKER);\n';
    writeFileSync(join(dir, 'entry.ts'), source);

    const plugin: ZntcPlugin = {
      name: 'lazy-map',
      setup(build) {
        build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
          code: 'const __lazyHeader = 0;\n' + args.code,
          map: {
            version: 3,
            sources: ['entry.ts'],
            sourcesContent: [source],
            mappings: lineOffsetMappings(1, 0, source.split('\n').length - 1),
          },
        }));
      },
    };

    const eager = await build({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      plugins: [plugin],
    });
    expect(eager.errors.length).toBe(0);
    const eagerMap = parseBundleMap(eager).map;
    expectMarkerMappedToSourceLine(eager, 'LAZY_MAP_MARKER', 'entry.ts', 0);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      plugins: [plugin],
      onReady() {
        readyDone();
      },
    });
    await readyP;
    const lazyMap = JSON.parse(handle.getBundleSourceMap()!);
    expect(lazyMap.sources).toEqual(eagerMap.sources);
    expect(lazyMap.mappings).toEqual(eagerMap.mappings);
    expectMarkerMappedToSourceLine(
      {
        outputFiles: [
          { path: join(dir, 'bundle.js'), text: readFileSync(join(dir, 'bundle.js'), 'utf-8') },
          { path: join(dir, 'bundle.js.map'), text: JSON.stringify(lazyMap) },
        ],
      },
      'LAZY_MAP_MARKER',
      'entry.ts',
      0,
    );
    handle.stop();
    rmSync(dir, { recursive: true, force: true });
  }, 10000);
});
