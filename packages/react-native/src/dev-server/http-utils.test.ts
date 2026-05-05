import { describe, expect, test } from 'bun:test';
import type { IncomingMessage } from 'node:http';
import { Readable } from 'node:stream';

import { parseRequestUrl, readJsonBody, sendJson, sendText } from './http-utils.ts';

interface MockRes {
  statusCode?: number;
  headers?: Record<string, unknown>;
  body?: string;
  writeHead(code: number, headers: Record<string, unknown>): void;
  end(body: string): void;
}

function createMockRes(): MockRes {
  return {
    writeHead(code, headers) {
      this.statusCode = code;
      this.headers = headers;
    },
    end(body) {
      this.body = body;
    },
  };
}

describe('sendText / sendJson', () => {
  test('sendText — text/plain default + 정확한 byteLength', () => {
    const res = createMockRes();
    sendText(res as never, 200, 'ok');
    expect(res.statusCode).toBe(200);
    expect(res.headers).toEqual({ 'Content-Type': 'text/plain', 'Content-Length': 2 });
    expect(res.body).toBe('ok');
  });

  test('sendText — contentType override', () => {
    const res = createMockRes();
    sendText(res as never, 200, '<html/>', 'text/html');
    expect(res.headers!['Content-Type']).toBe('text/html');
  });

  test('sendText — non-2xx', () => {
    const res = createMockRes();
    sendText(res as never, 404, 'Not Found');
    expect(res.statusCode).toBe(404);
  });

  test('sendJson — object stringify + Content-Length 일치', () => {
    const res = createMockRes();
    sendJson(res as never, 200, { ok: true });
    expect(res.statusCode).toBe(200);
    expect(res.headers).toEqual({
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(JSON.stringify({ ok: true })),
    });
    expect(JSON.parse(res.body!)).toEqual({ ok: true });
  });

  test('sendJson — UTF-8 멀티바이트 byteLength', () => {
    const res = createMockRes();
    sendJson(res as never, 200, { msg: '안녕' });
    const expected = JSON.stringify({ msg: '안녕' });
    expect(res.headers!['Content-Length']).toBe(Buffer.byteLength(expected));
  });
});

describe('parseRequestUrl', () => {
  test('req.url + req.headers.host 기준', () => {
    const req = { url: '/x?p=1', headers: { host: 'h:8081' } } as unknown as IncomingMessage;
    const url = parseRequestUrl(req, 'ignored', 9999);
    expect(url.pathname).toBe('/x');
    expect(url.searchParams.get('p')).toBe('1');
  });

  test('host header 미지정 시 fallback', () => {
    const req = { url: '/y', headers: {} } as unknown as IncomingMessage;
    const url = parseRequestUrl(req, '0.0.0.0', 8081);
    expect(url.host).toBe('0.0.0.0:8081');
    expect(url.pathname).toBe('/y');
  });

  test('req.url 미지정 시 / fallback', () => {
    const req = { url: undefined, headers: {} } as unknown as IncomingMessage;
    expect(parseRequestUrl(req, 'h', 1).pathname).toBe('/');
  });
});

interface MockReq extends Readable {
  complete?: boolean;
  body?: unknown;
  rawBody?: unknown;
}

function streamReq(json: string, opts: { complete?: boolean; readable?: boolean } = {}): MockReq {
  const r = new Readable({ read() {} }) as MockReq;
  r.push(json);
  r.push(null);
  if (opts.complete !== undefined) r.complete = opts.complete;
  return r;
}

describe('readJsonBody — stream path', () => {
  test('stream 으로 도착한 JSON 파싱', async () => {
    const req = streamReq('{"a":1}');
    const body = await readJsonBody<{ a: number }>(req as never);
    expect(body).toEqual({ a: 1 });
  });

  test('invalid JSON → reject', async () => {
    const req = streamReq('not json');
    await expect(readJsonBody(req as never)).rejects.toThrow();
  });

  test('stream error → reject', async () => {
    const r = new Readable({ read() {} }) as MockReq;
    setImmediate(() => r.destroy(new Error('boom')));
    await expect(readJsonBody(r as never)).rejects.toThrow('boom');
  });
});

describe('readJsonBody — augmented (drained) path', () => {
  function drainedReq(augment: { body?: unknown; rawBody?: unknown }): MockReq {
    // augmented (express body parser drained) path 시뮬레이션 — req.complete=true,
    // req.readable=false 인 IncomingMessage shape. 실제 Readable 을 안 만들고
    // duck-typed object 를 넘겨도 readJsonBody 는 augmented 분기만 탐.
    return Object.assign({ complete: true, readable: false }, augment) as MockReq;
  }

  test('req.body (object) 우선 사용', async () => {
    const req = drainedReq({ body: { x: 2 } });
    expect(await readJsonBody<{ x: number }>(req as never)).toEqual({ x: 2 });
  });

  test('req.body (string) JSON parse', async () => {
    const req = drainedReq({ body: '{"x":3}' });
    expect(await readJsonBody<{ x: number }>(req as never)).toEqual({ x: 3 });
  });

  test('req.body (Buffer) JSON parse', async () => {
    const req = drainedReq({ body: Buffer.from('{"x":4}', 'utf-8') });
    expect(await readJsonBody<{ x: number }>(req as never)).toEqual({ x: 4 });
  });

  test('body 없으면 rawBody fallback', async () => {
    const req = drainedReq({ rawBody: '{"y":5}' });
    expect(await readJsonBody<{ y: number }>(req as never)).toEqual({ y: 5 });
  });

  test('둘 다 없으면 빈 객체', async () => {
    const req = drainedReq({});
    expect(await readJsonBody(req as never)).toEqual({});
  });
});
