// dev-server public surface.

export type { CustomizeFrame, RnDevServerOptions, RnDevServerOptionsInput } from "./options.ts";
export { buildRnDevServerOptions } from "./options.ts";
export type { FrameInfo, Middleware, MiddlewareEnhanceContext } from "./types.ts";

/** Dev server lifecycle handle. */
export interface RnDevServerHandle {
  readonly url: string;
  readonly port: number;
  stop(): Promise<void>;
}
