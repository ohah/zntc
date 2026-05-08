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

describe('CLI: zntc.config plugins', () => {
  test('zntc.config.ts 의 plugins 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-plugins-'));
    writeFileSync(join(dir, 'entry.ts'), 'import x from "virtual:hello";\nconsole.log(x);');
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default {
         plugins: [{
           name: "virtual",
           setup(build) {
             build.onResolve({ filter: /^virtual:/ }, (args) => ({ path: args.path, namespace: "virtual" }));
             build.onLoad({ filter: /.*/, namespace: "virtual" }, () => ({ contents: 'export default "PLUGIN_OK";' }));
           },
         }],
       };`,
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('PLUGIN_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--plugin <path> 의 plugins 필드가 적용된다 (BuildOptions 다른 필드는 무시)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-only-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('original');");
    writeFileSync(
      join(dir, 'p.js'),
      `export default {
         plugins: [{
           name: "marker",
           setup(build) {
             build.onLoad({ filter: /entry\\.ts$/ }, () => ({ contents: 'console.log("MARKER_OK");' }));
           },
         }],
       };`,
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--plugin', join(dir, 'p.js'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('MARKER_OK');
    rmSync(dir, { recursive: true, force: true });
  });
});
