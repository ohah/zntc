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
} from '../../helpers';
import type { RollupPlugin } from '../../helpers';

describe('vitePlugin 어댑터 - 실전 GraphQL 로더 패턴', () => {
  test('실전 패턴: GraphQL 쿼리 로더', async () => {
    const gqlDir = mkdtempSync(join(tmpdir(), 'zntc-vite-gql-'));
    try {
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
    } finally {
      rmSync(gqlDir, { recursive: true, force: true });
    }
  });
});
