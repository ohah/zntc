// serveRn — 모든 dev-server 컴포넌트 wiring entry. caller (CLI / 외부 consumer)
// 가 RnDevServerOptions 만 만들면 cli-server-api / dev-middleware 부가 lazy
// 로드 + per-platform watch + HMR bridge + terminal actions 까지 자동 통합.

import { createDevHttpServer, type DevHttpServerHandle } from './http-server.ts';
import { createHmrBridge, type HmrBridge } from './hmr-bridge.ts';
import { logBundle, logError, logInfo, printZntcRnBanner } from './logger.ts';
import { loadCliServerApi } from './middleware/cli-server-api.ts';
import { loadDevMiddleware } from './middleware/dev-middleware.ts';
import type { RnDevServerOptions } from './options.ts';
import {
  createPlatformStateRegistry,
  type PlatformStateRegistry,
  waitForBuild,
} from './platform-state.ts';
import { printDefaultShortcuts, setupTerminalActions } from './terminal-actions.ts';
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
        `[zntc:rn-dev] broadcast('${method}') skipped — '@react-native-community/cli-server-api' 미설치 또는 load 실패. ` +
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
  /**
   * SIGINT/SIGTERM listener 등록 + shutdown 메시지. CLI 사용 시 default true,
   * embed 사용 시 caller 가 직접 lifecycle 관리하면 false. default true.
   */
  installSignalHandlers?: boolean;
}

export async function serveRn(
  options: RnDevServerOptions,
  extras: ServeRnExtras = {},
): Promise<RnDevServerHandle> {
  if (!extras.silent) printZntcRnBanner(extras.version);

  // 두 lazy load 는 독립 — 병렬로 dynamic import resolve.
  const [cliServerApi, devMiddleware] = await Promise.all([
    loadCliServerApi({
      port: options.port,
      host: options.host,
      projectRoot: options.bundle.projectRoot,
    }),
    loadDevMiddleware({ port: options.port, projectRoot: options.bundle.projectRoot }),
  ]);

  const broadcast: Broadcast = cliServerApi?.broadcast ?? makeNoopBroadcast();
  if (process.env.ZNTC_DEBUG_TERMINAL === '1') {
    process.stderr.write(
      `[zntc:rn-dev:debug] cli-server-api: ${cliServerApi ? 'loaded' : 'null (peer 미설치 또는 load 실패)'}\n`,
    );
    process.stderr.write(
      `[zntc:rn-dev:debug] dev-middleware: ${devMiddleware ? 'loaded' : 'null (peer 미설치)'}\n`,
    );
  }

  // hmrBridge 먼저 생성 — registry callback 으로 onRebuild 전달.
  const hmrBridge = options.hmr
    ? createHmrBridge({
        path: HMR_PATH,
        silent: extras.silent,
        forwardClientLogs: options.bundle.extra?.forwardClientLogs,
      })
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
        // 5s timeout — dev-middleware 미설치/hang 시 무한 대기 회피.
        fetch(`${httpHandle.url}/open-debugger`, {
          method: 'POST',
          signal: AbortSignal.timeout(5000),
        }).catch((err) => {
          logError(
            `Failed to open DevTools: ${(err as Error).message ?? err}. ` +
              `'@react-native/dev-middleware' peer dependency 설치 확인.`,
          );
        });
      },
      onClearCache: () => {
        for (const state of platforms.platforms.values()) {
          state.bundle = null;
          state.buildError = null;
          state.sourceMapCache = null;
        }
      },
      onToggleLogs: () => hmrBridge?.toggleLogs() ?? true,
    },
    { enabled: options.terminalActions },
  );
  if (!extras.silent) {
    logInfo(`Dev server listening on ${httpHandle.url} (platform=${options.bundle.rnPlatform})`);
    if (options.terminalActions) printDefaultShortcuts();
  }

  // shuttingDown — SIGINT 두 번/SIGINT+SIGTERM 동시 도착 재진입 차단. handle.stop()
  // 에서 listener 제거해 다중 serveRn() 호출 시 핸들러 누적 방지.
  let signalCleanup: (() => void) | null = null;
  if (extras.installSignalHandlers !== false) {
    let shuttingDown = false;
    const handleSignal = (signal: NodeJS.Signals): void => {
      if (shuttingDown) return;
      shuttingDown = true;
      if (!extras.silent) logInfo(`${signal} received, shutting down...`);
      void (async () => {
        try {
          terminalCleanup();
          await httpHandle.stop();
          await platforms.stopAll();
        } catch (err) {
          logError(`Shutdown error: ${(err as Error).message ?? err}`);
          process.exit(1);
        }
        if (!extras.silent) logInfo('Server stopped');
        process.exit(0);
      })();
    };
    process.on('SIGINT', handleSignal);
    process.on('SIGTERM', handleSignal);
    signalCleanup = () => {
      process.off('SIGINT', handleSignal);
      process.off('SIGTERM', handleSignal);
    };
  }

  return {
    url: httpHandle.url,
    port: httpHandle.port,
    hmrBridge,
    platforms,
    async stop() {
      signalCleanup?.();
      terminalCleanup();
      await httpHandle.stop();
      await platforms.stopAll();
    },
  };
}
