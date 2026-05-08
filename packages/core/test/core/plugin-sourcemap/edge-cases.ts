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
  expectPluginDiagnostic,
  lineOffsetMappings,
  expectMarkerMappedToSourceLine,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin transform sourcemap chain > edge cases', () => {
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
});
