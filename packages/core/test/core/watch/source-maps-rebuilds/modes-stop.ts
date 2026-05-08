import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  rmSync,
  existsSync,
  join,
  tmpdir,
} from './helpers';

describe('watch() > source maps rebuilds > modes and stop', () => {
  test('emitDiskSourcemap=false + eager (devMode=false) — .map 디스크 skip 유지', async () => {
    // devMode=false 면 NAPI 가 lazy 를 안 켬 → eager 경로. 이 상태에서도 emitDiskSourcemap
    // 옵션이 .map 디스크 write 제어 가능해야 한다. getter 는 lazy 가 꺼져있으니 null.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-eager-nodev-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: false,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);
    // eager 경로이므로 handle cache 에 builder 없음 → null.
    expect(handle.getBundleSourceMap()).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — stop() 후 null 반환 (use-after-stop 방어)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-stop-'));
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

    handle.stop();
    // stop 후 napi_remove_wrap 된 handle — getter 는 null 반환 (throw 하지 않음)
    expect(handle.getBundleSourceMap()).toBeNull();
    expect(handle.getHmrSourceMap('whatever')).toBeNull();

    rmSync(dir, { recursive: true });
  }, 10000);
});
