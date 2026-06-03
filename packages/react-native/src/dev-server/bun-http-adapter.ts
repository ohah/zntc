// Bun.serve `fetch(Request)` ↔ node:http `(req, res)` 어댑터.
//
// 왜 필요한가:
//   serveRn 의 모든 route handler / base middleware / enhanceMiddleware 는
//   node:http 의 `IncomingMessage` / `ServerResponse` 모양으로 작성돼 있다.
//   Bun 에서 dev server 를 띄울 때 HMR WebSocket(`/hot`)을 Bun.serve 의 native
//   upgrade 로 처리해야 하는데(수동 RFC6455 핸드셰이크가 Bun node:http 호환층
//   에서 깨짐, #RN-bun-hmr), Bun.serve 의 진입점은 `fetch(Request): Response`
//   라서 기존 미들웨어 체인을 그대로 못 쓴다.
//
//   이 어댑터는 Bun `Request` 를 최소한의 node `req` 모양으로 감싸고, node `res`
//   를 흉내내는 buffering shim 을 만들어 미들웨어를 그대로 실행한 뒤, 그 결과를
//   하나의 Bun `Response` 로 변환한다. → route handler 코드는 한 줄도 안 바뀐다.
//
// Zig/JS 초보자 메모:
//   - node:http 의 res 는 "쓰면 바로 소켓으로 흘러가는" 스트림이지만, 우리 route
//     들은 항상 동기적으로 writeHead → write* → end 를 호출하고 끝낸다(진짜
//     streaming 안 함). 그래서 write 청크를 배열에 모았다가 end 시점에 한 번에
//     Response 로 만들면 동작이 동일하다.
//   - body(POST)는 Bun Request 에서 미리 읽어 `req.rawBody` 로 넣어둔다. 기존
//     `readJsonBody` 가 (스트림이 이미 drain 된 케이스로 보고) 이 캐시에서 복구
//     하므로 `req.on('data')` 에뮬레이션 없이도 POST 가 동작한다.

import type { IncomingMessage, ServerResponse } from 'node:http';

import type { Middleware } from './types.ts';

/** node `res` 가 호출되며 모인 응답 상태. end 시 resolve 에 넘긴다. */
interface CapturedResponse {
  statusCode: number;
  headers: Record<string, string>;
  chunks: Array<Buffer>;
}

/**
 * node `ServerResponse` 의 부분 구현 — route 들이 실제로 쓰는 표면만
 * (writeHead/setHeader/write/end + headersSent/writableEnded/statusCode).
 * end() 가 불리면 `done(captured)` 를 정확히 한 번 호출한다.
 */
function createResponseShim(done: (captured: CapturedResponse) => void): {
  res: ServerResponse;
  captured: CapturedResponse;
} {
  const captured: CapturedResponse = { statusCode: 200, headers: {}, chunks: [] };
  let ended = false;
  let headersSent = false;

  const applyHeaders = (headers?: Record<string, unknown>): void => {
    if (!headers) return;
    for (const [k, v] of Object.entries(headers)) {
      // node 는 header 값으로 number/array 도 허용 — Bun Response 는 string 필요.
      captured.headers[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : String(v);
    }
  };

  const shim = {
    get statusCode(): number {
      return captured.statusCode;
    },
    set statusCode(code: number) {
      captured.statusCode = code;
    },
    get headersSent(): boolean {
      return headersSent;
    },
    get writableEnded(): boolean {
      return ended;
    },
    setHeader(name: string, value: unknown): void {
      captured.headers[String(name).toLowerCase()] = Array.isArray(value)
        ? value.join(', ')
        : String(value);
    },
    getHeader(name: string): string | undefined {
      return captured.headers[String(name).toLowerCase()];
    },
    writeHead(statusCode: number, headersOrReason?: unknown, maybeHeaders?: unknown): unknown {
      captured.statusCode = statusCode;
      // node 시그니처: writeHead(status, reasonPhrase?, headers?) — reason 은 무시.
      const headers =
        headersOrReason && typeof headersOrReason === 'object'
          ? headersOrReason
          : (maybeHeaders ?? undefined);
      applyHeaders(headers as Record<string, unknown> | undefined);
      headersSent = true;
      return shim;
    },
    write(chunk: unknown): boolean {
      if (chunk != null) {
        captured.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
      }
      headersSent = true;
      return true;
    },
    end(chunk?: unknown): unknown {
      if (ended) return shim;
      if (chunk != null) {
        captured.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
      }
      ended = true;
      headersSent = true;
      done(captured);
      return shim;
    },
  };

  return { res: shim as unknown as ServerResponse, captured };
}

/**
 * Bun `Request` → 최소 node `req` shim. `url` 은 path+query(`req.url` 관례),
 * `headers` 는 소문자 키 객체, body 는 `rawBody` 캐시로 제공.
 */
function createRequestShim(req: Request, rawBody: string | null): IncomingMessage {
  const u = new URL(req.url);
  const headers: Record<string, string> = {};
  req.headers.forEach((value, key) => {
    headers[key.toLowerCase()] = value;
  });
  const shim: Record<string, unknown> = {
    url: u.pathname + u.search,
    method: req.method,
    headers,
    // readJsonBody 의 "stream 이미 drain됨" 분기를 타게 함 → rawBody 에서 복구.
    complete: true,
    readable: false,
    rawBody,
    // route 들이 직접 req.on 을 쓰진 않지만(readJsonBody 만 사용), 방어적으로 no-op.
    on(): unknown {
      return shim;
    },
  };
  return shim as unknown as IncomingMessage;
}

/**
 * 미들웨어 체인(node req/res 기반)을 Bun `Request` 에 대해 실행하고 단일
 * `Response` 로 변환. terminal next() / next(err) 도 node 경로(chainToHandler)와
 * 동일하게 404 / 500 으로 매핑한다.
 *
 * route handler 가 비동기로 res.end() 를 호출하는 경우(.catch(next) 패턴)도
 * Promise 가 end / next 둘 중 먼저 오는 쪽에서 resolve 되도록 한다.
 */
export async function runMiddlewareForBun(middleware: Middleware, req: Request): Promise<Response> {
  // POST body 미리 읽기 — readJsonBody 가 rawBody 캐시에서 파싱.
  let rawBody: string | null = null;
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    try {
      rawBody = await req.text();
    } catch {
      rawBody = null;
    }
  }
  const reqShim = createRequestShim(req, rawBody);

  return new Promise<Response>((resolve) => {
    let settled = false;
    const toResponse = (c: CapturedResponse): Response => {
      // 빈 body 면 null, 아니면 합친 Buffer 를 Uint8Array 로(Response 가 허용).
      const body = c.chunks.length === 0 ? null : new Uint8Array(Buffer.concat(c.chunks));
      return new Response(body, { status: c.statusCode, headers: c.headers });
    };
    const { res } = createResponseShim((captured) => {
      if (settled) return;
      settled = true;
      resolve(toResponse(captured));
    });

    try {
      middleware(reqShim, res, (err?: unknown) => {
        if (settled) return;
        settled = true;
        if (err) {
          const msg = (err as Error)?.message ?? String(err);
          resolve(new Response(`Internal Server Error: ${msg}`, { status: 500 }));
          return;
        }
        // chainToHandler 의 terminal: 아직 응답 안 했으면 404.
        if (!res.headersSent && !res.writableEnded) {
          resolve(new Response('Not Found', { status: 404 }));
          return;
        }
        // enhanceMiddleware 가 res.end() 후 next() 호출하는 케이스 — 위 done 콜백이
        // 이미 resolve 했어야 하지만(settled), 방어적으로 빈 응답.
        resolve(new Response(null, { status: res.statusCode }));
      });
    } catch (err) {
      if (settled) return;
      settled = true;
      const msg = (err as Error)?.message ?? String(err);
      resolve(new Response(`Internal Server Error: ${msg}`, { status: 500 }));
    }
  });
}
