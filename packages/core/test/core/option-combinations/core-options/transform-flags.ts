import {
  afterAll,
  beforeAll,
  buildSync,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
} from '../helpers';

describe('옵션 조합 통합 테스트 - core options - transform flags', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('minify + target + dropLabels 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'app.ts')],
      minify: true,
      target: 'es2020',
      dropLabels: ['DEV'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('debug');
    expect(result.outputFiles[0].text).toContain('42');
  });

  test('legalComments: none + minify 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'with-license.ts')],
      legalComments: 'none',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('@license');
  });
});
