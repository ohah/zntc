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
} from './helpers';

describe('Issue #1223 HMR perf - content hash and boundaries', () => {
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
