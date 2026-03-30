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
  /** 확장자별 로더 (esbuild 호환). 예: { '.png': 'file', '.svg': 'dataurl' } */
  loader?: Record<string, Loader>;
  /** 글로벌 define (예: { 'process.env.NODE_ENV': '"production"' }) */
  define?: Record<string, string>;
  /** import 경로 별칭 (예: { '@': './src' }) */
  alias?: Record<string, string>;
  /** 외부 모듈 (번들 제외) */
  external?: string[];
  /** 소스맵 생성 */
  sourcemap?: boolean;
  /** 코드 압축 */
  minify?: boolean;
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
