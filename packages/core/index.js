/**
 * @zts/core — ZTS subprocess plugin host
 *
 * ZTS 바이너리가 이 파일을 실행하는 Node.js 프로세스를 spawn하고,
 * stdin/stdout JSON 프로토콜로 통신한다.
 *
 * 사용법:
 *   // zts.config.js
 *   import { definePlugin } from '@zts/core';
 *
 *   definePlugin((build) => {
 *     build.onLoad({ filter: '.css' }, async (args) => {
 *       const css = await fs.promises.readFile(args.path, 'utf8');
 *       return { contents: `export default ${JSON.stringify(css)};` };
 *     });
 *   });
 */

import { createInterface } from "node:readline";

class PluginHost {
  constructor() {
    this.hooks = {
      resolveId: [],
      load: [],
      transform: [],
    };
  }

  createBuildAPI() {
    return {
      onResolve: (options, callback) => {
        this.hooks.resolveId.push({ filter: options.filter, fn: callback });
      },
      onLoad: (options, callback) => {
        this.hooks.load.push({ filter: options.filter, fn: callback });
      },
      onTransform: (options, callback) => {
        this.hooks.transform.push({ filter: options.filter, fn: callback });
      },
    };
  }

  getFilters() {
    const filters = {};
    for (const [hook, entries] of Object.entries(this.hooks)) {
      filters[hook] = entries.map((e) => e.filter).filter(Boolean);
    }
    return filters;
  }

  async handleMessage(msg) {
    switch (msg.type) {
      case "init":
        return { id: msg.id, filters: this.getFilters(), error: null };
      case "resolveId":
        return this.runFirstHook("resolveId", msg);
      case "load":
        return this.runFirstHook("load", msg);
      case "transform":
        return this.runChainHook("transform", msg);
      case "shutdown":
        process.exit(0);
      default:
        return { id: msg.id, result: null, error: `Unknown message type: ${msg.type}` };
    }
  }

  async runFirstHook(hookName, msg) {
    for (const entry of this.hooks[hookName]) {
      const target = msg.specifier || msg.path || msg.moduleId || "";
      if (entry.filter && !target.endsWith(entry.filter)) continue;

      try {
        const args = this.buildArgs(hookName, msg);
        const result = await entry.fn(args);
        if (result != null) {
          return { id: msg.id, result, error: null };
        }
      } catch (err) {
        return { id: msg.id, result: null, error: String(err) };
      }
    }
    return { id: msg.id, result: null, error: null };
  }

  async runChainHook(hookName, msg) {
    let currentCode = msg.code;
    let changed = false;

    for (const entry of this.hooks[hookName]) {
      const target = msg.moduleId || "";
      if (entry.filter && !target.endsWith(entry.filter)) continue;

      try {
        const args = { ...this.buildArgs(hookName, msg), code: currentCode };
        const result = await entry.fn(args);
        if (result != null && result.contents != null) {
          currentCode = result.contents;
          changed = true;
        }
      } catch (err) {
        return { id: msg.id, result: null, error: String(err) };
      }
    }

    if (changed) {
      return { id: msg.id, result: { contents: currentCode }, error: null };
    }
    return { id: msg.id, result: null, error: null };
  }

  buildArgs(hookName, msg) {
    switch (hookName) {
      case "resolveId":
        return { specifier: msg.specifier, importer: msg.importer };
      case "load":
        return { path: msg.path };
      case "transform":
        return { code: msg.code, id: msg.moduleId };
      default:
        return msg;
    }
  }
}

/**
 * 플러그인 엔트리포인트. ZTS가 이 파일을 `node zts.config.js`로 실행한다.
 *
 * @param {(build: BuildAPI) => void} setup — 플러그인 등록 함수
 */
export function definePlugin(setup) {
  const host = new PluginHost();
  const build = host.createBuildAPI();
  setup(build);

  const rl = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });

  rl.on("line", async (line) => {
    try {
      const msg = JSON.parse(line);
      const response = await host.handleMessage(msg);
      process.stdout.write(`${JSON.stringify(response)}\n`);
    } catch (err) {
      process.stdout.write(`${JSON.stringify({ id: 0, result: null, error: String(err) })}\n`);
    }
  });
}
