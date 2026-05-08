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

describe('@zntc/core 옵션 조합 심화 - plugins', () => {
  test('build + platform=node + jsx=automatic + plugins (실제 코드 변환)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-node-jsx-'));
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const result = await build({
      entryPoints: [join(dir, 'app.tsx')],
      platform: 'node',
      jsx: 'automatic',
      external: ['react/jsx-runtime'],
      plugins: [
        {
          name: 'replace-transform',
          setup(build) {
            build.onTransform({ filter: /\.tsx$/ }, (args) => ({
              code: args.code.replace('hello', 'transformed'),
            }));
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('transformed');
    expect(result.outputFiles[0].text).toContain('jsx-runtime');
    rmSync(dir, { recursive: true, force: true });
  });

  test('build + define + plugins (define은 NAPI, plugin은 JS)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-plugin-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import css from "./style.css";\nconsole.log(__MODE__, css);',
    );

    const cssPlugin: ZntcPlugin = {
      name: 'css',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.css$/ }, () => ({ contents: 'export default "red";' }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      define: { __MODE__: '"production"' },
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    expect(result.outputFiles[0].text).toContain('red');
    rmSync(dir, { recursive: true, force: true });
  });
});
