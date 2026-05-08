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

describe('@zntc/core 플러그인 심화: options', () => {
  test('멀티스레드: 플러그인 + minify + sourcemap 동시 (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt3-'));
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(val0);`);

    const noopPlugin: ZntcPlugin = {
      name: 'noop',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [noopPlugin],
      minify: true,
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2);
    rmSync(dir, { recursive: true, force: true });
  });
});
