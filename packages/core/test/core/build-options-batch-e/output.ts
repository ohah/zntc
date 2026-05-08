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

describe('배치 E: S급 BuildOptions - output', () => {
  let fixture: BatchEFixture;

  beforeAll(() => {
    fixture = createBatchEFixture();
  });

  afterAll(() => fixture.cleanup());

  test('analyze: metafile 강제 활성화', () => {
    const result = buildSync({
      entryPoints: [fixture.entry],
      analyze: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
  });

  test('intro/outro/globals: output wrapper 옵션 적용', () => {
    writeFileSync(
      join(fixture.dir, 'globals.ts'),
      "import { useState } from 'react'; console.log(useState);",
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'globals.ts')],
      format: 'iife',
      globalName: 'Lib',
      external: ['react'],
      globals: { react: 'React' },
      intro: "console.log('intro');",
      outro: "console.log('outro');",
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain("console.log('intro');");
    expect(text).toContain("console.log('outro');");
    expect(text).toContain('})(React);');
  });

  test('outbase: 엔트리 공통 기준 경로', () => {
    const result = buildSync({
      entryPoints: [fixture.entry],
      outbase: fixture.dir,
    });
    expect(result.errors.length).toBe(0);
  });

  test('sourceRoot: 소스맵 sourceRoot', () => {
    const result = buildSync({
      entryPoints: [fixture.entry],
      sourcemap: true,
      sourceRoot: 'https://example.com/src',
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain('https://example.com/src');
  });
});
