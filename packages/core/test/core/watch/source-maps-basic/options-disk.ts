import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  join,
  tmpdir,
} from './helpers';

describe('watch() > source maps basic > options and disk output', () => {
  test('emitDiskSourcemap=false — rebuild 후 bundle.js.map 을 디스크에 쓰지 않는다', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-disk-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    // bundle.js 는 있지만 .map 은 없어야 함
    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — sources_content 옵션 반영 (false 면 sourcesContent 제외)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sc-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcesContent: false,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.sourcesContent).toBeUndefined();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — debug_ids 활성 시 JSON 과 bundle.js 가 동일 UUID 공유', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-did-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapDebugIds: true,
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    const match = js.match(/\/\/# debugId=([0-9a-f-]+)/);
    expect(match).not.toBeNull();
    const uuid = match![1];

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.debugId).toBe(uuid);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
