import {
  describe,
  expect,
  join,
  mkdtempSync,
  readEvents,
  rmSync,
  spawnWatchJson,
  stopSpawnedProcess,
  test,
  tmpdir,
  waitForEvent,
  writeFileSync,
} from '../helpers';

describe('CLI: watch', () => {
  test('--watch-json: 일반 entry 파일 변경은 rebuild (restart 아님)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-rebuild-not-restart-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    writeFileSync(join(dir, 'zntc.config.json'), `{}`);
    const outDir = join(dir, 'dist');

    const logPath = join(dir, 'watch.log');
    const errPath = join(dir, 'watch.err');
    const proc = spawnWatchJson(
      ['--bundle', join(dir, 'index.ts'), '--outdir', outDir],
      dir,
      logPath,
      errPath,
    );

    await waitForEvent(logPath, (e) => e.type === 'ready', 10000, errPath);
    const beforeRebuilds = readEvents(logPath).filter((e) => e.type === 'rebuild').length;
    // 초기 ready 후 entry 변경 — rebuild 만 와야 함.
    writeFileSync(join(dir, 'index.ts'), 'export const x = 2;');

    try {
      // rebuild 가 ready 외에 추가로 발생할 때까지 기다림.
      const start = Date.now();
      let extraRebuild = false;
      while (Date.now() - start < 5000) {
        const events = readEvents(logPath);
        if (events.filter((e) => e.type === 'rebuild').length > beforeRebuilds) {
          extraRebuild = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 50));
      }
      expect(extraRebuild).toBe(true);
      // restart 이벤트 없어야 함.
      expect(readEvents(logPath).some((e) => e.type === 'restart')).toBe(false);
    } finally {
      await stopSpawnedProcess(proc);
    }

    rmSync(dir, { recursive: true, force: true });
  }, 15000);
});
