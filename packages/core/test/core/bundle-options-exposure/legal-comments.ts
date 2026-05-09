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

function createLicensedEntry() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-all-opts-'));
  writeFileSync(join(dir, 'entry.ts'), '/** @license MIT */\nexport const x = 1;');
  return dir;
}

describe('BundleOptions: 전체 옵션 노출 > legal comments', () => {
  test('legalComments: none → 라이센스 주석 제거', () => {
    const dir = createLicensedEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        legalComments: 'none',
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).not.toContain('@license');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('legalComments: eof → 파일 끝에 주석 이동', () => {
    const dir = createLicensedEntry();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        legalComments: 'eof',
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('@license');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
