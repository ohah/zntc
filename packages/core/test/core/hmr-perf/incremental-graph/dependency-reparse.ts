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

describe('Issue #1223 HMR perf - incremental graph dependency reparsing', () => {
  test('phase2: 의존 그래프에서 leaf 1개만 변경 시 reparsedModules=1 이어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase2-'));
    writeFileSync(join(dir, 'a.ts'), 'import { b } from "./b"; export const a = b + 1;');
    writeFileSync(join(dir, 'b.ts'), 'import { c } from "./c"; export const b = c + 1;');
    writeFileSync(join(dir, 'c.ts'), 'export const c = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();

    const handle = watch({
      entryPoints: [join(dir, 'a.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // leaf(c.ts)만 변경 → c만 재파싱되어야 함 (a, b는 캐시)
    writeFileSync(join(dir, 'c.ts'), 'export const c = 999;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 10000);

  test('phase2b: 10단계 체인에서 leaf 변경 시 reparsedModules=1', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase2b-'));
    const N = 10;
    for (let i = 0; i < N - 1; i++) {
      writeFileSync(
        join(dir, `m${i}.ts`),
        `import { v${i + 1} } from "./m${i + 1}"; export const v${i} = v${i + 1} + 1;`,
      );
    }
    writeFileSync(join(dir, `m${N - 1}.ts`), `export const v${N - 1} = 1;`);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [join(dir, 'm0.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(join(dir, `m${N - 1}.ts`), `export const v${N - 1} = 999;`);
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 15000);

  test('phase2c: 체인 중간(b)만 변경 — 상위(a)/하위(c) 캐시 유지', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase2c-'));
    writeFileSync(join(dir, 'a.ts'), 'import { b } from "./b"; export const a = b + 1;');
    writeFileSync(join(dir, 'b.ts'), 'import { c } from "./c"; export const b = c + 1;');
    writeFileSync(join(dir, 'c.ts'), 'export const c = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [join(dir, 'a.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(join(dir, 'b.ts'), 'import { c } from "./c"; export const b = c + 42;');
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 10000);
});
