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

function createBasicFixture(): string {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-napi-build-'));
  writeFileSync(
    join(dir, 'entry.ts'),
    'import { hello } from "./util";\nconsole.log(hello("world"));',
  );
  writeFileSync(
    join(dir, 'util.ts'),
    'export function hello(name: string): string { return `Hello, ${name}!`; }',
  );
  return dir;
}

describe('@zntc/core buildSync - basic output artifacts', () => {
  test('minify', () => {
    const dir = createBasicFixture();
    try {
      const normal = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
      const minified = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        minify: true,
      });
      expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('소스맵 생성', () => {
    const dir = createBasicFixture();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        sourcemap: true,
      });
      expect(result.outputFiles.length).toBe(2);
      const smFile = result.outputFiles.find((f) => f.path.endsWith('.map'));
      expect(smFile).toBeDefined();
      const map = JSON.parse(smFile!.text);
      expect(map.version).toBe(3);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('metafile 생성', () => {
    const dir = createBasicFixture();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        metafile: true,
      });
      expect(result.metafile).toBeDefined();
      const meta = JSON.parse(result.metafile!);
      expect(meta.outputs).toBeDefined();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
