import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { RollupPlugin } from './helpers';

describe('vitePlugin 어댑터 - transform 체이닝', () => {
  test('실전 패턴: 코드 내 console.log 자동 제거 transform', async () => {
    const stripDir = mkdtempSync(join(tmpdir(), 'zntc-vite-strip-'));
    writeFileSync(
      join(stripDir, 'index.ts'),
      'console.log("debug");\nconst x = 1;\nconsole.log("also debug");\nconsole.warn("keep");',
    );

    const stripPlugin: RollupPlugin = {
      name: 'rollup-strip-console-log',
      transform(code, _id) {
        return code.replace(/console\.log\([^)]*\);?\n?/g, '');
      },
    };

    const result = await build({
      entryPoints: [join(stripDir, 'index.ts')],
      plugins: [vitePlugin(stripPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('console.log');
    expect(result.outputFiles[0].text).toContain('console.warn');
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(stripDir, { recursive: true, force: true });
  });

  test('실전 패턴: 다중 vitePlugin transform 체이닝', async () => {
    const chainDir = mkdtempSync(join(tmpdir(), 'zntc-vite-chain-'));
    writeFileSync(join(chainDir, 'index.ts'), 'const msg = "HELLO_WORLD";');

    // 첫 번째 플러그인: HELLO → Hello
    const lowercasePlugin: RollupPlugin = {
      name: 'lowercase-first',
      transform(code) {
        return code.replace('HELLO', 'Hello');
      },
    };

    // 두 번째 플러그인: _WORLD → _World (첫 번째 결과를 입력으로 받음)
    const capitalizePlugin: RollupPlugin = {
      name: 'capitalize-second',
      transform(code) {
        return code.replace('_WORLD', '_World');
      },
    };

    const result = await build({
      entryPoints: [join(chainDir, 'index.ts')],
      plugins: [vitePlugin(lowercasePlugin), vitePlugin(capitalizePlugin)],
    });
    expect(result.errors.length).toBe(0);
    // 두 플러그인의 transform이 순차 체이닝되어야 함
    expect(result.outputFiles[0].text).toContain('Hello_World');
    rmSync(chainDir, { recursive: true, force: true });
  });

  test('실전 패턴: 3개 플러그인 transform 체이닝', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-chain3-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "AAA_BBB_CCC";');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [
        vitePlugin({ name: 'p1', transform: (code) => code.replace('AAA', 'aaa') }),
        vitePlugin({ name: 'p2', transform: (code) => code.replace('BBB', 'bbb') }),
        vitePlugin({ name: 'p3', transform: (code) => code.replace('CCC', 'ccc') }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('aaa_bbb_ccc');
    rmSync(dir, { recursive: true, force: true });
  });
});
