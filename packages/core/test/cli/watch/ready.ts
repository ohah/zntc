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
  test('--watch-json 초기 빌드 후 ready 이벤트', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-watch-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    const outDir = join(dir, 'dist');

    const logPath = join(dir, 'watch.log');
    const errPath = join(dir, 'watch.err');
    const proc = spawnWatchJson(
      ['--bundle', join(dir, 'index.ts'), '--outdir', outDir],
      dir,
      logPath,
      errPath,
    );

    try {
      await waitForEvent(logPath, (e) => e.type === 'ready', 3000, errPath);
    } finally {
      await stopSpawnedProcess(proc);
    }

    const events = readEvents(logPath);
    expect(events.some((e) => e.type === 'ready')).toBe(true);

    rmSync(dir, { recursive: true, force: true });
  });
});
