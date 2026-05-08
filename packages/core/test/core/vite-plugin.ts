import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  vitePlugin,
  resolve,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
  expectPluginDiagnostic,
  lineOffsetMappings,
  expectMarkerMappedToSourceLine,
} from './helpers';

describe('vitePlugin 어댑터', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-vite-adapter-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(join(dir, 'app.ts'), 'import { greet } from "./util";\nconsole.log(greet());');
    writeFileSync(join(dir, 'util.ts'), "export function greet(): string { return 'Hello!'; }");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('resolveId 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "red";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('red');
  });

  test('resolveId 훅 — { id } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-object',
      resolveId(source) {
        if (source.endsWith('.css')) return { id: resolve(dir, source) };
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "blue";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('blue');
  });

  test('load 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "from-string";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-string');
  });

  test('load 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-object',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "from-object";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-object');
  });

  test('transform 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-string',
      transform(code, _id) {
        return code.replace('Hello!', 'Transformed!');
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Transformed!');
  });

  test('transform 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-object',
      transform(code, _id) {
        return { code: code.replace('Hello!', 'ObjectTransformed!') };
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ObjectTransformed!');
  });

  test('transform 훅 — null 반환 (통과)', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-null',
      transform() {
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });

  test('여러 Rollup 플러그인 조합', async () => {
    const resolverPlugin: RollupPlugin = {
      name: 'resolver',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
    };

    const loaderPlugin: RollupPlugin = {
      name: 'loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "multi-plugin";';
        return null;
      },
    };

    const transformerPlugin: RollupPlugin = {
      name: 'transformer',
      transform(code, _id) {
        return code.replace('multi-plugin', 'MULTI-TRANSFORMED');
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin(resolverPlugin),
        vitePlugin(loaderPlugin),
        vitePlugin(transformerPlugin),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MULTI-TRANSFORMED');
  });

  test('ZNTC 플러그인과 Vite 플러그인 혼합', async () => {
    const nativePlugin: ZntcPlugin = {
      name: 'native-resolve',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };

    const rollupLoader: RollupPlugin = {
      name: 'rollup-loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "mixed";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [nativePlugin, vitePlugin(rollupLoader)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('mixed');
  });

  test('훅이 없는 빈 Rollup 플러그인', async () => {
    const emptyPlugin: RollupPlugin = { name: 'empty' };
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(emptyPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });

  test('resolveId에서 undefined/void 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'void-return',
      resolveId() {
        // void — 아무것도 반환하지 않음
      },
    };
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
  });

  test('실전 패턴: JSON 플러그인 (Rollup 스타일)', async () => {
    const jsonDir = mkdtempSync(join(tmpdir(), 'zntc-vite-json-'));
    writeFileSync(join(jsonDir, 'data.json'), '{"name":"test","version":"1.0"}');
    writeFileSync(
      join(jsonDir, 'index.ts'),
      'import data from "./data.json";\nconsole.log(data.name);',
    );

    const jsonPlugin: RollupPlugin = {
      name: 'rollup-json',
      resolveId(source, importer) {
        if (source.endsWith('.json') && importer) {
          return resolve(jsonDir, source);
        }
        return null;
      },
      load(id) {
        if (id.endsWith('.json')) {
          const json = readFileSync(id, 'utf8');
          return `export default ${json};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(jsonDir, 'index.ts')],
      plugins: [vitePlugin(jsonPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('test');
    expect(result.outputFiles[0].text).toContain('1.0');
    rmSync(jsonDir, { recursive: true, force: true });
  });

  test('실전 패턴: 환경 변수 치환 플러그인', async () => {
    const envDir = mkdtempSync(join(tmpdir(), 'zntc-vite-env-'));
    writeFileSync(join(envDir, 'index.ts'), 'console.log(import.meta.env.MODE);');

    const envPlugin: RollupPlugin = {
      name: 'rollup-env',
      transform(code, _id) {
        return code.replace('import.meta.env.MODE', '"production"');
      },
    };

    const result = await build({
      entryPoints: [join(envDir, 'index.ts')],
      plugins: [vitePlugin(envPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    rmSync(envDir, { recursive: true, force: true });
  });

  test('실전 패턴: YAML 로더 플러그인', async () => {
    const yamlDir = mkdtempSync(join(tmpdir(), 'zntc-vite-yaml-'));
    writeFileSync(join(yamlDir, 'config.yaml'), 'name: test\nversion: 2.0');
    writeFileSync(
      join(yamlDir, 'index.ts'),
      'import config from "./config.yaml";\nconsole.log(config);',
    );

    const yamlPlugin: RollupPlugin = {
      name: 'rollup-yaml',
      resolveId(source, importer) {
        if (source.endsWith('.yaml') && importer) return resolve(yamlDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.yaml')) {
          const content = readFileSync(id, 'utf8');
          const obj: Record<string, string> = {};
          for (const line of content.split('\n')) {
            const [k, v] = line.split(': ');
            if (k && v) obj[k.trim()] = v.trim();
          }
          return `export default ${JSON.stringify(obj)};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(yamlDir, 'index.ts')],
      plugins: [vitePlugin(yamlPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('test');
    expect(result.outputFiles[0].text).toContain('2.0');
    rmSync(yamlDir, { recursive: true, force: true });
  });

  test('실전 패턴: SVG → React 컴포넌트 플러그인', async () => {
    const svgDir = mkdtempSync(join(tmpdir(), 'zntc-vite-svg-'));
    writeFileSync(join(svgDir, 'icon.svg'), '<svg><circle r="10"/></svg>');
    writeFileSync(join(svgDir, 'index.tsx'), 'import Icon from "./icon.svg";\nconsole.log(Icon);');

    const svgPlugin: RollupPlugin = {
      name: 'rollup-svg-react',
      resolveId(source, importer) {
        if (source.endsWith('.svg') && importer) return resolve(svgDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.svg')) {
          const svg = readFileSync(id, 'utf8');
          return `export default function SvgIcon() { return "${svg.replace(/"/g, '\\"')}"; }`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(svgDir, 'index.tsx')],
      plugins: [vitePlugin(svgPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SvgIcon');
    expect(result.outputFiles[0].text).toContain('circle');
    rmSync(svgDir, { recursive: true, force: true });
  });

  test('실전 패턴: GraphQL 쿼리 로더', async () => {
    const gqlDir = mkdtempSync(join(tmpdir(), 'zntc-vite-gql-'));
    writeFileSync(join(gqlDir, 'query.graphql'), 'query GetUser { user { name } }');
    writeFileSync(
      join(gqlDir, 'index.ts'),
      'import query from "./query.graphql";\nconsole.log(query);',
    );

    const gqlPlugin: RollupPlugin = {
      name: 'rollup-graphql',
      resolveId(source, importer) {
        if (source.endsWith('.graphql') && importer) return resolve(gqlDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.graphql')) {
          const content = readFileSync(id, 'utf8');
          return `export default ${JSON.stringify(content)};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(gqlDir, 'index.ts')],
      plugins: [vitePlugin(gqlPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('GetUser');
    rmSync(gqlDir, { recursive: true, force: true });
  });

  test('실전 패턴: 코드 내 console.log 자동 제거 transform', async () => {
    const stripDir = mkdtempSync(join(tmpdir(), 'zntc-vite-strip-'));
    writeFileSync(
      join(stripDir, 'index.ts'),
      'console.log("debug");\nconst x = 1;\nconsole.log("also debug");\nconsole.warn("keep");',
    );

    const stripPlugin: RollupPlugin = {
      name: 'rollup-strip-console-log',
      transform(code, _id) {
        return code.replace(/console\.log\([^)]*\);?\n?/g, '');
      },
    };

    const result = await build({
      entryPoints: [join(stripDir, 'index.ts')],
      plugins: [vitePlugin(stripPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('console.log');
    expect(result.outputFiles[0].text).toContain('console.warn');
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(stripDir, { recursive: true, force: true });
  });

  test('실전 패턴: 다중 vitePlugin transform 체이닝', async () => {
    const chainDir = mkdtempSync(join(tmpdir(), 'zntc-vite-chain-'));
    writeFileSync(join(chainDir, 'index.ts'), 'const msg = "HELLO_WORLD";');

    // 첫 번째 플러그인: HELLO → Hello
    const lowercasePlugin: RollupPlugin = {
      name: 'lowercase-first',
      transform(code) {
        return code.replace('HELLO', 'Hello');
      },
    };

    // 두 번째 플러그인: _WORLD → _World (첫 번째 결과를 입력으로 받음)
    const capitalizePlugin: RollupPlugin = {
      name: 'capitalize-second',
      transform(code) {
        return code.replace('_WORLD', '_World');
      },
    };

    const result = await build({
      entryPoints: [join(chainDir, 'index.ts')],
      plugins: [vitePlugin(lowercasePlugin), vitePlugin(capitalizePlugin)],
    });
    expect(result.errors.length).toBe(0);
    // 두 플러그인의 transform이 순차 체이닝되어야 함
    expect(result.outputFiles[0].text).toContain('Hello_World');
    rmSync(chainDir, { recursive: true, force: true });
  });

  test('실전 패턴: 3개 플러그인 transform 체이닝', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-chain3-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "AAA_BBB_CCC";');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [
        vitePlugin({ name: 'p1', transform: (code) => code.replace('AAA', 'aaa') }),
        vitePlugin({ name: 'p2', transform: (code) => code.replace('BBB', 'bbb') }),
        vitePlugin({ name: 'p3', transform: (code) => code.replace('CCC', 'ccc') }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('aaa_bbb_ccc');
    rmSync(dir, { recursive: true, force: true });
  });

  test('vitePlugin: resolveId에 importer가 올바르게 전달됨', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-importer-'));
    writeFileSync(join(dir, 'entry.ts'), 'import x from "./data.custom";\nconsole.log(x);');

    let receivedImporter: string | null | undefined = undefined;
    const plugin: RollupPlugin = {
      name: 'check-importer',
      resolveId(source, importer) {
        if (source.endsWith('.custom')) {
          receivedImporter = importer ?? null;
          return resolve(dir, source);
        }
        return null;
      },
      load(id) {
        if (id.endsWith('.custom')) return 'export default "custom-data";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    // importer는 entry.ts의 절대 경로여야 함
    expect(receivedImporter).toContain('entry.ts');
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin_error: vitePlugin.resolveId sync throw가 diagnostic으로 노출됨', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-resolve-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'import "virtual:boom";');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-resolve-fail',
          resolveId(source) {
            if (source === 'virtual:boom') throw new Error('resolve exploded');
          },
        }),
      ],
    });
    expectPluginDiagnostic(result, {
      plugin: 'vite-resolve-fail',
      hook: 'resolveId',
      message: 'resolve exploded',
      fileIncludes: 'entry.ts',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin_error: vitePlugin.load의 this.error가 RollupError-like location을 보존', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-this-error-'));
    const virtualId = join(dir, 'virtual.ts');
    writeFileSync(join(dir, 'entry.ts'), 'import "./virtual";');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-this-error',
          resolveId(source) {
            if (source === './virtual') return virtualId;
          },
          load(id) {
            if (id === virtualId) {
              this.error({
                message: 'rollup context failed',
                id,
                loc: { file: id, line: 7, column: 3 },
              });
            }
          },
        } as RollupPlugin),
      ],
    });
    expectPluginDiagnostic(result, {
      plugin: 'vite-this-error',
      hook: 'load',
      message: 'rollup context failed',
      fileIncludes: 'virtual.ts',
      textIncludes: '7:3',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin_error: vitePlugin.transform async reject가 diagnostic으로 노출됨', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-transform-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'console.log("vite transform");');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-transform-fail',
          async transform() {
            throw new Error('vite transform rejected');
          },
        }),
      ],
    });
    expectPluginDiagnostic(result, {
      plugin: 'vite-transform-fail',
      hook: 'transform',
      message: 'vite transform rejected',
      fileIncludes: 'entry.ts',
    });
    rmSync(dir, { recursive: true, force: true });
  });

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
