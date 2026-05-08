import {
  afterAll,
  beforeAll,
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
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core build + plugins - basic hooks', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('onResolve disabled: true → 빈 모듈로 대체 (Metro empty / webpack false 매핑)', async () => {
    // entry가 'should-be-empty'를 import. plugin이 disabled로 매핑.
    writeFileSync(
      join(dir, 'entry-disabled.ts'),
      `import * as m from "should-be-empty"; console.log(typeof m);`,
    );
    const disabledPlugin: ZntcPlugin = {
      name: 'disabled-resolver',
      setup(build) {
        build.onResolve({ filter: /^should-be-empty$/ }, () => ({
          disabled: true,
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry-disabled.ts')],
      plugins: [disabledPlugin],
    });
    expect(result.errors.length).toBe(0);
    // disabled 모듈은 빈 객체 export → typeof는 "object"
    expect(result.outputFiles[0].text).toMatch(/should-be-empty|module\.exports\s*=/);
  });

  test('onResolve + onLoad 플러그인 (CSS → JS 변환)', async () => {
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
  });

  test('multiple plugins 체이닝', async () => {
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
  });

  test('onTransform 플러그인 (코드 변환)', async () => {
    const transformPlugin: ZntcPlugin = {
      name: 'transform-plugin',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({
          code: args.code.replace('console.log', 'console.warn'),
        }));
      },
    };

    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-transform-'));
    writeFileSync(join(entryDir, 'main.ts'), 'console.log("hello");');

    const result = await build({
      entryPoints: [join(entryDir, 'main.ts')],
      plugins: [transformPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('console.warn');
    expect(result.outputFiles[0].text).not.toContain('console.log');
    rmSync(entryDir, { recursive: true, force: true });
  });
});
