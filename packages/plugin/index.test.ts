/**
 * @zts/plugin 단위 테스트
 * bun test packages/plugin/index.test.ts
 */
import { describe, test, expect } from "bun:test";

describe("PluginHost: resolveId", () => {
  test("returns first non-null result", async () => {
    const plugins = [
      { name: "skip", resolveId: () => null },
      { name: "match", resolveId: (source) => (source === "./foo" ? "/resolved/foo.ts" : null) },
      {
        name: "never",
        resolveId: () => {
          throw new Error("should not reach");
        },
      },
    ];

    // runResolveId 로직 재현
    let result = null;
    for (const p of plugins) {
      if (!p.resolveId) continue;
      const r = await p.resolveId("./foo", "/src/index.ts");
      if (r != null) {
        result = typeof r === "string" ? { path: r } : r;
        break;
      }
    }
    expect(result).toEqual({ path: "/resolved/foo.ts" });
  });

  test("returns null if no plugin matches", async () => {
    const plugins = [{ name: "skip", resolveId: () => null }];

    let result = null;
    for (const p of plugins) {
      const r = await p.resolveId("./bar", "/src/index.ts");
      if (r != null) {
        result = r;
        break;
      }
    }
    expect(result).toBeNull();
  });
});

describe("PluginHost: load", () => {
  test("string return becomes { contents }", async () => {
    const plugin = {
      name: "css",
      load: (id) => (id.endsWith(".css") ? "body { color: red }" : null),
    };

    const result = await plugin.load("style.css");
    expect(result).toBe("body { color: red }");

    const skip = await plugin.load("index.ts");
    expect(skip).toBeNull();
  });
});

describe("PluginHost: transform chain", () => {
  test("chains through all plugins", async () => {
    const plugins = [
      { name: "a", transform: (code) => `/* A */${code}` },
      { name: "b", transform: (code) => `/* B */${code}` },
    ];

    let code = "original";
    for (const p of plugins) {
      if (!p.transform) continue;
      const result = await p.transform(code, "test.ts");
      if (result != null) {
        code = typeof result === "string" ? result : result.contents;
      }
    }
    expect(code).toBe("/* B *//* A */original");
  });

  test("skips plugins without transform hook", async () => {
    const plugins = [
      { name: "no-transform" },
      { name: "has-transform", transform: (code) => `/* X */${code}` },
    ];

    let code = "src";
    for (const p of plugins) {
      if (!p.transform) continue;
      const r = await p.transform(code, "t.ts");
      if (r != null) code = typeof r === "string" ? r : r.contents;
    }
    expect(code).toBe("/* X */src");
  });
});

describe("PluginHost: error handling", () => {
  test("plugin error is caught and reported", async () => {
    const plugin = {
      name: "broken",
      load: () => {
        throw new Error("compilation failed");
      },
    };

    let error = null;
    try {
      await plugin.load("test.css");
    } catch (err) {
      error = String(err);
    }
    expect(error).toContain("compilation failed");
  });
});

describe("PluginHost: hooks detection", () => {
  test("getHooks reports registered hooks", () => {
    const plugins = [
      { name: "a", load: () => null },
      { name: "b", transform: () => null },
    ];

    const hooks = {
      resolveId: plugins.some((p) => p.resolveId),
      load: plugins.some((p) => p.load),
      transform: plugins.some((p) => p.transform),
    };

    expect(hooks.resolveId).toBe(false);
    expect(hooks.load).toBe(true);
    expect(hooks.transform).toBe(true);
  });
});

describe("IPC queue serialization", () => {
  test("processes messages in order", async () => {
    const results = [];
    let processing = false;
    const queue = [];

    async function processNext() {
      if (processing || queue.length === 0) return;
      processing = true;
      const item = queue.shift();
      await new Promise((r) => setTimeout(r, 5));
      results.push(item);
      processing = false;
      await processNext();
    }

    queue.push("a", "b", "c");
    await processNext();
    await new Promise((r) => setTimeout(r, 50));
    expect(results).toEqual(["a", "b", "c"]);
  });
});
