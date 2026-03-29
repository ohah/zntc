import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { join, resolve } from "node:path";

const CORE_PATH = resolve(import.meta.dir, "../../../packages/core/index.js");

describe("Plugin: subprocess", () => {
  test("load hook transforms .css to JS export", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import css from './style.css';\nconsole.log(css);`,
      "style.css": "body { color: red; }",
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { definePlugin } from '${CORE_PATH}';
        definePlugin("css-loader", (build) => {
          build.onLoad({ filter: '.css' }, async (args) => {
            const fs = await import('node:fs');
            const css = await fs.promises.readFile(args.path, 'utf8');
            return { contents: 'export default ' + JSON.stringify(css) + ';' };
          });
        });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
      ]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("body { color: red; }");
      expect(result.stdout).not.toContain("require(");
    } finally {
      await cleanup();
    }
  });

  test("load hook not called for non-matching extensions", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x: number = 42;\nconsole.log(x);`,
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { definePlugin } from '${CORE_PATH}';
        definePlugin("css-only", (build) => {
          build.onLoad({ filter: '.css' }, async () => {
            throw new Error('should not be called for .ts files');
          });
        });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
      ]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("const x = 42");
    } finally {
      await cleanup();
    }
  });

  test("transform hook modifies output code", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x = 42;\nconsole.log(x);`,
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { definePlugin } from '${CORE_PATH}';
        definePlugin("banner", (build) => {
          build.onTransform({ filter: '.ts' }, async (args) => {
            return { contents: '/* BANNER */\\n' + args.code };
          });
        });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
      ]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("/* BANNER */");
    } finally {
      await cleanup();
    }
  });

  test("plugin error shows descriptive message", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import './broken.css';`,
      "broken.css": "",
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { definePlugin } from '${CORE_PATH}';
        definePlugin("failing", (build) => {
          build.onLoad({ filter: '.css' }, async () => {
            throw new Error('CSS compilation failed');
          });
        });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
      ]);

      // 에러 메시지에 플러그인 이름과 에러 내용이 포함되어야 함
      expect(result.stderr).toContain("plugin:failing");
      expect(result.stderr).toContain("CSS compilation failed");
    } finally {
      await cleanup();
    }
  });

  test("multiple --plugin flags", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import css from './style.css';\nconsole.log(css);`,
      "style.css": "h1 { font-size: 24px; }",
      "package.json": '{"type": "module"}',
      "plugin-css.js": `
        import { definePlugin } from '${CORE_PATH}';
        definePlugin("css-loader", (build) => {
          build.onLoad({ filter: '.css' }, async (args) => {
            const fs = await import('node:fs');
            const css = await fs.promises.readFile(args.path, 'utf8');
            return { contents: 'export default ' + JSON.stringify(css) + ';' };
          });
        });
      `,
      "plugin-banner.js": `
        import { definePlugin } from '${CORE_PATH}';
        definePlugin("banner", (build) => {
          build.onTransform({ filter: '.ts' }, async (args) => {
            return { contents: '/* MULTI-PLUGIN */\\n' + args.code };
          });
        });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin-css.js"),
        "--plugin",
        join(dir, "plugin-banner.js"),
      ]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("h1 { font-size: 24px; }");
      expect(result.stdout).toContain("/* MULTI-PLUGIN */");
    } finally {
      await cleanup();
    }
  });

  test("no plugins preserves existing behavior", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x: number = 42;\nconsole.log(x);`,
    });

    try {
      const result = await runZts(["--bundle", join(dir, "entry.ts")]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("const x = 42");
    } finally {
      await cleanup();
    }
  });
});
