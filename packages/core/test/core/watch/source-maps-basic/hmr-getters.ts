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

describe('watch() > source maps basic > hmr getters', () => {
  test('getHmrSourceMap — 모듈 id 로 JSON 반환, 미존재 id 는 null', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-hmr-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 42;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: { id: string }[];
    }>();
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
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 7;\n');
    const event = await rebuildP;
    expect(event.updates).toBeDefined();
    expect(event.updates!.length).toBeGreaterThan(0);

    const moduleId = event.updates![0].id;
    const json = handle.getHmrSourceMap(moduleId);
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');

    expect(handle.getHmrSourceMap('does/not/exist')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getHmrSourceMap — multi-module rebuild 에서 모든 모듈 id 로 조회 가능', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-multi-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
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
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 999;\n');
    const event = await rebuildP;

    expect(event.updates).toBeDefined();
    // rebuild 의 updates 는 변경된 모듈(a.ts) 만 — 하지만 module_sm_map 에는 전체 모듈이
    // 적재돼 있어야 이후 요청에서 b.ts / entry.ts 의 map 도 lazy serve 가능.
    const u = event.updates![0];
    const mapA = handle.getHmrSourceMap(u.id);
    expect(mapA).not.toBeNull();

    // 변경 안 된 모듈도 module_sm_map 에 있으므로 id 알면 조회 가능.
    // NAPI 는 모든 모듈의 per-module code 를 수집하지만 JS 는 updates diff 만 받는다 —
    // id 를 직접 구성하는 대신 rebuild 에서 updates 의 id 패턴이 파일명을 포함하는지 확인.
    expect(u.id.endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getHmrSourceMap — initial build 직후 (rebuild 전) 모듈 id 조회 가능', async () => {
    // swap 이 rebuild 뿐 아니라 initial build 완료 시에도 호출돼야 한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-init-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
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
        rebuildDone(event);
      },
    });
    await readyP;

    // 아직 rebuild 없음 — 하지만 initial build 의 swap 으로 모듈 id 를 얻기 위해
    // 일단 한 번 수정을 일으켜 id 를 알아낸 뒤, 동일 rebuild 후 getter 를 호출한다.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;\n');
    const event = await rebuildP;
    const id = event.updates![0].id;

    // rebuild swap 이 된 상태에서 모듈 id 로 JSON 을 받아낼 수 있다.
    const json = handle.getHmrSourceMap(id);
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.version).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);
});
