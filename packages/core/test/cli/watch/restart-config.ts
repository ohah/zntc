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
  test('--watch-json: zntc.config.json 변경 시 restart 이벤트 (#2107)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-config-restart-'));
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

    // 초기 ready 까지 대기
    await waitForEvent(logPath, (e) => e.type === 'ready', 10000, errPath);

    // config 변경 trigger
    writeFileSync(join(dir, 'zntc.config.json'), `{"banner": "/* changed */"}`);

    // restart 이벤트 대기
    try {
      await waitForEvent(logPath, (e) => e.type === 'restart', 10000, errPath);
    } finally {
      await stopSpawnedProcess(proc);
    }

    const events = readEvents(logPath);
    const restart = events.find((e) => e.type === 'restart');
    expect(restart).toBeDefined();
    expect(restart.reason).toContain('config');

    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test('--watch-json: zntc.config.ts (TS) 변경도 restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-ts-cfg-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { banner: "/* v1 */" as const };`);
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
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { banner: "/* v2 */" as const };`);

    try {
      await waitForEvent(logPath, (e) => e.type === 'restart', 10000, errPath);
    } finally {
      await stopSpawnedProcess(proc);
    }

    expect(readEvents(logPath).some((e) => e.type === 'restart')).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test('--watch-json: --config <path> 의 명시 config 변경도 restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-explicit-cfg-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    writeFileSync(join(dir, 'custom.config.json'), `{}`);
    const outDir = join(dir, 'dist');

    const logPath = join(dir, 'watch.log');
    const errPath = join(dir, 'watch.err');
    const proc = spawnWatchJson(
      [
        '--bundle',
        '--config',
        join(dir, 'custom.config.json'),
        join(dir, 'index.ts'),
        '--outdir',
        outDir,
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
    rmSync(dir, { recursive: true, force: true });
  }, 15000);
});
