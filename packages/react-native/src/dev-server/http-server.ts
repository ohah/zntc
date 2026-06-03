// HTTP server bootstrap + middleware chain. base middleware 가 매치 못 한 path
// 는 next() 로 위임 — 후속 layer (asset/bundle/symbolicate routes, user
// enhanceMiddleware) 가 처리.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

import * as jscSafeUrl from 'jsc-safe-url';

import { runMiddlewareForBun } from './bun-http-adapter.ts';
import type { HmrBridge } from './hmr-bridge.ts';
import { parseRequestUrl, sendText } from './http-utils.ts';
import type { CliServerApi } from './middleware/cli-server-api.ts';
import { type DevMiddleware, isDevMiddlewareRoute } from './middleware/dev-middleware.ts';
import type { RnDevServerOptions } from './options.ts';
import type { PlatformStateRegistry } from './platform-state.ts';
import { handleAssetRequest, isAssetRoute } from './routes/assets.ts';
import {
  handleBundleRequest,
  handleHmrMapRequest,
  handleMapRequest,
  isBundleRoute,
  isHmrMapRoute,
  isMapRoute,
} from './routes/bundle.ts';
import { handleDevMenu, isDevMenuRoute } from './routes/devmenu.ts';
import { handleIndexPage, isIndexRoute } from './routes/index-page.ts';
import { handleOpenUrl, isOpenUrlRoute } from './routes/open-url.ts';
import { handleReload, isReloadRoute } from './routes/reload.ts';
import { handleStatus, isStatusRoute } from './routes/status.ts';
import { handleSymbolicateRequest, isSymbolicateRoute } from './routes/symbolicate.ts';
import type { Broadcast, Middleware } from './types.ts';

export interface DevHttpServerDeps {
  /** WS broadcast — caller 가 cli-server-api 의 messageSocketEndpoint.broadcast 와 wire. */
  broadcast: Broadcast;
  /** per-platform state — bundle/map/hmr-map 라우트가 plat 분기 시 사용. */
  platforms: PlatformStateRegistry;
  /** HMR bridge — `/hot` upgrade 핸들 + adapter. 미지정 시 HMR 비활성. */
  hmrBridge?: HmrBridge;
  /** RN DevTools dev-middleware (peer optional). 미지정 시 inspector 비활성. */
  devMiddleware?: DevMiddleware;
  /** cli-server-api 의 websocket endpoints (peer optional). */
  cliServerApi?: CliServerApi;
}

export interface DevHttpServerHandle {
  readonly server: Server;
  readonly url: string;
  readonly port: number;
  stop(): Promise<void>;
}

/**
 * Base middleware — status/reload/devmenu/open-url 4 라우트만 처리. 매칭 못
 * 한 path 는 next() 로 위임. user enhanceMiddleware (rozenite 등) 가 chain
 * 의 어느 layer 든 가로챌 수 있도록 connect-style next 호출.
 */
export function createBaseMiddleware(
  options: RnDevServerOptions,
  deps: DevHttpServerDeps,
): Middleware {
  return (req, res, next) => {
    // Metro `Server.js#_rewriteAndNormalizeUrl` 동일 패턴 — iOS/Hermes 의
    // jsc-safe URL 재요청을 normal URL routing 으로 매칭하기 위한 in-place 변경.
    if (req.url) {
      const normalized = jscSafeUrl.toNormalUrl(req.url);
      const rewritten = options.rewriteRequestUrl
        ? options.rewriteRequestUrl(normalized)
        : normalized;
      req.url = jscSafeUrl.toNormalUrl(rewritten);
    }
    const url = parseRequestUrl(req, options.host, options.port);
    const pathname = url.pathname;
    const method = req.method;

    if (isIndexRoute(pathname)) {
      handleIndexPage(req, res, options.port);
      return;
    }
    if (isStatusRoute(pathname)) {
      handleStatus(req, res, options.bundle.projectRoot);
      return;
    }
    if (isReloadRoute(pathname)) {
      handleReload(req, res, deps.broadcast);
      return;
    }
    if (isDevMenuRoute(pathname)) {
      handleDevMenu(req, res, deps.broadcast);
      return;
    }
    if (isOpenUrlRoute(pathname, method)) {
      handleOpenUrl(req, res).catch(next);
      return;
    }
    if (isAssetRoute(pathname)) {
      handleAssetRequest(req, res, url, {
        projectRoot: options.bundle.projectRoot,
        nodeModulesPaths: options.nodeModulesPaths,
      }).catch(next);
      return;
    }
    if (isBundleRoute(pathname)) {
      handleBundleRequest(
        req,
        res,
        url,
        deps.platforms,
        options.bundle.rnPlatform,
        options.bundle.projectRoot,
        options.port,
      ).catch(next);
      return;
    }
    if (isHmrMapRoute(pathname)) {
      handleHmrMapRequest(req, res, url, deps.platforms, options.bundle.rnPlatform);
      return;
    }
    if (isMapRoute(pathname)) {
      handleMapRequest(req, res, url, deps.platforms, options.bundle.rnPlatform);
      return;
    }
    if (isSymbolicateRoute(pathname, method)) {
      handleSymbolicateRequest(
        req,
        res,
        url,
        deps.platforms,
        options.bundle.rnPlatform,
        options.bundle.projectRoot,
        options.symbolicator?.customizeFrame,
      ).catch(next);
      return;
    }
    // dev-middleware (peer optional) — /json, /open-debugger, /debugger-frontend,
    // /launch-js-devtools 처리. 미설치 시 next() 로 fallthrough.
    if (deps.devMiddleware && isDevMiddlewareRoute(pathname)) {
      deps.devMiddleware.middleware(req, res, next);
      return;
    }
    next();
  };
}

/** Connect-style chain → 단일 request handler. terminal next() 시 404 / err 시 500. */
function chainToHandler(
  middleware: Middleware,
): (req: IncomingMessage, res: ServerResponse) => void {
  return (req, res) => {
    middleware(req, res, (err) => {
      if (err) {
        sendText(res, 500, `Internal Server Error: ${(err as Error).message ?? err}`);
        return;
      }
      if (!res.headersSent && !res.writableEnded) sendText(res, 404, 'Not Found');
    });
  };
}

/**
 * 단일 WS upgrade chain — hmrBridge `/hot` → cli-server-api endpoints →
 * dev-middleware endpoints. 매칭 안 되면 socket destroy (bungae parity).
 * 모든 deps 가 absent 면 listener 미등록 (default Node 동작 — destroy).
 */
type UpgradeListener = (
  req: IncomingMessage,
  socket: import('node:net').Socket,
  head: Buffer,
) => void;

function attachWebSocketEndpoints(
  server: Server,
  deps: DevHttpServerDeps,
  options: RnDevServerOptions,
): UpgradeListener | null {
  const hmr = deps.hmrBridge;
  const cli = deps.cliServerApi?.websocketEndpoints;
  const dev = deps.devMiddleware?.websocketEndpoints;
  if (!hmr && !cli && !dev) return null;

  const listener: UpgradeListener = (req, socket, head) => {
    const url = parseRequestUrl(req, options.host, options.port);
    if (hmr && (url.pathname === hmr.path || url.pathname.startsWith(`${hmr.path}?`))) {
      hmr.acceptUpgrade(req, socket as never);
      return;
    }
    if (cli) {
      for (const [path, ep] of Object.entries(cli)) {
        if (url.pathname === path || url.pathname.startsWith(`${path}?`)) {
          ep.handleUpgrade(req, socket, head, (ws) => ep.emit('connection', ws, req));
          return;
        }
      }
    }
    if (dev) {
      for (const [path, ep] of Object.entries(dev)) {
        if (url.pathname === path || url.pathname.startsWith(`${path}/`)) {
          ep.handleUpgrade(req, socket, head, (ws) => ep.emit('connection', ws, req));
          return;
        }
      }
    }
    socket.destroy();
  };
  server.on('upgrade', listener);
  return listener;
}

export async function createDevHttpServer(
  options: RnDevServerOptions,
  deps: DevHttpServerDeps,
): Promise<DevHttpServerHandle> {
  // server 를 먼저 instantiate (unbound) 해서 enhanceMiddleware 에 ref 전달. 첫
  // request 가 들어오는 시점에는 listen 완료 — listen 전 capture 만 하므로 안전.
  const server: Server = createServer();
  const baseMiddleware = createBaseMiddleware(options, deps);
  const enhanced = options.enhanceMiddleware
    ? options.enhanceMiddleware(baseMiddleware, { httpServer: server })
    : baseMiddleware;
  const requestHandler = chainToHandler(enhanced);
  server.on('request', requestHandler);
  const upgradeHandler = attachWebSocketEndpoints(server, deps, options);

  await new Promise<void>((resolve, reject) => {
    const onError = (err: Error) => {
      server.removeListener('listening', onListening);
      reject(err);
    };
    const onListening = () => {
      server.removeListener('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(options.port, options.host);
  });

  return {
    server,
    url: `http://${options.host}:${options.port}`,
    port: options.port,
    stop: () =>
      new Promise<void>((resolve, reject) => {
        // server.close() 는 listener 자동 제거 안 함. 명시 제거로 closure capture
        // 해제 — watch handle / channel client refs 가 GC 대상이 되도록.
        server.removeListener('request', requestHandler);
        if (upgradeHandler) server.removeListener('upgrade', upgradeHandler);
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

// ─── Bun runtime 전용 dev http server ────────────────────────────────────────
//
// 배경(#RN-bun-hmr): Bun 에서 `zntc dev --platform=react-native` 를 띄우면
// HMR WebSocket(`/hot`)이 연결되지 않는다. 원인은 node:http `server.on('upgrade')`
// + 수동 RFC6455 핸드셰이크(`socket.write("HTTP/1.1 101 ...")`)가 Bun 의 node:http
// 호환층에서 깨지는 것: socket.write 가 throw 없이 "성공"하지만 101 응답이 실제로
// TCP 로 전달되지 않아 client 가 OPEN 도 CLOSE 도 못 받는다(node 에선 정상).
//
// 해결: Bun 에선 Bun.serve 의 native WebSocket(`server.upgrade(req)` + `websocket`
// handler)으로 `/hot` 을 처리한다. 나머지 HTTP 요청(bundle/asset/symbolicate/
// status 등)과 enhanceMiddleware 는 Bun `Request` → node req/res 어댑터
// (runMiddlewareForBun)로 기존 미들웨어 체인을 *그대로* 재사용한다.
//
// 한계(코드 코멘트로 명시):
//   - cli-server-api(`/message` `/events`)와 dev-middleware(`/inspector` 등)의
//     WebSocket endpoint 는 `ws` 라이브러리의 `handleUpgrade(req, socket, head)`
//     가 raw Node socket(실제 fd) 을 요구한다. Bun.serve 의 fetch 는 raw socket 을
//     노출하지 않으므로 이 endpoint 들의 ws upgrade 는 Bun 에서 동작하지 않는다.
//     → HMR(`/hot`)만 Bun.serve 로 보장. cli-server-api 의 broadcast(터미널 r/d)는
//       그 client 가 연결돼야 동작하므로 Bun 에선 제한될 수 있다.
//   - enhanceMiddleware(ctx.httpServer)의 `.on('upgrade')` 도 같은 이유로 동작
//     불가 — no-op shim 을 넘겨 Rozenite 등이 crash 하지 않게만 한다(WS 의존
//     기능은 degrade).

/** Bun.serve websocket handler 가 받는 ws 객체의 최소 표면. */
interface BunServerWebSocket {
  send(data: string): void;
  readonly data?: unknown;
}

/** Bun.serve 가 반환하는 server 객체의 최소 표면(우리가 쓰는 부분만). */
interface BunServer {
  port: number;
  stop(closeActiveConnections?: boolean): void;
  upgrade(req: Request, options?: { data?: unknown }): boolean;
}

/**
 * enhanceMiddleware 에 넘길 httpServer shim. Bun.serve 는 listen 전 instance 가
 * 없고 `.on('upgrade')` 도 지원 안 하므로, node Server 인터페이스 흉내만 내고
 * upgrade 등록은 1회 경고 후 무시한다(한계 — 위 코멘트 참고).
 */
function createBunHttpServerShim(): Server {
  let warned = false;
  const shim: Record<string, unknown> = {
    on(event: string): unknown {
      if (event === 'upgrade' && !warned) {
        warned = true;
        process.stderr.write(
          `[zntc:rn-dev] Bun runtime: enhanceMiddleware 의 httpServer.on('upgrade') 는 ` +
            `Bun.serve 에서 지원되지 않습니다(raw socket 미노출). HMR(/hot)은 정상 동작하나 ` +
            `WebSocket upgrade 에 의존하는 enhanceMiddleware 기능(Rozenite 등)은 제한됩니다.\n`,
        );
      }
      return shim;
    },
    once(): unknown {
      return shim;
    },
    removeListener(): unknown {
      return shim;
    },
    off(): unknown {
      return shim;
    },
    address(): { port: number } {
      return { port: 0 };
    },
  };
  return shim as unknown as Server;
}

export async function createBunDevHttpServer(
  options: RnDevServerOptions,
  deps: DevHttpServerDeps,
): Promise<DevHttpServerHandle> {
  const Bun = (globalThis as { Bun?: { serve(opts: unknown): BunServer } }).Bun;
  if (!Bun) throw new Error('createBunDevHttpServer는 Bun runtime에서만 호출 가능합니다.');

  const baseMiddleware = createBaseMiddleware(options, deps);
  // enhanceMiddleware 는 node Server 모양의 httpServer 를 기대 — shim 전달.
  const enhanced = options.enhanceMiddleware
    ? options.enhanceMiddleware(baseMiddleware, { httpServer: createBunHttpServerShim() })
    : baseMiddleware;

  const hmr = deps.hmrBridge;

  const serveOpts: Record<string, unknown> = {
    port: options.port,
    hostname: options.host,
    // fetch 는 동기적으로 server.upgrade(req) 를 먼저 시도(첫 await 전)해야 native
    // WebSocket 업그레이드가 성립한다. /hot 이외는 어댑터로 미들웨어 체인 실행.
    async fetch(req: Request, server: BunServer): Promise<Response | undefined> {
      const url = new URL(req.url);
      if (hmr && (url.pathname === hmr.path || url.pathname.startsWith(`${hmr.path}?`))) {
        // server.upgrade 성공 시 undefined 반환(Bun 이 101 native 처리).
        if (server.upgrade(req)) return undefined;
        return new Response('Upgrade required', { status: 426 });
      }
      return runMiddlewareForBun(enhanced, req);
    },
  };

  if (hmr) {
    serveOpts.websocket = {
      open(ws: BunServerWebSocket): void {
        hmr.acceptBun(ws);
      },
      message(ws: BunServerWebSocket, message: string | Buffer): void {
        // RN HMR client 의 register-entrypoints / log 처리. Buffer 면 문자열화.
        const text = typeof message === 'string' ? message : message.toString('utf-8');
        hmr.handleBunMessage(ws, text);
      },
      close(ws: BunServerWebSocket): void {
        hmr.removeBun(ws);
      },
    };
  }

  const server = Bun.serve(serveOpts);

  return {
    // node Server 가 아니라 Bun server — DevHttpServerHandle.server 타입과 다르지만
    // serve.ts 는 url/port/stop 만 사용한다. 타입 호환을 위해 cast.
    server: server as unknown as Server,
    url: `http://${options.host}:${server.port}`,
    port: server.port,
    stop: () =>
      new Promise<void>((resolve) => {
        // true = active connection(WS 포함)도 강제 종료 → 포트 즉시 해제(restart 대비).
        server.stop(true);
        resolve();
      }),
  };
}
