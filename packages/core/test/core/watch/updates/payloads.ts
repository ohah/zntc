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

describe('watch() > rebuild updates > payloads', () => {
  test('devMode에서 moduleCodes diff → updates 전달', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string; map?: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
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
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 999;');

    const event = await rebuildP;
    expect(event.graphChanged).toBeFalsy();
    // updates가 있으면 변경된 모듈 코드가 포함되어야 함
    if (event.updates && event.updates.length > 0) {
      expect(event.updates[0].id).toBeDefined();
      expect(event.updates[0].code).toContain('999');
      // Issue #1248: 모듈별 standalone sourcemap이 함께 노출되어야 함
      expect(event.updates[0].map).toBeDefined();
      const map = event.updates[0].map!;
      expect(map).toContain('"version":3');
      expect(map).toContain('"mappings":"');
      expect(map).toContain('"sources":[');
    }
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('Issue #1248: 다중 모듈에서 변경 모듈만 updates에 + map은 자기 모듈만', async () => {
    // entry → a, b 그래프에서 a.ts만 수정 → updates=[a]만, map.sources=[a]만 검증.
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

    // Issue #1727 Phase B: per-module sourcemap 은 lazy getter 로 제공.
    // updates[i].map 은 lazy 경로에서 undefined 이고, handle.getHmrSourceMap(id) 로 조회.
    const mapJson = handle.getHmrSourceMap(u.id);
    expect(mapJson).not.toBeNull();
    const m = JSON.parse(mapJson!);
    expect(m.sources).toHaveLength(1);
    expect(m.sources[0].endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('changed 배열에 변경된 파일 경로 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    const entryPath = join(dir, 'entry.ts');
    writeFileSync(entryPath, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      changed?: string[];
    }>();

    const handle = watch({
      entryPoints: [entryPath],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entryPath, 'export const x = 2;');

    const event = await rebuildP;
    expect(event.changed).toBeDefined();
    expect(event.changed!.length).toBeGreaterThan(0);
    // 변경된 파일의 절대 경로가 포함되어야 함
    const hasEntry = event.changed!.some((p) => p.includes('entry.ts'));
    expect(hasEntry).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
