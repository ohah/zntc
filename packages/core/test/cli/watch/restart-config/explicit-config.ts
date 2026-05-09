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
} from '../../helpers';

describe('CLI: watch > explicit config restart', () => {
  test('--watch-json: --config <path> 의 명시 config 변경도 restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-explicit-cfg-'));
    try {
      writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
      writeFileSync(join(dir, 'custom.config.json'), `{}`);
      const logPath = join(dir, 'watch.log');
      const errPath = join(dir, 'watch.err');
      const proc = spawnWatchJson(
        [
          '--bundle',
          '--config',
          join(dir, 'custom.config.json'),
          join(dir, 'index.ts'),
          '--outdir',
          join(dir, 'dist'),
        ],
        dir,
        logPath,
        errPath,
      );

      await waitForEvent(logPath, (e) => e.type === 'ready', 10000, errPath);
      writeFileSync(join(dir, 'custom.config.json'), `{"banner": "/* changed */"}`);

      try {
        await waitForEvent(logPath, (e) => e.type === 'restart', 10000, errPath);
      } finally {
        await stopSpawnedProcess(proc);
      }

      expect(readEvents(logPath).some((e) => e.type === 'restart')).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 15000);
});
