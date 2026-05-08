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
  expectPluginDiagnostic,
  lineOffsetMappings,
  parseBundleMap,
  expectMarkerMappedToSourceLine,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin transform sourcemap chain', () => {
  test('onLoad map을 최종 sourcemap에 합성', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-load-'));
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
    rmSync(dir, { recursive: true, force: true });
  });

  test('단일 onTransform map을 최종 sourcemap에 합성', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-single-'));
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
    rmSync(dir, { recursive: true, force: true });
  });

  test('onTransform map만 반환해도 최종 sourcemap에 합성', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-only-'));
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
    rmSync(dir, { recursive: true, force: true });
  });

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

  test('map: null은 sourcemap 합성을 건너뛰고 빌드를 실패시키지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-null-'));
    writeFileSync(join(dir, 'entry.ts'), 'const NULL_MAP_MARKER = 1;\n');

    const plugin: ZntcPlugin = {
      name: 'null-map',
      setup(build) {
        build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
          code: args.code.replace('1', '2'),
          map: null,
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
      plugins: [plugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('NULL_MAP_MARKER');
    rmSync(dir, { recursive: true, force: true });
  });

  test('invalid transform map은 plugin_error diagnostic으로 실패', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-invalid-'));
    writeFileSync(join(dir, 'entry.ts'), 'const INVALID_MAP_MARKER = 1;\n');

    const plugin: ZntcPlugin = {
      name: 'invalid-map',
      setup(build) {
        build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
          code: args.code,
          map: '{ invalid sourcemap json',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
      plugins: [plugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'invalid-map',
      hook: 'transform',
      message: 'Invalid sourcemap',
      fileIncludes: 'entry.ts',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('index map sections 입력의 section offset을 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-sections-'));
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
    rmSync(dir, { recursive: true, force: true });
  });

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

// ─── 옵션 조합 심화 테스트 ───
