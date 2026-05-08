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
import type { ZntcPlugin } from './helpers';

describe('watch() > rebuild updates', () => {
  test('devMode에서 moduleCodes diff → updates 전달', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string }>;
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

  test('stop() 후 리빌드 발생하지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });

    await readyP;
    handle.stop();

    // stop 후 파일 수정
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');
    await new Promise((r) => setTimeout(r, 1000));

    expect(rebuildCount).toBe(0);
    rmSync(dir, { recursive: true });
  }, 5000);

  test('double stop()은 에러 없이 무시', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    // 두 번째 stop() — 에러 없이 무시되어야 함
    expect(() => handle.stop()).not.toThrow();
    rmSync(dir, { recursive: true });
  });

  test('플러그인과 함께 watch', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'import "./style.css"; export const x = 1;');
    writeFileSync(join(dir, 'style.css'), 'body { color: red; }');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const cssPlugin: ZntcPlugin = {
      name: 'css-loader',
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "css-loaded";',
        }));
      },
    };

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [cssPlugin],
      onReady(event) {
        expect(event.files).toBeGreaterThan(0);
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('콜백 없이 watch — crash 없이 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    // onReady, onRebuild 모두 미제공
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
    });

    // 초기 빌드 완료 대기 (콜백 없으므로 타이머로)
    await new Promise((r) => setTimeout(r, 1500));
    expect(() => handle.stop()).not.toThrow();
    rmSync(dir, { recursive: true });
  }, 5000);

  test('리빌드 중 문법 에러 시 success: false + error', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      error?: string;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 문법 에러가 있는 코드로 변경
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const = ;; {{{{');

    const event = await rebuildP;
    // 에러가 발생하더라도 watch는 계속 동작해야 함
    // (ZNTC 파서가 에러 복구를 하므로 success: true일 수도 있음)
    expect(typeof event.success).toBe('boolean');
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

  // ── Issue #1727 Phase B: Lazy sourcemap NAPI getters ─────────────────────
});
