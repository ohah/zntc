// index.ts
import { createRequire } from "module";
import { existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// ../shared/index.ts
var ES_TARGET_BITS = {
  es5: 4194303,
  es2015: 4192256,
  es2016: 4190208,
  es2017: 4186112,
  es2018: 4177920,
  es2019: 4161536,
  es2020: 4063232,
  es2021: 3932160,
  es2022: 3145728,
  es2023: 2097152,
  es2024: 2097152,
  es2025: 0,
  esnext: 0,
};
function encodeFlags(opts = {}) {
  let flags = 0;
  if (opts.sourcemap) flags |= 1 << 0;
  if (opts.minifyWhitespace || opts.minify) flags |= 1 << 1;
  if (opts.minifyIdentifiers || opts.minify) flags |= 1 << 2;
  if (opts.minifySyntax || opts.minify) flags |= 1 << 3;
  if (opts.jsx === "automatic") flags |= 1 << 4;
  if (opts.jsx === "automatic-dev") flags |= 1 << 5;
  if (opts.dropConsole) flags |= 1 << 6;
  if (opts.dropDebugger) flags |= 1 << 7;
  if (opts.asciiOnly) flags |= 1 << 8;
  if (opts.flow) flags |= 1 << 9;
  if (opts.experimentalDecorators) flags |= 1 << 10;
  if (opts.emitDecoratorMetadata) flags |= 1 << 11;
  if (opts.format === "cjs") flags |= 1 << 12;
  if (opts.quotes === "single") flags |= 1 << 14;
  if (opts.quotes === "preserve") flags |= 2 << 14;
  if (opts.useDefineForClassFields !== false) flags |= 1 << 16;
  if (opts.charsetUtf8) flags |= 1 << 17;
  if (opts.platform === "node") flags |= 1 << 18;
  if (opts.platform === "neutral") flags |= 2 << 18;
  if (opts.platform === "react-native") flags |= 3 << 18;
  if (opts.jsxInJs) flags |= 1 << 20;
  if (opts.sourcemapDebugIds) flags |= 1 << 21;
  if (opts.sourcesContent !== false) flags |= 1 << 22;
  return flags;
}

// index.ts
var native = null;
function findAddon() {
  const __dirname2 = dirname(fileURLToPath(import.meta.url));
  const local = join(__dirname2, "zts.node");
  if (existsSync(local)) return local;
  const parent = join(__dirname2, "../zts.node");
  if (existsSync(parent)) return parent;
  const zigOut = join(__dirname2, "../../zig-out/lib/zts.node");
  if (existsSync(zigOut)) return zigOut;
  const zigOut2 = join(__dirname2, "../../../zig-out/lib/zts.node");
  if (existsSync(zigOut2)) return zigOut2;
  throw new Error("@zts/core: zts.node not found. Run `zig build napi` first.");
}
function init(addonPath) {
  if (native) return;
  const path = addonPath ?? findAddon();
  const require2 = createRequire(import.meta.url);
  native = require2(path);
}
function transpile(source, options = {}) {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!source) throw new Error("@zts/core: empty source");
  const flags = encodeFlags(options);
  const unsupported = options.target ? (ES_TARGET_BITS[options.target] ?? 0) : 0;
  return native.transpile(
    source,
    options.filename ?? "input.ts",
    flags,
    unsupported,
    options.jsxFactory ?? "",
    options.jsxFragment ?? "",
    options.jsxImportSource ?? "",
  );
}
function createPluginDispatcher(plugins) {
  const hooks = {
    resolveId: [],
    load: [],
    transform: [],
  };
  for (const plugin of plugins) {
    const build = {
      onResolve(opts, cb) {
        hooks.resolveId.push({ filter: opts.filter, callback: cb });
      },
      onLoad(opts, cb) {
        hooks.load.push({ filter: opts.filter, callback: cb });
      },
      onTransform(opts, cb) {
        hooks.transform.push({ filter: opts.filter, callback: cb });
      },
    };
    plugin.setup(build);
  }
  const argBuilders = {
    resolveId: (arg1, arg2) => [arg1, { path: arg1, importer: arg2 }],
    load: (arg1, _) => [arg1, { path: arg1 }],
    transform: (arg1, arg2) => [arg2 ?? "", { code: arg1, path: arg2 }],
  };
  return function dispatcher(hookName, arg1, arg2) {
    const hookList = hooks[hookName];
    const buildArgs = argBuilders[hookName];
    if (!hookList || !buildArgs) return null;
    const [filterTarget, cbArgs] = buildArgs(arg1, arg2);
    for (const h of hookList) {
      if (h.filter.test(filterTarget)) {
        try {
          const result = h.callback(cbArgs);
          if (result != null) return result;
        } catch {
          return null;
        }
      }
    }
    return null;
  };
}
async function build(options) {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");
  const napiOptions = { ...options };
  if (options.plugins?.length) {
    napiOptions._pluginDispatcher = createPluginDispatcher(options.plugins);
    delete napiOptions.plugins;
  }
  return native.build(napiOptions);
}
function buildSync(options) {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");
  if (options.plugins?.length) {
    throw new Error(
      "@zts/core: plugins are only supported with build() (async). Use build() instead of buildSync().",
    );
  }
  return native.buildSync(options);
}
function close() {
  native = null;
}
function vitePlugin(rollupPlugin) {
  return {
    name: rollupPlugin.name,
    setup(build2) {
      if (rollupPlugin.resolveId) {
        const hook = rollupPlugin.resolveId;
        build2.onResolve({ filter: /.*/ }, (args) => {
          const result = hook(args.path, args.importer);
          if (result == null) return null;
          if (typeof result === "string") return { path: result };
          if (typeof result === "object" && "id" in result) {
            return { path: result.id, external: result.external };
          }
          return null;
        });
      }
      if (rollupPlugin.load) {
        const hook = rollupPlugin.load;
        build2.onLoad({ filter: /.*/ }, (args) => {
          const result = hook(args.path);
          if (result == null) return null;
          if (typeof result === "string") return { contents: result };
          if (typeof result === "object" && "code" in result) {
            return { contents: result.code };
          }
          return null;
        });
      }
      if (rollupPlugin.transform) {
        const hook = rollupPlugin.transform;
        build2.onTransform({ filter: /.*/ }, (args) => {
          const result = hook(args.code, args.path);
          if (result == null) return null;
          if (typeof result === "string") return { code: result };
          if (typeof result === "object" && "code" in result) {
            return { code: result.code };
          }
          return null;
        });
      }
    },
  };
}
export { vitePlugin, transpile, init, close, buildSync, build };
