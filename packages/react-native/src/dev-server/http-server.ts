// HTTP server bootstrap + middleware chain. base middleware 가 매치 못 한 path
// 는 next() 로 위임 — 후속 layer (asset/bundle/symbolicate routes, user
// enhanceMiddleware) 가 처리.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

import type { HmrBridge } from "./hmr-bridge.ts";
import { parseRequestUrl, sendText } from "./http-utils.ts";
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
import { handleOpenUrl, isOpenUrlRoute } from "./routes/open-url.ts";
import { handleReload, isReloadRoute } from "./routes/reload.ts";
import { handleStatus, isStatusRoute } from "./routes/status.ts";
import type { Broadcast, Middleware } from "./types.ts";

export interface DevHttpServerDeps {
  /** WS broadcast — caller 가 cli-server-api 의 messageSocketEndpoint.broadcast 와 wire. */
  broadcast: Broadcast;
  /** per-platform state — bundle/map/hmr-map 라우트가 plat 분기 시 사용. */
  platforms: PlatformStateRegistry;
  /** HMR bridge — `/hot` upgrade 핸들 + adapter (PR #E). 미지정 시 HMR 비활성. */
  hmrBridge?: HmrBridge;
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
  server.on("request", chainToHandler(enhanced));
  deps.hmrBridge?.attachToServer(server);

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
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}
