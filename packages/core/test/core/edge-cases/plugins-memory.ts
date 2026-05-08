import {
  describe,
  test,
  expect,
  build,
  transpile,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core edge cases: plugins and memory', () => {
  test('plugin: null 반환 시 기본 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-plugin-null-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const noopPlugin: ZntcPlugin = {
      name: 'noop',
      setup(build) {
        build.onLoad({ filter: /never-match/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [noopPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin: setup에서 아무 훅도 등록하지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-empty-plugin-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [{ name: 'empty', setup() {} }],
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('transpile: 반복 호출 1000회 메모리 안정성', () => {
    for (let i = 0; i < 1000; i++) {
      const result = transpile(`const x${i} = ${i};`);
      expect(result.code).toContain(`x${i} = ${i}`);
    }
  });
});
