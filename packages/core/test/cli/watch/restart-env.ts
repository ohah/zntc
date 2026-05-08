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
  test('--watch-json: .env 변경 시 restart 이벤트', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-env-restart-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    writeFileSync(join(dir, '.env'), 'VITE_K=initial');
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

    writeFileSync(join(dir, '.env'), 'VITE_K=changed');

    try {
      await waitForEvent(logPath, (e) => e.type === 'restart', 10000, errPath);
    } finally {
      await stopSpawnedProcess(proc);
    }

    const events = readEvents(logPath);
    expect(events.some((e) => e.type === 'restart')).toBe(true);

    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test('--watch-json: .env.production (mode-specific) 변경도 restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-mode-env-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    writeFileSync(join(dir, '.env.production'), 'VITE_K=initial');
    const outDir = join(dir, 'dist');

    const logPath = join(dir, 'watch.log');
    const errPath = join(dir, 'watch.err');
    const proc = spawnWatchJson(
      ['--bundle', '--mode=production', join(dir, 'index.ts'), '--outdir', outDir],
      dir,
      logPath,
      errPath,
    );

    await waitForEvent(logPath, (e) => e.type === 'ready', 10000, errPath);
    writeFileSync(join(dir, '.env.production'), 'VITE_K=changed');

    try {
      await waitForEvent(logPath, (e) => e.type === 'restart', 10000, errPath);
    } finally {
      await stopSpawnedProcess(proc);
    }

    expect(readEvents(logPath).some((e) => e.type === 'restart')).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15000);
});
