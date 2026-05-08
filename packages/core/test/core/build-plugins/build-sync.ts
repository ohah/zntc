import {
  buildSync,
  describe,
  diagText,
  expect,
  expectPluginDiagnostic,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core build + plugins - buildSync hooks', () => {
  test('buildSync: onResolve/onLoad/onTransform sync plugin 동작', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-plugin-'));
    writeFileSync(
      join(syncDir, 'entry.ts'),
      'import msg from "virtual:message";\nconsole.log(msg);',
    );
    const virtualPath = join(syncDir, 'virtual-message.ts');

    const plugin: ZntcPlugin = {
      name: 'sync-plugin',
      setup(build) {
        build.onResolve({ filter: /^virtual:message$/ }, () => ({ path: virtualPath }));
        build.onLoad({ filter: /virtual-message\.ts$/ }, () => ({
          contents: 'export default "SYNC_LOAD";',
        }));
        build.onTransform({ filter: /virtual-message\.ts$/ }, (args) => ({
          code: args.code.replace('SYNC_LOAD', 'SYNC_TRANSFORM'),
        }));
      },
    };

    const result = buildSync({
      entryPoints: [join(syncDir, 'entry.ts')],
      plugins: [plugin],
    });

    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SYNC_TRANSFORM');
    rmSync(syncDir, { recursive: true, force: true });
  });

  test('buildSync: vitePlugin sync hooks 동작', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-vite-plugin-'));
    writeFileSync(
      join(syncDir, 'entry.ts'),
      'import { msg } from "virtual:vite";\nconsole.log(msg);',
    );
    const virtualPath = join(syncDir, 'virtual-vite.ts');

    const result = buildSync({
      entryPoints: [join(syncDir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-sync-plugin',
          resolveId(id) {
            if (id === 'virtual:vite') return virtualPath;
            return null;
          },
          load(id) {
            if (id === virtualPath) return 'export const msg = "VITE_LOAD";';
            return null;
          },
          transform(code, id) {
            if (id === virtualPath) return { code: code.replace('VITE_LOAD', 'VITE_TRANSFORM') };
            return null;
          },
        }),
      ],
    });

    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('VITE_TRANSFORM');
    rmSync(syncDir, { recursive: true, force: true });
  });

  test('buildSync: Promise 반환 plugin hook은 plugin_error로 실패하고 async build 안내를 포함', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-async-plugin-'));
    writeFileSync(join(syncDir, 'entry.ts'), 'import "./async-module";');
    writeFileSync(join(syncDir, 'async-module.ts'), 'console.log("original");');

    const plugin: ZntcPlugin = {
      name: 'async-in-sync-plugin',
      setup(build) {
        build.onLoad({ filter: /async-module\.ts$/ }, () =>
          Promise.resolve({ contents: 'console.log("async");' }),
        );
      },
    };

    const result = buildSync({
      entryPoints: [join(syncDir, 'entry.ts')],
      plugins: [plugin],
    });

    expectPluginDiagnostic(result, {
      plugin: 'async-in-sync-plugin',
      hook: 'load',
      message: 'buildSync() does not support async plugin hooks',
      fileIncludes: 'async-module.ts',
    });
    expect(diagText(result.errors[0])).toContain('use build() instead');
    rmSync(syncDir, { recursive: true, force: true });
  });
});
