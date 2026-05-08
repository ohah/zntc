import {
  describe,
  test,
  expect,
  build,
  buildSync,
  resolve,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
  runBundleStdout,
  useBuildOptionsFixture,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > resource loaders', () => {
  const getDir = useBuildOptionsFixture();

  test('loader: .txt=text → 텍스트 파일이 문자열로 export됨', () => {
    const dir = getDir();
    writeFileSync(join(dir, 'import-txt.ts'), 'import txt from "./data.txt";\nconsole.log(txt);');
    const result = buildSync({
      entryPoints: [join(dir, 'import-txt.ts')],
      loader: { '.txt': 'text' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('hello text');
  });

  test('loader: JSON/CSS/asset disk reads + plugin load source stay stable', async () => {
    const fixture = mkdtempSync(join(tmpdir(), 'zntc-resource-read-mtime-'));
    try {
      writeFileSync(
        join(fixture, 'entry.ts'),
        [
          'import data from "./data.json";',
          'import "./style.css";',
          'import text from "./note.txt";',
          'import logo from "./logo.png";',
          'import virtual from "./generated.virtual";',
          'console.log(data.answer, text.trim(), logo.includes(".png"), virtual);',
        ].join('\n'),
      );
      writeFileSync(join(fixture, 'data.json'), '{"answer":42}');
      writeFileSync(join(fixture, 'style.css'), '.card { color: red; }\n');
      writeFileSync(join(fixture, 'note.txt'), 'hello resource\n');
      writeFileSync(join(fixture, 'logo.png'), 'png-bytes');

      const plugin: ZntcPlugin = {
        name: 'virtual-source',
        setup(build) {
          build.onResolve({ filter: /\.virtual$/ }, (args) => ({
            path: resolve(fixture, args.path),
          }));
          build.onLoad({ filter: /\.virtual$/ }, () => ({
            contents: 'export default "plugin-source";',
            loader: 'js',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(fixture, 'entry.ts')],
        loader: { '.txt': 'text', '.png': 'file' },
        plugins: [plugin],
      });

      expect(result.errors.length).toBe(0);
      expect(await runBundleStdout(result.outputFiles[0].text)).toBe(
        '42 hello resource true plugin-source',
      );
    } finally {
      rmSync(fixture, { recursive: true, force: true });
    }
  });
});
