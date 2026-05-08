import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
  ROOT_NODE_MODULES,
} from './helpers';

describe('실제 라이브러리 번들링', () => {
  let dir: string;
  const projectNodeModules = ROOT_NODE_MODULES;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-real-lib-'));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('React: ESM 번들', async () => {
    writeFileSync(
      join(dir, 'react-app.tsx'),
      'import React from "react";\nexport const el = React.createElement("div", null, "hello");',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-app.tsx')],
      format: 'esm',
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('createElement');
  });

  test('React: UMD + external → require 유지', async () => {
    writeFileSync(
      join(dir, 'react-umd.tsx'),
      'import React from "react";\nexport function App() { return React.createElement("div", null, "hi"); }',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-umd.tsx')],
      format: 'umd',
      globalName: 'ReactApp',
      external: ['react'],
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('ReactApp');
    expect(text).toContain('require');
  });

  test('React: IIFE 인라인 → 런타임 실행', async () => {
    writeFileSync(
      join(dir, 'react-iife.tsx'),
      'import React from "react";\nexport const version = React.version;',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-iife.tsx')],
      format: 'iife',
      globalName: 'ReactBundle',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const fn = new Function(result.outputFiles[0].text + '\nreturn ReactBundle;');
    const lib = fn();
    expect(lib.version).toBeDefined();
  });

  test('React + minify → 압축 후 런타임 실행 (#1041)', async () => {
    writeFileSync(
      join(dir, 'react-min.tsx'),
      'import React from "react";\nexport const v = React.version;',
    );
    const normal = await build({
      entryPoints: [join(dir, 'react-min.tsx')],
      format: 'iife',
      globalName: 'R',
      nodePaths: [projectNodeModules],
    });
    const minified = await build({
      entryPoints: [join(dir, 'react-min.tsx')],
      format: 'iife',
      globalName: 'R',
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(minified.errors.length).toBe(0);
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
    // 런타임 실행: minify 후에도 React가 정상 동작
    const fn = new Function(minified.outputFiles[0].text + '\nreturn R;');
    const lib = fn();
    expect(lib.v).toBeDefined();
  });

  test('lodash-es: tree-shaking으로 번들 크기 축소', async () => {
    writeFileSync(
      join(dir, 'lodash-app.ts'),
      'import { chunk } from "lodash-es";\nexport const result = chunk([1,2,3,4], 2);',
    );
    const result = await build({
      entryPoints: [join(dir, 'lodash-app.ts')],
      format: 'esm',
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text.length).toBeLessThan(50000);
  });

  test('다중 엔트리 + code splitting + React', async () => {
    writeFileSync(
      join(dir, 'page-a.tsx'),
      'import React from "react";\nexport const A = React.createElement("div", null, "A");',
    );
    writeFileSync(
      join(dir, 'page-b.tsx'),
      'import React from "react";\nexport const B = React.createElement("div", null, "B");',
    );
    const result = await build({
      entryPoints: [join(dir, 'page-a.tsx'), join(dir, 'page-b.tsx')],
      splitting: true,
      format: 'esm',
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(3);
  });

  test('React JSX automatic 모드', async () => {
    writeFileSync(join(dir, 'jsx-auto.tsx'), 'export const App = () => <div>hello</div>;');
    const result = await build({
      entryPoints: [join(dir, 'jsx-auto.tsx')],
      jsx: 'automatic',
      format: 'esm',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('jsx');
  });

  test('React + define + platform=browser → production 빌드', async () => {
    writeFileSync(
      join(dir, 'react-prod.tsx'),
      'import React from "react";\nif (process.env.NODE_ENV !== "production") { console.log("dev"); }\nexport const v = React.version;',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-prod.tsx')],
      format: 'iife',
      globalName: 'Prod',
      platform: 'browser',
      define: { 'process.env.NODE_ENV': '"production"' },
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('"dev"');
  });
});

// ─── import.meta.glob 테스트 (#1026) ───
