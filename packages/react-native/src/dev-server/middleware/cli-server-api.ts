// @react-native-community/cli-server-api lazy load — Metro 호환 websocket
// endpoints (`/message` / `/events` / `/devtools`) + messageSocketEndpoint.broadcast.
// peer optional 이라 미설치 시 graceful skip — 본 dev server 는 broadcast
// 없이도 base/asset/bundle/symbolicate 라우트는 동작 (HMR adapter 가 자체
// broadcast 처리).

import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";

import type { Broadcast } from "../types.ts";

export interface CliWebsocketEndpoint {
  handleUpgrade(
    req: IncomingMessage,
    socket: Duplex,
    head: Buffer,
    callback: (ws: unknown) => void,
  ): void;
  emit(event: string, ws: unknown, req: IncomingMessage): void;
}

export interface CliServerApi {
  /** ws path → endpoint. /message, /events, /debugger-proxy 등. */
  websocketEndpoints: Record<string, CliWebsocketEndpoint>;
  /** 모든 ws client 에 broadcast — RN runtime 의 `/reload` / `/devmenu` 메시지. */
  broadcast: Broadcast;
}

export interface LoadCliServerApiOptions {
  port: number;
  host: string;
}

/**
 * `@react-native-community/cli-server-api` 의 `createDevServerMiddleware` 실행
 * 결과 wrapping. 미설치 시 null. caller 가 broadcast 가 필요하면 fallback.
 */
export async function loadCliServerApi(
  options: LoadCliServerApiOptions,
): Promise<CliServerApi | null> {
  try {
    // dynamic import — peer optional. tsc 의 module resolution 회피하려 string
    // variable 로 우회 (peer 미설치 환경에서 type-check 통과).
    const specifier: string = "@react-native-community/cli-server-api";
    const mod = (await import(specifier)) as unknown as {
      createDevServerMiddleware: (input: {
        port: number;
        host: string;
        watchFolders: string[];
      }) => {
        websocketEndpoints: Record<string, CliWebsocketEndpoint>;
        messageSocketEndpoint: {
          broadcast: Broadcast;
        };
      };
    };
    const result = mod.createDevServerMiddleware({
      port: options.port,
      host: options.host,
      watchFolders: [], // dev server 의 HMR bridge 가 변경 추적 — cli watch 비활성.
    });
    return {
      websocketEndpoints: result.websocketEndpoints,
      broadcast: result.messageSocketEndpoint.broadcast,
    };
  } catch {
    return null;
  }
}
