// HMR bridge — PlatformState 의 onRebuild 콜백을 MetroHmrAdapter 의 메시지
// 송출로 연결 + WS path 노출. graph 변경은 reload, module 변경은 update
// sequence (start → update → done), build error 는 error 메시지.
//
// per-module sourceMappingURL 주석 — eval 된 update.code 끝에 라우트 (`/__zntc_hmr_map/`)
// 를 가리키는 주석을 붙여 DevTools 가 lazy fetch 가능 (관심사 분리: emitter
// 가 sourceURL 주입, dev server 가 sourceMappingURL).

import type { IncomingMessage } from 'node:http';
import type { Socket } from 'node:net';

import type { WatchRebuildEvent } from '@zntc/core';

import { createMetroHmrAdapter, type MetroHmrAdapter } from '../metro-hmr-adapter.ts';
import { colors, formatLogBadge, logError, logInfo } from './logger.ts';
import type { PlatformState, PlatformStateCallbacks } from './platform-state.ts';

export interface HmrBridgeOptions {
  /** ws path. Metro 호환 default `/hot`. */
  readonly path: string;
  /** rebuild log 출력 비활성 (test 환경). default false. */
  readonly silent?: boolean;
}

export interface HmrBridge {
  readonly adapter: MetroHmrAdapter;
  readonly callbacks: PlatformStateCallbacks;
  readonly path: string;
  /** http upgrade chain 안에서 호출 — channel.accept + initial greeting. */
  acceptUpgrade(req: IncomingMessage, socket: Socket): void;
  /**
   * RN runtime console.log forwarding 출력 표시 toggle. 새 상태 반환. server-side
   * mute 라 클라이언트는 계속 보냄 — 트래픽 절약하려면 forwardClientLogs OFF 로 build.
   */
  toggleLogs(): boolean;
}

function annotateUpdates(
  updates: ReadonlyArray<{ id: string; code: string }>,
  platform: 'ios' | 'android',
): Array<{ id: string; code: string }> {
  return updates.map((u) => {
    const sourceMappingURL = `/__zntc_hmr_map/${encodeURIComponent(u.id)}?platform=${platform}`;
    return { ...u, code: `${u.code}\n//# sourceMappingURL=${sourceMappingURL}\n` };
  });
}

function buildOnRebuild(adapter: MetroHmrAdapter, opts: { silent?: boolean } = {}) {
  return (state: PlatformState, event: WatchRebuildEvent): void => {
    if (!event.success) {
      const errMsg = state.buildError ?? event.error ?? 'Unknown build error';
      adapter.sendError(errMsg);
      if (!opts.silent) logError(`Build failed [${state.platform}]: ${errMsg}`);
      return;
    }
    const changedCount = (event as unknown as { changed?: unknown[] }).changed?.length ?? 0;
    const ms =
      (event as unknown as { phaseDurations?: { total?: number } }).phaseDurations?.total ??
      Date.now() - state.lastRebuildTime;
    if (event.graphChanged) {
      adapter.sendReload();
      if (!opts.silent) {
        logInfo(
          `Graph changed ${colors.dim}[${state.platform}] (${changedCount} files, ${ms}ms)${colors.reset}, full reload`,
        );
      }
      return;
    }
    if (event.updates && event.updates.length > 0) {
      const annotated = annotateUpdates(
        event.updates as ReadonlyArray<{ id: string; code: string }>,
        state.platform,
      );
      adapter.sendUpdate(annotated);
      if (!opts.silent) {
        logInfo(
          `HMR update ${colors.dim}[${state.platform}] ${event.updates.length} module(s) (${ms}ms)${colors.reset}`,
        );
      }
      return;
    }
    if (!opts.silent && changedCount > 0) {
      logInfo(
        `Rebuilt ${colors.dim}[${state.platform}] (${changedCount} files, ${ms}ms, no code change)${colors.reset}`,
      );
    }
  };
}

/**
 * RN client 메시지 처리 — `register-entrypoints` ACK + `log` forwarding (RN runtime
 * 의 console.log → dev server 터미널). `getLogsEnabled` false 시 출력 skip.
 */
function buildIncomingHandler(adapter: MetroHmrAdapter, getLogsEnabled: () => boolean) {
  return (text: string, socket: import('node:net').Socket): void => {
    let msg: { type?: string; level?: string; data?: unknown } | null = null;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (!msg || typeof msg.type !== 'string') return;
    if (msg.type === 'register-entrypoints') {
      // single-client ACK — adapter.channel 의 nodeSockets[other] 에는 안 보내고
      // 이 socket 에만 직접 send. text frame builder 사용.
      socket.write(buildAckFrame());
      return;
    }
    if (msg.type === 'log') {
      if (!getLogsEnabled()) return;
      const level = typeof msg.level === 'string' ? msg.level : 'log';
      const data = Array.isArray(msg.data) ? msg.data : [msg.data];
      const formatted = data
        .map((arg) => {
          if (typeof arg === 'object' && arg !== null) {
            try {
              return JSON.stringify(arg, null, 2);
            } catch {
              return String(arg);
            }
          }
          return String(arg);
        })
        .join(' ');
      console.log(`${formatLogBadge(level)} ${formatted}`);
      // adapter 가 server-broadcast 하지 않음 — log 는 client→server one-way.
      void adapter;
    }
  };
}

const ACK_TEXT = JSON.stringify({ type: 'bundle-registered' });
function buildAckFrame(): Buffer {
  // RFC 6455 §5.2 server→client text frame (FIN + opcode 0x1). short payload.
  const payload = Buffer.from(ACK_TEXT);
  return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
}

export function createHmrBridge(options: HmrBridgeOptions): HmrBridge {
  const adapter = createMetroHmrAdapter();
  const onRebuild = buildOnRebuild(adapter, { silent: options.silent });
  let logsEnabled = true;
  adapter.channel.onIncoming(buildIncomingHandler(adapter, () => logsEnabled));

  return {
    adapter,
    callbacks: { onRebuild },
    path: options.path,
    acceptUpgrade(req, socket) {
      adapter.channel.accept(req, socket);
      adapter.sendInitialGreeting();
    },
    toggleLogs() {
      logsEnabled = !logsEnabled;
      return logsEnabled;
    },
  };
}
