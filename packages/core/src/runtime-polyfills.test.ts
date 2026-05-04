import { describe, expect, test } from "bun:test";

import {
  __runtimePolyfillTestHooks,
  applyRuntimePolyfillsToNapiOptions,
  computeCoreJsCompatModules,
  isEsTarget,
  normalizeRuntimePolyfillOptions,
  normalizeRuntimeTargets,
} from "./runtime-polyfills.ts";

function withRuntimeRequire<T>(runtimeRequire: any, fn: () => T): T {
  __runtimePolyfillTestHooks.setRuntimeRequire(runtimeRequire);
  try {
    return fn();
  } finally {
    __runtimePolyfillTestHooks.reset();
  }
}

function makeRuntimeRequire(listForModules: (modules: string[] | RegExp | undefined) => string[]) {
  const compat = (options: { modules?: string[] | RegExp }) => ({
    list: listForModules(options.modules),
  });
  return Object.assign(
    (id: string) => {
      if (id === "core-js-compat") return compat;
      throw new Error(`unexpected require: ${id}`);
    },
    {
      resolve(specifier: string) {
        if (specifier.startsWith("core-js/modules/")) return `/virtual/${specifier}`;
        if (specifier === "core-js/package.json") throw new Error("no package version");
        throw new Error(`unexpected resolve: ${specifier}`);
      },
    },
  );
}

describe("runtime polyfill target normalization", () => {
  test("keeps Rspack/SWC browserslist targets", () => {
    expect(normalizeRuntimeTargets("ios_saf 12")).toBe("ios_saf 12");
    expect(normalizeRuntimeTargets("iOS >= 12")).toBe("iOS >= 12");
    expect(normalizeRuntimeTargets("chrome >= 85")).toBe("chrome >= 85");
    expect(normalizeRuntimeTargets("android >= 5")).toBe("android >= 5");
    expect(normalizeRuntimeTargets("samsung >= 14")).toBe("samsung >= 14");
    expect(normalizeRuntimeTargets("node 18")).toBe("node 18");
    expect(normalizeRuntimeTargets(["chrome >= 85", "safari >= 14"])).toEqual([
      "chrome >= 85",
      "safari >= 14",
    ]);
  });

  test("rejects device names and unsupported shorthand targets", () => {
    expect(() => normalizeRuntimeTargets("iPhone 8")).toThrow("Physical device names");
    expect(() => normalizeRuntimeTargets("Galaxy S10")).toThrow("Physical device names");
    expect(() => normalizeRuntimeTargets("ios12")).toThrow("Compact runtime target shorthands");
    expect(() => normalizeRuntimeTargets("hermes0.7")).toThrow("Compact runtime target shorthands");
    expect(() => normalizeRuntimeTargets("node18")).toThrow("Compact runtime target shorthands");
    expect(() => normalizeRuntimeTargets("hermes 0.7")).toThrow("Rspack/SWC env.targets");
    expect(() => normalizeRuntimeTargets("react-native 0.70")).toThrow("Rspack/SWC env.targets");
  });

  test("keeps browserslist queries when they are not engine-version targets", () => {
    expect(normalizeRuntimeTargets("last 2 chrome versions")).toBe("last 2 chrome versions");
    expect(normalizeRuntimeTargets(["last 2 versions", "not dead"])).toEqual([
      "last 2 versions",
      "not dead",
    ]);
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
    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          target: "node18",
          runtimePolyfills: "entry",
        }) as any
      ).targets,
    ).toEqual({ node: "18" });
    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          target: "chrome >= 85",
          runtimePolyfills: "entry",
        }) as any
      ).targets,
    ).toBe("chrome >= 85");
    expect(
      (
        normalizeRuntimePolyfillOptions({
          entryPoints: [],
          runtimePolyfills: { mode: "entry", targets: ["safari >= 14"], coreJs: "3.49" },
          coreJs: "3.48",
        }) as any
      ).coreJsVersion,
    ).toBe("3.49");

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

describe("runtime polyfill native plan", () => {
  test("auto/usage no longer requires @babel/parser and passes graph candidates", () => {
    const runtimeRequire = makeRuntimeRequire((modules) =>
      Array.isArray(modules) ? modules.filter((name) => name !== "es.set") : [],
    );

    withRuntimeRequire(runtimeRequire, () => {
      const napiOptions: Record<string, unknown> = { runtimePolyfills: "auto" };
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: "auto",
        target: "ios_saf 12",
      });

      expect(applied.modules).toContain("es.string.replace-all");
      expect(applied.modules).not.toContain("es.set");
      expect(napiOptions.runtimePolyfillModeNative).toBe("usage");
      expect(napiOptions.runtimePolyfillCandidateFeatures).toContain("string_replace_all");
      expect(napiOptions.runtimePolyfillCandidateModules).toContain("es.string.replace-all");
      expect((napiOptions.runtimePolyfillCandidatePaths as string[])[0]).toStartWith(
        "/virtual/core-js/modules/",
      );
      expect(napiOptions.runBeforeMain).toBeUndefined();
      applied.cleanup();
    });
  });

  test("auto native candidates include broad core-js feature modules and ignore unmodeled results", () => {
    const runtimeRequire = makeRuntimeRequire(() => [
      "es.map",
      "es.map.constructor",
      "es.map.group-by",
      "es.set",
      "es.set.union.v2",
      "es.promise",
      "es.promise.any",
      "es.object.values",
      "es.array.find-last",
      "es.string.pad-start",
      "es.weak-map",
      "es.math.trunc",
      "web.url",
      "web.structured-clone",
      "es.string.replace-all",
      "es.array.at",
      "es.object.has-own",
    ]);

    withRuntimeRequire(runtimeRequire, () => {
      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: { mode: "auto", targets: ["safari 5"] },
      });

      expect(napiOptions.runtimePolyfillCandidateModules).toEqual([
        "es.array.at",
        "es.array.find-last",
        "es.map",
        "es.map.group-by",
        "es.math.trunc",
        "es.object.has-own",
        "es.object.values",
        "es.set",
        "es.set.union.v2",
        "es.promise",
        "es.promise.any",
        "web.structured-clone",
        "es.string.pad-start",
        "es.string.replace-all",
        "es.weak-map",
        "web.url",
      ]);
      expect(napiOptions.runtimePolyfillCandidateFeatures).toContain("map_group_by");
      expect(napiOptions.runtimePolyfillCandidateFeatures).toContain("set_union");
      expect(napiOptions.runtimePolyfillCandidateFeatures).toContain("promise_any");
      expect(napiOptions.runtimePolyfillCandidateFeatures).toContain("object_values");
      expect(napiOptions.runtimePolyfillCandidateModules).not.toContain("es.map.constructor");
      applied.cleanup();
    });
  });

  test("usage alias and normalized core-js include/exclude use the same native path", () => {
    const runtimeRequire = makeRuntimeRequire(() => []);

    withRuntimeRequire(runtimeRequire, () => {
      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: {
          mode: "usage",
          targets: ["safari 5"],
          include: ["core-js/modules/es.array.at.js", "es.promise"],
          exclude: ["es.array.at"],
        },
      });

      expect(applied.modules).toEqual(["es.promise"]);
      expect(napiOptions.runtimePolyfillModeNative).toBe("usage");
      expect(napiOptions.runtimePolyfillIncludeModules).toEqual(["es.promise"]);
      expect(napiOptions.runtimePolyfillExcludeModules).toEqual(["es.array.at"]);
      expect(napiOptions.runBeforeMain).toBeUndefined();
      applied.cleanup();
    });
  });

  test("off mode does not load core-js-compat or mutate runtime fields", () => {
    const throwingRequire = Object.assign(
      () => {
        throw new Error("core-js-compat should not load");
      },
      {
        resolve() {
          throw new Error("core-js should not resolve");
        },
      },
    );

    withRuntimeRequire(throwingRequire, () => {
      const napiOptions: Record<string, unknown> = {
        runtimePolyfills: "off",
        coreJs: "3.49",
      };
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: "off",
        coreJs: "3.49",
      });

      expect(applied.modules).toEqual([]);
      expect(napiOptions.runtimePolyfills).toBeUndefined();
      expect(napiOptions.coreJs).toBeUndefined();
      expect(napiOptions.runtimePolyfillModeNative).toBeUndefined();
      applied.cleanup();
    });
  });

  test("applies include/exclude without mutating runBeforeMain", () => {
    const runtimeRequire = makeRuntimeRequire((modules) =>
      Array.isArray(modules) ? modules : ["es.promise", "web.structured-clone"],
    );

    withRuntimeRequire(runtimeRequire, () => {
      const init = "/app/src/init.ts";
      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: {
          mode: "auto",
          targets: ["ios_saf 12"],
          include: ["es.array.at"],
          exclude: ["es.string.replace-all"],
        },
        runBeforeMain: [init],
      });

      expect(applied.modules).toContain("es.array.at");
      expect(applied.modules).not.toContain("es.string.replace-all");
      expect(napiOptions.runtimePolyfillModeNative).toBe("usage");
      expect(napiOptions.runtimePolyfillIncludeModules).toEqual(["es.array.at"]);
      expect(napiOptions.runtimePolyfillExcludeModules).toEqual(["es.string.replace-all"]);
      expect(napiOptions.runBeforeMain).toBeUndefined();
      applied.cleanup();
    });
  });

  test("entry mode passes target-wide modules as native entry roots", () => {
    const runtimeRequire = makeRuntimeRequire((modules) =>
      modules instanceof RegExp ? ["es.promise", "web.structured-clone"] : [],
    );

    withRuntimeRequire(runtimeRequire, () => {
      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: { mode: "entry", targets: ["ie 11"], include: ["es.array.at"] },
      });

      expect(applied.modules).toEqual(["es.array.at", "es.promise", "web.structured-clone"]);
      expect(napiOptions.runtimePolyfillModeNative).toBe("entry");
      expect(napiOptions.runtimePolyfillEntryModules).toEqual([
        "es.promise",
        "web.structured-clone",
      ]);
      expect(napiOptions.runtimePolyfillIncludeModules).toEqual(["es.array.at"]);
      applied.cleanup();
    });
  });

  test("entry mode skips native plan when target-wide result is empty", () => {
    const runtimeRequire = makeRuntimeRequire(() => []);

    withRuntimeRequire(runtimeRequire, () => {
      const napiOptions: Record<string, unknown> = {};
      const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: { mode: "entry", targets: ["node 18"] },
      });

      expect(applied.modules).toEqual([]);
      expect(napiOptions.runtimePolyfillModeNative).toBeUndefined();
      applied.cleanup();
    });
  });

  test("resolves core-js with package-relative fallback when no test require is installed", () => {
    __runtimePolyfillTestHooks.reset();
    const napiOptions: Record<string, unknown> = {};
    const applied = applyRuntimePolyfillsToNapiOptions(napiOptions, {
      entryPoints: ["/app/src/entry.ts"],
      runtimePolyfills: { mode: "auto", include: ["es.array.at"] },
    });

    expect(applied.modules).toContain("es.array.at");
    expect((napiOptions.runtimePolyfillIncludePaths as string[])[0]).toContain(
      "core-js/modules/es.array.at.js",
    );
    applied.cleanup();
  });

  test("throws when a requested core-js module cannot be resolved", () => {
    const runtimeRequire = Object.assign(
      (id: string) => {
        if (id === "core-js-compat") return () => ({ list: [] });
        throw new Error(`unexpected require: ${id}`);
      },
      {
        resolve() {
          throw new Error("missing core-js");
        },
      },
    );

    withRuntimeRequire(runtimeRequire, () => {
      expect(() =>
        applyRuntimePolyfillsToNapiOptions(
          {},
          {
            entryPoints: ["/app/src/entry.ts"],
            runtimePolyfills: { mode: "auto", include: ["es.array.at"] },
          },
        ),
      ).toThrow("could not resolve");
    });
  });

  test("off mode and empty target results return callable cleanup functions", () => {
    const off = applyRuntimePolyfillsToNapiOptions({}, { entryPoints: ["/app/src/entry.ts"] });
    expect(off.modules).toEqual([]);
    off.cleanup();

    const runtimeRequire = makeRuntimeRequire(() => []);
    withRuntimeRequire(runtimeRequire, () => {
      const napiOptions: Record<string, unknown> = {};
      const empty = applyRuntimePolyfillsToNapiOptions(napiOptions, {
        entryPoints: ["/app/src/entry.ts"],
        runtimePolyfills: { mode: "auto", targets: ["node 18"] },
      });
      expect(empty.modules).toEqual([]);
      expect(napiOptions.runtimePolyfillModeNative).toBeUndefined();
      empty.cleanup();
    });
  });
});
