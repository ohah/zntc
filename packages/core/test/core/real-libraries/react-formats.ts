import { build, describe, expect, test, writeFileSync } from '../helpers';
import { useRealLibraryFixture } from './fixture';

describe('실제 라이브러리 번들링', () => {
  const fixture = useRealLibraryFixture();

  test('React: ESM 번들', async () => {
    writeFileSync(
      fixture.path('react-app.tsx'),
      'import React from "react";\nexport const el = React.createElement("div", null, "hello");',
    );
    const result = await build({
      entryPoints: [fixture.path('react-app.tsx')],
      format: 'esm',
      jsx: 'classic',
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('createElement');
  });

  test('React: UMD + external → require 유지', async () => {
    writeFileSync(
      fixture.path('react-umd.tsx'),
      'import React from "react";\nexport function App() { return React.createElement("div", null, "hi"); }',
    );
    const result = await build({
      entryPoints: [fixture.path('react-umd.tsx')],
      format: 'umd',
      globalName: 'ReactApp',
      external: ['react'],
      jsx: 'classic',
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('ReactApp');
    expect(text).toContain('require');
  });

  test('React: IIFE 인라인 → 런타임 실행', async () => {
    writeFileSync(
      fixture.path('react-iife.tsx'),
      'import React from "react";\nexport const version = React.version;',
    );
    const result = await build({
      entryPoints: [fixture.path('react-iife.tsx')],
      format: 'iife',
      globalName: 'ReactBundle',
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const fn = new Function(result.outputFiles[0].text + '\nreturn ReactBundle;');
    const lib = fn();
    expect(lib.version).toBeDefined();
  });
});
