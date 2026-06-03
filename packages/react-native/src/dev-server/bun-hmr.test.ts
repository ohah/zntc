// #RN-bun-hmr 회귀 테스트 — Bun 에서 `/hot` HMR WebSocket 이 OPEN 되는지.
//
// 배경: node:http 의 수동 RFC6455 핸드셰이크(socket.write("HTTP/1.1 101 ..."))는
// Bun 의 node:http 호환층에서 101 응답이 TCP 로 전달 안 돼 client 가 OPEN/CLOSE
// 둘 다 못 받고 timeout 한다(node 는 정상). 이 테스트는 그 최소 재현을 실제
// dev http server(createBunDevHttpServer) 위에서 재현해, Bun.serve native
// WebSocket 경로로 /hot 이 정상 연결되는지 검증한다.
//
// 이 테스트 파일은 bun:test 로만 실행된다(WebSocket 글로벌 + Bun.serve 필요).

import { describe, expect, test } from 'bun:test';

import { createBunDevHttpServer, type DevHttpServerHandle } from './http-server.ts';
import { createHmrBridge } from './hmr-bridge.ts';
import { buildRnDevServerOptions } from './options.ts';
import type { PlatformStateRegistry } from './platform-state.ts';

const BUNDLE = {
  entry: '/proj/src/index.ts',
  projectRoot: '/proj',
  rnPlatform: 'ios' as const,
  dev: true,
};

const noopPlatforms: PlatformStateRegistry = {
  platforms: new Map(),
  getOrCreate: () => {
    throw new Error('not used');
  },
  async stopAll() {},
};

/** 첫 메시지 1개를 기다리거나 timeout. close/error 도 reject 로 surfacing. */
function waitOpen(ws: WebSocket, ms: number): Promise<'open'> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('TIMEOUT: no open')), ms);
    ws.onopen = () => {
      clearTimeout(timer);
      resolve('open');
    };
    ws.onclose = (e) => {
      clearTimeout(timer);
      reject(new Error(`CLOSE before open: ${e.code}`));
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error('WS error before open'));
    };
  });
}

/** 특정 type 의 메시지가 올 때까지 수집 후 첫 일치 메시지 반환. */
function waitMessageType(
  ws: WebSocket,
  type: string,
  ms: number,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`TIMEOUT: no '${type}' message`)), ms);
    ws.addEventListener('message', (e: MessageEvent) => {
      try {
        const msg = JSON.parse(String(e.data));
        if (msg && msg.type === type) {
          clearTimeout(timer);
          resolve(msg);
        }
      } catch {
        /* ignore non-JSON */
      }
    });
  });
}

describe('createBunDevHttpServer — /hot HMR WebSocket (#RN-bun-hmr)', () => {
  test('client 가 /hot 에 OPEN + connected greeting 수신', async () => {
    const hmrBridge = createHmrBridge({ path: '/hot', silent: true });
    const handle: DevHttpServerHandle = await createBunDevHttpServer(
      buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }),
      { broadcast: () => {}, platforms: noopPlatforms, hmrBridge },
    );
    try {
      const wsUrl = `ws://localhost:${handle.port}/hot`;
      const ws = new WebSocket(wsUrl);
      // 핵심 단언: node:http 수동 핸드셰이크는 Bun 에서 여기서 timeout 한다.
      await expect(waitOpen(ws, 3000)).resolves.toBe('open');
      // greeting — connected + (initial) update-start/done sequence 중 connected 확인.
      const connected = await waitMessageType(ws, 'connected', 3000);
      expect(connected.type).toBe('connected');
      ws.close();
    } finally {
      await handle.stop();
    }
  });

  test('register-entrypoints → bundle-registered ACK (client incoming dispatch)', async () => {
    const hmrBridge = createHmrBridge({ path: '/hot', silent: true });
    const handle = await createBunDevHttpServer(
      buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }),
      { broadcast: () => {}, platforms: noopPlatforms, hmrBridge },
    );
    try {
      const ws = new WebSocket(`ws://localhost:${handle.port}/hot`);
      await waitOpen(ws, 3000);
      const ack = waitMessageType(ws, 'bundle-registered', 3000);
      ws.send(JSON.stringify({ type: 'register-entrypoints', entryPoints: [] }));
      const msg = await ack;
      expect(msg.type).toBe('bundle-registered');
      ws.close();
    } finally {
      await handle.stop();
    }
  });

  test('broadcast 가 연결된 Bun client 에 도달 (hmr:reload)', async () => {
    const hmrBridge = createHmrBridge({ path: '/hot', silent: true });
    const handle = await createBunDevHttpServer(
      buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }),
      { broadcast: () => {}, platforms: noopPlatforms, hmrBridge },
    );
    try {
      const ws = new WebSocket(`ws://localhost:${handle.port}/hot`);
      await waitOpen(ws, 3000);
      // greeting 소비 대기 후 broadcast.
      await waitMessageType(ws, 'connected', 3000);
      const reload = waitMessageType(ws, 'hmr:reload', 3000);
      hmrBridge.adapter.sendReload();
      const msg = await reload;
      expect(msg.type).toBe('hmr:reload');
      ws.close();
    } finally {
      await handle.stop();
    }
  });

  test('plain HTTP route(/status) 도 어댑터로 정상 동작', async () => {
    const handle = await createBunDevHttpServer(
      buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }),
      { broadcast: () => {}, platforms: noopPlatforms },
    );
    try {
      const res = await fetch(`http://localhost:${handle.port}/status`);
      expect(res.status).toBe(200);
      expect(res.headers.get('X-React-Native-Project-Root')).toBe('/proj');
      expect(await res.text()).toBe('packager-status:running');
    } finally {
      await handle.stop();
    }
  });

  test('POST /open-url body 가 어댑터의 rawBody 경로로 파싱됨', async () => {
    const handle = await createBunDevHttpServer(
      buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }),
      { broadcast: () => {}, platforms: noopPlatforms },
    );
    try {
      // 빈 body → 400 (open-url 핸들러가 url 누락 검증). body 가 어댑터로 전달돼
      // 파싱까지 도달했다는 증거.
      const res = await fetch(`http://localhost:${handle.port}/open-url`, {
        method: 'POST',
        body: '{}',
        headers: { 'Content-Type': 'application/json' },
      });
      expect(res.status).toBe(400);
    } finally {
      await handle.stop();
    }
  });

  test('미매치 path → 404 Not Found (terminal next)', async () => {
    const handle = await createBunDevHttpServer(
      buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }),
      { broadcast: () => {}, platforms: noopPlatforms },
    );
    try {
      const res = await fetch(`http://localhost:${handle.port}/__nope`);
      expect(res.status).toBe(404);
      expect(await res.text()).toBe('Not Found');
    } finally {
      await handle.stop();
    }
  });
});
