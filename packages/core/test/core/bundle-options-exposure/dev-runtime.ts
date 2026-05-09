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
  const dir = mkdtempSync(join(tmpdir(), 'zntc-dev-options-'));
  writeFileSync(join(dir, 'entry.ts'), '/** @license MIT */\nexport const x = 1;');
  return dir;
}

describe('BundleOptions: 전체 옵션 노출 > dev runtime', () => {
  test('devMode: dev 모드 활성화', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        devMode: true,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('__zntc_modules');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('devMode: RN HMR reload fallback은 DevSettings wrapper를 우선 사용', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        devMode: true,
      });
      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).toContain('require("react-native")');
      expect(code).toContain('rn.DevSettings.reload(why)');
      expect(code).toContain('setTimeout(fn, 0)');
      expect(code).not.toContain('__zntc_g.nativeModuleProxy.DevSettings.reload()');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('reactRefresh: Fast Refresh 활성화', () => {
    const dir = createEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        devMode: true,
        reactRefresh: true,
      });
      expect(result.errors.length).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
