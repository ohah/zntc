/**
 * @zntc/rspack-loader — Rspack/Webpack loader that runs source through ZNTC
 * (TS/JSX/Flow → JS) instead of swc-loader / esbuild-loader / babel-loader.
 *
 * @example
 * ```js
 * // rspack.config.mjs
 * export default {
 *   module: {
 *     rules: [
 *       {
 *         test: /\.(?:tsx?|jsx?)$/,
 *         exclude: /node_modules/,
 *         loader: "@zntc/rspack-loader",
 *         options: {
 *           transpileOptions: { target: "es2020", jsx: "automatic" },
 *         },
 *       },
 *     ],
 *   },
 * };
 * ```
 */

import { TsconfigCache, init, transpile } from '@zntc/core';
import type { TranspileOptions } from '@zntc/core';

/**
 * webpack/rspack loader 의 최소 contract — 두 번들러가 공유하는 surface 만
 * 정의해 사용자가 webpack 또는 @rspack/core 한쪽만 설치해도 타입이 깨지지
 * 않도록 함 (esbuild-loader 와 동일 패턴).
 */
interface LoaderContext {
  resourcePath: string;
  async(): (err: Error | null, content?: string, sourceMap?: object | string) => void;
  getOptions(): unknown;
}

export interface ZntcLoaderOptions {
  /**
   * ZNTC transpile 옵션 (target, jsx 등). `filename` 은 loader 가 자동으로
   * `this.resourcePath` 에서 채워주므로 지정하지 않아도 됨.
   */
  transpileOptions?: Omit<TranspileOptions, 'filename'>;
  /**
   * tsconfig autodiscover walk 결과 캐시 (기본: true). Rspack/Webpack 의 watch
   * 세션 동안 같은 워크스페이스 안 파일은 한 번만 walk → file 당 5–10 fs
   * syscall 절약 (#2367). `transpileOptions.tsconfigPath` / `tsconfigRaw`
   * 명시 시 캐시는 자동으로 무시됨.
   */
  tsconfigCache?: boolean;
}

// 모듈 lifetime 동안 1 회 — `init()` 은 idempotent 가 아닐 수 있어 직접 가드.
let initialized = false;
// loader 인스턴스가 worker thread 별로 별도 module 이라 자연스럽게 worker 별
// 캐시. tsconfigCache=false 면 생성 자체를 스킵.
let cache: TsconfigCache | undefined;

function ensureInit(useCache: boolean): void {
  if (!initialized) {
    init();
    initialized = true;
  }
  if (useCache && !cache) {
    cache = new TsconfigCache();
  }
}

export default function zntcLoader(this: LoaderContext, source: string): void {
  const callback = this.async();

  const options = (this.getOptions() ?? {}) as ZntcLoaderOptions;
  const transpileOpts = options.transpileOptions ?? {};
  const useCache = options.tsconfigCache ?? true;

  try {
    ensureInit(useCache);
    const result = transpile(source, {
      ...transpileOpts,
      filename: this.resourcePath,
      cache: useCache ? cache : undefined,
    });
    callback(null, result.code, result.map ? JSON.parse(result.map) : undefined);
  } catch (err) {
    callback(err instanceof Error ? err : new Error(String(err)));
  }
}
