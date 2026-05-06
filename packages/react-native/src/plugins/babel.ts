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
import type { InlineBabelConfig, PluginConfig } from "./types.ts";

interface BabelConfigModule {
  plugins?: unknown[];
}

// Babel API: `name` 또는 `[name, options]` 또는 `[name, options, instanceName]`
// (multi-instance plugin/preset 구분용 3번째 요소). 사용자 babel docs 그대로
// 적은 3-tuple 도 silently drop 안 되도록 spread 보존.
type BabelEntry = string | [string, Record<string, unknown>?, string?];

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
 * Babel plugin 이름 컨벤션을 적용 (`@babel/core` 의 `standardizeName` 와 동등).
 *
 *  - `'lodash'`         → `'babel-plugin-lodash'`
 *  - `'@babel/foo'`     → `'@babel/plugin-foo'`
 *  - `'@scope/foo'`     → `'@scope/babel-plugin-foo'`
 *  - 절대/상대 경로, `module:` prefix, 이미 prefix 를 가진 이름은 그대로.
 *
 * babel CLI 는 이 prefix 를 자동 적용하지만 ZTS 는 plugin 을 사전 절대경로로 resolve
 * 해 babel 에 넘기므로 직접 적용해야 한다. 안 그러면 `'lodash'` 가 lodash 라이브러리
 * 자체로 풀려 babel 이 `.__wrapped__ is not a valid Plugin property` 로 reject.
 */
export function applyBabelPluginPrefix(name: string): string {
  if (name.startsWith("./") || name.startsWith("/") || name.startsWith("module:")) return name;
  if (name.startsWith("@babel/")) {
    const rest = name.slice("@babel/".length);
    if (rest.startsWith("plugin-") || rest.startsWith("preset-")) return name;
    return `@babel/plugin-${rest}`;
  }
  if (name.startsWith("@")) {
    const slashIdx = name.indexOf("/");
    if (slashIdx > 0) {
      const scope = name.slice(0, slashIdx);
      const rest = name.slice(slashIdx + 1);
      if (rest.startsWith("babel-plugin-") || rest.startsWith("babel-preset-")) return name;
      return `${scope}/babel-plugin-${rest}`;
    }
    return name;
  }
  if (name.startsWith("babel-plugin-") || name.startsWith("babel-preset-")) return name;
  return `babel-plugin-${name}`;
}

function entryName(p: unknown): string {
  return typeof p === "string" ? p : Array.isArray(p) ? (p[0] as string) : "";
}

function hasNonNative(plugins: unknown[]): boolean {
  return plugins.some((p) => {
    const name = entryName(p);
    // 빈 string (number/object/null 같은 invalid plugin entry) 은 skip — bungae
    // 의 minor bug fix (#2540): 원본은 빈 string 도 native 외 로 카운트해 false
    // negative.
    return typeof name === "string" && name !== "" && !isZtsNativePlugin(name);
  });
}

/**
 * Babel pass 가 필요한지 판정. (a) babel.config.js 의 plugins 또는 (b) inline
 * config (zts.config.ts `transformer.babel`) 중 하나라도 ZTS native list 외
 * plugin/preset 이 있으면 true. 둘 다 0 → false (Babel pass skip).
 */
export function detectCustomPlugins(projectRoot: string, inline?: InlineBabelConfig): boolean {
  // preset/plugin 모두 동일한 native filter 적용 — `@react-native/babel-preset`
  // 같은 ZTS native 처리 항목을 inline 으로 적은 경우 detect=true 가 되면 transformer
  // pass 가 켜진 후 filter 에서 제거되어 사용자 의도 (native preset 동작) 가 silent
  // drop. 둘 다 hasNonNative 통과 시점부터 진정한 custom 인 것.
  if (inline?.presets && hasNonNative(inline.presets)) return true;
  if (inline?.plugins && hasNonNative(inline.plugins)) return true;
  try {
    const configPath = join(projectRoot, "babel.config.js");
    if (!existsSync(configPath)) return false;
    // project 기준 require — examples/<app>/node_modules 의 babel plugin 을
    // 정확히 resolve 하기 위해 project 의 package.json 을 ref base 로.
    const projectRequire = createRequire(`${projectRoot}/package.json`);
    const config = projectRequire(configPath) as BabelConfigModule;
    const plugins: unknown[] = config?.plugins ?? [];
    return hasNonNative(plugins);
  } catch {
    return false;
  }
}

/**
 * Lazy Babel transformer factory. 첫 transform 호출 시점에 require('@babel/core')
 * + babel.config.js 평가 + inline config (zts.config.ts `transformer.babel`)
 * concat. Babel options 한 번 빌드 후 캐시. plugin require.resolve 는 user 의
 * node_modules 우선 (Bun deep-link symlink 미생성 케이스 대비 fallback 명시).
 */
export function createBabelTransformer(
  projectRoot: string,
  inline?: InlineBabelConfig,
): (code: string, filename: string) => string | null {
  let babel: BabelInstance | null = null;
  let babelOptions: BabelTransformOptions | null = null;

  function ensureBabel(): void {
    if (babel) return;
    // project 기준 require — examples/<app>/node_modules 의 babel plugin 을
    // 정확히 resolve. fallback 으로 zts CLI require (workspace hoist case).
    const projectRequire = createRequire(`${projectRoot}/package.json`);
    function resolvePluginPath(name: string): string {
      // Babel plugin 이름 컨벤션 적용: `'lodash'` → `'babel-plugin-lodash'`,
      // `'@babel/foo'` → `'@babel/plugin-foo'`, `'@scope/foo'` → `'@scope/babel-plugin-foo'`.
      // (절대/상대 경로, `module:` prefix, 이미 prefix 가진 이름은 그대로.)
      // prefix 없이 raw require 하면 `'lodash'` 가 lodash 라이브러리 자체로 풀려
      // babel 이 "__wrapped__ is not a valid Plugin property" 로 reject (#TBD).
      const prefixed = applyBabelPluginPrefix(name);
      if (prefixed !== name) {
        try {
          return projectRequire.resolve(prefixed);
        } catch {
          try {
            return requireFromCli.resolve(prefixed);
          } catch {
            // prefixed 형태로 못 찾으면 raw 로 fallback (사용자가 직접 절대경로/scope plugin
            // 을 적은 케이스).
          }
        }
      }
      try {
        return projectRequire.resolve(name);
      } catch {
        return requireFromCli.resolve(name);
      }
    }
    function resolveEntry(entry: BabelEntry): unknown {
      if (Array.isArray(entry)) {
        try {
          // 2nd/3rd 요소 (options + instanceName) 그대로 보존 — slice spread.
          return [resolvePluginPath(entry[0]), ...entry.slice(1)];
        } catch {
          return entry;
        }
      }
      try {
        return resolvePluginPath(entry);
      } catch {
        return entry;
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
    const fileConfig = existsSync(configPath)
      ? (projectRequire(configPath) as BabelConfigModule)
      : { plugins: [] };
    const filePlugins: unknown[] = fileConfig?.plugins ?? [];
    const inlinePlugins: unknown[] = inline?.plugins ?? [];

    const customPlugins: unknown[] = [];
    for (const plugin of [...filePlugins, ...inlinePlugins]) {
      const name = entryName(plugin);
      if (typeof name === "string" && name !== "" && !isZtsNativePlugin(name)) {
        customPlugins.push(resolveEntry(plugin as BabelEntry));
      }
    }

    // ZTS 가 항상 추가하는 preset (TS strip) + 사용자 inline preset.
    const customPresets: unknown[] = [
      ["@babel/preset-typescript", { isTSX: true, allExtensions: true }],
    ];
    if (inline?.presets) {
      for (const preset of inline.presets) {
        const name = entryName(preset);
        if (typeof name === "string" && name !== "" && !isZtsNativePlugin(name)) {
          customPresets.push(resolveEntry(preset as BabelEntry));
        }
      }
    }

    babelOptions = {
      presets: customPresets,
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
      if (!detectCustomPlugins(config.projectRoot, config.inlineBabel)) return;

      const transformer = createBabelTransformer(config.projectRoot, config.inlineBabel);

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
