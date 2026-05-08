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
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { RollupPlugin, ZntcPlugin } from './helpers';

describe('vitePlugin 어댑터 - 기본 훅 반환값', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-vite-adapter-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(join(dir, 'app.ts'), 'import { greet } from "./util";\nconsole.log(greet());');
    writeFileSync(join(dir, 'util.ts'), "export function greet(): string { return 'Hello!'; }");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('resolveId 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "red";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('red');
  });

  test('resolveId 훅 — { id } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-object',
      resolveId(source) {
        if (source.endsWith('.css')) return { id: resolve(dir, source) };
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "blue";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('blue');
  });

  test('load 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "from-string";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-string');
  });

  test('load 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-object',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "from-object";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-object');
  });

  test('transform 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-string',
      transform(code, _id) {
        return code.replace('Hello!', 'Transformed!');
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Transformed!');
  });

  test('transform 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-object',
      transform(code, _id) {
        return { code: code.replace('Hello!', 'ObjectTransformed!') };
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ObjectTransformed!');
  });

  test('transform 훅 — null 반환 (통과)', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-null',
      transform() {
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });

  test('여러 Rollup 플러그인 조합', async () => {
    const resolverPlugin: RollupPlugin = {
      name: 'resolver',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
    };

    const loaderPlugin: RollupPlugin = {
      name: 'loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "multi-plugin";';
        return null;
      },
    };

    const transformerPlugin: RollupPlugin = {
      name: 'transformer',
      transform(code, _id) {
        return code.replace('multi-plugin', 'MULTI-TRANSFORMED');
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin(resolverPlugin),
        vitePlugin(loaderPlugin),
        vitePlugin(transformerPlugin),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MULTI-TRANSFORMED');
  });

  test('ZNTC 플러그인과 Vite 플러그인 혼합', async () => {
    const nativePlugin: ZntcPlugin = {
      name: 'native-resolve',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };

    const rollupLoader: RollupPlugin = {
      name: 'rollup-loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "mixed";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [nativePlugin, vitePlugin(rollupLoader)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('mixed');
  });

  test('훅이 없는 빈 Rollup 플러그인', async () => {
    const emptyPlugin: RollupPlugin = { name: 'empty' };
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(emptyPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });

  test('resolveId에서 undefined/void 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'void-return',
      resolveId() {
        // void — 아무것도 반환하지 않음
      },
    };
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
  });
});
