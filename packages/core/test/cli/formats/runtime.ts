import {
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  runCli,
  runNodeEval,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: UMD/AMD format', () => {
  test('UMD: Node.js에서 실행 가능', () => {
    // react mock + UMD 번들을 Node.js에서 실행
    const mockDir = mkdtempSync(join(tmpdir(), 'zntc-umd-e2e-'));
    writeFileSync(
      join(mockDir, 'app.ts'),
      'import { greet } from "mylib";\nexport const msg = greet("world");',
    );
    mkdirSync(join(mockDir, 'node_modules', 'mylib'), { recursive: true });
    writeFileSync(
      join(mockDir, 'node_modules', 'mylib', 'index.js'),
      'exports.greet = function(n) { return "Hello " + n; };',
    );

    const outFile = join(mockDir, 'bundle.js');
    const { exitCode } = runCli([
      '--bundle',
      join(mockDir, 'app.ts'),
      '--format=umd',
      '--external',
      'mylib',
      '-o',
      outFile,
    ]);
    expect(exitCode).toBe(0);

    // Node.js에서 UMD 번들 require → CJS 경로로 실행
    const run = runNodeEval(`const m = require(${JSON.stringify(outFile)}); console.log(m.msg);`, {
      cwd: mockDir,
    });
    expect(run.stdout.trim()).toBe('Hello world');

    rmSync(mockDir, { recursive: true, force: true });
  });
});
