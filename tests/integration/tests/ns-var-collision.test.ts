import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

describe("namespace variable collision (scope hoisting)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("hoisted function sees correct CJS namespace after other modules initialize", async () => {
    // Reproduces the exact bug pattern:
    // Module A sets __ns_0 = CJS_X, then Module B sets __ns_0 = CJS_Y.
    // When Module A's hoisted function runs, it should still see CJS_X, not CJS_Y.
    const result = await bundleAndRun({
      "index.ts": `
        import { getDevice } from "./gesture-handler";
        import { getState } from "./safe-area";
        console.log(getDevice() + "," + getState());
      `,
      "react-native.js": `
        module.exports = {
          get DeviceEventEmitter() { return { name: "DeviceEventEmitter" }; },
          get Platform() { return { OS: "ios" }; },
        };
      `,
      "react.js": `
        module.exports = {
          get useState() { return function() { return ["state", function(){}]; }; },
          get createElement() { return function() {}; },
        };
      `,
      // gesture-handler: imports from react-native, has hoisted function
      "gesture-handler.ts": `
        import { DeviceEventEmitter } from "./react-native";
        // This function is hoisted — it captures the namespace var by reference.
        // If another module overwrites the shared __ns_0, DeviceEventEmitter becomes undefined.
        export function getDevice() {
          return DeviceEventEmitter.name;
        }
        // Trigger initialization side effect
        const _init = DeviceEventEmitter;
      `,
      // safe-area: imports from react (different CJS module)
      // In the old code, this would overwrite __ns_0 = react, clobbering react-native
      "safe-area.ts": `
        import { useState } from "./react";
        export function getState() {
          const [s] = useState();
          return s;
        }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    // If namespace vars collide, getDevice() would throw "Cannot read property 'name' of undefined"
    expect(result.runOutput).toBe("DeviceEventEmitter,state");
  });

  test("three CJS modules with interleaved ESM consumers produce correct results", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        import { a } from "./esm-a";
        import { b } from "./esm-b";
        import { c } from "./esm-c";
        console.log([a(), b(), c()].join(","));
      `,
      "cjs-x.js": `module.exports = { val: "X" };`,
      "cjs-y.js": `module.exports = { val: "Y" };`,
      "cjs-z.js": `module.exports = { val: "Z" };`,
      "esm-a.ts": `
        import { val } from "./cjs-x";
        export function a() { return val; }
      `,
      "esm-b.ts": `
        import { val } from "./cjs-y";
        export function b() { return val; }
      `,
      "esm-c.ts": `
        import { val } from "./cjs-z";
        export function c() { return val; }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("X,Y,Z");
  });
});
