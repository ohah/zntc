import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  spawnWatchJson,
  stopSpawnedProcess,
  waitForEvent,
  readEvents,
} from './helpers';

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
