// dev-server public surface.

export {
  createBaseMiddleware,
  createDevHttpServer,
  type DevHttpServerDeps,
  type DevHttpServerHandle,
} from "./http-server.ts";
export { parseRequestUrl, readJsonBody, sendJson, sendText } from "./http-utils.ts";
export type { CustomizeFrame, RnDevServerOptions, RnDevServerOptionsInput } from "./options.ts";
export { buildRnDevServerOptions } from "./options.ts";
export type { Broadcast, FrameInfo, Middleware, MiddlewareEnhanceContext } from "./types.ts";

/** Dev server lifecycle handle. */
export interface RnDevServerHandle {
  readonly url: string;
  readonly port: number;
  stop(): Promise<void>;
}
