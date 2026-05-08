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
  expectPluginDiagnostic,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core 플러그인 심화', () => {
  test('plugin_error: thrown string과 hook 이름을 보존', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-throw-'));
    writeFileSync(join(dir, 'index.ts'), 'import "./data.json";');

    const throwPlugin: ZntcPlugin = {
      name: 'throw-on-load',
      setup(build) {
        build.onResolve({ filter: /\.json$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.json$/ }, () => {
          throw 'plain string failure';
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [throwPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'throw-on-load',
      hook: 'load',
      message: 'plain string failure',
      fileIncludes: 'data.json',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('다중 모듈 번들 + 플러그인', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-large-'));

    // 5개 모듈 생성
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 5 }, (_, i) => `val${i}`).join(' + ');
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(${usage});`);

    let transformCount = 0;
    const countPlugin: ZntcPlugin = {
      name: 'count-transforms',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          transformCount++;
          return null; // 변환 없이 카운트만
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('val4');
    // 최소 1회 이상 transform 호출됨
    expect(transformCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('플러그인 콜백이 undefined 반환 (null과 동일 처리)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-undef-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const undefPlugin: ZntcPlugin = {
      name: 'undef-return',
      setup(build) {
        build.onLoad({ filter: /\.ts$/ }, () => undefined as any);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [undefPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('멀티스레드: 10개 모듈 + onTransform 플러그인 (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt-'));
    for (let i = 0; i < 10; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 10 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 10 }, (_, i) => `val${i}`).join(' + ');
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(${usage});`);

    let callCount = 0;
    const countPlugin: ZntcPlugin = {
      name: 'count',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          callCount++;
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('val9');
    expect(callCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

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

  test('멀티스레드: 플러그인 + minify + sourcemap 동시 (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt3-'));
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(val0);`);

    const noopPlugin: ZntcPlugin = {
      name: 'noop',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [noopPlugin],
      minify: true,
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2); // js + map
    rmSync(dir, { recursive: true, force: true });
  });
});
