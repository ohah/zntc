import type { IncomingMessage, Server, ServerResponse } from 'node:http';

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

/**
 * enhanceMiddleware hook 의 ctx. `httpServer` 는 `listen()` 전 instance — `.on("upgrade")`
 * 등 event 등록 용도. lifecycle (close / connection limits) 은 host (serveRn) 책임.
 */
export interface MiddlewareEnhanceContext {
  readonly httpServer: Server;
}

/**
 * WS broadcast — cli-server-api 의 `messageSocketEndpoint.broadcast(method, params)` 와
 * 동일 시그니처. PR #G 가 zero-mapping wire.
 */
export type Broadcast = (method: string, params?: Record<string, unknown>) => void;
