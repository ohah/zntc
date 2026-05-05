import type { IncomingMessage, Server, ServerResponse } from "node:http";

/** Connect-style middleware (Metro / cli-server-api 호환). */
export type Middleware = (
  req: IncomingMessage,
  res: ServerResponse,
  next: (err?: unknown) => void,
) => void;

/** RN runtime stack frame (metro `IntermediateStackFrame` 와 structural compat). */
export interface FrameInfo {
  file: string | null;
  methodName: string | null;
  lineNumber: number | null;
  column: number | null;
}

/** enhanceMiddleware hook 의 두 번째 인자. */
export interface MiddlewareEnhanceContext {
  readonly httpServer: Server;
}
