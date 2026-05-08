import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: workspace (#2111)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-'));
    // root config — 모든 entry 가 상속
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ format: 'esm', logLevel: 'silent' }),
    );
    // packages/app — package.json + entry + own zntc.config
    mkdirSync(join(dir, 'packages', 'app'), { recursive: true });
    writeFileSync(join(dir, 'packages', 'app', 'package.json'), JSON.stringify({ name: 'my-app' }));
    writeFileSync(join(dir, 'packages', 'app', 'entry.ts'), "console.log('app');");
    writeFileSync(
      join(dir, 'packages', 'app', 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './dist' }),
    );
    // packages/lib — entry only, no per-pkg config (root inherited)
    mkdirSync(join(dir, 'packages', 'lib'));
    writeFileSync(join(dir, 'packages', 'lib', 'package.json'), JSON.stringify({ name: 'my-lib' }));
    writeFileSync(join(dir, 'packages', 'lib', 'entry.ts'), "console.log('lib');");
    writeFileSync(
      join(dir, 'packages', 'lib', 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './out' }),
    );
    // workspace 정의 — path/glob/inline 3종 동시 사용
    mkdirSync(join(dir, 'shared'));
    writeFileSync(join(dir, 'shared', 'x.ts'), "console.log('shared');");
    writeFileSync(
      join(dir, 'zntc.workspace.json'),
      JSON.stringify([
        './packages/app',
        './packages/lib',
        { name: 'inline-shared', entryPoints: ['./shared/x.ts'], outdir: './shared/dist' },
      ]),
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('3종 형식 동시 사용 — fan-out 빌드', () => {
    const { stderr, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('3 entries');
    expect(stderr).toContain('workspace: my-app');
    expect(stderr).toContain('workspace: my-lib');
    expect(stderr).toContain('workspace: inline-shared');
    expect(existsSync(join(dir, 'packages', 'app', 'dist'))).toBe(true);
    expect(existsSync(join(dir, 'packages', 'lib', 'out'))).toBe(true);
    expect(existsSync(join(dir, 'shared', 'dist'))).toBe(true);
  });

  test('--workspace=<name> 필터 — 단일 entry 만 빌드', () => {
    rmSync(join(dir, 'packages', 'app', 'dist'), { recursive: true, force: true });
    rmSync(join(dir, 'packages', 'lib', 'out'), { recursive: true, force: true });
    const { stderr, exitCode } = runCli(['--bundle', '--workspace=my-app'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('1 entry');
    expect(stderr).toContain('workspace: my-app');
    expect(existsSync(join(dir, 'packages', 'app', 'dist'))).toBe(true);
    expect(existsSync(join(dir, 'packages', 'lib', 'out'))).toBe(false);
  });

  test('--workspace=ghost — 매칭 0개 시 에러 + available 노출', () => {
    const { stderr, exitCode } = runCli(['--bundle', '--workspace=ghost'], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('matched 0 entries');
    expect(stderr).toContain('my-app');
  });

  test('root config 상속 — entry 가 root format=esm 적용받음', () => {
    rmSync(join(dir, 'packages', 'app', 'dist'), { recursive: true, force: true });
    runCli(['--bundle', '--workspace=my-app'], { cwd: dir });
    // dist 디렉토리 안의 첫 .js 파일 내용 확인 — workspace 가 entry.ts 를 번들했는지.
    const distFiles = require('node:fs').readdirSync(join(dir, 'packages', 'app', 'dist'));
    const jsFile = distFiles.find((f: string) => f.endsWith('.js'));
    expect(jsFile).toBeDefined();
    const out = readFileSync(join(dir, 'packages', 'app', 'dist', jsFile!), 'utf8');
    expect(out).toContain('app');
  });

  test('--workspace-config <path> 명시 — 자동 탐색 우회', () => {
    const altDir = mkdtempSync(join(tmpdir(), 'zntc-workspace-explicit-'));
    mkdirSync(join(altDir, 'src'));
    writeFileSync(join(altDir, 'src', 'main.ts'), "console.log('explicit');");
    const wsPath = join(altDir, 'custom.workspace.json');
    writeFileSync(
      wsPath,
      JSON.stringify([{ name: 'explicit', entryPoints: ['./src/main.ts'], outdir: './out' }]),
    );
    const { exitCode } = runCli(
      ['--bundle', `--workspace-config=${wsPath}`, '--log-level=silent'],
      { cwd: altDir },
    );
    expect(exitCode).toBe(0);
    expect(existsSync(join(altDir, 'out'))).toBe(true);
    rmSync(altDir, { recursive: true, force: true });
  });

  test('--workspace-config 가 없는 파일이면 에러', () => {
    const { stderr, exitCode } = runCli(
      ['--bundle', '--workspace-config=/tmp/zntc-nonexistent-workspace.ts'],
      { cwd: dir },
    );
    expect(exitCode).toBe(1);
    expect(stderr).toContain('file not found');
  });

  test('inline entry 의 outdir 이 root 디렉토리 기준으로 정규화됨', () => {
    rmSync(join(dir, 'shared', 'dist'), { recursive: true, force: true });
    runCli(['--bundle', '--workspace=inline-shared'], { cwd: dir });
    expect(existsSync(join(dir, 'shared', 'dist'))).toBe(true);
  });
});
