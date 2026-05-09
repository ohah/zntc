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

describe('@zntc/core build + plugins - disabled resolve hooks', () => {
  test('onResolve disabled: true → 빈 모듈로 대체 (Metro empty / webpack false 매핑)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-disabled-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
