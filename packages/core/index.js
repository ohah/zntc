/**
 * @zts/core — ZTS Plugin API
 *
 * Vite/Rollup 호환 플러그인 인터페이스.
 * ZTS 바이너리가 config 파일을 Node.js로 실행하고 stdin/stdout JSON으로 통신한다.
 *
 * 사용법:
 *   // zts.config.js
 *   import { defineConfig } from '@zts/core';
 *
 *   export default defineConfig({
 *     plugins: [
 *       {
 *         name: 'css-loader',
 *         load(id) {
 *           if (!id.endsWith('.css')) return null;
 *           return fs.readFileSync(id, 'utf8');
 *         }
 *       }
 *     ]
 *   });
 *
 * 플러그인 훅 (Rollup 호환):
 *   resolveId(source, importer) → { path } | string | null
 *   load(id)                    → string | { contents } | null
 *   transform(code, id)         → string | { contents } | null
 */

import { createInterface } from "node:readline";

class PluginHost {
  constructor(plugins) {
    this.plugins = plugins || [];
  }

  getFilters() {
    const filters = { resolveId: [], load: [], transform: [] };
    // Rollup 스타일 플러그인에는 명시적 필터가 없으므로 빈 배열 반환
    // (Zig 측에서 빈 필터 = 모든 대상에 적용)
    return filters;
  }

  getHooks() {
    return {
      resolveId: this.plugins.some((p) => p.resolveId),
      load: this.plugins.some((p) => p.load),
      transform: this.plugins.some((p) => p.transform),
    };
  }

  getPluginNames() {
    return this.plugins.map((p) => p.name || "unnamed").join(", ");
  }

  async handleMessage(msg) {
    switch (msg.type) {
      case "init":
        return {
          id: msg.id,
          name: this.getPluginNames(),
          filters: this.getFilters(),
          hooks: this.getHooks(),
          error: null,
        };
      case "resolveId":
        return this.runResolveId(msg);
      case "load":
        return this.runLoad(msg);
      case "transform":
        return this.runTransform(msg);
      case "shutdown":
        process.exit(0);
      default:
        return { id: msg.id, result: null, error: `Unknown message type: ${msg.type}` };
    }
  }

  // resolveId: first 모드 — 첫 번째 non-null 반환
  async runResolveId(msg) {
    for (const plugin of this.plugins) {
      if (!plugin.resolveId) continue;
      try {
        const result = await plugin.resolveId(msg.specifier, msg.importer);
        if (result == null) continue;
        // string 반환 시 → { path: string }
        const resolved = typeof result === "string" ? { path: result } : result;
        return { id: msg.id, result: resolved, error: null };
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name || "plugin"}] ${err}` };
      }
    }
    return { id: msg.id, result: null, error: null };
  }

  // load: first 모드 — 첫 번째 non-null 반환
  async runLoad(msg) {
    for (const plugin of this.plugins) {
      if (!plugin.load) continue;
      try {
        const result = await plugin.load(msg.path);
        if (result == null) continue;
        // string 반환 시 → { contents: string }
        const loaded = typeof result === "string" ? { contents: result } : result;
        return { id: msg.id, result: loaded, error: null };
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name || "plugin"}] ${err}` };
      }
    }
    return { id: msg.id, result: null, error: null };
  }

  // transform: chain 모드 — 모든 플러그인 순차 적용
  async runTransform(msg) {
    let currentCode = msg.code;
    let changed = false;

    for (const plugin of this.plugins) {
      if (!plugin.transform) continue;
      try {
        const result = await plugin.transform(currentCode, msg.moduleId);
        if (result == null) continue;
        const code = typeof result === "string" ? result : result.contents;
        if (code != null) {
          currentCode = code;
          changed = true;
        }
      } catch (err) {
        return { id: msg.id, result: null, error: `[${plugin.name || "plugin"}] ${err}` };
      }
    }

    if (changed) {
      return { id: msg.id, result: { contents: currentCode }, error: null };
    }
    return { id: msg.id, result: null, error: null };
  }
}

/**
 * ZTS config를 정의한다. plugins 배열에 Rollup/Vite 스타일 플러그인 객체를 전달.
 *
 * @param {{ plugins: Plugin[] }} config
 *
 * 사용법:
 *   export default defineConfig({ plugins: [myPlugin()] });
 */
export function defineConfig(config) {
  const host = new PluginHost(config.plugins);
  startIPC(host);
  return config;
}

/**
 * 단일 플러그인을 직접 실행. config 없이 플러그인 하나만 테스트할 때 사용.
 *
 * @param {Plugin} plugin
 *
 * 사용법:
 *   export default definePlugin({ name: 'my', load(id) { ... } });
 */
export function definePlugin(plugin) {
  const host = new PluginHost([plugin]);
  startIPC(host);
  return plugin;
}

function startIPC(host) {
  const rl = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });

  let processing = false;
  const queue = [];

  async function processNext() {
    if (processing || queue.length === 0) return;
    processing = true;
    const line = queue.shift();
    try {
      const msg = JSON.parse(line);
      const response = await host.handleMessage(msg);
      process.stdout.write(`${JSON.stringify(response)}\n`);
    } catch (err) {
      process.stdout.write(`${JSON.stringify({ id: 0, result: null, error: String(err) })}\n`);
    }
    processing = false;
    processNext();
  }

  rl.on("line", (line) => {
    queue.push(line);
    processNext();
  });
}
