import {
  afterAll,
  beforeAll,
  build,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
  vitePlugin,
} from './helpers';

describe('옵션 조합 통합 테스트 - plugin hooks', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('async build + 모든 플러그인 훅 조합', async () => {
    const hooks: string[] = [];
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      dropLabels: ['DEV'],
      plugins: [
        vitePlugin({
          name: 'full-lifecycle',
          resolveId(source) {
            if (source === './lib') {
              hooks.push('resolveId');
              return join(dir, 'lib.ts');
            }
          },
          load(id) {
            if (id.endsWith('lib.ts')) hooks.push('load');
          },
          transform(_code) {
            hooks.push('transform');
          },
          renderChunk(code) {
            hooks.push('renderChunk');
            return `/* built */\n${code}`;
          },
          generateBundle(_outputs) {
            hooks.push('generateBundle');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(hooks).toContain('resolveId');
    expect(hooks).toContain('renderChunk');
    expect(hooks).toContain('generateBundle');
    expect(result.outputFiles[0].text).toContain('/* built */');
  });
});
