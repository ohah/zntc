// HTTP server bootstrap + middleware chain. base middleware 가 매치 못 한 path
// 는 next() 로 위임 — 후속 layer (asset/bundle/symbolicate routes, user
// enhanceMiddleware) 가 처리.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

import type { HmrBridge } from "./hmr-bridge.ts";
import { parseRequestUrl, sendText } from "./http-utils.ts";
import type { CliServerApi } from "./middleware/cli-server-api.ts";
import { DEV_MIDDLEWARE_PATH_PREFIXES, type DevMiddleware } from "./middleware/dev-middleware.ts";
import type { RnDevServerOptions } from "./options.ts";
import type { PlatformStateRegistry } from "./platform-state.ts";
import { handleAssetRequest, isAssetRoute } from "./routes/assets.ts";
import {
  handleBundleRequest,
  handleHmrMapRequest,
  handleMapRequest,
  isBundleRoute,
  isHmrMapRoute,
  isMapRoute,
} from "./routes/bundle.ts";
import { handleDevMenu, isDevMenuRoute } from "./routes/devmenu.ts";
import { handleIndexPage, isIndexRoute } from "./routes/index-page.ts";
import { handleOpenUrl, isOpenUrlRoute } from "./routes/open-url.ts";
import { handleReload, isReloadRoute } from "./routes/reload.ts";
import { handleStatus, isStatusRoute } from "./routes/status.ts";
import { handleSymbolicateRequest, isSymbolicateRoute } from "./routes/symbolicate.ts";
import type { Broadcast, Middleware } from "./types.ts";

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
    const url = parseRequestUrl(req, options.host, options.port);
    const pathname = options.rewriteRequestUrl
      ? options.rewriteRequestUrl(url.pathname)
      : url.pathname;
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
    if (deps.devMiddleware && DEV_MIDDLEWARE_PATH_PREFIXES.some((p) => pathname.startsWith(p))) {
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
      if (!res.headersSent && !res.writableEnded) sendText(res, 404, "Not Found");
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
  socket: import("node:net").Socket,
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
          ep.handleUpgrade(req, socket, head, (ws) => ep.emit("connection", ws, req));
          return;
        }
      }
    }
    if (dev) {
      for (const [path, ep] of Object.entries(dev)) {
        if (url.pathname === path || url.pathname.startsWith(`${path}/`)) {
          ep.handleUpgrade(req, socket, head, (ws) => ep.emit("connection", ws, req));
          return;
        }
      }
    }
    socket.destroy();
  };
  server.on("upgrade", listener);
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
  server.on("request", requestHandler);
  const upgradeHandler = attachWebSocketEndpoints(server, deps, options);

  await new Promise<void>((resolve, reject) => {
    const onError = (err: Error) => {
      server.removeListener("listening", onListening);
      reject(err);
    };
    const onListening = () => {
      server.removeListener("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
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
        server.removeListener("request", requestHandler);
        if (upgradeHandler) server.removeListener("upgrade", upgradeHandler);
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}
