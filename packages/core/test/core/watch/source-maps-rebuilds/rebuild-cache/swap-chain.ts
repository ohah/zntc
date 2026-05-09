import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  watch,
  writeFileSync,
} from '../helpers';

describe('watch() > source maps rebuilds > swap chain', () => {
  test('getBundleSourceMap — 연쇄 rebuild (3회) 에서 최신 swap 만 유효', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-chain-'));
    let handle: ReturnType<typeof watch> | undefined;
    try {
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

      const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
      let rebuilds = 0;
      const rebuildResolvers: Array<() => void> = [];
      handle = watch({
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

      expect(lens[0]).toBeGreaterThan(0);
      expect(lens[1]).toBeGreaterThan(lens[0]);
      expect(lens[2]).toBeGreaterThan(lens[1]);
      expect(rebuilds).toBe(3);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 20000);
});
