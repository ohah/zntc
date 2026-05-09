import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from '../helpers';

function createAsyncPluginFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-async-plugin-'));
  writeFileSync(join(dir, 'entry.ts'), 'import val from "./data.custom";\nconsole.log(val);');
  writeFileSync(join(dir, 'data.custom'), 'CUSTOM_DATA');
  return dir;
}

describe('vitePlugin async 훅 지원 > transform and mixed hooks', () => {
  test('async transform 훅', async () => {
    const dir = createAsyncPluginFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [
          vitePlugin({
            name: 'async-transformer',
            async transform(code, id) {
              if (id.endsWith('.ts')) {
                await new Promise((r) => setTimeout(r, 10));
                return code.replace('console.log', 'console.info');
              }
            },
          }),
          vitePlugin({
            name: 'custom-loader',
            load(id) {
              if (id.endsWith('.custom')) return { code: 'export default "X";' };
            },
          }),
        ],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('console.info');
      expect(result.outputFiles[0].text).not.toContain('console.log');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('동기 + 비동기 훅 혼합', async () => {
    const dir = createAsyncPluginFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [
          vitePlugin({
            name: 'sync-plugin',
            load(id) {
              if (id.endsWith('.custom')) return { code: 'export default "SYNC";' };
            },
          }),
          vitePlugin({
            name: 'async-plugin',
            async transform(code) {
              await new Promise((r) => setTimeout(r, 5));
              return code.replace('console.log', 'console.warn');
            },
          }),
        ],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('SYNC');
      expect(result.outputFiles[0].text).toContain('console.warn');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
