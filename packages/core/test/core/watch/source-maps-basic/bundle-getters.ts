import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('watch() > source maps basic > bundle getters', () => {
  test('getBundleSourceMap — sourcemap + devMode 시 초기 빌드 후 V3 JSON 반환', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 1;\nconsole.log(x);\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false, // lazy 엔드포인트로만 serve
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');
    expect(json).toContain('"mappings"');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — sourcemap 비활성 시 null', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-off-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    expect(handle.getBundleSourceMap()).toBeNull();
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — 반복 호출 시 동일 JSON 반환 (재진입 안전)', async () => {
    // NAPI mutex + builder.buf clearRetainingCapacity 로 여러 번 호출해도 동일 결과.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-repeat-'));
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

    const j1 = handle.getBundleSourceMap();
    const j2 = handle.getBundleSourceMap();
    const j3 = handle.getBundleSourceMap();
    expect(j1).not.toBeNull();
    expect(j2).toBe(j1!);
    expect(j3).toBe(j1!);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — rebuild 후 swap 이 반영되고 이전 mappings 와 달라짐', async () => {
    // rebuild 마다 새 builder 로 swap. 내용이 바뀐 코드에 대한 mappings 가 업데이트되어야.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-swap-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const x = 1;\nexport const y = 2;\nexport const z = 3;\n',
    );
    await rebuildP;

    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    // 코드가 길어졌으니 mappings 문자열도 길어져야 한다.
    const m1 = JSON.parse(before!);
    const m2 = JSON.parse(after!);
    expect(m2.mappings.length).toBeGreaterThan(m1.mappings.length);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);
});
