/**
 * @zntc/vite-plugin — Vite의 esbuild transform을 ZNTC로 교체하는 플러그인
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
   * 변환할 파일 확장자 패턴 (기본: /\.(tsx?|jsx)$/)
   */
  include?: RegExp;
  /**
   * 제외할 파일 패턴 (기본: /node_modules/)
   */
  exclude?: RegExp;
  /**
   * ZNTC transpile 옵션 (target, jsx 등)
   */
  transpileOptions?: Omit<TranspileOptions, 'filename'>;
  /**
   * tsconfig autodiscover 결과 캐시 활성화 (기본: true). plugin 인스턴스 lifetime 동안
   * 같은 워크스페이스 안 파일은 한 번만 walk → file 당 5–10 fs syscall 절약 (#2367).
   * `transpileOptions.tsconfigPath` / `tsconfigRaw` 명시 시 캐시는 자동으로 무시됨.
   * Vite dev 세션이 너무 길어 메모리가 우려되면 false 로 비활성화 가능.
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
