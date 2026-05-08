import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: bundle + plugin', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-plugin-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');

    // zntc.config.js — CSS 플러그인
    writeFileSync(
      join(dir, 'zntc.config.js'),
      `
import { resolve } from "node:path";
export default {
  plugins: [{
    name: "css-plugin",
    setup(build) {
      build.onResolve({ filter: /\\.css$/ }, (args) => ({
        path: resolve("${dir.replace(/\\/g, '\\\\')}", args.path),
      }));
      build.onLoad({ filter: /\\.css$/ }, () => ({
        contents: 'export default "color: red";',
      }));
    },
  }],
};
`,
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('--plugin으로 JS 설정 파일 로드', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      '--plugin',
      join(dir, 'zntc.config.js'),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('color: red');
  });
});

// ─── Watch 모드 ───
