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

describe('watch() > rebuild updates > payloads > partial module maps', () => {
  test('Issue #1248: 다중 모듈에서 변경 모듈만 updates에 + map은 자기 모듈만', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-partial-'));
    writeFileSync(join(dir, 'a.ts'), "export const A = 'A-original';\n");
    writeFileSync(join(dir, 'b.ts'), "export const B = 'B-original';\n");
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string; map?: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      sourcemap: true,
      onReady: () => readyDone(),
      onRebuild: (e) => rebuildDone(e),
    });

    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), "export const A = 'A-changed';\n");

    const event = await rebuildP;

    expect(event.graphChanged).toBeFalsy();
    expect(event.updates).toBeDefined();
    expect(event.updates!.length).toBe(1);

    const u = event.updates![0];
    expect(u.id.endsWith('a.ts')).toBe(true);
    expect(u.code).toContain('A-changed');
    expect(u.code).not.toContain('B-original');

    const mapJson = handle.getHmrSourceMap(u.id);
    expect(mapJson).not.toBeNull();
    const m = JSON.parse(mapJson!);
    expect(m.sources).toHaveLength(1);
    expect(m.sources[0].endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
