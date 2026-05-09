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

describe('vitePlugin async 훅 지원 > load and resolve', () => {
  test('async load 훅', async () => {
    const dir = createAsyncPluginFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [
          vitePlugin({
            name: 'async-loader',
            async load(id) {
              if (id.endsWith('.custom')) {
                await new Promise((r) => setTimeout(r, 10));
                return { code: 'export default "ASYNC_LOADED";' };
              }
            },
          }),
        ],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('ASYNC_LOADED');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('async resolveId 훅', async () => {
    const dir = createAsyncPluginFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [
          vitePlugin({
            name: 'async-resolver',
            async resolveId(source) {
              if (source.endsWith('.custom')) {
                await new Promise((r) => setTimeout(r, 10));
                return join(dir, 'data.custom');
              }
            },
            load(id) {
              if (id.endsWith('.custom')) return { code: 'export default "RESOLVED";' };
            },
          }),
        ],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('RESOLVED');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
