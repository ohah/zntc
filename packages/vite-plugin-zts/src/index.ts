/**
 * vite-plugin-zts — Vite의 esbuild transform을 ZTS로 교체하는 플러그인
 *
 * @example
 * ```ts
 * // vite.config.ts
 * import { defineConfig } from "vite";
 * import { zts } from "vite-plugin-zts";
 *
 * export default defineConfig({
 *   plugins: [zts()],
 * });
 * ```
 */

import type { Plugin } from "vite";
import { init, transpile } from "../../core/index";
import type { TranspileOptions } from "../../core/index";

export interface ZtsPluginOptions {
  /**
   * 변환할 파일 확장자 패턴 (기본: /\.(tsx?|jsx)$/)
   */
  include?: RegExp;
  /**
   * 제외할 파일 패턴 (기본: /node_modules/)
   */
  exclude?: RegExp;
  /**
   * ZTS transpile 옵션 (target, jsx 등)
   */
  transpileOptions?: Omit<TranspileOptions, "filename">;
}

const DEFAULT_INCLUDE = /\.(tsx?|jsx)$/;
const DEFAULT_EXCLUDE = /node_modules/;

export function zts(options: ZtsPluginOptions = {}): Plugin {
  const include = options.include ?? DEFAULT_INCLUDE;
  const exclude = options.exclude ?? DEFAULT_EXCLUDE;
  const transpileOpts = options.transpileOptions ?? {};

  let initialized = false;

  return {
    name: "vite-plugin-zts",

    // esbuild transform 비활성화 — ZTS가 대신 처리
    config() {
      return {
        esbuild: false,
      };
    },

    buildStart() {
      if (!initialized) {
        init();
        initialized = true;
      }
    },

    transform(code, id) {
      if (!include.test(id)) return null;
      if (exclude.test(id)) return null;

      const result = transpile(code, {
        ...transpileOpts,
        filename: id,
      });

      return {
        code: result.code,
        map: result.map ? JSON.parse(result.map) : null,
      };
    },
  };
}

export default zts;
