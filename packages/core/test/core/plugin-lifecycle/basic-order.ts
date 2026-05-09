import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core plugin lifecycle > basic order', () => {
  test('buildStart / buildEnd / closeBundle 정상 build 시 호출 + 호출 순서', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

      const order: string[] = [];
      const plugin: ZntcPlugin = {
        name: 'lifecycle',
        setup(build) {
          build.onBuildStart(() => {
            order.push('buildStart');
          });
          build.onTransform({ filter: /\.ts$/ }, (args) => {
            order.push('transform');
            return { code: args.code };
          });
          build.onBuildEnd((err) => {
            order.push(err ? `buildEnd:err=${err.message}` : 'buildEnd');
          });
          build.onCloseBundle(() => {
            order.push('closeBundle');
          });
        },
      };

      await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });

      expect(order[0]).toBe('buildStart');
      expect(order[order.length - 2]).toBe('buildEnd');
      expect(order[order.length - 1]).toBe('closeBundle');
      expect(order).toContain('transform');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('buildStart / buildEnd / closeBundle 미등록 plugin 도 정상 build', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-empty-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const plugin: ZntcPlugin = {
        name: 'no-lifecycle',
        setup(build) {
          build.onTransform({ filter: /\.ts$/ }, (args) => ({ code: args.code }));
        },
      };
      const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
      expect(r.outputFiles[0].text).toContain('const x = 1');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
