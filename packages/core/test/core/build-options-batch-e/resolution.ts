import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  mkdirSync,
  test,
  writeFileSync,
} from '../helpers';
import { createBatchEFixture, type BatchEFixture } from './fixture';

describe('배치 E: S급 BuildOptions - resolution', () => {
  let fixture: BatchEFixture;

  beforeAll(() => {
    fixture = createBatchEFixture();
  });

  afterAll(() => fixture.cleanup());

  test('preserveSymlinks: 옵션 파싱 확인', () => {
    const result = buildSync({
      entryPoints: [fixture.entry],
      preserveSymlinks: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('nodePaths: 추가 탐색 경로', () => {
    const vendor = join(fixture.dir, 'vendor');
    mkdirSync(join(vendor, 'pkg'), { recursive: true });
    writeFileSync(join(vendor, 'pkg', 'package.json'), JSON.stringify({ main: 'index.js' }));
    writeFileSync(join(vendor, 'pkg', 'index.js'), "export const value = 'NODE_PATH_VALUE';");
    writeFileSync(
      join(fixture.dir, 'node-paths.ts'),
      "import { value } from 'pkg'; console.log(value);",
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'node-paths.ts')],
      nodePaths: [vendor],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('NODE_PATH_VALUE');
  });
});
