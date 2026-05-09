import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

function createEntry() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-misc-options-'));
  writeFileSync(join(dir, 'entry.ts'), '/** @license MIT */\nexport const x = 1;');
  return dir;
}

describe('BundleOptions: 전체 옵션 노출 > misc options', () => {
  test('timing: 옵션 파싱 확인', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        timing: true,
      });
      expect(result.errors.length).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('configurableExports: configurable:true 추가', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        configurableExports: true,
      });
      expect(result.errors.length).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('globalIdentifiers: 예약 식별자', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        globalIdentifiers: ['__global', 'self'],
      });
      expect(result.errors.length).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('rootDir + collectModuleCodes: dev 모드 옵션 조합', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        devMode: true,
        rootDir: dir,
        collectModuleCodes: true,
      });
      expect(result.errors.length).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
