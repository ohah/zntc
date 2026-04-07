/**
 * @zts/core — ZTS Plugin API
 *
 * Vite/Rollup 호환 플러그인 인터페이스.
 * ZTS 바이너리가 config 파일을 실행하고 stdin/stdout JSON으로 통신한다.
 *
 * 사용법:
 *   import { defineConfig } from '@zts/core';
 *   import fs from 'node:fs';
 *
 *   export default defineConfig({
 *     plugins: [
 *       {
 *         name: 'css-loader',
 *         load(id) {
 *           if (!id.endsWith('.css')) return null;
 *           const css = fs.readFileSync(id, 'utf8');
 *           return { contents: css, loader: 'text' };
 *         }
 *       }
 *     ]
 *   });
 */

import { createInterface } from "node:readline";

// ===== 타입 정의 =====

export interface ResolveResult {
  path: string;
}

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

export type Format = "esm" | "cjs" | "iife";

export type Platform = "browser" | "node" | "neutral" | "react-native";

export type JsxMode = "classic" | "automatic" | "automatic-dev";

export type LegalComments = "none" | "inline" | "eof";

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

export interface LoadResult {
  contents: string;
  loader?: Loader;
}

export interface OutputFile {
  path: string;
}

export interface Plugin {
  name: string;
  resolveId?(
    source: string,
    importer: string,
  ): Promise<ResolveResult | string | null> | ResolveResult | string | null;
  load?(id: string): Promise<LoadResult | string | null> | LoadResult | string | null;
  transform?(
    code: string,
    id: string,
  ): Promise<LoadResult | string | null> | LoadResult | string | null;
  renderChunk?(
    code: string,
    chunkName: string,
  ): Promise<LoadResult | string | null> | LoadResult | string | null;
  generateBundle?(outputs: OutputFile[]): Promise<void> | void;
}

export interface ServerConfig {
  port?: number;
  host?: string;
  open?: boolean;
  proxy?: Record<string, string>;
}

export interface ZtsConfig {
  plugins?: Plugin[];

  // === 입출력 ===
  /** 엔트리 포인트 목록 */
  entryPoints?: string[];
  /** 출력 디렉토리 (다중 파일 출력 시) */
  outdir?: string;
  /** 출력 파일 (단일 파일 출력 시) */
  outfile?: string;

  // === 번들 옵션 ===
  /** 번들 모드 활성화 */
  bundle?: boolean;
  /** 모듈 포맷 */
  format?: Format;
  /** 타겟 플랫폼 */
  platform?: Platform;
  /** ES/엔진 타겟 (예: "es2015", "chrome80", ["es2020", "node16"]) */
  target?: Target | Target[];
  /** 코드 스플리팅 활성화 */
  splitting?: boolean;
  /** 모듈별 개별 파일 출력 (라이브러리 빌드) */
  preserveModules?: boolean;
  /** preserveModules 출력 기준 디렉토리 */
  preserveModulesRoot?: string;

  // === 변환 ===
  /** 확장자별 로더. 예: { '.png': 'file', '.svg': 'dataurl' } */
  loader?: Record<string, Loader>;
  /** 글로벌 define. 예: { 'process.env.NODE_ENV': '"production"' } */
  define?: Record<string, string>;
  /** import 경로 별칭. 예: { '@': './src' } */
  alias?: Record<string, string>;
  /** 외부 모듈 (번들 제외) */
  external?: string[];
  /** 소스맵 생성 */
  sourcemap?: boolean;
  /** 코드 압축 */
  minify?: boolean;
  /** JSX 런타임 모드 */
  jsx?: JsxMode;
  /** classic 모드 JSX factory (기본: React.createElement) */
  jsxFactory?: string;
  /** classic 모드 Fragment factory (기본: React.Fragment) */
  jsxFragment?: string;
  /** automatic 모드 import source (기본: react) */
  jsxImportSource?: string;

  // === 출력 ===
  /** 출력 파일 앞에 삽입할 텍스트 */
  banner?: { js?: string };
  /** 출력 파일 뒤에 삽입할 텍스트 */
  footer?: { js?: string };
  /** 에셋/청크 URL prefix */
  publicPath?: string;
  /** 모든 엔트리에 자동 import */
  inject?: string[];
  /** IIFE 포맷의 글로벌 변수명 */
  globalName?: string;
  /** 라이센스 주석 처리 */
  legalComments?: LegalComments;
  /** minify 시 함수/클래스 .name 보존 */
  keepNames?: boolean;

  // === dev server ===
  /** dev server 설정 */
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

  constructor(config: ZtsConfig) {
    this.plugins = config.plugins || [];
    this.config = config;
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
    for (const plugin of this.plugins) {
      if (!plugin.resolveId) continue;
      try {
        const result = await plugin.resolveId(msg.specifier!, msg.importer!);
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
    for (const plugin of this.plugins) {
      if (!plugin.load) continue;
      try {
        const result = await plugin.load(msg.path!);
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

    for (const plugin of this.plugins) {
      const hookFn = plugin[hookName];
      if (!hookFn) continue;
      try {
        const result = await hookFn.call(plugin, currentCode, key);
        if (result == null) continue;
        const code = typeof result === "string" ? result : result.contents;
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
    for (const plugin of this.plugins) {
      if (!plugin.generateBundle) continue;
      try {
        await plugin.generateBundle(msg.outputs || []);
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name}] ${err}` };
      }
    }
    return { id: msg.id, result: null, error: null };
  }
}

// ===== Public API =====

export function defineConfig(config: ZtsConfig): ZtsConfig {
  const host = new PluginHost(config);
  startIPC(host);
  return config;
}

export function definePlugin(plugin: Plugin): Plugin {
  const host = new PluginHost({ plugins: [plugin] });
  startIPC(host);
  return plugin;
}

// ===== Build API =====

export interface BuildOptions extends Omit<ZtsConfig, "plugins" | "server"> {
  /** write=false면 디스크에 쓰지 않고 메모리에서 결과 반환 */
  write?: boolean;
}

export interface BuildResult {
  /** 출력 파일 목록 (write=false일 때 contents 포함) */
  outputFiles: BuildOutputFile[];
  /** 에러 메시지 (빌드 실패 시) */
  errors: string[];
}

export interface BuildOutputFile {
  path: string;
  contents: string;
}

/**
 * ZTS CLI를 subprocess로 실행하여 번들을 빌드한다.
 *
 * 사용법:
 *   import { build } from '@zts/core';
 *   const result = await build({
 *     entryPoints: ['src/index.ts'],
 *     outdir: 'dist',
 *     bundle: true,
 *     minify: true,
 *   });
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  const args = buildArgsFromOptions(options);
  const { spawn } = await import("node:child_process");
  const { resolve, dirname } = await import("node:path");
  const { readFile, readdir } = await import("node:fs/promises");

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
  if (options.preserveModulesRoot) args.push(`--preserve-modules-root=${options.preserveModulesRoot}`);
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
  const { readFile, readdir, stat } = await import("node:fs/promises");
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
