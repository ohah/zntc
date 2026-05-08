import {
  describe,
  test,
  expect,
  build,
  resolve,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core 플러그인 심화: multi hook', () => {
  test('멀티스레드: 동시 resolveId + load + transform (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt2-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');

    const hooksCalled: string[] = [];
    const multiHookPlugin: ZntcPlugin = {
      name: 'multi-hook',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => {
          hooksCalled.push('resolve');
          return { path: resolve(dir, args.path) };
        });
        build.onLoad({ filter: /\.css$/ }, () => {
          hooksCalled.push('load');
          return { contents: 'export default "red";' };
        });
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          hooksCalled.push('transform');
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [multiHookPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('red');
    expect(hooksCalled).toContain('resolve');
    expect(hooksCalled).toContain('load');
    expect(hooksCalled).toContain('transform');
    rmSync(dir, { recursive: true, force: true });
  });
});
