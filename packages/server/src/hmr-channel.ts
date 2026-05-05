import type { IncomingMessage } from "node:http";
import type { Socket } from "node:net";

import {
  HMR_MSG,
  type HmrError,
  type HmrErrorMessage,
  type HmrMessage,
  type HmrRnMessage,
  normalizeHmrErrors,
} from "./protocol.ts";
import { buildHandshakeResponse, writeTextFrame } from "./ws-frame.ts";

/**
 * Bun.serve `WebSocket` 의 최소 표면. Bun runtime 의 ws 객체와 호환.
 * Node 의 raw socket 은 별도 path (`accept`) 에서 처리.
 */
export interface BunHmrClient {
  send(text: string): void;
}

export interface HmrChannel {
  /** Node `http.Server` 의 `'upgrade'` 이벤트 핸들러로 사용. */
  accept(req: IncomingMessage, socket: Socket): void;
  /** Bun.serve 의 WebSocket client 등록. */
  addBunClient(ws: BunHmrClient): void;
  removeBunClient(ws: BunHmrClient): void;
  /**
   * 모든 client (Node + Bun) 에 메시지 송출. web overlay 의 `HmrMessage` 또는
   * RN Metro 호환 `HmrRnMessage` (#2540) 모두 허용. send impl 은 JSON.stringify
   * 만 — 메시지 schema 검증은 caller 책임 (type-safe 호출).
   */
  broadcast(message: HmrMessage | HmrRnMessage): void;
  /** Build error 를 전체 broadcast + 새 connection 에도 자동 송출. */
  reportError(errors: readonly unknown[] | unknown): void;
  /** 런타임 throw 를 stack 추출해 reportError 로 전달. */
  reportThrownError(error: unknown): void;
  /** 현재 latched error 해제. */
  clearError(): void;
  /** Test 전용 — 현재 등록된 client 수. production 사용 비추. */
  readonly clientCount: number;
}

interface WithStack {
  stack?: unknown;
  message?: unknown;
}

function extractErrorText(error: unknown): string {
  // zts.mjs parity (L1169): truthy chain — 빈 string 은 다음 fallback 으로 떨어짐.
  const e = (error ?? {}) as WithStack;
  return (
    (typeof e.stack === "string" && e.stack) ||
    (typeof e.message === "string" && e.message) ||
    String(error)
  );
}

export function createHmrChannel(): HmrChannel {
  const nodeSockets = new Set<Socket>();
  const bunClients = new Set<BunHmrClient>();
  const connectedText = JSON.stringify({ type: HMR_MSG.Connected } satisfies HmrMessage);
  let currentError: HmrErrorMessage | null = null;
  // Latched error text 캐시 — N client 마다 N+1 stringify 회피 (`connected` 와 동일 패턴).
  let currentErrorText: string | null = null;

  function broadcastText(text: string): void {
    for (const socket of nodeSockets) writeTextFrame(socket, text);
    for (const ws of bunClients) ws.send(text);
  }

  function greetNode(socket: Socket): void {
    writeTextFrame(socket, connectedText);
    if (currentErrorText) writeTextFrame(socket, currentErrorText);
  }

  function greetBun(ws: BunHmrClient): void {
    ws.send(connectedText);
    if (currentErrorText) ws.send(currentErrorText);
  }

  return {
    accept(req, socket) {
      const key = req.headers["sec-websocket-key"];
      if (typeof key !== "string") {
        socket.destroy();
        return;
      }
      socket.write(buildHandshakeResponse(key));
      nodeSockets.add(socket);
      socket.on("close", () => nodeSockets.delete(socket));
      socket.on("error", () => nodeSockets.delete(socket));
      greetNode(socket);
    },
    addBunClient(ws) {
      bunClients.add(ws);
      greetBun(ws);
    },
    removeBunClient(ws) {
      bunClients.delete(ws);
    },
    broadcast(message) {
      broadcastText(JSON.stringify(message));
    },
    reportError(errors) {
      currentError = {
        type: HMR_MSG.Error,
        errors: normalizeHmrErrors(errors as HmrError[]),
        timestamp: Date.now(),
      };
      currentErrorText = JSON.stringify(currentError);
      broadcastText(currentErrorText);
    },
    reportThrownError(error) {
      this.reportError([{ text: extractErrorText(error) }]);
    },
    clearError() {
      currentError = null;
      currentErrorText = null;
    },
    get clientCount() {
      return nodeSockets.size + bunClients.size;
    },
  };
}
