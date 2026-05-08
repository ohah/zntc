import {
  describe,
  test,
  expect,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';

describe('buildResult moduleCodes/modulePaths', () => {
  test('buildSync: collectModuleCodes=true → moduleCodes 반환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mc-'));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');

    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.moduleCodes).toBeDefined();
    expect(result.moduleCodes!.length).toBeGreaterThan(0);
    // 각 moduleCodes에 id와 code가 있어야 함
    for (const mc of result.moduleCodes!) {
      expect(mc.id).toBeDefined();
      expect(mc.code.length).toBeGreaterThan(0);
    }
    rmSync(dir, { recursive: true });
  });

  test('buildSync: collectModuleCodes 미지정 → moduleCodes 없음', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mc-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.moduleCodes).toBeUndefined();
  });

  test('buildSync: modulePaths 반환 (번들에 포함된 모듈 경로)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mp-'));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');

    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.modulePaths).toBeDefined();
    expect(result.modulePaths!.length).toBeGreaterThanOrEqual(2);
    // entry.ts와 util.ts 경로가 포함되어야 함
    const hasEntry = result.modulePaths!.some((p) => p.includes('entry.ts'));
    const hasUtil = result.modulePaths!.some((p) => p.includes('util.ts'));
    expect(hasEntry).toBe(true);
    expect(hasUtil).toBe(true);
  });

  test('build (async): moduleCodes + modulePaths 반환', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mc-async-'));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.moduleCodes).toBeDefined();
    expect(result.moduleCodes!.length).toBeGreaterThan(0);
    expect(result.modulePaths).toBeDefined();
    expect(result.modulePaths!.length).toBeGreaterThanOrEqual(2);
    rmSync(dir, { recursive: true });
  });
});
