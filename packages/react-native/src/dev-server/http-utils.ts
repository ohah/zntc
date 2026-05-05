// HTTP request/response 헬퍼. routes/* 가 공유.

import type { IncomingMessage, ServerResponse } from "node:http";

export function sendText(
  res: ServerResponse,
  statusCode: number,
  text: string,
  contentType = "text/plain",
): void {
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Content-Length": Buffer.byteLength(text),
  });
  res.end(text);
}

export function sendJson(res: ServerResponse, statusCode: number, data: unknown): void {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

/**
 * Connect/Express 가 IncomingMessage 에 덧붙이는 비표준 필드. body 가 stream
 * 으로 drain 되었을 때 cached 영역에서 복구.
 */
interface MiddlewareAugmentedRequest {
  body?: unknown;
  rawBody?: string | Buffer | null;
}

function parseCachedBody<T>(cached: unknown): T | null {
  if (cached == null) return null;
  if (typeof cached === "string") return JSON.parse(cached) as T;
  if (Buffer.isBuffer(cached)) return JSON.parse(cached.toString("utf-8")) as T;
  if (typeof cached === "object") return cached as T;
  return null;
}

/**
 * POST body 를 JSON 으로 read. Connect/Express middleware (e.g. cli-server-api
 * 의 rawBodyMiddleware, @rozenite/middleware 의 express.json()) 가 stream 을 미리
 * drain 한 경우 augmented `req.body` / `req.rawBody` 에서 복구 — 그렇지 않으면
 * `req.on('data')` 가 영원히 발화 안 해 hang.
 */
export async function readJsonBody<T>(req: IncomingMessage): Promise<T> {
  const augmented = req as IncomingMessage & MiddlewareAugmentedRequest;
  if (req.complete && !req.readable) {
    return parseCachedBody<T>(augmented.body) ?? parseCachedBody<T>(augmented.rawBody) ?? ({} as T);
  }
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk.toString();
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(body) as T);
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

export function parseRequestUrl(
  req: IncomingMessage,
  fallbackHost: string,
  fallbackPort: number,
): URL {
  const hostHeader = req.headers.host || `${fallbackHost}:${fallbackPort}`;
  return new URL(req.url || "/", `http://${hostHeader}`);
}
