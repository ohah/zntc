// preset RnBundleInput 와 mirror. zts 외부 의존성 0.

import type { RnBundleInput } from "../preset.ts";
import type { FrameInfo, Middleware, MiddlewareEnhanceContext } from "./types.ts";

/** customizeFrame `collapse:true` → DevTools 에서 frame 숨김. caller 가 try/catch 로 swallow. */
export type CustomizeFrame = (frame: FrameInfo) => Promise<{ collapse?: boolean } | void>;

export interface RnDevServerOptions {
  bundle: RnBundleInput;
  port: number;
  host: string;
  /** Asset resolution 의 fallback (monorepo / pnpm / bun 의 .bun 디렉토리 등). */
  nodeModulesPaths: readonly string[];
  enhanceMiddleware?: (mw: Middleware, ctx: MiddlewareEnhanceContext) => Middleware;
  /**
   * Request URL 을 routing 전에 rewrite (Metro 호환). Argument 는 jsc-safe URL
   * normalize 가 적용된 **full URL** (path + query). 반환값은 다시 normalize 후
   * `req.url` 에 set. iOS/Hermes 의 jsc-safe URL 재요청을 정상 routing 하려면
   * 미설정해도 OK — 미설정 시 normalize 만 적용.
   */
  rewriteRequestUrl?: (url: string) => string;
  symbolicator?: { customizeFrame?: CustomizeFrame };
  terminalActions: boolean;
  hmr: boolean;
}

export type RnDevServerOptionsInput = { bundle: RnBundleInput } & Partial<
  Omit<RnDevServerOptions, "bundle">
>;

export function buildRnDevServerOptions(input: RnDevServerOptionsInput): RnDevServerOptions {
  return {
    bundle: input.bundle,
    port: input.port ?? 8081,
    host: input.host ?? "localhost",
    nodeModulesPaths: input.nodeModulesPaths ?? [],
    enhanceMiddleware: input.enhanceMiddleware,
    rewriteRequestUrl: input.rewriteRequestUrl,
    symbolicator: input.symbolicator?.customizeFrame
      ? { customizeFrame: input.symbolicator.customizeFrame }
      : undefined,
    terminalActions: input.terminalActions ?? true,
    hmr: input.hmr ?? true,
  };
}
