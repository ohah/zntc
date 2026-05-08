import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  test,
  writeFileSync,
} from '../helpers';
import { createBatchEFixture, type BatchEFixture } from './fixture';

describe('배치 E: S급 BuildOptions - optimization', () => {
  let fixture: BatchEFixture;

  beforeAll(() => {
    fixture = createBatchEFixture();
  });

  afterAll(() => fixture.cleanup());

  test('packagesExternal: bare import를 external 처리', () => {
    writeFileSync(
      join(fixture.dir, 'ext-entry.ts'),
      'import React from "react";\nexport default React;',
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'ext-entry.ts')],
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test('dropLabels: DEV 라벨 제거', () => {
    const result = buildSync({
      entryPoints: [fixture.entry],
      dropLabels: ['DEV'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('dev only');
    expect(result.outputFiles[0].text).toContain('x = 1');
  });

  test('pure: 미사용 순수 함수 호출 제거', () => {
    const result = buildSync({
      entryPoints: [fixture.pureTest],
      pure: ['pureUtil'],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('2');
  });

  test('lineLimit: 줄 길이 제한', () => {
    const result = buildSync({
      entryPoints: [fixture.entry],
      lineLimit: 40,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('ignoreAnnotations: @__PURE__ annotation 무시', () => {
    writeFileSync(
      join(fixture.dir, 'ignore-annotations.ts'),
      "function side(){ console.log('PURE_CALL'); }\n/* @__PURE__ */ side();\nconsole.log('live');",
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'ignore-annotations.ts')],
      ignoreAnnotations: true,
      minifySyntax: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('side()');
    expect(result.outputFiles[0].text).toContain('PURE_CALL');
  });

  test('jsxSideEffects: unused JSX expression 보존', () => {
    writeFileSync(
      join(fixture.dir, 'jsx-side-effects.tsx'),
      [
        'const React = { createElement(type) { console.log(type); } };',
        '<div />;',
        "console.log('live');",
      ].join('\n'),
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'jsx-side-effects.tsx')],
      jsxSideEffects: true,
      minifySyntax: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('React.createElement');
  });
});
