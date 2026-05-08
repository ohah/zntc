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

describe('watch() > rebuild updates > graph changes', () => {
  test('Issue #1682: 충돌 rename 모듈은 cache-hit 시 HMR updates 에서 제외 (phantom filter)', async () => {
    // Linker 의 conflict rename 은 initial build 와 첫 rebuild 간 `$N` 접미사가
    // 비결정적으로 움직여 cache-hit 모듈의 emit 결과가 미세하게 달라진다.
    // module_code_cache 는 바이트 비교라 이런 모듈을 phantom 변경으로 오인,
    // 첫 rebuild HMR payload 에 포함시켜 — 런타임 `__zntc_apply_update` 가
    // hot-accept 없는 모듈을 만나자마자 `__zntc_reload()` 로 빠지게 만든다.
    //
    // 수정 (BundleResult.reparsed_paths 필터): cache-hit 모듈은 source 변경이
    // 증명되지 않았으므로 HMR payload 에서 제외. 회귀 테스트로 같은 이름 export
    // 두 개를 가진 fixture 를 만든 뒤, entry 만 수정한 rebuild 에서 updates 에
    // a.ts / b.ts 가 들어가지 않는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-phantom-'));
    // 두 모듈에서 같은 top-level 이름 export → Linker 가 한쪽을 `$1` 로 rename.
    writeFileSync(join(dir, 'a.ts'), 'export const count = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const count = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady: () => readyDone(),
      onRebuild: (e) => rebuildDone(e),
    });

    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    // entry.ts 만 수정 → a.ts / b.ts 는 cache-hit.
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B, 1);\n",
    );

    const event = await rebuildP;
    handle.stop();

    expect(event.graphChanged).toBeFalsy();
    expect(event.updates).toBeDefined();
    // 수정 전: a.ts / b.ts 도 phantom update 로 들어와 updates.length >= 3.
    // 수정 후: entry.ts 단독 → 1.
    const ids = event.updates!.map((u) => u.id);
    expect(ids.some((id) => id.endsWith('entry.ts'))).toBe(true);
    expect(ids.some((id) => id.endsWith('a.ts'))).toBe(false);
    expect(ids.some((id) => id.endsWith('b.ts'))).toBe(false);

    rmSync(dir, { recursive: true });
  }, 10000);

  test('새 import 추가 시 graphChanged 감지', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
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

    // 새 모듈 추가 → graph 변경
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');

    const event = await rebuildP;
    expect(event.graphChanged).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
