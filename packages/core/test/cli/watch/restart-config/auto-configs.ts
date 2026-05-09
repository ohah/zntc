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

describe('CLI: watch > config restart auto-discovery', () => {
  test('--watch-json: zntc.config.json 변경 시 restart 이벤트 (#2107)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-config-restart-'));
    try {
      writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
      writeFileSync(join(dir, 'zntc.config.json'), `{}`);
      const logPath = join(dir, 'watch.log');
      const errPath = join(dir, 'watch.err');
      const proc = spawnWatchJson(
        ['--bundle', join(dir, 'index.ts'), '--outdir', join(dir, 'dist')],
        dir,
        logPath,
        errPath,
      );
      await waitForEvent(logPath, (e) => e.type === 'ready', 10000, errPath);
      writeFileSync(join(dir, 'zntc.config.json'), `{"banner": "/* changed */"}`);
      try {
        await waitForEvent(logPath, (e) => e.type === 'restart', 10000, errPath);
      } finally {
        await stopSpawnedProcess(proc);
      }
      const restart = readEvents(logPath).find((e) => e.type === 'restart');
      expect(restart).toBeDefined();
      expect(restart.reason).toContain('config');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 15000);

  test('--watch-json: zntc.config.ts (TS) 변경도 restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-ts-cfg-'));
    try {
      writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
      writeFileSync(join(dir, 'zntc.config.ts'), `export default { banner: "/* v1 */" as const };`);
      const logPath = join(dir, 'watch.log');
      const errPath = join(dir, 'watch.err');
      const proc = spawnWatchJson(
        ['--bundle', join(dir, 'index.ts'), '--outdir', join(dir, 'dist')],
        dir,
        logPath,
        errPath,
      );

      await waitForEvent(logPath, (e) => e.type === 'ready', 10000, errPath);
      writeFileSync(join(dir, 'zntc.config.ts'), `export default { banner: "/* v2 */" as const };`);

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
