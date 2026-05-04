import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  __runtimePolyfillTestHooks,
  applyRuntimePolyfillsToNapiOptions,
  collectRuntimePolyfillUsageFromFiles,
  computeCoreJsCompatModules,
  createRuntimePolyfillPrelude,
  isEsTarget,
  normalizeRuntimePolyfillOptions,
  normalizeRuntimeTargets,
  scanRuntimePolyfillUsage,
} from "./runtime-polyfills.ts";

function withRuntimeRequire<T>(runtimeRequire: any, fn: () => T): T {
  __runtimePolyfillTestHooks.setRuntimeRequire(runtimeRequire);
  try {
    return fn();
  } finally {
    __runtimePolyfillTestHooks.reset();
  }
}

describe("runtime polyfill target normalization", () => {
  test("normalizes compact and spaced engine targets", () => {
    expect(normalizeRuntimeTargets("ios12")).toEqual({ ios: "12" });
    expect(normalizeRuntimeTargets("ios_saf 12")).toEqual({ ios: "12" });
    expect(normalizeRuntimeTargets("iOS >= 12")).toEqual({ ios: "12" });
    expect(normalizeRuntimeTargets("chrome >= 85")).toEqual({ chrome: "85" });
    expect(normalizeRuntimeTargets("android >= 5")).toEqual({ android: "5" });
    expect(normalizeRuntimeTargets("samsung >= 14")).toEqual({ samsung: "14" });
    expect(normalizeRuntimeTargets("hermes0.7")).toEqual({ hermes: "0.7" });
    expect(normalizeRuntimeTargets("hermes 0.7")).toEqual({ hermes: "0.7" });
    expect(normalizeRuntimeTargets("react-native 0.70")).toEqual({ "react-native": "0.70" });
    expect(normalizeRuntimeTargets("node18")).toEqual({ node: "18" });
  });

  test("merges object targets and rejects device names", () => {
    expect(normalizeRuntimeTargets([{ ios: "12" }, "chrome85", "node18"])).toEqual({
      ios: "12",
      chrome: "85",
      node: "18",
    });
    expect(() => normalizeRuntimeTargets("iPhone 8")).toThrow("Physical device names");
    expect(() => normalizeRuntimeTargets("Galaxy S10")).toThrow("Physical device names");
  });

  test("keeps browserslist queries when they are not engine-version targets", () => {
    expect(normalizeRuntimeTargets("last 2 chrome versions")).toBe("last 2 chrome versions");
    expect(() => normalizeRuntimeTargets(["last 2 versions", "hermes0.7"])).toThrow(
      "cannot mix browserslist queries",
    );
  });

  test("normalizes runtime polyfill options and validates invalid inputs", () => {
    expect(isEsTarget("es2020")).toBe(true);
    expect(isEsTarget(undefined)).toBe(false);

    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          runtimePolyfills: "entry",
        }) as any
      ).targets,
    ).toBe("defaults");
    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          platform: "node",
          runtimePolyfills: "entry",
        }) as any
      ).targets.node,
    ).toMatch(/^\d+\.\d+$/);
    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          platform: "react-native",
          runtimePolyfills: "entry",
        }) as any
      ).targets,
    ).toEqual({ hermes: "0.7" });
    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          target: "hermes0.7",
          runtimePolyfills: "entry",
        }) as any
      ).targets,
    ).toEqual({ hermes: "0.7" });

    expect(() =>
      normalizeRuntimePolyfillOptions({
        entryPoints: [],
        runtimePolyfills: { mode: "bad" as any },
      }),
    ).toThrow("mode must be");
    expect(() =>
      normalizeRuntimePolyfillOptions({
        entryPoints: [],
        runtimePolyfills: { provider: "other" as any },
      }),
    ).toThrow("supports only 'core-js'");
    expect(() =>
      normalizeRuntimePolyfillOptions({
        entryPoints: [],
        runtimePolyfills: { include: ["not-a-core-js-module"] },
      }),
    ).toThrow("invalid core-js module");
  });
});

describe("core-js-compat adapter", () => {
  test("matches representative replaceAll support snapshots", () => {
    expect(computeCoreJsCompatModules({ ios: "12" }, ["es.string.replace-all"])).toEqual([
      "es.string.replace-all",
    ]);
    expect(computeCoreJsCompatModules({ ios: "13.4" }, ["es.string.replace-all"])).toEqual([]);
    expect(computeCoreJsCompatModules({ hermes: "0.6" }, ["es.string.replace-all"])).toEqual([
      "es.string.replace-all",
    ]);
    expect(computeCoreJsCompatModules({ hermes: "0.7" }, ["es.string.replace-all"])).toEqual([]);
    expect(computeCoreJsCompatModules({ node: "14" }, ["es.string.replace-all"])).toEqual([
      "es.string.replace-all",
    ]);
    expect(computeCoreJsCompatModules({ node: "18" }, ["es.string.replace-all"])).toEqual([]);
  });

  test("reports optional dependency load failures with actionable errors", () => {
    const missingRequire = Object.assign(
      () => {
        throw new Error("missing");
      },
      {
        resolve() {
          throw new Error("missing");
        },
      },
    );

    withRuntimeRequire(missingRequire, () => {
      expect(() => computeCoreJsCompatModules({ ios: "12" }, ["es.string.replace-all"])).toThrow(
        "core-js-compat",
      );
      expect(() => computeCoreJsCompatModules({ ios: "12" }, ["es.string.replace-all"])).toThrow(
        "core-js-compat",
      );
    });

    withRuntimeRequire(missingRequire, () => {
      expect(() => scanRuntimePolyfillUsage(`new Promise(() => {});`)).toThrow("@babel/parser");
      expect(() => scanRuntimePolyfillUsage(`new Promise(() => {});`)).toThrow("@babel/parser");
    });

    withRuntimeRequire(missingRequire, () => {
      expect(
        (
          normalizeRuntimePolyfillOptions({
            entryPoints: [],
            runtimePolyfills: "entry",
          }) as any
        ).coreJsVersion,
      ).toBeUndefined();
    });
  });
});

describe("runtime polyfill usage scanner", () => {
  test("finds supported v1 built-in usage", () => {
    const modules = scanRuntimePolyfillUsage(`
      const a = "a".replaceAll("a", "b");
      const b = values.at(0);
      const c = Object.hasOwn({ a: 1 }, "a");
      const d = structuredClone(c);
      const e = new Map();
      const f = new Set();
      const g = Promise.resolve(d);
      void [a, b, e, f, g];
    `);
    expect(modules).toEqual([
      "es.array.at",
      "es.map",
      "es.object.has-own",
      "es.promise",
      "es.set",
      "es.string.replace-all",
      "web.structured-clone",
    ]);
  });

  test("ignores dynamic computed member access", () => {
    expect(scanRuntimePolyfillUsage(`value[methodName]("x");`)).toEqual([]);
  });

  test("falls back to Flow parsing when TypeScript parsing fails", () => {
    expect(scanRuntimePolyfillUsage(`opaque type ID = string;\nnew Promise(() => {});`)).toEqual([
      "es.promise",
    ]);
  });

  test("retries with Flow parser options after a parser failure", () => {
    const parser = {
      calls: 0,
      parse() {
        this.calls += 1;
        if (this.calls === 1) throw new Error("typescript parse failed");
        return {
          type: "File",
          program: {
            type: "Program",
            body: [
              {
                type: "ExpressionStatement",
                expression: {
                  type: "CallExpression",
                  callee: { type: "Identifier", name: "Promise" },
                  arguments: [],
                },
              },
            ],
          },
        };
      },
    };
    const runtimeRequire = Object.assign(
      (id: string) => {
        if (id === "@babel/parser") return parser;
        throw new Error("unexpected require");
      },
      {
        resolve() {
          throw new Error("unexpected resolve");
        },
      },
    );

    withRuntimeRequire(runtimeRequire, () => {
      expect(scanRuntimePolyfillUsage(`ignored`)).toEqual(["es.promise"]);
      expect(parser.calls).toBe(2);
    });
  });

  test("scans local dependency files", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-scan-"));
    try {
      writeFileSync(join(dir, "entry.ts"), `import { run } from "./dep"; run();`);
      writeFileSync(join(dir, "dep.ts"), `export const run = () => "a".replaceAll("a", "b");`);
      expect(
        collectRuntimePolyfillUsageFromFiles([join(dir, "entry.ts")], {
          resolveExtensions: [".ts", ".custom"],
        }),
      ).toEqual(["es.string.replace-all"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("scans require dependencies and directory index modules", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-scan-"));
    try {
      writeFileSync(
        join(dir, "entry.ts"),
        `require("./dep"); import "./folder"; import "./empty"; import "./missing"; import "./style.css";`,
      );
      writeFileSync(join(dir, "dep.js"), `new Set();`);
      mkdirSync(join(dir, "folder"));
      writeFileSync(join(dir, "folder", "index.ts"), `[1].at(0);`);
      mkdirSync(join(dir, "empty"));
      writeFileSync(join(dir, "style.css"), `.x { color: red; }`);
      expect(collectRuntimePolyfillUsageFromFiles([join(dir, "entry.ts")])).toEqual([
        "es.array.at",
        "es.set",
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("runtime polyfill prelude", () => {
  test("creates a removable side-effect import prelude", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-prelude-"));
    try {
      const entry = join(dir, "entry.ts");
      writeFileSync(entry, `console.log("entry");`);
      const prelude = createRuntimePolyfillPrelude(["es.string.replace-all"], {
        entryPoints: [entry],
      });
      expect(prelude).not.toBeNull();
      const path = prelude!.path;
      expect(readFileSync(path, "utf8")).toContain("core-js/modules/es.string.replace-all.js");
      prelude!.cleanup();
      expect(existsSync(path)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("throws when a requested core-js module cannot be resolved", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-prelude-"));
    try {
      const entry = join(dir, "entry.ts");
      writeFileSync(entry, `console.log("entry");`);
      expect(() =>
        createRuntimePolyfillPrelude(["es.not-real"], {
          entryPoints: [entry],
        }),
      ).toThrow("could not resolve");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("applies include/exclude and prepends runtime prelude before runBeforeMain", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-apply-"));
    try {
      const entry = join(dir, "entry.ts");
      const init = join(dir, "init.ts");
      writeFileSync(entry, `"a".replaceAll("a", "b");`);
      writeFileSync(init, `globalThis.__INIT__ = true;`);

      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: [entry],
        runtimePolyfills: {
          mode: "auto",
          targets: "ios12",
          include: ["es.array.at"],
          exclude: ["es.string.replace-all"],
        },
        runBeforeMain: [init],
      });
      try {
        expect(applied.modules).toEqual(["es.array.at"]);
        const runBeforeMain = napiOptions.runBeforeMain as string[];
        expect(typeof runBeforeMain[0]).toBe("string");
        expect(runBeforeMain[1]).toBe(init);
        expect(readFileSync(runBeforeMain[0], "utf8")).toContain("core-js/modules/es.array.at.js");
      } finally {
        applied.cleanup();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("entry mode injects the target-wide compat prelude", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-entry-"));
    try {
      const entry = join(dir, "entry.ts");
      writeFileSync(entry, `console.log("entry");`);
      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: [entry],
        runtimePolyfills: { mode: "entry", targets: "node999" },
      });
      try {
        expect(applied.modules.length).toBeGreaterThan(0);
        const runBeforeMain = napiOptions.runBeforeMain as string[];
        expect(readFileSync(runBeforeMain[0], "utf8")).toContain("core-js/modules/");
      } finally {
        applied.cleanup();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("off mode and empty module results return callable cleanup functions", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfill-empty-"));
    try {
      const entry = join(dir, "entry.ts");
      writeFileSync(entry, `console.log("entry");`);

      const off = applyRuntimePolyfillsToNapiOptions({}, { entryPoints: [entry] });
      expect(off.modules).toEqual([]);
      off.cleanup();

      const empty = applyRuntimePolyfillsToNapiOptions(
        {},
        {
          entryPoints: [entry],
          runtimePolyfills: { mode: "auto", targets: "node18" },
        },
      );
      expect(empty.modules).toEqual([]);
      empty.cleanup();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
