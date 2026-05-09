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
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core build + plugins - resolve and load hooks', () => {
  test('onResolve + onLoad 플러그인 (CSS → JS 변환)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-css-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
      const cssPlugin: ZntcPlugin = {
        name: 'css-plugin',
        setup(build) {
          build.onResolve({ filter: /\.css$/ }, (args) => ({
            path: resolve(dir, args.path),
          }));
          build.onLoad({ filter: /\.css$/ }, () => ({
            contents: 'export default "color: red";',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [cssPlugin],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('color: red');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('multiple plugins 체이닝', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-chain-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
      const plugin1: ZntcPlugin = {
        name: 'css-resolve',
        setup(build) {
          build.onResolve({ filter: /\.css$/ }, (args) => ({
            path: resolve(dir, args.path),
          }));
        },
      };
      const plugin2: ZntcPlugin = {
        name: 'css-load',
        setup(build) {
          build.onLoad({ filter: /\.css$/ }, () => ({
            contents: 'export default "blue";',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin1, plugin2],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('blue');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
