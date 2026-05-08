import { afterAll, beforeAll, join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export function useLifecycleFixture() {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-lifecycle-'));
    writeFileSync(join(dir, 'lifecycle-entry.ts'), 'console.log("hi");');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  return {
    path(file: string) {
      return join(dir, file);
    },
  };
}
