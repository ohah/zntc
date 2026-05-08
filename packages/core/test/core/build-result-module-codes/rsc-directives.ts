import {
  describe,
  test,
  expect,
  transpile,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';

describe('RSC 디렉티브 보존 (NAPI)', () => {
  test("transpile: 'use client' 첫 문장 보존", () => {
    const result = transpile(
      `"use client";\nimport { useState } from "react";\nexport default function C(){return useState(0)[0];}`,
      { filename: 'client.tsx' },
    );
    expect(result.code.trimStart().startsWith('"use client"')).toBe(true);
  });

  test("transpile: 'use server' 첫 문장 보존", () => {
    const result = transpile(`"use server";\nexport async function f(){return 1;}`, {
      filename: 'server.ts',
    });
    expect(result.code.trimStart().startsWith('"use server"')).toBe(true);
  });

  test("transpile: 'use cache' 보존", () => {
    const result = transpile(`"use cache";\nexport async function f(){return 1;}`, {
      filename: 'cache.ts',
    });
    expect(result.code.trimStart().startsWith('"use cache"')).toBe(true);
  });

  test('buildSync preserve-modules: 각 파일이 자기 디렉티브 첫 문장으로 보존', () => {
    const d = mkdtempSync(join(tmpdir(), 'zntc-napi-rsc-'));
    writeFileSync(join(d, 'client.tsx'), `"use client";\nexport default function C(){return 1;}`);
    writeFileSync(join(d, 'server.ts'), `"use server";\nexport async function act(){return 1;}`);
    writeFileSync(
      join(d, 'entry.tsx'),
      `import C from "./client";\nimport { act } from "./server";\nexport default function E(){act();return C();}`,
    );
    const result = buildSync({
      entryPoints: [join(d, 'entry.tsx')],
      bundle: true,
      preserveModules: true,
      outdir: join(d, 'out'),
    });
    expect(result.errors.length).toBe(0);
    const clientFile = result.outputFiles.find((f) => f.path.includes('client'));
    const serverFile = result.outputFiles.find((f) => f.path.includes('server'));
    expect(clientFile).toBeDefined();
    expect(serverFile).toBeDefined();
    expect(clientFile!.text.trimStart().startsWith('"use client"')).toBe(true);
    expect(serverFile!.text.trimStart().startsWith('"use server"')).toBe(true);
    rmSync(d, { recursive: true });
  });

  test('buildSync ESM 단일 번들: entry 디렉티브 최상단', () => {
    const d = mkdtempSync(join(tmpdir(), 'zntc-napi-esm-'));
    writeFileSync(join(d, 'dep.ts'), `export const x = 1;`);
    writeFileSync(
      join(d, 'entry.tsx'),
      `"use client";\nimport { x } from "./dep";\nexport default x;`,
    );
    const result = buildSync({
      entryPoints: [join(d, 'entry.tsx')],
      bundle: true,
      format: 'esm',
      outdir: join(d, 'out'),
    });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0];
    expect(out).toBeDefined();
    expect(out.text.trimStart().startsWith('"use client"')).toBe(true);
    rmSync(d, { recursive: true });
  });
});
