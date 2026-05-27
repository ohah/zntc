// SSE / Control API 통합 테스트
//
// `zntc --serve --bundle entry.ts`를 subprocess로 띄우고, 같은 프로세스의 fetch로
// HTTP 엔드포인트(`/sse/events`, `/reset-cache`)를 검증한다.
//
// IMPORTANT: 반드시 tests/integration 디렉토리에서 `bun test`로 실행할 것.

import { describe, test, expect, afterEach } from 'bun:test';
import { waitForServer } from '@zntc/test-helpers';
import { createFixture, ZNTC_BIN } from './helpers';
import { join } from 'node:path';

interface Server {
  port: number;
  kill: () => Promise<void>;
}

async function findFreePort(): Promise<number> {
  // 임의의 미사용 포트 — listen + close 후 OS가 곧바로 재할당
  const sock = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data() {} } });
  const port = sock.port;
  sock.stop(true);
  return port;
}

async function startServer(args: string[]): Promise<Server> {
  const port = await findFreePort();
  const proc = Bun.spawn({
    cmd: [ZNTC_BIN, ...args, '--port', String(port)],
    stdout: 'pipe',
    stderr: 'pipe',
  });

  // dev server 가 bundle.js 응답 (200/500 둘 다 ready 신호) 할 때까지 최대 5초 폴링.
  await waitForServer(port, {
    host: '127.0.0.1',
    path: '/bundle.js',
    timeoutMs: 5_000,
    intervalMs: 100,
    requestTimeoutMs: 200,
    acceptStatus: (s) => s === 200 || s === 500,
  });

  return {
    port,
    kill: async () => {
      proc.kill();
      await proc.exited;
    },
  };
}

describe('Dev Server: SSE / Control API', () => {
  let killServer: (() => Promise<void>) | undefined;
  let cleanupFixture: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (killServer) {
      await killServer();
      killServer = undefined;
    }
    if (cleanupFixture) {
      await cleanupFixture();
      cleanupFixture = undefined;
    }
  });

  async function setupServer() {
    const fixture = await createFixture({
      'entry.ts': `console.log("ok");`,
    });
    cleanupFixture = fixture.cleanup;
    const server = await startServer(['--serve', '--bundle', join(fixture.dir, 'entry.ts')]);
    killServer = server.kill;
    return server;
  }

  // ─── Control API ───────────────────────────────────────────

  test('/reset-cache: 200 + JSON ok 응답', async () => {
    const server = await setupServer();
    const res = await fetch(`http://127.0.0.1:${server.port}/reset-cache`, {
      method: 'POST',
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(body.action).toBe('reset_cache');
  });

  test('/reset-cache: GET도 허용', async () => {
    const server = await setupServer();
    const res = await fetch(`http://127.0.0.1:${server.port}/reset-cache`);
    expect(res.status).toBe(200);
  });

  // ─── SSE ───────────────────────────────────────────────────

  test('/sse/events: text/event-stream 헤더 + 초기 연결 메시지', async () => {
    const server = await setupServer();
    const controller = new AbortController();
    const res = await fetch(`http://127.0.0.1:${server.port}/sse/events`, {
      signal: controller.signal,
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');

    // 첫 청크에 ": connected" 주석 포함
    const reader = res.body!.getReader();
    const { value } = await reader.read();
    const text = new TextDecoder().decode(value);
    expect(text).toContain(': connected');

    controller.abort();
    await reader.cancel().catch(() => {});
  });

  test('/sse/events: cache_reset 이벤트 broadcast', async () => {
    const server = await setupServer();
    const controller = new AbortController();
    const res = await fetch(`http://127.0.0.1:${server.port}/sse/events`, {
      signal: controller.signal,
    });
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();

    // 초기 연결 메시지 소비
    await reader.read();

    // 별도 클라이언트가 /reset-cache 호출 → SSE 이벤트 발생
    fetch(`http://127.0.0.1:${server.port}/reset-cache`, { method: 'POST' }).catch(() => {});

    // cache_reset 이벤트 수신 대기 (최대 3초)
    let received = '';
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && !received.includes('cache_reset')) {
      const { value, done } = await reader.read();
      if (done) break;
      received += decoder.decode(value);
    }
    expect(received).toContain('event: cache_reset');
    expect(received).toContain('"type":"cache_reset"');

    controller.abort();
    await reader.cancel().catch(() => {});
  });
});
