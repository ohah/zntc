import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  readFileSync,
  resolve,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from '../helpers';
import type { RollupPlugin } from '../helpers';

describe('vitePlugin 어댑터 - 실전 로더 패턴', () => {
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
});
