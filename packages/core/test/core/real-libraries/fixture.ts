import {
  afterAll,
  beforeAll,
  join,
  mkdtempSync,
  rmSync,
  tmpdir,
  ROOT_NODE_MODULES,
} from '../helpers';

export function useRealLibraryFixture() {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-real-lib-'));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  return {
    get dir() {
      return dir;
    },
    path(file: string) {
      return join(dir, file);
    },
    projectNodeModules: ROOT_NODE_MODULES,
  };
}
