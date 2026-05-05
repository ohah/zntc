// preset RnBundleInput 와 mirror. zts 외부 의존성 0.

import type { RnBundleInput } from "../preset.ts";
import type { FrameInfo, Middleware, MiddlewareEnhanceContext } from "./types.ts";

/** customizeFrame `collapse:true` → DevTools 에서 frame 숨김. caller 가 try/catch 로 swallow. */
export type CustomizeFrame = (frame: FrameInfo) => Promise<{ collapse?: boolean } | void>;

export interface RnDevServerOptions {
  bundle: RnBundleInput;
  port: number;
  host: string;
  enhanceMiddleware?: (mw: Middleware, ctx: MiddlewareEnhanceContext) => Middleware;
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
    enhanceMiddleware: input.enhanceMiddleware,
    rewriteRequestUrl: input.rewriteRequestUrl,
    symbolicator: input.symbolicator?.customizeFrame
      ? { customizeFrame: input.symbolicator.customizeFrame }
      : undefined,
    terminalActions: input.terminalActions ?? true,
    hmr: input.hmr ?? true,
  };
}
