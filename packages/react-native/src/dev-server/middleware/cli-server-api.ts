// @react-native-community/cli-server-api — Metro 호환 websocket endpoints
// (`/message` / `/events` / `/debugger-proxy`) + messageSocketEndpoint.broadcast.
// `@zts/react-native` 의 dependency 로 자동 install (번개 parity) — 사용자
// 프로젝트가 별도 버전을 hoist 하면 caller projectRoot 기준 resolve 우선.

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
/**
 * caller projectRoot → @zts/react-native → process.cwd 순으로 resolve 시도.
 * 사용자 프로젝트가 `@react-native-community/cli-server-api` 를 hoist 했으면
 * 그 instance 가 우선 (RN runtime 과의 module identity 보장 — Rozenite 같은
 * monkey-patch 도구 호환).
 */
function resolveCliServerApiPath(projectRoot: string | undefined): string {
  const candidates: Array<() => string> = [];
  if (projectRoot) {
    const projectRequire = createRequire(`${projectRoot}/package.json`);
    candidates.push(() => projectRequire.resolve('@react-native-community/cli-server-api'));
  }
  // `@zts/react-native` 자체 dependency — workspace install 시 자동 hoist.
  const selfRequire = createRequire(import.meta.url);
  candidates.push(() => selfRequire.resolve('@react-native-community/cli-server-api'));
  for (const c of candidates) {
    try {
      return c();
    } catch {
      /* try next */
    }
  }
  return '@react-native-community/cli-server-api';
}

export async function loadCliServerApi(
  options: LoadCliServerApiOptions,
): Promise<CliServerApi | null> {
  try {
    const resolvedPath = resolveCliServerApiPath(options.projectRoot);
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
