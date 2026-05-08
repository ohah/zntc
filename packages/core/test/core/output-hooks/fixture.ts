import { beforeAll, afterAll, mkdtempSync, writeFileSync, rmSync, join, tmpdir } from '../helpers';

export function useOutputHookFixture() {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-chunk-hooks-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  return {
    entryPoint() {
      return join(dir, 'entry.ts');
    },
  };
}
