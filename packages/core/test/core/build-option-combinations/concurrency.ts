import {
  afterAll,
  beforeAll,
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

describe('@zntc/core build 옵션 조합 - concurrency', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-combo-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import { helper } from "./util";\nconsole.log(helper());',
    );
    writeFileSync(join(dir, 'util.ts'), 'export function helper() { return 42; }');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('build async: 동시 5개 호출', async () => {
    const results = await Promise.all(
      Array.from({ length: 5 }, () => build({ entryPoints: [join(dir, 'index.ts')] })),
    );
    for (const r of results) {
      expect(r.errors.length).toBe(0);
      expect(r.outputFiles[0].text).toContain('helper');
    }
  });
});
