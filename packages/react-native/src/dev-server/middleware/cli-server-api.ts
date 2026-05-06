// @react-native-community/cli-server-api lazy load — Metro 호환 websocket
// endpoints (`/message` / `/events` / `/devtools`) + messageSocketEndpoint.broadcast.
// peer optional 이라 미설치 시 graceful skip — 본 dev server 는 broadcast
// 없이도 base/asset/bundle/symbolicate 라우트는 동작 (HMR adapter 가 자체
// broadcast 처리).

import type { IncomingMessage } from 'node:http';
import { createRequire } from 'node:module';
import type { Duplex } from 'node:stream';

import type { Broadcast } from '../types.ts';

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
  /**
   * peer dependency resolve base — 사용자 프로젝트 root. cli-server-api 가
   * `@zts/react-native/node_modules` 가 아니라 caller (예: `examples/react-native-bare`)
   * 의 node_modules 에 설치된 경우 dynamic import 가 못 찾는 문제 회피용.
   * 미지정 시 `process.cwd()`.
   */
  projectRoot?: string;
}

/**
 * `@react-native-community/cli-server-api` 의 `createDevServerMiddleware` 실행
 * 결과 wrapping. 미설치 시 null. caller 가 broadcast 가 필요하면 fallback.
 *
 * `ZTS_DEBUG_TERMINAL=1` 시 import 실패 reason 을 stderr 출력 — 사용자가
 * cli-server-api 미설치인지 다른 이유인지 추적. peer 미설치는 흔한 케이스라
 * default 는 silent.
 */
export async function loadCliServerApi(
  options: LoadCliServerApiOptions,
): Promise<CliServerApi | null> {
  try {
    // peer optional — caller (사용자 프로젝트) 의 node_modules 기준으로 resolve.
    // dynamic `await import('@...')` 만 쓰면 import 호출하는 모듈 (`@zts/react-native/dist`)
    // 의 node_modules 기준이라 caller 측 peer 를 못 찾음. createRequire(projectRoot)
    // 로 user-side resolve 우선.
    const projectRoot = options.projectRoot ?? process.cwd();
    const projectRequire = createRequire(`${projectRoot}/package.json`);
    const resolvedPath = projectRequire.resolve('@react-native-community/cli-server-api');
    const mod = (await import(resolvedPath)) as unknown as {
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
  } catch (err) {
    if (process.env.ZTS_DEBUG_TERMINAL === '1') {
      process.stderr.write(
        `[zts:rn-dev:debug] cli-server-api load failed: ${(err as Error)?.message ?? err}\n`,
      );
    }
    return null;
  }
}
