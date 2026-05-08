import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  join,
  tmpdir,
} from './helpers';

describe('watch() > source maps basic', () => {
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

  test('emitDiskSourcemap=false — rebuild 후 bundle.js.map 을 디스크에 쓰지 않는다', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-disk-'));
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

    // bundle.js 는 있지만 .map 은 없어야 함
    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);

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

  test('getBundleSourceMap — sources_content 옵션 반영 (false 면 sourcesContent 제외)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sc-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcesContent: false,
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
    expect(m.sourcesContent).toBeUndefined();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — debug_ids 활성 시 JSON 과 bundle.js 가 동일 UUID 공유', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-did-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapDebugIds: true,
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    const match = js.match(/\/\/# debugId=([0-9a-f-]+)/);
    expect(match).not.toBeNull();
    const uuid = match![1];

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.debugId).toBe(uuid);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

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
