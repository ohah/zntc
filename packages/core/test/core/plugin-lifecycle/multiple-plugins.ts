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

describe('@zntc/core plugin lifecycle > multiple plugins', () => {
  test('다중 plugin: 모든 plugin 의 buildStart / buildEnd / closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-multi-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

      let p1Start = 0,
        p2Start = 0,
        p1End = 0,
        p2End = 0,
        p1Close = 0,
        p2Close = 0;
      const p1: ZntcPlugin = {
        name: 'p1',
        setup(b) {
          b.onBuildStart(() => {
            p1Start++;
          });
          b.onBuildEnd(() => {
            p1End++;
          });
          b.onCloseBundle(() => {
            p1Close++;
          });
        },
      };
      const p2: ZntcPlugin = {
        name: 'p2',
        setup(b) {
          b.onBuildStart(() => {
            p2Start++;
          });
          b.onBuildEnd(() => {
            p2End++;
          });
          b.onCloseBundle(() => {
            p2Close++;
          });
        },
      };
      await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [p1, p2] });
      expect(p1Start).toBe(1);
      expect(p2Start).toBe(1);
      expect(p1End).toBe(1);
      expect(p2End).toBe(1);
      expect(p1Close).toBe(1);
      expect(p2Close).toBe(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
