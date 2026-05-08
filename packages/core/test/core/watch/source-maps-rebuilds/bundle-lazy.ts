import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('watch() > source maps rebuilds > bundle lazy maps', () => {
  test('getBundleSourceMap — custom output_filename 이 map.file 에 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-file-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'custom-name.mjs'),
      sourcemap: true,
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
    expect(typeof m.file).toBe('string');
    expect(m.file.endsWith('custom-name.mjs')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — sourcemap_function_map 활성 시에도 lazy JSON 생성 성공', async () => {
    // lazy 경로는 generateJSON 을 일반 경로로 호출 (infra PR 은 per-source fn_map 통합 미지원).
    // function_map 옵션이 켜져 있어도 bundle sourcemap JSON 이 crash 없이 반환되고 V3 형식.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-fnmap-'));
    writeFileSync(join(dir, 'entry.ts'), "export function hello() { return 'hi'; }\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapFunctionMap: true,
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
    expect(m.version).toBe(3);
    expect(Array.isArray(m.sources)).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('bundle.js — lazy 경로에서도 sourceMappingURL 주석 출력 (DevTools fetch 경로)', async () => {
    // lazy 는 .map 을 디스크에 쓰지 않지만 bundle.js 의 sourceMappingURL 주석은 유지.
    // DevTools / Sentry 가 이 URL 을 fetch → NAPI getter → JSON 응답 경로.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-url-'));
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

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    expect(js).toContain('//# sourceMappingURL=');
    expect(js).toContain('.map');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
