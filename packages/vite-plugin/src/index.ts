/**
 * @zntc/vite-plugin — Vite plugin that replaces Vite's esbuild transform with ZNTC.
 *
 * @example
 * ```ts
 * // vite.config.ts
 * import { defineConfig } from "vite";
 * import { zntc } from "@zntc/vite-plugin";
 *
 * export default defineConfig({
 *   plugins: [zntc()],
 * });
 * ```
 */

import type { Plugin } from 'vite';
import { TsconfigCache, init, transpile } from '@zntc/core';
import type { TranspileOptions } from '@zntc/core';

export interface ZntcPluginOptions {
  /**
   * File extension pattern to transform (default: /\.(tsx?|jsx)$/).
   */
  include?: RegExp;
  /**
   * File pattern to exclude (default: /node_modules/).
   */
  exclude?: RegExp;
  /**
   * ZNTC transpile options (target, jsx, etc.).
   */
  transpileOptions?: Omit<TranspileOptions, 'filename'>;
  /**
   * Enable caching of tsconfig autodiscovery results (default: true). For the
   * lifetime of the plugin instance, files in the same workspace are walked only
   * once → saves 5–10 fs syscalls per file (#2367).
   * The cache is automatically bypassed when `transpileOptions.tsconfigPath` /
   * `tsconfigRaw` is set explicitly.
   * Set to false to disable if a very long Vite dev session raises memory concerns.
   */
  tsconfigCache?: boolean;
}

const DEFAULT_INCLUDE = /\.(tsx?|jsx)$/;
const DEFAULT_EXCLUDE = /node_modules/;
/// jsx: 'preserve' 모드에서 ZNTC 가 위임할 파일 패턴 — JSX 가 있을 수 있는 확장자.
const JSX_EXT_PATTERN = /\.[jt]sx$/;

export function zntc(options: ZntcPluginOptions = {}): Plugin {
  const include = options.include ?? DEFAULT_INCLUDE;
  const exclude = options.exclude ?? DEFAULT_EXCLUDE;
  const transpileOpts = options.transpileOptions ?? {};
  const useTsconfigCache = options.tsconfigCache ?? true;

  let initialized = false;
  // plugin 인스턴스 lifetime 동안 1 회 생성 — buildStart 에서 init() 후 set.
  // GC 시 native cache 자동 cleanup, 사용자 명시 dispose 불필요.
  let cache: TsconfigCache | undefined;

  return {
    name: '@zntc/vite-plugin',

    // Vite 5: esbuild transform 비활성화, Vite 6+: 이미 Rolldown 기반이므로 불필요
    config(_, _env) {
      // Vite 5 이하에서만 esbuild 비활성화 (Vite 6+는 Rolldown 사용)
      try {
        const viteVersion = parseInt(require('vite/package.json').version);
        if (viteVersion < 6) return { esbuild: false };
      } catch {}
      return {};
    },

    buildStart() {
      if (!initialized) {
        init();
        initialized = true;
      }
      if (useTsconfigCache && !cache) {
        cache = new TsconfigCache();
      }
    },

    transform(code, id) {
      if (!include.test(id)) return null;
      if (exclude.test(id)) return null;

      // jsx: 'preserve' 면 JSX 가 포함될 수 있는 .tsx/.jsx 는 ZNTC 가 건너뛰고
      // downstream framework plugin (`@vitejs/plugin-react`, `@preact/preset-vite`,
      // `vite-plugin-solid` 등) 이 JSX 와 TS strip 까지 함께 처리하도록 위임한다.
      // ZNTC core 의 preserve 출력 (raw JSX + TS stripped) 을 babel-based plugin
      // 이 후처리할 때 sourcemap 이나 parse 측면에서 깨지는 케이스가 있어 안전쪽으로.
      if (transpileOpts.jsx === 'preserve' && JSX_EXT_PATTERN.test(id)) {
        return null;
      }

      const result = transpile(code, {
        ...transpileOpts,
        filename: id,
        cache,
      });

      return {
        code: result.code,
        map: result.map ? JSON.parse(result.map) : null,
      };
    },
  };
}

export default zntc;
