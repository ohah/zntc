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

describe('@zntc/core build + plugins - transform hooks', () => {
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
    try {
      writeFileSync(join(entryDir, 'main.ts'), 'console.log("hello");');

      const result = await build({
        entryPoints: [join(entryDir, 'main.ts')],
        plugins: [transformPlugin],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('console.warn');
      expect(result.outputFiles[0].text).not.toContain('console.log');
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });

  test('transform filter 가 g 플래그여도 모든 매칭 파일 처리 (#4291)', async () => {
    // /…/g 정규식의 .test() 는 stateful(lastIndex 누적)이라, 미수정 시 파일을 격번 skip.
    const transformed: string[] = [];
    const plugin: ZntcPlugin = {
      name: 'g-filter-plugin',
      setup(build) {
        build.onTransform({ filter: /\.ts$/g }, (args) => {
          transformed.push(args.path ?? '');
          return { code: args.code.replace(/OLDVAL/g, 'NEWVAL') };
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-gfilter-'));
    try {
      writeFileSync(join(dir, 'a.ts'), 'import "./b.ts"; export const a = "OLDVAL";');
      writeFileSync(join(dir, 'b.ts'), 'import "./c.ts"; export const b = "OLDVAL";');
      writeFileSync(join(dir, 'c.ts'), 'import "./d.ts"; export const c = "OLDVAL";');
      writeFileSync(join(dir, 'd.ts'), 'export const d = "OLDVAL";');

      const result = await build({
        entryPoints: [join(dir, 'a.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      // 모든 .ts 파일(4개)이 transform 콜백을 받아야 한다 — 격번 skip 이면 4 미만.
      expect(transformed.length).toBe(4);
      // 어떤 파일도 변환 누락(OLDVAL 잔존)되면 안 된다.
      expect(result.outputFiles[0].text).not.toContain('OLDVAL');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
