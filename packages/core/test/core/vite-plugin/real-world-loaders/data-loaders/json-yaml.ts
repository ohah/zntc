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

describe('vitePlugin 어댑터 - 실전 JSON/YAML 로더 패턴', () => {
  test('실전 패턴: JSON 플러그인 (Rollup 스타일)', async () => {
    const jsonDir = mkdtempSync(join(tmpdir(), 'zntc-vite-json-'));
    try {
      writeFileSync(join(jsonDir, 'data.json'), '{"name":"test","version":"1.0"}');
      writeFileSync(
        join(jsonDir, 'index.ts'),
        'import data from "./data.json";\nconsole.log(data.name);',
      );

      const jsonPlugin: RollupPlugin = {
        name: 'rollup-json',
        resolveId(source, importer) {
          if (source.endsWith('.json') && importer) return resolve(jsonDir, source);
          return null;
        },
        load(id) {
          if (id.endsWith('.json')) return `export default ${readFileSync(id, 'utf8')};`;
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
    } finally {
      rmSync(jsonDir, { recursive: true, force: true });
    }
  });

  test('실전 패턴: YAML 로더 플러그인', async () => {
    const yamlDir = mkdtempSync(join(tmpdir(), 'zntc-vite-yaml-'));
    try {
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
          if (!id.endsWith('.yaml')) return null;
          const obj: Record<string, string> = {};
          for (const line of readFileSync(id, 'utf8').split('\n')) {
            const [k, v] = line.split(': ');
            if (k && v) obj[k.trim()] = v.trim();
          }
          return `export default ${JSON.stringify(obj)};`;
        },
      };

      const result = await build({
        entryPoints: [join(yamlDir, 'index.ts')],
        plugins: [vitePlugin(yamlPlugin)],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('test');
      expect(result.outputFiles[0].text).toContain('2.0');
    } finally {
      rmSync(yamlDir, { recursive: true, force: true });
    }
  });
});
