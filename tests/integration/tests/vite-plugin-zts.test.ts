import { describe, it, expect, afterEach } from "bun:test";
import { createFixture } from "./helpers";
import { join, resolve } from "node:path";

// vite-plugin-zts 스모크 테스트
// Vite 빌드에서 ZTS가 esbuild 대신 TS/JSX를 트랜스파일하는지 검증

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");

function hasPackage(name: string): boolean {
  try {
    const { statSync } = require("node:fs");
    statSync(join(PROJECT_ROOT, "node_modules", name, "package.json"));
    return true;
  } catch {
    return false;
  }
}

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
});
