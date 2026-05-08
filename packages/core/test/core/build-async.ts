import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core build (async)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-async-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, 'util.ts'),
      'export function hello(name: string): string { return `Hello, ${name}!`; }',
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('비동기 번들링 (Promise)', async () => {
    const result = await build({ entryPoints: [join(dir, 'entry.ts')] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('hello');
  });

  test('비동기 minify', async () => {
    const normal = await build({ entryPoints: [join(dir, 'entry.ts')] });
    const minified = await build({
      entryPoints: [join(dir, 'entry.ts')],
      minify: true,
    });
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
  });

  test('비동기 소스맵', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
    });
    expect(result.outputFiles.length).toBe(2);
    const smFile = result.outputFiles.find((f) => f.path.endsWith('.map'));
    expect(smFile).toBeDefined();
  });

  test('buildSync과 동일한 결과', async () => {
    const syncResult = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    const asyncResult = await build({ entryPoints: [join(dir, 'entry.ts')] });
    expect(asyncResult.outputFiles[0].text).toBe(syncResult.outputFiles[0].text);
  });
});
