// Plugin factory 들의 internal shared util — RN 외부 사용자에게 노출 X (src/index.ts 미수출).
// 4 plugin 파일 (babel/codegen/asset/metro-resolve-request) 의 require + Babel
// type + error message 추출의 단일 출처.

import { createRequire } from 'node:module';

/** ZTS CLI 의 createRequire — fallback / require 의 모든 plugin 공용. */
export const requireFromCli = createRequire(import.meta.url);

/** Babel @babel/core 의 transformSync 표면. babel.ts / codegen.ts 가 lazy load 후 사용. */
export interface BabelInstance {
  transformSync(code: string, options: BabelTransformOptions): { code?: string } | null;
  transformFromAstSync?(
    ast: unknown,
    code: string | undefined,
    options: { filename?: string; babelrc?: boolean; configFile?: boolean },
  ): { code?: string } | null;
}

export interface BabelTransformOptions {
  filename?: string;
  presets?: unknown[];
  plugins?: unknown[];
  babelrc?: boolean;
  configFile?: boolean;
  compact?: boolean;
  retainLines?: boolean;
  sourceMaps?: boolean;
  parserOpts?: { plugins?: string[] };
}

/**
 * `unknown` error 에서 message string 추출. 4 plugin 파일이 stderr write
 * 시점에 사용 — 매번 `as { message?: string }` cast 의 boilerplate 회피.
 */
export function getErrorMessage(err: unknown, max = 100): string {
  const e = err as { message?: unknown };
  if (typeof e?.message === 'string') return e.message.slice(0, max);
  return String(err).slice(0, max);
}
