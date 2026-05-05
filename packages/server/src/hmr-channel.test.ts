import { describe, expect, test } from 'bun:test';
import { Buffer } from 'node:buffer';
import { EventEmitter } from 'node:events';
import type { IncomingMessage } from 'node:http';
import type { Socket } from 'node:net';

import { type BunHmrClient, createHmrChannel } from './hmr-channel.ts';
import { HMR_MSG } from './protocol.ts';

class MockSocket extends EventEmitter {
  written: Buffer[] = [];
  destroyed = false;
  destroyCalls = 0;
  write(chunk: Buffer | string): boolean {
    this.written.push(typeof chunk === 'string' ? Buffer.from(chunk) : Buffer.from(chunk));
    return true;
  }
  destroy(): void {
    this.destroyed = true;
    this.destroyCalls += 1;
  }
}

function asSocket(s: MockSocket): Socket {
  return s as unknown as Socket;
}

function fakeUpgradeRequest(key: string | undefined): IncomingMessage {
  return {
    headers: key === undefined ? {} : { 'sec-websocket-key': key },
  } as unknown as IncomingMessage;
}

function payloadOf(socket: MockSocket, frameIndex: number): string {
  const frame = socket.written[frameIndex]!;
  // server text frame: header 2~10 byte, payload 그 뒤. 단순 case (< 126) 는 frame[1] 가 length.
  const len = frame[1]!;
  if (len <= 125) return frame.slice(2).toString('utf8');
  // tests below 는 짧은 payload 만 사용 — 안전.
  throw new Error('unexpected long payload in test');
}

class MockBunClient implements BunHmrClient {
  sent: string[] = [];
  send(text: string): void {
    this.sent.push(text);
  }
}

describe('createHmrChannel — accept (Node upgrade)', () => {
  test('정상 key 로 handshake + connected 메시지', () => {
    const ch = createHmrChannel();
    const socket = new MockSocket();
    ch.accept(fakeUpgradeRequest('dGhlIHNhbXBsZSBub25jZQ=='), asSocket(socket));
    expect(socket.written.length).toBe(2);
    const handshake = socket.written[0]!.toString('utf8');
    expect(handshake.startsWith('HTTP/1.1 101')).toBe(true);
    expect(handshake).toContain('Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
    expect(payloadOf(socket, 1)).toBe(JSON.stringify({ type: HMR_MSG.Connected }));
    expect(ch.clientCount).toBe(1);
  });

  test('missing sec-websocket-key 면 destroy + 등록 안 함', () => {
    const ch = createHmrChannel();
    const socket = new MockSocket();
    ch.accept(fakeUpgradeRequest(undefined), asSocket(socket));
    expect(socket.destroyed).toBe(true);
    expect(socket.written.length).toBe(0);
    expect(ch.clientCount).toBe(0);
  });

  test('close 이벤트 시 client 자동 정리', () => {
    const ch = createHmrChannel();
    const socket = new MockSocket();
    ch.accept(fakeUpgradeRequest('k'), asSocket(socket));
    expect(ch.clientCount).toBe(1);
    socket.emit('close');
    expect(ch.clientCount).toBe(0);
  });

  test('error 이벤트 시 client 자동 정리', () => {
    const ch = createHmrChannel();
    const socket = new MockSocket();
    ch.accept(fakeUpgradeRequest('k'), asSocket(socket));
    socket.emit('error', new Error('x'));
    expect(ch.clientCount).toBe(0);
  });

  test('currentError 가 있으면 새 connection 에도 송출', () => {
    const ch = createHmrChannel();
    ch.reportError([{ text: 'boom' }]);
    const socket = new MockSocket();
    ch.accept(fakeUpgradeRequest('k'), asSocket(socket));
    // [0]=handshake, [1]=connected, [2]=error
    expect(socket.written.length).toBe(3);
    const errorPayload = JSON.parse(payloadOf(socket, 2));
    expect(errorPayload.type).toBe(HMR_MSG.Error);
    expect(errorPayload.errors).toEqual([{ file: '', message: 'boom' }]);
  });
});

describe('createHmrChannel — Bun client', () => {
  test('addBunClient 시 connected 메시지 즉시 송출', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    expect(ws.sent).toEqual([JSON.stringify({ type: HMR_MSG.Connected })]);
    expect(ch.clientCount).toBe(1);
  });

  test('currentError 가 있으면 새 Bun client 에도 송출', () => {
    const ch = createHmrChannel();
    ch.reportError([{ text: 'boom' }]);
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    expect(ws.sent.length).toBe(2);
    const errorPayload = JSON.parse(ws.sent[1]!);
    expect(errorPayload.type).toBe(HMR_MSG.Error);
  });

  test('removeBunClient 후 broadcast 도달 안 함', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    ch.removeBunClient(ws);
    ch.broadcast({ type: HMR_MSG.FullReload, timestamp: 1 });
    // connected 1회만 — broadcast 추가 도달 X
    expect(ws.sent.length).toBe(1);
    expect(ch.clientCount).toBe(0);
  });
});

describe('createHmrChannel — broadcast', () => {
  test('Node + Bun 양쪽 모두에 동일 payload 송출', () => {
    const ch = createHmrChannel();
    const node = new MockSocket();
    const bun = new MockBunClient();
    ch.accept(fakeUpgradeRequest('k'), asSocket(node));
    ch.addBunClient(bun);

    ch.broadcast({ type: HMR_MSG.FullReload, timestamp: 999 });

    // node: [0]=handshake, [1]=connected, [2]=full-reload
    expect(JSON.parse(payloadOf(node, 2))).toEqual({ type: HMR_MSG.FullReload, timestamp: 999 });
    // bun: [0]=connected, [1]=full-reload
    expect(JSON.parse(bun.sent[1]!)).toEqual({ type: HMR_MSG.FullReload, timestamp: 999 });
  });

  test('CssUpdate broadcast', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    ch.broadcast({ type: HMR_MSG.CssUpdate, href: '/a.css', timestamp: 1 });
    expect(JSON.parse(ws.sent[1]!)).toEqual({
      type: HMR_MSG.CssUpdate,
      href: '/a.css',
      timestamp: 1,
    });
  });
});

describe('createHmrChannel — error 관리', () => {
  test('reportError 는 latch + broadcast 동시 수행', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    ch.reportError([{ text: 'x' }]);
    expect(ws.sent.length).toBe(2);
    const payload = JSON.parse(ws.sent[1]!);
    expect(payload.type).toBe(HMR_MSG.Error);
    expect(payload.errors).toEqual([{ file: '', message: 'x' }]);
  });

  test('reportThrownError 는 stack 추출 후 reportError 로', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    const err = new Error('boom');
    ch.reportThrownError(err);
    const payload = JSON.parse(ws.sent[1]!);
    expect(payload.errors[0].message).toContain('Error: boom');
  });

  test('reportThrownError — stack 없으면 message fallback', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    ch.reportThrownError({ message: 'no stack' });
    const payload = JSON.parse(ws.sent[1]!);
    expect(payload.errors[0].message).toBe('no stack');
  });

  test('reportThrownError — string 입력은 String() fallback', () => {
    const ch = createHmrChannel();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    ch.reportThrownError('plain string');
    const payload = JSON.parse(ws.sent[1]!);
    expect(payload.errors[0].message).toBe('plain string');
  });

  test('clearError 후 새 connection 은 error 안 받음', () => {
    const ch = createHmrChannel();
    ch.reportError([{ text: 'x' }]);
    ch.clearError();
    const ws = new MockBunClient();
    ch.addBunClient(ws);
    expect(ws.sent.length).toBe(1);
  });

  test('latched error 는 1회 stringify — 새 client 에 cached text 재사용', () => {
    const ch = createHmrChannel();
    // reportError 시 1회 stringify (broadcast 용).
    ch.reportError([{ text: 'x' }]);

    const seen: string[] = [];
    const ws1 = { send: (t: string) => seen.push(t) };
    const ws2 = { send: (t: string) => seen.push(t) };
    ch.addBunClient(ws1);
    ch.addBunClient(ws2);

    // 두 client 가 받은 error payload 가 같은 string instance (cache 동작).
    // ws1.sent[1] = error, ws2.sent[1] = error
    expect(seen.length).toBe(4); // ws1 connected + error + ws2 connected + error
    expect(seen[1]).toBe(seen[3]);
    // 그리고 같은 문자열은 reportError 시 만들어진 것이라 string 동치.
    const errPayload = JSON.parse(seen[1]!);
    expect(errPayload.errors).toEqual([{ file: '', message: 'x' }]);
  });
});
