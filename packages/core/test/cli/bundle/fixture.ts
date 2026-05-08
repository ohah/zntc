import { afterAll, beforeAll, join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export function useBundleFixture() {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-bundle-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, 'util.ts'),
      'export function hello(name: string): string { return `Hello, ${name}!`; }',
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  return {
    dir() {
      return dir;
    },
    entryPoint() {
      return join(dir, 'entry.ts');
    },
  };
}
