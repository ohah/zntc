import {
  describe,
  test,
  expect,
  build,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core 플러그인 심화: multi module transforms', () => {
  test('다중 모듈 번들 + 플러그인', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-large-'));

    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 5 }, (_, i) => `val${i}`).join(' + ');
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(${usage});`);

    let transformCount = 0;
    const countPlugin: ZntcPlugin = {
      name: 'count-transforms',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          transformCount++;
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('val4');
    expect(transformCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('멀티스레드: 10개 모듈 + onTransform 플러그인 (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt-'));
    for (let i = 0; i < 10; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 10 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 10 }, (_, i) => `val${i}`).join(' + ');
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(${usage});`);

    let callCount = 0;
    const countPlugin: ZntcPlugin = {
      name: 'count',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          callCount++;
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('val9');
    expect(callCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });
});
