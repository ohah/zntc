/**
 * @zts/core — ZTS Plugin & Build API
 *
 * Vite/Rollup-compatible plugin interface for ZTS.
 * The ZTS binary spawns the config file and communicates via stdin/stdout JSON IPC.
 *
 * @example
 * ```ts
 * import { defineConfig } from '@zts/core';
 * import fs from 'node:fs';
 *
 * export default defineConfig({
 *   plugins: [
 *     {
 *       name: 'css-loader',
 *       load(id) {
 *         if (!id.endsWith('.css')) return null;
 *         const css = fs.readFileSync(id, 'utf8');
 *         return { contents: css, loader: 'text' };
 *       }
 *     }
 *   ]
 * });
 * ```
 *
 * @packageDocumentation
 */

import { createInterface } from "node:readline";

// ===== Type Definitions =====

/** Result of a plugin's `resolveId` hook. */
export interface ResolveResult {
  /** Resolved absolute file path. */
  path: string;
}

/**
 * File loader type. Determines how a file extension is processed during bundling.
 *
 * - `"js"` / `"ts"` — Parse as JavaScript/TypeScript
 * - `"json"` — Parse as JSON module
 * - `"text"` — Import as a string
 * - `"file"` — Copy to output and export the URL
 * - `"dataurl"` — Inline as a `data:` URL
 * - `"binary"` — Import as a `Uint8Array`
 * - `"copy"` — Copy to output preserving directory structure
 * - `"empty"` — Replace with an empty module
 */
export type Loader =
  | "js"
  | "ts"
  | "json"
  | "text"
  | "css"
  | "file"
  | "dataurl"
  | "binary"
  | "copy"
  | "empty";

/** Output module format. */
export type Format = "esm" | "cjs" | "iife";

/** Target platform. Affects module resolution, built-in polyfills, and default format. */
export type Platform = "browser" | "node" | "neutral" | "react-native";

/** JSX transform mode. */
export type JsxMode = "classic" | "automatic" | "automatic-dev";

/** How to handle legal comments (license headers) in the output. */
export type LegalComments = "none" | "inline" | "eof";

/**
 * Transpilation target. Can be an ES version, a browser/engine with version number,
 * or an array of targets for multi-target builds.
 *
 * @example
 * ```ts
 * target: "es2020"
 * target: ["chrome90", "firefox88"]
 * target: "hermes0.12"
 * ```
 */
export type Target =
  | "es5"
  | "es2015"
  | "es2016"
  | "es2017"
  | "es2018"
  | "es2019"
  | "es2020"
  | "es2021"
  | "es2022"
  | "esnext"
  | `chrome${number}`
  | `firefox${number}`
  | `safari${number}`
  | `edge${number}`
  | `node${number}`
  | `deno${number}`
  | `ios${number}`
  | `hermes${number}`
  | (string & {});

/** Result returned by a plugin's `load` or `transform` hook. */
export interface LoadResult {
  /** The transformed source code. */
  contents: string;
  /** Optional loader override for this file. */
  loader?: Loader;
}

/** Represents an output file from the bundle. */
export interface OutputFile {
  /** Absolute path of the output file. */
  path: string;
}

// ===== Plugin Context API =====

/** Options for {@link PluginContext.emitFile}. */
export interface EmitFileOptions {
  /** Output file name (relative to outdir). */
  fileName: string;
  /** File contents as a string. */
  source: string;
}

/** Module metadata returned by {@link PluginContext.getModuleInfo}. */
export interface ModuleInfo {
  /** Resolved module ID (absolute path). */
  id: string;
  /** Whether this module is an entry point. */
  isEntry: boolean;
  /** List of imported module specifiers. */
  importedIds: string[];
}

/** Context object passed to plugin hooks for accessing build utilities. */
export interface PluginContext {
  /**
   * Emit an additional file to the output directory.
   * Can be called during `generateBundle` or `renderChunk` hooks.
   */
  emitFile(options: EmitFileOptions): string;

  /**
   * Resolve a module specifier using the plugin chain.
   * Calls other plugins' `resolveId` hooks (skipping the calling plugin to avoid infinite recursion).
   */
  resolve(specifier: string, importer?: string): Promise<ResolveResult | null>;

  /**
   * Get metadata about a module by its resolved ID.
   * Returns null if the module is not in the graph.
   */
  getModuleInfo(id: string): ModuleInfo | null;
}

/**
 * Plugin interface — compatible with Vite/Rollup plugin conventions.
 *
 * Hooks are called via JSON IPC between the ZTS binary and the Node.js/Bun subprocess.
 * Each hook receives a {@link PluginContext} as `this`, providing access to build utilities.
 *
 * @example
 * ```ts
 * const myPlugin: Plugin = {
 *   name: 'virtual-module',
 *   resolveId(source) {
 *     if (source === 'virtual:config') return { path: '\0virtual:config' };
 *     return null;
 *   },
 *   load(id) {
 *     if (id === '\0virtual:config') return 'export default { debug: true }';
 *     return null;
 *   }
 * };
 * ```
 */
export interface Plugin {
  /** Plugin name, shown in debug logs and error messages. */
  name: string;
  /**
   * Resolve a module specifier to an absolute path.
   * Return `null` to defer to the next plugin or default resolution.
   */
  resolveId?(
    this: PluginContext,
    source: string,
    importer: string,
  ): Promise<ResolveResult | string | null> | ResolveResult | string | null;
  /**
   * Load the contents of a module by its resolved path.
   * Return `null` to defer to the next plugin or default loading.
   */
  load?(
    this: PluginContext,
    id: string,
  ): Promise<LoadResult | string | null> | LoadResult | string | null;
  /**
   * Transform the source code of a module after loading.
   * Plugins are chained: each plugin receives the previous plugin's output.
   */
  transform?(
    this: PluginContext,
    code: string,
    id: string,
  ): Promise<LoadResult | string | null> | LoadResult | string | null;
  /**
   * Post-process a generated chunk's code before writing to disk.
   * Plugins are chained like `transform`.
   */
  renderChunk?(
    this: PluginContext,
    code: string,
    chunkName: string,
  ): Promise<LoadResult | string | null> | LoadResult | string | null;
  /** Called after all chunks have been generated. Use for side effects like writing extra files. */
  generateBundle?(this: PluginContext, outputs: OutputFile[]): Promise<void> | void;
}

/** Dev server configuration. */
export interface ServerConfig {
  /** Server port (default: 12300). */
  port?: number;
  /** Bind address (default: "localhost", use "0.0.0.0" for all interfaces). */
  host?: string;
  /** Automatically open the browser on start. */
  open?: boolean;
  /** API proxy mapping. Example: `{ "/api": "http://localhost:3000" }` */
  proxy?: Record<string, string>;
}

/**
 * ZTS configuration object. Passed to {@link defineConfig} to configure
 * plugins, bundling options, and the dev server.
 *
 * @example
 * ```ts
 * import { defineConfig } from '@zts/core';
 *
 * export default defineConfig({
 *   entryPoints: ['src/index.ts'],
 *   outdir: 'dist',
 *   bundle: true,
 *   format: 'esm',
 *   platform: 'browser',
 *   minify: true,
 *   plugins: [myPlugin],
 * });
 * ```
 */
export interface ZtsConfig {
  /** List of plugins to apply. */
  plugins?: Plugin[];

  // === Input / Output ===
  /** Entry point file paths. */
  entryPoints?: string[];
  /** Output directory (for multi-file output). */
  outdir?: string;
  /** Output file path (for single-file output). */
  outfile?: string;

  // === Bundle Options ===
  /** Enable bundle mode. */
  bundle?: boolean;
  /** Output module format. */
  format?: Format;
  /** Target platform. */
  platform?: Platform;
  /** ES/engine target. Example: `"es2020"`, `"chrome90"`, `["es2020", "node16"]` */
  target?: Target | Target[];
  /** Enable code splitting. */
  splitting?: boolean;
  /** Output each module as a separate file (library builds). */
  preserveModules?: boolean;
  /** Root directory for `preserveModules` output structure. */
  preserveModulesRoot?: string;

  // === Transform ===
  /** Loader overrides by file extension. Example: `{ '.png': 'file' }` */
  loader?: Record<string, Loader>;
  /** Global define replacements. Example: `{ 'process.env.NODE_ENV': '"production"' }` */
  define?: Record<string, string>;
  /** Import path aliases. Example: `{ '@': './src' }` */
  alias?: Record<string, string>;
  /** Packages to exclude from the bundle. */
  external?: string[];
  /** Generate source maps. */
  sourcemap?: boolean;
  /** Minify the output. */
  minify?: boolean;
  /** JSX transform mode. */
  jsx?: JsxMode;
  /** JSX factory function for classic mode (default: `"React.createElement"`). */
  jsxFactory?: string;
  /** JSX fragment factory for classic mode (default: `"React.Fragment"`). */
  jsxFragment?: string;
  /** Import source for automatic JSX mode (default: `"react"`). */
  jsxImportSource?: string;

  // === Output ===
  /** Text to prepend to each output file. */
  banner?: { js?: string };
  /** Text to append to each output file. */
  footer?: { js?: string };
  /** URL prefix for assets and chunks (CDN deployments). */
  publicPath?: string;
  /** Files to auto-import in every entry point. */
  inject?: string[];
  /** Global variable name for IIFE format. */
  globalName?: string;
  /** How to handle legal/license comments. */
  legalComments?: LegalComments;
  /** Preserve `.name` property on functions/classes when minifying. */
  keepNames?: boolean;

  // === Dev Server ===
  /** Dev server configuration. */
  server?: ServerConfig;
}

// ===== IPC 메시지 타입 =====

interface IpcMessage {
  id: number;
  type: string;
  specifier?: string;
  importer?: string;
  path?: string;
  code?: string;
  moduleId?: string;
  chunkName?: string;
  outputs?: OutputFile[];
}

interface IpcResponse {
  id: number;
  result?: unknown;
  error: string | null;
  name?: string;
  filters?: Record<string, string[]>;
  hooks?: Record<string, boolean>;
  config?: Partial<ZtsConfig>;
}

// ===== PluginHost =====

class PluginHost {
  private plugins: Plugin[];
  private config: ZtsConfig;
  /** Files emitted by plugins via emitFile(). Written after generateBundle. */
  emittedFiles: EmitFileOptions[] = [];
  /** Module info cache populated during build. */
  moduleInfoMap: Map<string, ModuleInfo> = new Map();

  constructor(config: ZtsConfig) {
    this.plugins = config.plugins || [];
    this.config = config;
  }

  /**
   * Create a PluginContext for a specific plugin.
   * The context skips the current plugin in resolve() to prevent infinite recursion.
   */
  private createContext(currentPluginIndex: number): PluginContext {
    return {
      emitFile: (options: EmitFileOptions): string => {
        this.emittedFiles.push(options);
        return options.fileName;
      },

      resolve: async (specifier: string, importer?: string): Promise<ResolveResult | null> => {
        // Call other plugins' resolveId hooks (skip current plugin to avoid infinite recursion)
        for (let i = 0; i < this.plugins.length; i++) {
          if (i === currentPluginIndex) continue;
          const plugin = this.plugins[i];
          if (!plugin.resolveId) continue;
          try {
            const ctx = this.createContext(i);
            const result = await plugin.resolveId.call(ctx, specifier, importer || "");
            if (result == null) continue;
            return typeof result === "string" ? { path: result } : result;
          } catch {
            continue;
          }
        }
        return null;
      },

      getModuleInfo: (id: string): ModuleInfo | null => {
        return this.moduleInfoMap.get(id) || null;
      },
    };
  }

  getFilters(): Record<string, string[]> {
    return { resolveId: [], load: [], transform: [] };
  }

  getHooks(): Record<string, boolean> {
    return {
      resolveId: this.plugins.some((p) => !!p.resolveId),
      load: this.plugins.some((p) => !!p.load),
      transform: this.plugins.some((p) => !!p.transform),
      renderChunk: this.plugins.some((p) => !!p.renderChunk),
      generateBundle: this.plugins.some((p) => !!p.generateBundle),
    };
  }

  getPluginNames(): string {
    return this.plugins.map((p) => p.name || "unnamed").join(", ");
  }

  async handleMessage(msg: IpcMessage): Promise<IpcResponse> {
    switch (msg.type) {
      case "init": {
        const { plugins: _, ...configWithoutPlugins } = this.config;
        return {
          id: msg.id,
          name: this.getPluginNames(),
          filters: this.getFilters(),
          hooks: this.getHooks(),
          config: configWithoutPlugins,
          error: null,
        };
      }
      case "resolveId":
        return this.runResolveId(msg);
      case "load":
        return this.runLoad(msg);
      case "transform":
        return this.runTransform(msg);
      case "renderChunk":
        return this.runRenderChunk(msg);
      case "generateBundle":
        return this.runGenerateBundle(msg);
      case "shutdown":
        process.exit(0);
      default:
        return { id: msg.id, result: null, error: `Unknown message type: ${msg.type}` };
    }
  }

  private async runResolveId(msg: IpcMessage): Promise<IpcResponse> {
    for (let i = 0; i < this.plugins.length; i++) {
      const plugin = this.plugins[i];
      if (!plugin.resolveId) continue;
      try {
        const ctx = this.createContext(i);
        const result = await plugin.resolveId.call(ctx, msg.specifier!, msg.importer!);
        if (result == null) continue;
        const resolved = typeof result === "string" ? { path: result } : result;
        return { id: msg.id, result: resolved, error: null };
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name}] ${err}` };
      }
    }
    return { id: msg.id, result: null, error: null };
  }

  private async runLoad(msg: IpcMessage): Promise<IpcResponse> {
    for (let i = 0; i < this.plugins.length; i++) {
      const plugin = this.plugins[i];
      if (!plugin.load) continue;
      try {
        const ctx = this.createContext(i);
        const result = await plugin.load.call(ctx, msg.path!);
        if (result == null) continue;
        const loaded = typeof result === "string" ? { contents: result } : result;
        return { id: msg.id, result: loaded, error: null };
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name}] ${err}` };
      }
    }
    return { id: msg.id, result: null, error: null };
  }

  private async runTransform(msg: IpcMessage): Promise<IpcResponse> {
    return this.runChainHook("transform", msg.code!, msg.moduleId!, msg);
  }

  private async runRenderChunk(msg: IpcMessage): Promise<IpcResponse> {
    return this.runChainHook("renderChunk", msg.code!, msg.chunkName!, msg);
  }

  private async runChainHook(
    hookName: "transform" | "renderChunk",
    initialCode: string,
    key: string,
    msg: IpcMessage,
  ): Promise<IpcResponse> {
    let currentCode = initialCode;
    let changed = false;

    for (let i = 0; i < this.plugins.length; i++) {
      const plugin = this.plugins[i];
      const hookFn = plugin[hookName];
      if (!hookFn) continue;
      try {
        const ctx = this.createContext(i);
        const result = await hookFn.call(ctx, currentCode, key);
        if (result == null) continue;
        const code = typeof result === "string" ? result : (result.contents ?? result.code);
        if (code != null) {
          currentCode = code;
          changed = true;
        }
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name}] ${err}` };
      }
    }

    return changed
      ? { id: msg.id, result: { contents: currentCode }, error: null }
      : { id: msg.id, result: null, error: null };
  }

  private async runGenerateBundle(msg: IpcMessage): Promise<IpcResponse> {
    // Populate module info cache from outputs
    if (msg.outputs) {
      for (const output of msg.outputs) {
        this.moduleInfoMap.set(output.path, {
          id: output.path,
          isEntry: false,
          importedIds: [],
        });
      }
    }

    // Reset emitted files for this generateBundle run
    this.emittedFiles = [];

    for (let i = 0; i < this.plugins.length; i++) {
      const plugin = this.plugins[i];
      if (!plugin.generateBundle) continue;
      try {
        const ctx = this.createContext(i);
        await plugin.generateBundle.call(ctx, msg.outputs || []);
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name}] ${err}` };
      }
    }

    // Include emitted files in the response so Zig can write them
    const result = this.emittedFiles.length > 0 ? { emittedFiles: this.emittedFiles } : null;
    return { id: msg.id, result, error: null };
  }
}

// ===== Public API =====

/**
 * Define a ZTS configuration with plugins.
 * Initializes the plugin host and starts JSON IPC communication with the ZTS binary.
 *
 * @example
 * ```ts
 * // zts.config.ts
 * import { defineConfig } from '@zts/core';
 *
 * export default defineConfig({
 *   plugins: [myPlugin],
 *   bundle: true,
 *   outdir: 'dist',
 * });
 * ```
 */
export function defineConfig(config: ZtsConfig): ZtsConfig {
  const host = new PluginHost(config);
  startIPC(host);
  return config;
}

/**
 * Define a single ZTS plugin.
 * Convenience wrapper that creates a plugin host with a single plugin.
 *
 * @example
 * ```ts
 * // my-plugin.ts
 * import { definePlugin } from '@zts/core';
 *
 * export default definePlugin({
 *   name: 'my-plugin',
 *   transform(code, id) {
 *     if (!id.endsWith('.graphql')) return null;
 *     return `export default \`${code}\``;
 *   }
 * });
 * ```
 */
export function definePlugin(plugin: Plugin): Plugin {
  const host = new PluginHost({ plugins: [plugin] });
  startIPC(host);
  return plugin;
}

// ===== Build API =====

/**
 * Options for the programmatic {@link build} API.
 * Extends {@link ZtsConfig} without `plugins` and `server`.
 */
export interface BuildOptions extends Omit<ZtsConfig, "plugins" | "server"> {
  /** If `false`, return output in memory instead of writing to disk. */
  write?: boolean;
}

/** Result of a programmatic {@link build} call. */
export interface BuildResult {
  /** Generated output files. When `write: false`, `contents` contains the file data. */
  outputFiles: BuildOutputFile[];
  /** Error messages if the build failed. Empty array on success. */
  errors: string[];
}

/** A single output file from a {@link build} call. */
export interface BuildOutputFile {
  /** Absolute path of the output file. */
  path: string;
  /** File contents as a UTF-8 string. */
  contents: string;
}

/**
 * Programmatically run the ZTS bundler.
 * Spawns the ZTS CLI binary as a subprocess and returns the build result.
 *
 * @example
 * ```ts
 * import { build } from '@zts/core';
 *
 * const result = await build({
 *   entryPoints: ['src/index.ts'],
 *   outdir: 'dist',
 *   bundle: true,
 *   minify: true,
 * });
 *
 * if (result.errors.length > 0) {
 *   console.error('Build failed:', result.errors);
 * }
 * ```
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  const args = buildArgsFromOptions(options);
  const { spawn } = await import("node:child_process");

  // ZTS 바이너리 경로: @zts/core 패키지 기준으로 탐색
  const ztsBin = await findZtsBin();

  return new Promise<BuildResult>((res, reject) => {
    const proc = spawn(ztsBin, args, { stdio: ["pipe", "pipe", "pipe"] });

    let stdout = "";
    let stderr = "";

    proc.stdout?.on("data", (data: Buffer) => {
      stdout += data.toString();
    });
    proc.stderr?.on("data", (data: Buffer) => {
      stderr += data.toString();
    });

    proc.on("error", (err: Error) => {
      reject(new Error(`Failed to spawn ZTS: ${err.message}`));
    });

    proc.on("close", async (code: number | null) => {
      if (code !== 0) {
        res({ outputFiles: [], errors: [stderr.trim() || `ZTS exited with code ${code}`] });
        return;
      }

      // write=false (stdout 출력)이면 stdout이 번들 결과
      if (options.write === false && !options.outdir) {
        res({
          outputFiles: [{ path: options.outfile || "bundle.js", contents: stdout }],
          errors: [],
        });
        return;
      }

      // outdir가 있으면 출력 파일을 읽어서 반환
      if (options.outdir) {
        const { existsSync } = await import("node:fs");
        if (!existsSync(options.outdir)) {
          res({ outputFiles: [], errors: [stderr.trim() || "Output directory was not created"] });
          return;
        }
        try {
          const files = await collectOutputFiles(options.outdir);
          res({ outputFiles: files, errors: [] });
        } catch (err) {
          res({ outputFiles: [], errors: [`Failed to read output: ${err}`] });
        }
        return;
      }

      // outfile이 있으면 해당 파일 읽기
      if (options.outfile) {
        try {
          const { readFile } = await import("node:fs/promises");
          const contents = await readFile(options.outfile, "utf-8");
          res({ outputFiles: [{ path: options.outfile, contents }], errors: [] });
        } catch (err) {
          res({ outputFiles: [], errors: [`Failed to read output: ${err}`] });
        }
        return;
      }

      // 출력 경로 미지정 → stdout이 결과
      res({
        outputFiles: [{ path: "bundle.js", contents: stdout }],
        errors: [],
      });
    });
  });
}

async function findZtsBin(): Promise<string> {
  const { resolve } = await import("node:path");
  const { existsSync } = await import("node:fs");

  // 1. 환경변수
  if (process.env.ZTS_BIN && existsSync(process.env.ZTS_BIN)) {
    return process.env.ZTS_BIN;
  }

  // 2. 프로젝트 루트의 zig-out/bin/zts
  let dir = process.cwd();
  for (let i = 0; i < 5; i++) {
    const candidate = resolve(dir, "zig-out/bin/zts");
    if (existsSync(candidate)) return candidate;
    const candidate2 = resolve(dir, "node_modules/.bin/zts");
    if (existsSync(candidate2)) return candidate2;
    dir = resolve(dir, "..");
  }

  // 3. PATH에서 찾기
  return "zts";
}

function buildArgsFromOptions(options: BuildOptions): string[] {
  const args: string[] = [];

  if (options.bundle !== false) args.push("--bundle");

  // 엔트리 포인트
  if (options.entryPoints && options.entryPoints.length > 0) {
    args.push(options.entryPoints[0]);
    // 다중 엔트리는 현재 CLI에서 미지원 — 첫 번째만 사용
  }

  // 출력
  if (options.outdir) {
    args.push("--outdir", options.outdir);
  } else if (options.outfile) {
    args.push("-o", options.outfile);
  }

  // 포맷/플랫폼
  if (options.format) args.push(`--format=${options.format}`);
  if (options.platform) args.push(`--platform=${options.platform}`);

  // 타겟
  if (options.target) {
    const targets = Array.isArray(options.target) ? options.target : [options.target];
    args.push(`--target=${targets.join(",")}`);
  }

  // 번들 옵션
  if (options.splitting) args.push("--splitting");
  if (options.preserveModules) args.push("--preserve-modules");
  if (options.preserveModulesRoot)
    args.push(`--preserve-modules-root=${options.preserveModulesRoot}`);
  if (options.sourcemap) args.push("--sourcemap");
  if (options.minify) args.push("--minify");
  if (options.keepNames) args.push("--keep-names");
  if (options.globalName) args.push(`--global-name=${options.globalName}`);
  if (options.publicPath) args.push(`--public-path=${options.publicPath}`);
  if (options.legalComments) args.push(`--legal-comments=${options.legalComments}`);

  // JSX
  if (options.jsx) args.push(`--jsx=${options.jsx}`);
  if (options.jsxFactory) args.push(`--jsx-factory=${options.jsxFactory}`);
  if (options.jsxFragment) args.push(`--jsx-fragment=${options.jsxFragment}`);
  if (options.jsxImportSource) args.push(`--jsx-import-source=${options.jsxImportSource}`);

  // banner/footer
  if (options.banner?.js) args.push(`--banner:js=${options.banner.js}`);
  if (options.footer?.js) args.push(`--footer:js=${options.footer.js}`);

  // define
  if (options.define) {
    for (const [key, value] of Object.entries(options.define)) {
      args.push(`--define:${key}=${value}`);
    }
  }

  // alias
  if (options.alias) {
    for (const [from, to] of Object.entries(options.alias)) {
      args.push(`--alias:${from}=${to}`);
    }
  }

  // external
  if (options.external) {
    for (const ext of options.external) {
      args.push("--external", ext);
    }
  }

  // loader
  if (options.loader) {
    for (const [ext, loader] of Object.entries(options.loader)) {
      args.push(`--loader:${ext}=${loader}`);
    }
  }

  // inject
  if (options.inject) {
    for (const path of options.inject) {
      args.push(`--inject:${path}`);
    }
  }

  return args;
}

async function collectOutputFiles(dir: string): Promise<BuildOutputFile[]> {
  const { readFile, readdir } = await import("node:fs/promises");
  const { resolve } = await import("node:path");
  const files: BuildOutputFile[] = [];

  async function walk(d: string): Promise<void> {
    const entries = await readdir(d, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = resolve(d, entry.name);
      if (entry.isDirectory()) {
        await walk(fullPath);
      } else {
        const contents = await readFile(fullPath, "utf-8");
        files.push({ path: fullPath, contents });
      }
    }
  }

  await walk(dir);
  return files;
}

function startIPC(host: PluginHost): void {
  const rl = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });

  let processing = false;
  const queue: string[] = [];

  async function processNext(): Promise<void> {
    if (processing || queue.length === 0) return;
    processing = true;
    const line = queue.shift()!;
    try {
      const msg: IpcMessage = JSON.parse(line);
      const response = await host.handleMessage(msg);
      process.stdout.write(`${JSON.stringify(response)}\n`);
    } catch (err) {
      process.stdout.write(`${JSON.stringify({ id: 0, result: null, error: String(err) })}\n`);
    }
    processing = false;
    processNext();
  }

  rl.on("line", (line: string) => {
    queue.push(line);
    processNext();
  });
}
