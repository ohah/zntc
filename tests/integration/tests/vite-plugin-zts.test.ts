import { describe, it, expect, afterEach } from "bun:test";
import { createFixture, hasPackage } from "./helpers";
import { join, resolve } from "node:path";

// vite-plugin-zts 스모크 테스트
// Vite 빌드에서 ZTS가 esbuild 대신 TS/JSX를 트랜스파일하는지 검증

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");

const hasVite = hasPackage("vite");

async function viteBuildLib(root: string, entry: string): Promise<{ output: any[] }> {
  const vite = await import("vite");
  const { zts } = await import(join(PROJECT_ROOT, "packages/vite-plugin-zts/src/index.ts"));

  const result = await vite.build({
    root,
    plugins: [zts()],
    build: {
      lib: { entry, formats: ["es"], fileName: "out" },
      outDir: "dist",
      minify: false,
      write: false,
    },
    logLevel: "silent",
  });

  const rollupOutput = Array.isArray(result) ? result[0] : result;
  return { output: (rollupOutput as any).output ?? [] };
}

describe.skipIf(!hasVite)("vite-plugin-zts", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("TypeScript transform → type annotations stripped", async () => {
    const fixture = await createFixture({
      "main.ts": `export const greeting: string = "hello from ZTS";\nexport const num: number = 42;`,
    });
    cleanup = fixture.cleanup;

    const result = await viteBuildLib(fixture.dir, join(fixture.dir, "main.ts"));

    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    expect(jsChunk.code).toContain("hello from ZTS");
    expect(jsChunk.code).not.toContain(": string");
    expect(jsChunk.code).not.toContain(": number");
  });

  it("JSX transform → JSX syntax compiled to JS", async () => {
    const fixture = await createFixture({
      "main.tsx": `export const App = () => <div className="app">Hello JSX</div>;`,
    });
    cleanup = fixture.cleanup;

    const vite = await import("vite");
    const { zts } = await import(join(PROJECT_ROOT, "packages/vite-plugin-zts/src/index.ts"));
    const r = await vite.build({
      root: fixture.dir,
      plugins: [zts()],
      build: {
        lib: { entry: join(fixture.dir, "main.tsx"), formats: ["es"], fileName: "out" },
        outDir: "dist",
        minify: false,
        write: false,
        rollupOptions: { external: ["react", "react/jsx-runtime", "react/jsx-dev-runtime"] },
      },
      logLevel: "silent",
    });
    const rollupOutput = Array.isArray(r) ? r[0] : r;
    const result = { output: (rollupOutput as any).output ?? [] };

    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    expect(jsChunk.code).not.toContain("<div");
    expect(jsChunk.code).toContain("Hello JSX");
  });

  it("enum transform → enum compiled to object", async () => {
    const fixture = await createFixture({
      "main.ts": `export enum Color { Red, Green, Blue }\nexport const c = Color.Red;`,
    });
    cleanup = fixture.cleanup;

    const result = await viteBuildLib(fixture.dir, join(fixture.dir, "main.ts"));

    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    expect(jsChunk.code).not.toContain("enum ");
    expect(jsChunk.code).toContain("Color");
  });

  it("interface/type stripped without error", async () => {
    const fixture = await createFixture({
      "main.ts": `
        interface User { name: string; age: number; }
        type ID = string | number;
        export const greet = (u: User): string => u.name;
      `,
    });
    cleanup = fixture.cleanup;

    const result = await viteBuildLib(fixture.dir, join(fixture.dir, "main.ts"));

    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    expect(jsChunk.code).not.toContain("interface");
    expect(jsChunk.code).not.toContain("type ID");
    expect(jsChunk.code).toContain("greet");
  });

  it("RSC: 'use client' 디렉티브 보존 (Vite + ZTS)", async () => {
    const fixture = await createFixture({
      "main.tsx": `"use client";\nexport const tag = "CLIENT";\nexport function f(x: number){return x + 1;}`,
    });
    cleanup = fixture.cleanup;

    const result = await viteBuildLib(fixture.dir, join(fixture.dir, "main.tsx"));
    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    // Vite/Rollup이 디렉티브를 출력 청크 top에 보존 (ZTS transform이 디렉티브를 살린 상태로 넘김)
    expect(
      jsChunk.code.trimStart().startsWith('"use client"') ||
        jsChunk.code.trimStart().startsWith("'use client'"),
    ).toBe(true);
  });

  it("RSC: 'use server' 디렉티브 보존 (Vite + ZTS)", async () => {
    const fixture = await createFixture({
      "main.ts": `"use server";\nexport async function action(){return 1;}`,
    });
    cleanup = fixture.cleanup;

    const result = await viteBuildLib(fixture.dir, join(fixture.dir, "main.ts"));
    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    expect(
      jsChunk.code.trimStart().startsWith('"use server"') ||
        jsChunk.code.trimStart().startsWith("'use server'"),
    ).toBe(true);
  });

  it("tsconfig 자동 적용 — 다수 파일 빌드 시 cache 활성으로 정상 동작 (#2367)", async () => {
    // 같은 디렉토리에 여러 .ts 파일 + tsconfig.json. plugin 의 cache 가 활성이면
    // 각 파일마다 walk 안 하고 cache hit. 결과 정확성 검증 — tsconfig 의 target=es2020
    // 이 모든 파일에 적용되는지.
    const fixture = await createFixture({
      "tsconfig.json": JSON.stringify({ compilerOptions: { target: "es2020" } }),
      "main.ts": `import { add, mul } from "./util";\nexport const result = add(1, 2) + mul(3, 4);`,
      "util.ts": `export const add = (a: number, b: number) => a + b;\nexport const mul = (a: number, b: number) => a * b;`,
    });
    cleanup = fixture.cleanup;

    const result = await viteBuildLib(fixture.dir, join(fixture.dir, "main.ts"));
    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    // 두 파일 모두 transpile 성공 (cache 가 정확성에 영향 없음)
    expect(jsChunk.code).toContain("add");
    expect(jsChunk.code).toContain("mul");
    // type annotation 제거 확인
    expect(jsChunk.code).not.toContain(": number");
  });

  it("tsconfigCache: false 옵션 — 캐시 비활성도 정상 빌드", async () => {
    const fixture = await createFixture({
      "tsconfig.json": JSON.stringify({ compilerOptions: { target: "es2020" } }),
      "main.ts": `export const x: number = 42;`,
    });
    cleanup = fixture.cleanup;

    const vite = await import("vite");
    const { zts } = await import(join(PROJECT_ROOT, "packages/vite-plugin-zts/src/index.ts"));
    const r = await vite.build({
      root: fixture.dir,
      plugins: [zts({ tsconfigCache: false })],
      build: {
        lib: { entry: join(fixture.dir, "main.ts"), formats: ["es"], fileName: "out" },
        outDir: "dist",
        minify: false,
        write: false,
      },
      logLevel: "silent",
    });
    const rollupOutput = Array.isArray(r) ? r[0] : r;
    const result = { output: (rollupOutput as any).output ?? [] };

    const jsChunk = result.output.find((o: any) => o.type === "chunk");
    expect(jsChunk).toBeDefined();
    expect(jsChunk.code).toContain("42");
    expect(jsChunk.code).not.toContain(": number");
  });
});
