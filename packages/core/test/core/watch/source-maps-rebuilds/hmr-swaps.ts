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

describe('watch() > source maps rebuilds > hmr swaps', () => {
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
});
