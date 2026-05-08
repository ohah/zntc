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

describe('Issue #1223 HMR perf 재현', () => {
  // ---- Phase 3: 관측성 (phaseDurations) ----
  test('phase3: WatchRebuildEvent에 phaseDurations 필드가 노출되어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase3-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();

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
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.phaseDurations).toBeDefined();
    expect(typeof event.phaseDurations.detect).toBe('number');
    expect(typeof event.phaseDurations.graph).toBe('number');
    expect(typeof event.phaseDurations.link).toBe('number');
    expect(typeof event.phaseDurations.shake).toBe('number');
    expect(typeof event.phaseDurations.emit).toBe('number');
    expect(typeof event.phaseDurations.delta).toBe('number');
    expect(typeof event.phaseDurations.total).toBe('number');
    expect(event.phaseDurations.total).toBeGreaterThan(0);
  }, 10000);

  // ---- Phase 1a: 워처 latency (목표 < 200ms, 현재 폴링 500ms) ----
  test('phase1a: 변경 감지부터 onRebuild까지 200ms 이내여야 함 (현재 500ms 폴링)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1a-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 50));

    const t0 = performance.now();
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');
    await rebuildP;
    const elapsed = performance.now() - t0;

    handle.stop();
    rmSync(dir, { recursive: true });

    expect(elapsed).toBeLessThan(200);
  }, 10000);

  // ---- Phase 1b: content hash (mtime만 갱신, 내용 동일 → 알림 없음) ----
  test('phase1b: 내용이 동일하면 onRebuild가 호출되지 않아야 함 (content hash)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1b-'));
    const entry = join(dir, 'entry.ts');
    const src = 'export const x = 1;';
    writeFileSync(entry, src);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;

    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 내용 동일, mtime만 갱신 (touch와 유사)
    writeFileSync(entry, src);
    await new Promise((r) => setTimeout(r, 1500));

    handle.stop();
    rmSync(dir, { recursive: true });

    // 현재: mtime만 봐서 무조건 리빌드 트리거 → rebuildCount=1
    // 목표: content hash로 스킵 → rebuildCount=0
    expect(rebuildCount).toBe(0);
  }, 10000);

  // ---- Phase 1c: 디바운스 (idle 상태에서 50ms 내 두 번 저장 → 1회 리빌드) ----
  test('phase1c: 첫 리빌드 후 50ms 내 두 번 저장은 한 번으로 병합되어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1c-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;
    let firstRebuildResolve: (() => void) | null = null;
    const firstRebuildP = new Promise<void>((r) => {
      firstRebuildResolve = r;
    });

    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
        if (rebuildCount === 1) firstRebuildResolve!();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 첫 저장 → 첫 리빌드 완료까지 대기
    writeFileSync(entry, 'export const x = 2;');
    await firstRebuildP;
    expect(rebuildCount).toBe(1);

    // idle 상태에서 50ms 내에 두 번 빠르게 저장
    writeFileSync(entry, 'export const x = 3;');
    await new Promise((r) => setTimeout(r, 10));
    writeFileSync(entry, 'export const x = 4;');

    // 디바운스(50ms) + 빌드 시간 충분히 대기
    await new Promise((r) => setTimeout(r, 2000));
    handle.stop();
    rmSync(dir, { recursive: true });

    // 현재: 폴링으로 두 번 모두 감지 → rebuildCount=3
    // 목표: 디바운스로 병합 → rebuildCount=2
    expect(rebuildCount).toBe(2);
  }, 15000);

  // ---- Phase 2: 증분 그래프 (1개 변경 → 1개만 재파싱) ----
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

  // ---- phase2b: deep dependency chain (10단계) ----
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

  // ---- phase2c: 체인 중간 모듈 변경 시 해당 모듈만 재파싱 ----
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

  // ---- phase1d: stale content_hash 엔트리 정리 ----
  test('phase1d: import 제거 후 이전 파일 변경은 리빌드 트리거 안 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1d-'));
    const entry = join(dir, 'entry.ts');
    const extra = join(dir, 'extra.ts');
    writeFileSync(extra, 'export const y = 1;');
    writeFileSync(entry, 'import { y } from "./extra"; export const x = y;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const rebuilds: Array<{ changed?: string[] }> = [];
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuilds.push(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 1차: entry에서 extra import 제거 → graph에서 extra 빠짐
    writeFileSync(entry, 'export const x = 1;');
    await new Promise((r) => setTimeout(r, 1500));
    const reb1 = rebuilds.length;
    expect(reb1).toBeGreaterThanOrEqual(1);

    // 2차: extra.ts 내용 변경 — 이미 그래프에서 빠졌으므로 리빌드 없어야 함
    writeFileSync(extra, 'export const y = 999;');
    await new Promise((r) => setTimeout(r, 1500));
    handle.stop();
    rmSync(dir, { recursive: true });

    // extra 변경 후 추가 리빌드가 없어야 — watcher가 extra를 removePath 한 결과
    expect(rebuilds.length).toBe(reb1);
  }, 15000);

  // ---- phase1e: 중복 이벤트 dedup (같은 파일 여러 번 touch → 1회 리빌드) ----
  test('phase1e: 같은 파일 연속 touch 시 리빌드 1회만 발생', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1e-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 같은 파일에 동일 내용 5회 빠르게 write — 이벤트는 5개이지만 content hash로 dedup
    for (let i = 0; i < 5; i++) {
      writeFileSync(entry, 'export const x = 2;');
      await new Promise((r) => setTimeout(r, 5));
    }
    await new Promise((r) => setTimeout(r, 1500));
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(rebuildCount).toBe(1);
  }, 10000);

  // ---- phase1f: 디바운스 starvation cap (지속 변경되는 파일에도 리빌드 진행) ----
  test('phase1f: 디바운스 윈도우를 계속 갱신해도 500ms 상한 내 리빌드 발생', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1f-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 50));

    // 20ms마다 파일 수정 — 매번 debounce window(50ms) 내에 새 이벤트.
    // starvation cap(500ms)이 없으면 영영 리빌드 안 됨.
    let counter = 0;
    const interval = setInterval(() => {
      counter++;
      writeFileSync(entry, `export const x = ${counter};`);
    }, 20);

    const t0 = performance.now();
    await rebuildP;
    const elapsed = performance.now() - t0;
    clearInterval(interval);
    handle.stop();
    rmSync(dir, { recursive: true });

    // 500ms cap + 빌드 시간 여유 포함하여 상한 검증
    expect(elapsed).toBeLessThan(1500);
  }, 10000);

  // ---- phase1g: 경계 — 빈 파일 해시 ----
  test('phase1g: 빈 파일도 해시되어 리빌드 동작 정상', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1g-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, '');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entry, 'export const x = 1;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.success).toBe(true);
  }, 10000);

  // ---- phase1h: 경계 — 대형 파일(>10MB) 해시 폴백 경로 ----
  test('phase1h: 대형 파일(15MB)에서도 크래시 없이 리빌드 트리거', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1h-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'import "./big.json"; export const x = 1;');
    // 15MB JSON 배열 — watch_hash_max_bytes(256MB) 이내라 정상 해시 경로 사용,
    // 크래시/OOM 없이 동작해야 함을 보장.
    const big = '[' + '0,'.repeat(3_000_000) + '0]';
    writeFileSync(join(dir, 'big.json'), big);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [entry],
      loader: { '.json': 'json' },
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(entry, 'import "./big.json"; export const x = 2;');
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.success).toBe(true);
  }, 20000);
});

// ================================================================
// buildResult에 moduleCodes/modulePaths 노출 테스트
// ================================================================
