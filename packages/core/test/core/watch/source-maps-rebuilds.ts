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

describe('watch() > source maps rebuilds', () => {
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

  test('getHmrSourceMap — graph 변경 (모듈 추가) 후 새 모듈도 swap 에 포함', async () => {
    // graph_changed=true 이면 NAPI 가 updates 배열을 비우므로, 2단계로 진행:
    //   1) b.ts 추가 → graphChanged 이벤트
    //   2) b.ts 재수정 → updates=[b] — 이 시점에 b 의 id 를 획득
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-graph-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'entry.ts'), "import { A } from './a';\nconsole.log(A);\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let seenGraphChange = false;
    let secondUpdates: Array<{ id: string }> | undefined;
    const { promise: secondP, resolve: secondDone } = Promise.withResolvers<void>();

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
        if (!seenGraphChange) {
          if (event.graphChanged) seenGraphChange = true;
        } else if (event.updates && event.updates.length > 0) {
          secondUpdates = event.updates;
          secondDone();
        }
      },
    });
    await readyP;

    // 1차: b.ts 추가 + entry import 확장 → graphChanged.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );
    // graphChanged 이벤트 처리 대기.
    await new Promise((r) => setTimeout(r, 500));
    expect(seenGraphChange).toBe(true);

    // 2차: b.ts 재수정 → updates=[b] — b 의 id 획득 경로.
    writeFileSync(join(dir, 'b.ts'), 'export const B = 999;\n');
    await secondP;

    const bId = secondUpdates!.find((u) => u.id.endsWith('b.ts'))?.id;
    expect(bId).toBeDefined();

    // graph 변경 후에도 handle 의 module_sm_map 에 b 가 포함 → getter 성공.
    const mapB = handle.getHmrSourceMap(bId!);
    expect(mapB).not.toBeNull();

    // 완전 존재하지 않는 id — null.
    expect(handle.getHmrSourceMap('absolutely/not/a/module.ts')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);

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

  test('getBundleSourceMap + getHmrSourceMap 교대 호출 — 상호 간섭 없음', async () => {
    // 같은 handle 에서 bundle/hmr getter 를 번갈아 호출. mutex 가 재진입 아니므로
    // 동일 thread 순차 호출은 안전. JSON 내용이 서로 섞이지 않는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-mix-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 42;\n');

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
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 99;\n');
    const event = await rebuildP;
    const id = event.updates![0].id;

    // 교대로 3회씩 호출 — 각 호출이 type 정합성 유지.
    for (let i = 0; i < 3; i++) {
      const bundleJson = handle.getBundleSourceMap();
      expect(bundleJson).not.toBeNull();
      expect(JSON.parse(bundleJson!).version).toBe(3);

      const hmrJson = handle.getHmrSourceMap(id);
      expect(hmrJson).not.toBeNull();
      const hm = JSON.parse(hmrJson!);
      expect(hm.version).toBe(3);
      // per-module map 은 sources 길이 1.
      expect(hm.sources.length).toBe(1);
    }

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

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
