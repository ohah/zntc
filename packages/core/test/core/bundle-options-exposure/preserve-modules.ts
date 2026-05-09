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

function createPreserveModulesFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-preserve-modules-'));
  writeFileSync(join(dir, 'mod-a.ts'), 'export const a = 1;');
  writeFileSync(join(dir, 'mod-entry.ts'), 'import { a } from "./mod-a";\nexport const b = a + 1;');
  return dir;
}

describe('BundleOptions: 전체 옵션 노출 > preserve modules', () => {
  test('preserveModules: 모듈별 개별 파일 출력', async () => {
    const dir = createPreserveModulesFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'mod-entry.ts')],
        preserveModules: true,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('preserveModulesRoot: 출력 경로 기준', async () => {
    const dir = createPreserveModulesFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'mod-entry.ts')],
        preserveModules: true,
        preserveModulesRoot: dir,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
