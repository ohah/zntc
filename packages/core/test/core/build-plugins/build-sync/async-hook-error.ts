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
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core build + plugins - buildSync async hook errors', () => {
  test('buildSync: Promise 반환 plugin hook은 plugin_error로 실패하고 async build 안내를 포함', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-async-plugin-'));
    try {
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
    } finally {
      rmSync(syncDir, { recursive: true, force: true });
    }
  });
});
