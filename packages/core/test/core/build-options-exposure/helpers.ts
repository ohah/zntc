export {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  resolve,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
  runBundleStdout,
} from '../helpers';

import { beforeAll, afterAll, mkdtempSync, writeFileSync, rmSync, join, tmpdir } from '../helpers';

export type { ZntcPlugin } from '../helpers';

export function useBuildOptionsFixture() {
  let dir = '';

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-build-opts-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const fn = () => 1;');
    writeFileSync(join(dir, 'data.txt'), 'hello text');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  return () => dir;
}
