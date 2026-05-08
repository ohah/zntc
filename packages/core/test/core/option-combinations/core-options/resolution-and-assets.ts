import {
  afterAll,
  beforeAll,
  buildSync,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
  writeFileSync,
} from '../helpers';

describe('옵션 조합 통합 테스트 - core options - resolution and assets', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('loader + packagesExternal 조합', () => {
    writeFileSync(
      join(dir, 'asset-entry.ts'),
      'import logo from "./logo.txt";\nimport React from "react";\nexport { logo, React };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'asset-entry.ts')],
      loader: { '.txt': 'text' },
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('LOGO_TEXT');
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test('define + alias + inject 조합', () => {
    writeFileSync(join(dir, 'shim.ts'), 'globalThis.__INJECTED__ = true;');
    writeFileSync(
      join(dir, 'define-entry.ts'),
      'import { foo } from "@alias/mod";\nconsole.log(__DEV__, foo);',
    );
    writeFileSync(join(dir, 'real.ts'), 'export const foo = "real";');
    const result = buildSync({
      entryPoints: [join(dir, 'define-entry.ts')],
      define: { __DEV__: 'false' },
      alias: { '@alias/mod': join(dir, 'real.ts') },
      inject: [join(dir, 'shim.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('false');
    expect(result.outputFiles[0].text).toContain('real');
    expect(result.outputFiles[0].text).toContain('__INJECTED__');
  });
});
