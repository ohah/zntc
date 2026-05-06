// serveRn — 모든 dev-server 컴포넌트 wiring entry. caller (CLI / 외부 consumer)
// 가 RnDevServerOptions 만 만들면 cli-server-api / dev-middleware 부가 lazy
// 로드 + per-platform watch + HMR bridge + terminal actions 까지 자동 통합.

import { createDevHttpServer, type DevHttpServerHandle } from './http-server.ts';
import { createHmrBridge, type HmrBridge } from './hmr-bridge.ts';
import { logBundle, logInfo, printZtsRnBanner } from './logger.ts';
import { loadCliServerApi } from './middleware/cli-server-api.ts';
import { loadDevMiddleware } from './middleware/dev-middleware.ts';
import type { RnDevServerOptions } from './options.ts';
import {
  createPlatformStateRegistry,
  type PlatformStateRegistry,
  waitForBuild,
} from './platform-state.ts';
import { setupTerminalActions } from './terminal-actions.ts';
import type { Broadcast } from './types.ts';

export interface RnDevServerHandle {
  readonly url: string;
  readonly port: number;
  readonly hmrBridge?: HmrBridge;
  readonly platforms: PlatformStateRegistry;
  stop(): Promise<void>;
}

const HMR_PATH = '/hot';

/**
 * cli-server-api 미설치 시 fallback. broadcast 호출은 silent 가 맞지만 —
 * 사용자가 r/d 키 누르고 reload 안 됨 → 진단 어려움. 한 번만 stderr 알림 후
 * 이후 호출은 silent (noisy 회피).
 */
function makeNoopBroadcast(): Broadcast {
  let warned = false;
  return (method) => {
    if (!warned) {
      warned = true;
      process.stderr.write(
        `[zts:rn-dev] broadcast('${method}') skipped — '@react-native-community/cli-server-api' 미설치 또는 load 실패. ` +
          `RN runtime 의 reload/devMenu 메시지 안 감. peer dependency 설치 필요.\n`,
      );
    }
  };
}

/**
 * dev server lifecycle 시작. 첫 platform 의 initial build 까지 대기 후 handle
 * 반환. 종료는 `handle.stop()` — http server close + watch handles stop +
 * terminal raw mode 복원 순서로 graceful.
 */
export interface ServeRnExtras {
  /** package version — banner 에 표시. */
  version?: string;
  /** banner / startup log 출력 안 함 (test 환경 등). default false. */
  silent?: boolean;
}

export async function serveRn(
  options: RnDevServerOptions,
  extras: ServeRnExtras = {},
): Promise<RnDevServerHandle> {
  if (!extras.silent) printZtsRnBanner(extras.version);

  // 두 lazy load 는 독립 — 병렬로 dynamic import resolve.
  const [cliServerApi, devMiddleware] = await Promise.all([
    loadCliServerApi({ port: options.port, host: options.host }),
    loadDevMiddleware({ port: options.port, projectRoot: options.bundle.projectRoot }),
  ]);

  const broadcast: Broadcast = cliServerApi?.broadcast ?? makeNoopBroadcast();
  if (process.env.ZTS_DEBUG_TERMINAL === '1') {
    process.stderr.write(
      `[zts:rn-dev:debug] cli-server-api: ${cliServerApi ? 'loaded' : 'null (peer 미설치 또는 load 실패)'}\n`,
    );
    process.stderr.write(
      `[zts:rn-dev:debug] dev-middleware: ${devMiddleware ? 'loaded' : 'null (peer 미설치)'}\n`,
    );
  }

  // hmrBridge 먼저 생성 — registry callback 으로 onRebuild 전달.
  const hmrBridge = options.hmr
    ? createHmrBridge({ path: HMR_PATH, silent: extras.silent })
    : undefined;
  const platforms = createPlatformStateRegistry(options, hmrBridge?.callbacks);

  const httpHandle: DevHttpServerHandle = await createDevHttpServer(options, {
    broadcast,
    platforms,
    hmrBridge,
    devMiddleware: devMiddleware ?? undefined,
    cliServerApi: cliServerApi ?? undefined,
  });

  // initial platform pre-spawn + first build 대기.
  const buildStart = Date.now();
  const firstState = platforms.getOrCreate(options.bundle.rnPlatform);
  await waitForBuild(firstState);
  if (!extras.silent) {
    if (firstState.buildError) {
      logBundle('failed', options.bundle.rnPlatform, options.bundle.entry, firstState.buildError);
    } else if (firstState.bundle !== null) {
      const sizeKB = (Buffer.byteLength(firstState.bundle) / 1024).toFixed(1);
      const buildMs = Date.now() - buildStart;
      logBundle(
        'done',
        options.bundle.rnPlatform,
        options.bundle.entry,
        `(${firstState.fileCount} files, ${sizeKB} KB, ${buildMs}ms)`,
      );
    }
  }

  const terminalCleanup = setupTerminalActions(
    {
      onReload: () => broadcast('reload'),
      onDevMenu: () => broadcast('devMenu'),
      onOpenDevTools: () => {
        // dev-middleware 가 /open-debugger POST 를 처리. 미설치 시 silent skip.
        fetch(`${httpHandle.url}/open-debugger`, { method: 'POST' }).catch(() => {});
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
  if (!extras.silent && options.terminalActions) {
    logInfo('Press ? to show keyboard shortcuts (r/d/j/i/a/c)');
  }
  if (!extras.silent) {
    logInfo(`Dev server listening on ${httpHandle.url} (platform=${options.bundle.rnPlatform})`);
  }

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
