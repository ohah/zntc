import { join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export {
  afterAll,
  beforeAll,
  build,
  buildSync,
  describe,
  expect,
  join,
  readFileSync,
  rmSync,
  test,
  vitePlugin,
  writeFileSync,
} from '../helpers';

export function createOptionCombinationFixture(): string {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-'));
  writeFileSync(
    join(dir, 'app.ts'),
    'import { util } from "./lib";\nDEV: { console.log("debug"); }\nconsole.log(util());',
  );
  writeFileSync(join(dir, 'lib.ts'), 'export function util() { return 42; }');
  writeFileSync(join(dir, 'logo.txt'), 'LOGO_TEXT');
  writeFileSync(
    join(dir, 'with-license.ts'),
    '/** @license Apache-2.0 */\nexport const licensed = "yes";',
  );
  return dir;
}

export function removeOptionCombinationFixture(dir: string): void {
  rmSync(dir, { recursive: true, force: true });
}
