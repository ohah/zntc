// Babel 패스: 사용자 babel.config.js 의 custom plugin (Reanimated / NativeWind /
// 사용자 worklet) 만 — ZTS 가 native 처리하는 plugin (TS strip / RN preset /
// JSX / class fields / worklets / flow / arrow / block-scoping 등) 은 zero-cost
// pass. Babel/lazy-load — 첫 transform 호출 시점에 require, custom plugin 0 면
// plugin 자체 등록 skip (createBabelPlugin 의 detectCustomPlugins false 분기).

import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

import type { ZtsPlugin } from "@zts/core";

import {
  type BabelInstance,
  type BabelTransformOptions,
  getErrorMessage,
  requireFromCli,
} from "./internal.ts";
import type { PluginConfig } from "./types.ts";

interface BabelConfigModule {
  plugins?: unknown[];
}

/**
 * ZTS native 처리 plugin patterns — Babel pass-through 시 제외 (이 list 에 매칭
 * 되면 ZTS 가 이미 처리). 사용자 babel.config.js 의 plugin 중 *이 list 외* 만
 * Babel 로 forward.
 */
export const ZTS_NATIVE_PLUGIN_PATTERNS = [
  "optional-chaining",
  "nullish-coalescing",
  "class-properties",
  "private-methods",
  "private-property-in-object",
  "flow-strip-types",
  "transform-flow",
  "transform-typescript",
  "transform-react-jsx",
  "transform-arrow-functions",
  "transform-block-scoping",
  "transform-shorthand-properties",
  "transform-template-literals",
  "transform-modules-commonjs",
  "react-native-worklets",
  "react-native-reanimated/plugin",
  "react-native-reanimated",
  "@react-native/babel-preset",
];

/** Plugin name 이 ZTS 가 native 처리하는 list 에 매칭되는가. substring 매칭. */
export function isZtsNativePlugin(name: string): boolean {
  return ZTS_NATIVE_PLUGIN_PATTERNS.some((pattern) => name.includes(pattern));
}

/**
 * babel.config.js 의 plugins 배열 중 ZTS native list 외 의 plugin 이 하나라도
 * 있으면 true — Babel pass 가 필요하다는 신호. 미존재 / require fail / list
 * 외 plugin 0 → false (Babel pass skip 으로 startup latency 0).
 */
export function detectCustomPlugins(projectRoot: string): boolean {
  try {
    const configPath = join(projectRoot, "babel.config.js");
    if (!existsSync(configPath)) return false;
    // project 기준 require — examples/<app>/node_modules 의 babel plugin 을
    // 정확히 resolve 하기 위해 project 의 package.json 을 ref base 로.
    const projectRequire = createRequire(`${projectRoot}/package.json`);
    const config = projectRequire(configPath) as BabelConfigModule;
    const plugins: unknown[] = config?.plugins ?? [];
    return plugins.some((p) => {
      const name = typeof p === "string" ? p : Array.isArray(p) ? (p[0] as string) : "";
      // 빈 string (number/object/null 같은 invalid plugin entry) 은 skip — bungae
      // 의 minor bug fix (#2540): 원본은 빈 string 도 native 외 로 카운트해 false
      // negative.
      return typeof name === "string" && name !== "" && !isZtsNativePlugin(name);
    });
  } catch {
    return false;
  }
}

/**
 * Lazy Babel transformer factory. 첫 transform 호출 시점에 require('@babel/core')
 * + babel.config.js 평가. Babel options (preset / plugins / parser flag) 는
 * 한 번 빌드 후 캐시. Reanimated 같은 plugin 의 require.resolve 는 user 의
 * node_modules 우선 (Bun deep-link symlink 미생성 케이스 대비 fallback 명시).
 */
export function createBabelTransformer(
  projectRoot: string,
): (code: string, filename: string) => string | null {
  let babel: BabelInstance | null = null;
  let babelOptions: BabelTransformOptions | null = null;

  function ensureBabel(): void {
    if (babel) return;
    // project 기준 require — examples/<app>/node_modules 의 babel plugin 을
    // 정확히 resolve. fallback 으로 zts CLI require (workspace hoist case).
    const projectRequire = createRequire(`${projectRoot}/package.json`);
    function resolvePluginPath(name: string): string {
      try {
        return projectRequire.resolve(name);
      } catch {
        return requireFromCli.resolve(name);
      }
    }
    babel = (() => {
      try {
        return projectRequire("@babel/core") as BabelInstance;
      } catch {
        return requireFromCli("@babel/core") as BabelInstance;
      }
    })();

    const configPath = join(projectRoot, "babel.config.js");
    const config = projectRequire(configPath) as BabelConfigModule;
    const plugins: unknown[] = config?.plugins ?? [];

    const customPlugins: unknown[] = [];
    for (const plugin of plugins) {
      const name =
        typeof plugin === "string" ? plugin : Array.isArray(plugin) ? (plugin[0] as string) : "";
      if (typeof name === "string" && !isZtsNativePlugin(name)) {
        if (Array.isArray(plugin)) {
          try {
            customPlugins.push([
              resolvePluginPath(plugin[0] as string),
              ...(plugin.slice(1) as unknown[]),
            ]);
          } catch {
            customPlugins.push(plugin);
          }
        } else {
          try {
            customPlugins.push(resolvePluginPath(name));
          } catch {
            customPlugins.push(name);
          }
        }
      }
    }

    babelOptions = {
      presets: [["@babel/preset-typescript", { isTSX: true, allExtensions: true }]],
      plugins: customPlugins,
      babelrc: false,
      configFile: false,
      compact: false,
      sourceMaps: false,
    };

    const pluginNames = customPlugins.map((p) =>
      Array.isArray(p) ? (p[0] as string).split("/").pop() : String(p).split("/").pop(),
    );
    process.stderr.write(`[zts:babel] loaded: ${pluginNames.join(", ")}\n`);
  }

  return (code: string, filename: string): string | null => {
    try {
      ensureBabel();
      const result = babel!.transformSync(code, {
        ...(babelOptions ?? {}),
        filename,
      });
      if (result?.code && result.code !== code) {
        process.stderr.write(
          `[zts:babel] ${filename.split("/").pop()}: ${code.length} -> ${result.code.length}\n`,
        );
        return result.code;
      }
      return null;
    } catch (err: unknown) {
      process.stderr.write(`[zts:babel] error: ${getErrorMessage(err)}\n`);
      throw err;
    }
  };
}

/**
 * Babel transform plugin — 사용자 babel.config.js 의 custom plugin (Reanimated
 * / NativeWind / 사용자 worklet) 을 source file 마다 적용. detectCustomPlugins
 * false 면 plugin 자체 등록 skip (NAPI build 의 startup latency 0).
 */
export function createBabelPlugin(config: PluginConfig): ZtsPlugin {
  return {
    name: "zts:react-native:babel-transform",
    setup(build) {
      if (!detectCustomPlugins(config.projectRoot)) return;

      const transformer = createBabelTransformer(config.projectRoot);

      const extPatterns = config.sourceExts.map((e) => e.replace(/^\./, "")).join("|");
      const sourcePattern = new RegExp(`\\.(${extPatterns})$`);

      build.onTransform({ filter: sourcePattern }, (args) => {
        // Skip node_modules — custom plugin 은 사용자 코드만 적용.
        if (args.path.includes("node_modules")) return null;
        try {
          const result = transformer(args.code, args.path);
          return result ? { code: result } : null;
        } catch {
          // Babel 에러는 transformer 가 stderr 에 이미 기록 — build 자체는 진행.
          return null;
        }
      });
    },
  };
}
