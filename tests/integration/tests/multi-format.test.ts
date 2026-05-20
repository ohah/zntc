/// multi-format API smoke (#3561). rollup-style `zntc(input).write(output)` 패턴 + 출력
/// 검증.

import { describe, test, expect } from 'bun:test';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build, zntc, type BuildOptions } from '@zntc/core';

async function createFixture(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'zntc-multi-format-'));
  for (const [name, content] of Object.entries(files)) {
    const filePath = join(dir, name);
    const parent = join(dir, name.split('/').slice(0, -1).join('/'));
    if (parent !== dir) await mkdir(parent, { recursive: true });
    await writeFile(filePath, content);
  }
  return dir;
}

describe('multi-format JS API (#3561)', () => {
  test('esbuild-style build({output:[esm,cjs]}) returns outputsByFormat', async () => {
    const dir = await createFixture({
      'index.ts': 'export const greet = (n: string) => `hello ${n}`;\nconsole.log(greet("b"));',
    });
    try {
      const result = await build({
        entryPoints: [join(dir, 'index.ts')],
        output: [
          { format: 'esm', dir: join(dir, 'dist-esm') },
          { format: 'cjs', dir: join(dir, 'dist-cjs') },
        ],
      } as BuildOptions);
      expect(result.errors.length).toBe(0);
      expect(result.outputsByFormat).toBeDefined();
      expect(result.outputsByFormat!.length).toBe(2);
      expect(result.outputsByFormat![0].format).toBe('esm');
      expect(result.outputsByFormat![1].format).toBe('cjs');
      expect(result.outputsByFormat![0].outputFiles.length).toBeGreaterThan(0);
      expect(result.outputsByFormat![1].outputFiles.length).toBeGreaterThan(0);
      const esmText = result.outputsByFormat![0].outputFiles.map((f) => f.text).join('\n');
      const cjsText = result.outputsByFormat![1].outputFiles.map((f) => f.text).join('\n');
      expect(esmText).not.toBe(cjsText);
      // backward-compat: outputFiles 가 첫 format 의 alias
      expect(result.outputFiles).toEqual(result.outputsByFormat![0].outputFiles);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('zntc(input).write(esm) + write(cjs) produces both outputs', async () => {
    const dir = await createFixture({
      'index.ts': 'export const greet = (n: string) => `hi ${n}`;\nconsole.log(greet("a"));',
    });
    try {
      const bundle = await zntc({
        entryPoints: [join(dir, 'index.ts')],
      } as BuildOptions);
      try {
        const esm = await bundle.write({ format: 'esm', dir: join(dir, 'dist-esm') });
        const cjs = await bundle.write({ format: 'cjs', dir: join(dir, 'dist-cjs') });
        expect(esm.errors.length).toBe(0);
        expect(cjs.errors.length).toBe(0);
        expect(esm.outputFiles.length).toBeGreaterThan(0);
        expect(cjs.outputFiles.length).toBeGreaterThan(0);
        // ESM 와 CJS 결과는 byte-different 여야 함 (format 분기 실제 동작)
        const esmText = esm.outputFiles.map((f) => f.text).join('\n');
        const cjsText = cjs.outputFiles.map((f) => f.text).join('\n');
        expect(esmText).not.toBe(cjsText);
      } finally {
        await bundle.close();
      }
      // close 이후 write 호출 시 error
      const bundleClosed = await zntc({ entryPoints: [join(dir, 'index.ts')] } as BuildOptions);
      await bundleClosed.close();
      expect(bundleClosed.closed).toBe(true);
      await expect(bundleClosed.write({ format: 'esm' })).rejects.toThrow(/closed/);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
