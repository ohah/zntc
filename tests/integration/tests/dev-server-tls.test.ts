/**
 * Zig dev server TLS 통합 e2e (#2538 4-2 PR-4).
 *
 * `zig-out/bin/zntc --serve --certfile cert.pem --keyfile key.pem` 으로 HTTPS dev
 * server 시작 + self-signed cert 동적 생성 + fetch (rejectUnauthorized: false) 로
 * 200/404 + Server-Sent Events CORS 헤더 + wss `/__hmr` WebSocket handshake +
 * 첫 HMR `{"type":"connected"}` frame payload 검증.
 *
 * 기존 packages/core/test/cli/serve/https/status-cors.ts 는 JS dev server
 * (node + zntc.mjs) HTTPS 검증 — 본 test 는 Zig dev server (BoringSSL TLS) 검증.
 * 두 path 가 같은 외부 동작이어야 한다. drift 가드 (parametrize both paths) 는
 * docs/BACKLOG.md 의 follow-up 항목 — 본 PR scope 외.
 *
 * Runtime: Bun-only — `tls: { rejectUnauthorized: false }` 옵션이 Bun fetch 한정.
 * Node 의 undici fetch 는 이 옵션을 무시해 self-signed cert 검증 실패로 fail.
 * 향후 node:test 마이그레이션 시 https.Agent + node:https 직접 사용 필요.
 *
 * Fixture sharing: 5 test 가 같은 server/fixture 공유 (beforeAll/afterAll). server
 * spawn + openssl cert generation cost (~150ms × 5 = 750ms) 절감 위해 — 첫 test
 * 가 server crash 유발 시 나머지 cascade fail 은 감수.
 */

import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { execSync, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZNTC_BIN } from './helpers';

async function findFreePort(): Promise<number> {
  const { createServer } = await import('node:net');
  return new Promise<number>((resolve, reject) => {
    const srv = createServer();
    srv.listen(0, () => {
      const port = (srv.address() as { port: number }).port;
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

async function waitForHttps(port: number, maxRetries = 50, intervalMs = 100): Promise<void> {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const res = await fetch(`https://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as RequestInit);
      if (res.status < 500) return;
    } catch {
      // server not ready — retry
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(
    `Zig dev server not reachable on https://localhost:${port}/ after ${maxRetries * intervalMs}ms`,
  );
}

function createFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-zig-tls-'));
  writeFileSync(
    join(dir, 'index.html'),
    '<!doctype html><html><body><h1>Zig TLS OK</h1></body></html>',
  );
  writeFileSync(join(dir, 'app.css'), 'body { background: #abc; }');
  const certFile = join(dir, 'cert.pem');
  const keyFile = join(dir, 'key.pem');
  execSync(
    `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
  );
  return { dir, certFile, keyFile };
}

/** RFC 6455 server→client frame (mask bit=0) 파싱. opcode=0x1 text + FIN=1 가정. */
function parseWsTextFrame(frame: Buffer): { opcode: number; fin: boolean; payload: string } {
  if (frame.length < 2) throw new Error(`frame too short: ${frame.length}`);
  const fin = (frame[0]! & 0x80) === 0x80;
  const opcode = frame[0]! & 0x0f;
  const maskBit = (frame[1]! & 0x80) === 0x80;
  if (maskBit) throw new Error('server frame must not be masked (RFC 6455 §5.3)');
  let len = frame[1]! & 0x7f;
  let offset = 2;
  if (len === 126) {
    len = frame.readUInt16BE(offset);
    offset += 2;
  } else if (len === 127) {
    // 64-bit length — dev server connected frame 은 20 byte 라 도달 불가
    throw new Error('64-bit frame length unexpected for connected message');
  }
  const payload = frame.slice(offset, offset + len).toString('utf8');
  return { opcode, fin, payload };
}

describe('Zig dev server TLS (#2538 4-2)', () => {
  let dir: string;
  let certFile: string;
  let keyFile: string;
  let port: number;
  let proc: ChildProcessWithoutNullStreams;
  // server stderr 누적 — test fail 시 진단용 노출. helpers.ts:374 runNode 와 동일 패턴.
  let serverLogs: string;

  beforeAll(async () => {
    const fixture = createFixture();
    dir = fixture.dir;
    certFile = fixture.certFile;
    keyFile = fixture.keyFile;
    port = await findFreePort();

    proc = spawn(ZNTC_BIN, [
      '--serve',
      dir,
      '--port',
      String(port),
      '--certfile',
      certFile,
      '--keyfile',
      keyFile,
    ]) as ChildProcessWithoutNullStreams;

    serverLogs = '';
    proc.stdout.on('data', (chunk: Buffer) => {
      serverLogs += chunk.toString('utf8');
    });
    proc.stderr.on('data', (chunk: Buffer) => {
      serverLogs += chunk.toString('utf8');
    });

    try {
      await waitForHttps(port);
    } catch (err) {
      console.error(`[zntc dev server logs]\n${serverLogs}`);
      throw err;
    }
  });

  afterAll(async () => {
    if (proc && !proc.killed) {
      proc.kill('SIGTERM');
      // Zig dev server 의 TLS thread join + listener close 가 비동기 — rmSync 전
      // 종료 대기 (좀비/orphan 방지 + fixture file race 차단).
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => resolve(), 2000); // fallback timeout
        proc.once('exit', () => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
    if (dir) rmSync(dir, { recursive: true, force: true });
  });

  test('HTTPS 200 OK — index.html 응답', async () => {
    const res = await fetch(`https://localhost:${port}/`, {
      tls: { rejectUnauthorized: false },
    } as RequestInit);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain('Zig TLS OK');
  });

  test('HTTPS 404 — 존재하지 않는 path', async () => {
    const res = await fetch(`https://localhost:${port}/nonexistent`, {
      tls: { rejectUnauthorized: false },
    } as RequestInit);
    expect(res.status).toBe(404);
  });

  test('HTTPS CORS Allow-Origin 헤더', async () => {
    const res = await fetch(`https://localhost:${port}/`, {
      tls: { rejectUnauthorized: false },
    } as RequestInit);
    expect(res.headers.get('Access-Control-Allow-Origin')).toBe('*');
  });

  test('HTTPS CSS 정적 파일 응답', async () => {
    const res = await fetch(`https://localhost:${port}/app.css`, {
      tls: { rejectUnauthorized: false },
    } as RequestInit);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/css');
    const text = await res.text();
    expect(text).toContain('background');
  });

  test('WSS /__hmr handshake + 첫 connected frame payload', async () => {
    const tls = await import('node:tls');
    const crypto = await import('node:crypto');

    const wsKey = crypto.randomBytes(16).toString('base64');
    const handshakeReq =
      `GET /__hmr HTTP/1.1\r\n` +
      `Host: localhost:${port}\r\n` +
      `Upgrade: websocket\r\n` +
      `Connection: Upgrade\r\n` +
      `Sec-WebSocket-Key: ${wsKey}\r\n` +
      `Sec-WebSocket-Version: 13\r\n` +
      `\r\n`;

    const { response, firstFrame } = await new Promise<{ response: string; firstFrame: Buffer }>(
      (resolve, reject) => {
        const socket = tls.connect(
          {
            host: 'localhost',
            port,
            rejectUnauthorized: false,
            servername: 'localhost',
          },
          () => {
            socket.write(handshakeReq);
          },
        );
        const accum: Buffer[] = [];
        let headersDone = false;
        let responseStr = '';
        socket.on('data', (chunk) => {
          accum.push(chunk);
          if (!headersDone) {
            responseStr = Buffer.concat(accum).toString('utf8');
            const sep = responseStr.indexOf('\r\n\r\n');
            if (sep >= 0) {
              headersDone = true;
              // header 이후 byte = 첫 frame 의 시작
              const headerBytes = Buffer.byteLength(responseStr.slice(0, sep + 4), 'utf8');
              const all = Buffer.concat(accum);
              const tailStart = headerBytes;
              const tail = all.slice(tailStart);
              if (tail.length >= 22) {
                // {"type":"connected"} = 20 byte payload + 2 byte header = 22 byte
                socket.destroy();
                resolve({ response: responseStr.slice(0, sep), firstFrame: tail });
                return;
              }
              accum.splice(0, accum.length, tail);
            }
          } else {
            const merged = Buffer.concat(accum);
            if (merged.length >= 22) {
              socket.destroy();
              resolve({
                response: responseStr.slice(0, responseStr.indexOf('\r\n\r\n')),
                firstFrame: merged,
              });
            }
          }
        });
        socket.on('error', reject);
        setTimeout(() => {
          socket.destroy();
          reject(new Error('WSS handshake + frame timeout'));
        }, 5000);
      },
    );

    // HTTP header name case-insensitive (RFC 7230 §3.2). Zig http.Server 는
    // lowercase 출력 — 일관 lowercase 비교.
    const lower = response.toLowerCase();
    expect(lower).toContain('101 switching protocols');
    expect(lower).toContain('upgrade: websocket');
    // RFC 6455 의 Sec-WebSocket-Accept = base64(sha1(key + GUID))
    const guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    const expectedAccept = crypto
      .createHash('sha1')
      .update(wsKey + guid)
      .digest('base64');
    expect(lower).toContain(`sec-websocket-accept: ${expectedAccept.toLowerCase()}`);

    // 첫 frame = HMR_MSG.Connected JSON text. RFC 6455 §5.2 frame format
    // (FIN=1, opcode=0x1 text, mask=0 server→client, payload="{\"type\":\"connected\"}").
    const parsed = parseWsTextFrame(firstFrame);
    expect(parsed.fin).toBe(true);
    expect(parsed.opcode).toBe(0x1); // text
    expect(parsed.payload).toBe('{"type":"connected"}');
  });
});
