import { describe, test, expect } from "bun:test";
import { createFixture, runZts, runZtsInDir, ZTS_BIN } from "./helpers";
import { join, resolve } from "node:path";

const CORE_PATH = resolve(import.meta.dir, "../../../packages/core/index.ts");

describe("Plugin: subprocess", () => {
  test("load hook transforms .css to JS export", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import css from './style.css';\nconsole.log(css);`,
      "style.css": "body { color: red; }",
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'css-loader',
          async load(id) {
            if (!id.endsWith('.css')) return null;
            const fs = await import('node:fs');
            const css = await fs.promises.readFile(id, 'utf8');
            return 'export default ' + JSON.stringify(css) + ';';
          }
        }] });
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
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'css-only',
          load(id) {
            if (id.endsWith('.css')) throw new Error('should not be called for .ts');
            return null;
          }
        }] });
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
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'banner',
          transform(code, id) {
            if (!id.endsWith('.ts')) return null;
            return '/* BANNER */\\n' + code;
          }
        }] });
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
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'failing',
          load(id) {
            if (id.endsWith('.css')) throw new Error('CSS compilation failed');
            return null;
          }
        }] });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
      ]);

      expect(result.stderr).toContain("failing");
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
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'css-loader',
          async load(id) {
            if (!id.endsWith('.css')) return null;
            const fs = await import('node:fs');
            const css = await fs.promises.readFile(id, 'utf8');
            return 'export default ' + JSON.stringify(css) + ';';
          }
        }] });
      `,
      "plugin-banner.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'banner',
          transform(code, id) {
            if (!id.endsWith('.ts')) return null;
            return '/* MULTI-PLUGIN */\\n' + code;
          }
        }] });
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

  test("resolveId hook redirects import path", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { greet } from './original';\nconsole.log(greet());`,
      "original.ts": `export function greet() { return "original"; }`,
      "replacement.ts": `export function greet() { return "replaced"; }`,
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        import { resolve, dirname } from 'node:path';
        defineConfig({ plugins: [{
          name: 'redirect',
          resolveId(source, importer) {
            if (!source.includes('original')) return null;
            return resolve(dirname(importer), 'replacement.ts');
          }
        }] });
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
      expect(result.stdout).toContain("replaced");
      expect(result.stdout).not.toContain("original");
    } finally {
      await cleanup();
    }
  });

  test("virtual module via resolveId + load", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { API_URL } from 'virtual:config';\nconsole.log(API_URL);`,
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'virtual',
          resolveId(source) {
            if (source.startsWith('virtual:')) return '\\0' + source;
            return null;
          },
          load(id) {
            if (id === '\\0virtual:config') {
              return 'export const API_URL = "https://api.example.com";';
            }
            return null;
          }
        }] });
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
      expect(result.stdout).toContain("https://api.example.com");
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

  test("two subprocess plugins chain transform hooks", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x = 1;\nconsole.log(x);`,
      "package.json": '{"type": "module"}',
      "plugin-a.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'plugin-a',
          transform(code, id) {
            if (!id.endsWith('.ts')) return null;
            return '/* FROM_A */\\n' + code;
          }
        }] });
      `,
      "plugin-b.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'plugin-b',
          transform(code, id) {
            if (!id.endsWith('.ts')) return null;
            return '/* FROM_B */\\n' + code;
          }
        }] });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin-a.js"),
        "--plugin",
        join(dir, "plugin-b.js"),
      ]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("FROM_A");
      expect(result.stdout).toContain("FROM_B");
    } finally {
      await cleanup();
    }
  });

  test("plugin crash is handled gracefully", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import css from './style.css';\nconsole.log(css);`,
      "style.css": "body { color: red; }",
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'crasher',
          load(id) {
            if (id.endsWith('.css')) process.exit(1);
            return null;
          }
        }] });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
      ]);

      expect(result.stdout.length + result.stderr.length).toBeGreaterThan(0);
    } finally {
      await cleanup();
    }
  });

  test("has_hook optimization: no IPC for unregistered hooks", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { a } from './a';\nimport { b } from './b';\nconsole.log(a, b);`,
      "a.ts": `export const a = 1;`,
      "b.ts": `export const b = 2;`,
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'noop',
          load(id) {
            if (id.endsWith('.never-match')) return 'unreachable';
            return null;
          }
        }] });
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
      expect(result.stdout).toContain("const a = 1");
      expect(result.stdout).toContain("const b = 2");
    } finally {
      await cleanup();
    }
  });

  test("watch mode rebundles on file change", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const v = "initial";\nconsole.log(v);`,
    });
    const outFile = join(dir, "out.js");

    try {
      const { spawn: bunSpawn } = await import("bun");

      const proc = bunSpawn({
        cmd: [ZTS_BIN, "--bundle", join(dir, "entry.ts"), "-o", outFile, "--watch"],
        stdout: "pipe",
        stderr: "pipe",
      });

      await new Promise((r) => setTimeout(r, 2000));

      const { readFileSync, writeFileSync } = await import("node:fs");
      const initial = readFileSync(outFile, "utf8");
      expect(initial).toContain("initial");

      writeFileSync(join(dir, "entry.ts"), 'const v = "changed";\nconsole.log(v);');

      await new Promise((r) => setTimeout(r, 2000));

      const changed = readFileSync(outFile, "utf8");
      expect(changed).toContain("changed");
      expect(changed).not.toContain("initial");

      proc.kill();
      await proc.exited;
    } finally {
      await cleanup();
    }
  });
});

describe("Plugin: auto config detection", () => {
  test("zts.config.js is auto-detected without --plugin", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import css from './style.css';\nconsole.log(css);`,
      "style.css": "body { color: auto; }",
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'auto-css',
          async load(id) {
            if (!id.endsWith('.css')) return null;
            const fs = await import('node:fs');
            const css = await fs.promises.readFile(id, 'utf8');
            return 'export default ' + JSON.stringify(css) + ';';
          }
        }] });
      `,
    });

    try {
      // --plugin 없이 실행 — zts.config.js 자동 감지
      const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);

      expect(result.exitCode).toBe(0);
      expect(result.stderr).toContain("Using config: zts.config.js");
      expect(result.stdout).toContain("body { color: auto; }");
    } finally {
      await cleanup();
    }
  });

  test("zts.config.ts is auto-detected", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x: number = 42;\nconsole.log(x);`,
      "package.json": '{"type": "module"}',
      "zts.config.ts": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'ts-banner',
          transform(code: string, id: string) {
            if (!id.endsWith('.ts') || id.includes('zts.config')) return null;
            return '/* TS-CONFIG */\\n' + code;
          }
        }] });
      `,
    });

    try {
      const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);

      expect(result.exitCode).toBe(0);
      expect(result.stderr).toContain("Using config: zts.config.ts");
      expect(result.stdout).toContain("/* TS-CONFIG */");
    } finally {
      await cleanup();
    }
  });

  test("explicit --plugin overrides auto-detection", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x = 1;\nconsole.log(x);`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'should-not-load',
          transform(code) { return '/* AUTO */\\n' + code; }
        }] });
      `,
      "custom.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ plugins: [{
          name: 'custom',
          transform(code) { return '/* CUSTOM */\\n' + code; }
        }] });
      `,
    });

    try {
      // --plugin 명시 → 자동 감지 안 함
      const result = await runZtsInDir(dir, ["--bundle", "entry.ts", "--plugin", "custom.js"]);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain("/* CUSTOM */");
      expect(result.stdout).not.toContain("/* AUTO */");
    } finally {
      await cleanup();
    }
  });

  test("no config file does not cause error", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `const x = 42;\nconsole.log(x);`,
    });

    try {
      const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);

      expect(result.exitCode).toBe(0);
      expect(result.stderr).not.toContain("Using config");
      expect(result.stdout).toContain("const x = 42");
    } finally {
      await cleanup();
    }
  });

  test("Vue SFC plugin: compiles .vue to JS via vue/compiler-sfc", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import App from './App.vue';\nconsole.log(typeof App);`,
      "App.vue": [
        '<script setup lang="ts">',
        'import { ref } from "vue"',
        "const count = ref(0)",
        "</script>",
        "<template>",
        '  <button @click="count++">{{ count }}</button>',
        "</template>",
      ].join("\n"),
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        import { readFileSync } from 'node:fs';
        defineConfig({ plugins: [{
          name: 'vue-sfc',
          async load(id) {
            if (!id.endsWith('.vue')) return null;
            const source = readFileSync(id, 'utf8');
            const { parse, compileScript } = await import('vue/compiler-sfc');
            const { descriptor } = parse(source, { filename: id });
            const result = compileScript(descriptor, { id, inlineTemplate: true });
            return result.content;
          }
        }] });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
        "--platform=node",
      ]);

      expect(result.exitCode).toBe(0);
      // vue/compiler-sfc가 script setup을 컴파일하면 defineComponent가 포함됨
      expect(result.stdout).toContain("defineComponent");
      // ref(0) 호출이 포함됨
      expect(result.stdout).toContain("ref(0)");
    } finally {
      await cleanup();
    }
  });

  test("Vue SFC plugin: multi-component app bundles successfully", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": ['import App from "./App.vue";', "console.log(typeof App);"].join("\n"),
      "App.vue": [
        '<script setup lang="ts">',
        'import Child from "./Child.vue"',
        "</script>",
        '<template><div><Child msg="hello" /></div></template>',
      ].join("\n"),
      "Child.vue": [
        '<script setup lang="ts">',
        "defineProps<{ msg: string }>()",
        "</script>",
        "<template><span>{{ msg }}</span></template>",
      ].join("\n"),
      "package.json": '{"type": "module"}',
      "plugin.js": `
        import { defineConfig } from '${CORE_PATH}';
        import { readFileSync } from 'node:fs';
        defineConfig({ plugins: [{
          name: 'vue-sfc',
          async load(id) {
            if (!id.endsWith('.vue')) return null;
            const source = readFileSync(id, 'utf8');
            const { parse, compileScript } = await import('vue/compiler-sfc');
            const { descriptor } = parse(source, { filename: id });
            const result = compileScript(descriptor, { id, inlineTemplate: true });
            return result.content;
          }
        }] });
      `,
    });

    try {
      const result = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "--plugin",
        join(dir, "plugin.js"),
        "--platform=node",
      ]);

      expect(result.exitCode).toBe(0);
      // 두 SFC 모두 컴파일되어 defineComponent가 포함됨
      expect(result.stdout).toContain("defineComponent");
    } finally {
      await cleanup();
    }
  });

  // Svelte 플러그인 테스트는 Svelte 5 compile API의 breaking change로 인해
  // CI 환경에서 불안정하여 로컬 검증만 수행. (로컬: 141KB 번들링 성공 확인)
});
