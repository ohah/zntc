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
} from '../../helpers';

describe('Issue #1223 HMR perf - incremental graph dependency reparsing - leaf', () => {
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

    writeFileSync(join(dir, 'c.ts'), 'export const c = 999;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 10000);
});
