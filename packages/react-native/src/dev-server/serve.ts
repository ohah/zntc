// serveRn — 모든 dev-server 컴포넌트 wiring entry. caller (CLI / 외부 consumer)
// 가 RnDevServerOptions 만 만들면 cli-server-api / dev-middleware 부가 lazy
// 로드 + per-platform watch + HMR bridge + terminal actions 까지 자동 통합.

import { createDevHttpServer, type DevHttpServerHandle } from "./http-server.ts";
import { createHmrBridge, type HmrBridge } from "./hmr-bridge.ts";
import { loadCliServerApi } from "./middleware/cli-server-api.ts";
import { loadDevMiddleware } from "./middleware/dev-middleware.ts";
import type { RnDevServerOptions } from "./options.ts";
import {
  createPlatformStateRegistry,
  type PlatformStateRegistry,
  waitForBuild,
} from "./platform-state.ts";
import { setupTerminalActions } from "./terminal-actions.ts";
import type { Broadcast } from "./types.ts";

export interface RnDevServerHandle {
  readonly url: string;
  readonly port: number;
  readonly hmrBridge?: HmrBridge;
  readonly platforms: PlatformStateRegistry;
  stop(): Promise<void>;
}

const HMR_PATH = "/hot";

const noopBroadcast: Broadcast = () => {};

/**
 * dev server lifecycle 시작. 첫 platform 의 initial build 까지 대기 후 handle
 * 반환. 종료는 `handle.stop()` — http server close + watch handles stop +
 * terminal raw mode 복원 순서로 graceful.
 */
export async function serveRn(options: RnDevServerOptions): Promise<RnDevServerHandle> {
  // 두 lazy load 는 독립 — 병렬로 dynamic import resolve.
  const [cliServerApi, devMiddleware] = await Promise.all([
    loadCliServerApi({ port: options.port, host: options.host }),
    loadDevMiddleware({ port: options.port, projectRoot: options.bundle.projectRoot }),
  ]);

  const broadcast: Broadcast = cliServerApi?.broadcast ?? noopBroadcast;

  // hmrBridge 먼저 생성 — registry callback 으로 onRebuild 전달.
  const hmrBridge = options.hmr ? createHmrBridge({ path: HMR_PATH }) : undefined;
  const platforms = createPlatformStateRegistry(options, hmrBridge?.callbacks);

  const httpHandle: DevHttpServerHandle = await createDevHttpServer(options, {
    broadcast,
    platforms,
    hmrBridge,
    devMiddleware: devMiddleware ?? undefined,
    cliServerApi: cliServerApi ?? undefined,
  });

  // initial platform pre-spawn + first build 대기.
  const firstState = platforms.getOrCreate(options.bundle.rnPlatform);
  await waitForBuild(firstState);

  const terminalCleanup = setupTerminalActions(
    {
      onReload: () => broadcast("reload"),
      onDevMenu: () => broadcast("devMenu"),
      onOpenDevTools: () => {
        // dev-middleware 가 /open-debugger POST 를 처리. 미설치 시 silent skip.
        fetch(`${httpHandle.url}/open-debugger`, { method: "POST" }).catch(() => {});
      },
      onClearCache: () => {
        for (const state of platforms.platforms.values()) {
          state.bundle = null;
          state.buildError = null;
          state.sourceMapCache = null;
        }
      },
    },
    { enabled: options.terminalActions },
  );

  return {
    url: httpHandle.url,
    port: httpHandle.port,
    hmrBridge,
    platforms,
    async stop() {
      terminalCleanup();
      await httpHandle.stop();
      await platforms.stopAll();
    },
  };
}
