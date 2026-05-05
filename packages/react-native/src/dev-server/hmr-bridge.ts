// HMR bridge — PlatformState 의 onRebuild 콜백을 MetroHmrAdapter 의 메시지
// 송출로 연결 + WS upgrade (`/hot`) handler 등록. graph 변경은 reload, module
// 변경은 update sequence (start → update → done), build error 는 error 메시지.
//
// per-module sourceMappingURL 주석 — eval 된 update.code 끝에 라우트 (PR #D 의
// `/__zts_hmr_map/<id>`) 를 가리키는 주석을 붙여 DevTools 가 lazy fetch 가능
// (관심사 분리: emitter 가 sourceURL 주입, dev server 가 sourceMappingURL).

import type { Server } from "node:http";
import type { Socket } from "node:net";

import type { WatchRebuildEvent } from "@zts/core";

import { createMetroHmrAdapter, type MetroHmrAdapter } from "../metro-hmr-adapter.ts";
import { parseRequestUrl } from "./http-utils.ts";
import type { PlatformState, PlatformStateCallbacks } from "./platform-state.ts";

export interface HmrBridgeOptions {
  /** ws path. Metro 호환 default `/hot`. */
  readonly path: string;
  /** request 의 fallback host/port — parseRequestUrl 호출에 필요. */
  readonly host: string;
  readonly port: number;
}

export interface HmrBridge {
  readonly adapter: MetroHmrAdapter;
  readonly callbacks: PlatformStateCallbacks;
  attachToServer(server: Server): void;
}

function annotateUpdates(
  updates: ReadonlyArray<{ id: string; code: string }>,
  platform: "ios" | "android",
): Array<{ id: string; code: string }> {
  return updates.map((u) => {
    const sourceMappingURL = `/__zts_hmr_map/${encodeURIComponent(u.id)}?platform=${platform}`;
    return { ...u, code: `${u.code}\n//# sourceMappingURL=${sourceMappingURL}\n` };
  });
}

function buildOnRebuild(adapter: MetroHmrAdapter) {
  return (state: PlatformState, event: WatchRebuildEvent): void => {
    if (!event.success) {
      adapter.sendError(state.buildError ?? event.error ?? "Unknown build error");
      return;
    }
    if (event.graphChanged) {
      adapter.sendReload();
      return;
    }
    if (event.updates && event.updates.length > 0) {
      const annotated = annotateUpdates(
        event.updates as ReadonlyArray<{ id: string; code: string }>,
        state.platform,
      );
      adapter.sendUpdate(annotated);
    }
  };
}

export function createHmrBridge(options: HmrBridgeOptions): HmrBridge {
  const adapter = createMetroHmrAdapter();
  const onRebuild = buildOnRebuild(adapter);

  return {
    adapter,
    callbacks: { onRebuild },
    attachToServer(server) {
      server.on("upgrade", (req, socket, _head) => {
        const url = parseRequestUrl(req, options.host, options.port);
        if (url.pathname === options.path) {
          // Duplex (http upgrade) → net.Socket cast — HmrChannel 이 raw socket 로
          // handshake response write. Node http upgrade 의 socket 은 항상 net.Socket.
          adapter.channel.accept(req, socket as Socket);
          // Initial greeting — RN HMRClient 의 isInitialUpdate 로 'Refreshing...' 배너 회피.
          adapter.sendInitialGreeting();
        }
        // 다른 path 는 다른 upgrade handler 가 처리 (PR #G 가 cli-server-api 의
        // websocket endpoints 추가 시 chain). 여기선 destroy 안 함.
      });
    },
  };
}
