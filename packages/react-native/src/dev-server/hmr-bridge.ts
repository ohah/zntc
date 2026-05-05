// HMR bridge — PlatformState 의 onRebuild 콜백을 MetroHmrAdapter 의 메시지
// 송출로 연결 + WS path 노출. graph 변경은 reload, module 변경은 update
// sequence (start → update → done), build error 는 error 메시지.
//
// per-module sourceMappingURL 주석 — eval 된 update.code 끝에 라우트 (`/__zts_hmr_map/`)
// 를 가리키는 주석을 붙여 DevTools 가 lazy fetch 가능 (관심사 분리: emitter
// 가 sourceURL 주입, dev server 가 sourceMappingURL).

import type { IncomingMessage } from "node:http";
import type { Socket } from "node:net";

import type { WatchRebuildEvent } from "@zts/core";

import { createMetroHmrAdapter, type MetroHmrAdapter } from "../metro-hmr-adapter.ts";
import type { PlatformState, PlatformStateCallbacks } from "./platform-state.ts";

export interface HmrBridgeOptions {
  /** ws path. Metro 호환 default `/hot`. */
  readonly path: string;
}

export interface HmrBridge {
  readonly adapter: MetroHmrAdapter;
  readonly callbacks: PlatformStateCallbacks;
  readonly path: string;
  /** http upgrade chain 안에서 호출 — channel.accept + initial greeting. */
  acceptUpgrade(req: IncomingMessage, socket: Socket): void;
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
    path: options.path,
    acceptUpgrade(req, socket) {
      adapter.channel.accept(req, socket);
      adapter.sendInitialGreeting();
    },
  };
}
