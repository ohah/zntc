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

import type { BunHmrClient } from '@zntc/server';

import { createMetroHmrAdapter, type MetroHmrAdapter } from '../metro-hmr-adapter.ts';
import { colors, formatLogBadge, logError, logInfo } from './logger.ts';
import type { PlatformState, PlatformStateCallbacks } from './platform-state.ts';

export interface HmrBridgeOptions {
  /** ws path. Metro 호환 default `/hot`. */
  readonly path: string;
  /** rebuild log 출력 비활성 (test 환경). default false. */
  readonly silent?: boolean;
  /** Metro `server.forwardClientLogs` 호환. default true. */
  readonly forwardClientLogs?: boolean;
}

export interface HmrBridge {
  readonly adapter: MetroHmrAdapter;
  readonly callbacks: PlatformStateCallbacks;
  readonly path: string;
  /** http upgrade chain 안에서 호출 (Node) — channel.accept + initial greeting. */
  acceptUpgrade(req: IncomingMessage, socket: Socket): void;
  /**
   * Bun.serve websocket `open(ws)` 에서 호출 — Bun client 등록 + initial greeting.
   * Node 의 `acceptUpgrade` 와 대칭이지만 raw socket 핸드셰이크가 없다 (Bun.serve
   * 의 `server.upgrade(req)` 가 RFC6455 핸드셰이크를 native 로 처리하므로).
   */
  acceptBun(ws: BunHmrClient): void;
  /** Bun.serve websocket `close(ws)` 에서 호출 — Bun client 정리. */
  removeBun(ws: BunHmrClient): void;
  /**
   * Bun.serve websocket `message(ws, msg)` 에서 호출 — client → server text 를
   * incoming 핸들러(register-entrypoints ACK / log forwarding)로 dispatch.
   * Node 경로는 `channel.accept` 의 `socket.on('data')` 가 같은 역할.
   */
  handleBunMessage(ws: BunHmrClient, text: string): void;
  /** RN runtime console.log forwarding 출력 표시 toggle. 새 상태 반환. */
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
  // reply 는 channel 이 주입 — Node 는 raw socket 의 text frame, Bun 은 ws.send.
  // 둘 다 plain text 만 받으므로 핸들러는 runtime 무관(ACK_TEXT 그대로 전달).
  return (text: string, reply: (text: string) => void): void => {
    let msg: { type?: string; level?: string; data?: unknown } | null = null;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (!msg || typeof msg.type !== 'string') return;
    if (msg.type === 'register-entrypoints') {
      // single-client ACK — broadcast 가 아니라 요청한 client 에게만 응답.
      reply(ACK_TEXT);
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

// RN HMR client 의 register-entrypoints 에 대한 ACK payload. 프레이밍(RFC6455
// text frame)은 channel 의 reply 가 담당 — 여기선 plain text 만.
const ACK_TEXT = JSON.stringify({ type: 'bundle-registered' });

export function createHmrBridge(options: HmrBridgeOptions): HmrBridge {
  const adapter = createMetroHmrAdapter();
  const onRebuild = buildOnRebuild(adapter, { silent: options.silent });
  let logsEnabled = options.forwardClientLogs !== false;
  adapter.channel.onIncoming(buildIncomingHandler(adapter, () => logsEnabled));

  return {
    adapter,
    callbacks: { onRebuild },
    path: options.path,
    acceptUpgrade(req, socket) {
      adapter.channel.accept(req, socket);
      adapter.sendInitialGreeting();
    },
    acceptBun(ws) {
      adapter.channel.addBunClient(ws);
      adapter.sendInitialGreeting();
    },
    removeBun(ws) {
      adapter.channel.removeBunClient(ws);
    },
    handleBunMessage(ws, text) {
      adapter.channel.dispatchBunIncoming(ws, text);
    },
    toggleLogs() {
      logsEnabled = !logsEnabled;
      return logsEnabled;
    },
  };
}
