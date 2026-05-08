import { build, describe, expect, test, writeFileSync } from '../helpers';
import { useRealLibraryFixture } from './fixture';

describe('실제 라이브러리 번들링', () => {
  const fixture = useRealLibraryFixture();

  test('React + minify → 압축 후 런타임 실행 (#1041)', async () => {
    writeFileSync(
      fixture.path('react-min.tsx'),
      'import React from "react";\nexport const v = React.version;',
    );
    const normal = await build({
      entryPoints: [fixture.path('react-min.tsx')],
      format: 'iife',
      globalName: 'R',
      nodePaths: [fixture.projectNodeModules],
    });
    const minified = await build({
      entryPoints: [fixture.path('react-min.tsx')],
      format: 'iife',
      globalName: 'R',
      minify: true,
      nodePaths: [fixture.projectNodeModules],
    });
    expect(minified.errors.length).toBe(0);
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
    // 런타임 실행: minify 후에도 React가 정상 동작
    const fn = new Function(minified.outputFiles[0].text + '\nreturn R;');
    const lib = fn();
    expect(lib.v).toBeDefined();
  });

  test('다중 엔트리 + code splitting + React', async () => {
    writeFileSync(
      fixture.path('page-a.tsx'),
      'import React from "react";\nexport const A = React.createElement("div", null, "A");',
    );
    writeFileSync(
      fixture.path('page-b.tsx'),
      'import React from "react";\nexport const B = React.createElement("div", null, "B");',
    );
    const result = await build({
      entryPoints: [fixture.path('page-a.tsx'), fixture.path('page-b.tsx')],
      splitting: true,
      format: 'esm',
      jsx: 'classic',
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(3);
  });

  test('React JSX automatic 모드', async () => {
    writeFileSync(fixture.path('jsx-auto.tsx'), 'export const App = () => <div>hello</div>;');
    const result = await build({
      entryPoints: [fixture.path('jsx-auto.tsx')],
      jsx: 'automatic',
      format: 'esm',
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('jsx');
  });

  test('React + define + platform=browser → production 빌드', async () => {
    writeFileSync(
      fixture.path('react-prod.tsx'),
      'import React from "react";\nif (process.env.NODE_ENV !== "production") { console.log("dev"); }\nexport const v = React.version;',
    );
    const result = await build({
      entryPoints: [fixture.path('react-prod.tsx')],
      format: 'iife',
      globalName: 'Prod',
      platform: 'browser',
      define: { 'process.env.NODE_ENV': '"production"' },
      minify: true,
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('"dev"');
  });
});
