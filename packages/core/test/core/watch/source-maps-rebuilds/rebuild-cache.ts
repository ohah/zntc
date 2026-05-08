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

describe('watch() > source maps rebuilds > rebuild cache', () => {
  test('getBundleSourceMap — rebuild 실패 후 이전 JSON 이 캐시로 유지된다', async () => {
    // rebuild 가 parse error 등으로 실패하면 swap 이 호출되지 않아 이전 rebuild 의 builder 유지.
    // dev 서버가 의미있는 sourcemap 을 계속 제공할 수 있어야 함.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-err-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildResolved = false;
    const { promise: errP, resolve: errDone } = Promise.withResolvers<{ success: boolean }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        if (!rebuildResolved) {
          rebuildResolved = true;
          errDone(event);
        }
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    // 파싱 불가능한 코드로 덮어쓰기.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: = = =;;;\n');
    await errP;

    // 실패해도 이전 builder 가 남아있어 getter 는 유효 JSON 반환.
    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    const m = JSON.parse(after!);
    expect(m.version).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — 연쇄 rebuild (3회) 에서 최신 swap 만 유효', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-chain-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuilds = 0;
    const rebuildResolvers: Array<() => void> = [];
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
        rebuilds++;
        const next = rebuildResolvers.shift();
        if (next) next();
      },
    });
    await readyP;

    const lens: number[] = [];
    for (let i = 0; i < 3; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      rebuildResolvers.push(resolve);
      await new Promise((r) => setTimeout(r, 100));
      // 매 rebuild 마다 코드 길이 증가.
      const body = Array.from(
        { length: (i + 1) * 3 },
        (_, k) => `export const e${i}_${k} = ${k};`,
      ).join('\n');
      writeFileSync(join(dir, 'entry.ts'), body + '\n');
      await promise;

      const json = handle.getBundleSourceMap();
      expect(json).not.toBeNull();
      const m = JSON.parse(json!);
      lens.push(m.mappings.length);
    }

    // 매 rebuild 마다 mappings 가 더 길어지는 경향 (strictly increasing).
    expect(lens[0]).toBeGreaterThan(0);
    expect(lens[1]).toBeGreaterThan(lens[0]);
    expect(lens[2]).toBeGreaterThan(lens[1]);
    expect(rebuilds).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);
});
