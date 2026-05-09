import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: zntc.config.{mode}.* 자동 머지 > base overrides', () => {
  test('mode-specific config 가 base 를 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-cfg-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ banner: '/* base */' }));
    writeFileSync(
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({ banner: '/* prod-mode */' }),
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=production', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* prod-mode */');
    expect(stdout).not.toContain('/* base */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('base + mode 머지: 둘 다 정의된 키 + 한쪽만 정의된 키', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-merge-'));
    writeFileSync(join(dir, 'entry.ts'), 'console.log(__VER__, __BUILD__);');
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        define: { __VER__: '"v1"', __BUILD__: '"prod"' },
      }),
    );
    writeFileSync(
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({
        define: { __BUILD__: '"prod-override"' },
      }),
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=production', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    // base 의 __VER__ 그대로, mode 의 __BUILD__ override
    expect(stdout).toContain('"v1"');
    expect(stdout).toContain('"prod-override"');
    expect(stdout).not.toContain('"prod"' + ')'); // 기존 prod 값 미사용
    rmSync(dir, { recursive: true, force: true });
  });
});
