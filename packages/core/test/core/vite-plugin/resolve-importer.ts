import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  resolve,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { RollupPlugin } from './helpers';

describe('vitePlugin 어댑터 - resolveId importer', () => {
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
});
