// NAPI startDevServer / stopDevServer — in-process HTTP & HTTPS dev server.
//
// 시나리오:
//   1. mkdtemp 으로 임시 root + index.html.
//   2. startDevServer({rootDir, port, ...}) → handle.
//   3. fetch http://host:port/index.html → 200 + body.
//   4. stopDevServer(handle) — graceful shutdown.
//   5. HTTPS 변형 — self-signed cert + NODE_TLS_REJECT_UNAUTHORIZED=0 으로 fetch.
//
// 메모리 가이드: 반드시 tests/integration 디렉토리에서 `bun test`.

import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';

const repoRoot = resolve(__dirname, '..', '..', '..');
const requireFromHere = createRequire(__filename);
const native: any = requireFromHere(join(repoRoot, 'zig-out', 'lib', 'zntc.node'));

let tmpRoot: string;
let certPath: string;
let keyPath: string;

// 16xxx range — 시스템 사용 적은 port. 동시 실행 시 충돌 없게 test 별 다른 port.
let nextPort = 16400;
function reservePort(): number {
  return nextPort++;
}

beforeAll(() => {
  tmpRoot = mkdtempSync(join(tmpdir(), 'zntc-napi-serve-'));
  writeFileSync(join(tmpRoot, 'index.html'), '<h1>NAPI serve OK</h1>');
  certPath = join(tmpRoot, 'cert.pem');
  keyPath = join(tmpRoot, 'key.pem');
  execSync(
    `openssl req -x509 -newkey rsa:2048 -keyout ${keyPath} -out ${certPath} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
  );
});

afterAll(() => {
  if (tmpRoot) rmSync(tmpRoot, { recursive: true, force: true });
});

async function waitUntilReady(url: string, timeoutMs = 5000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.status === 200) return;
    } catch {
      // not ready yet
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server at ${url} not ready within ${timeoutMs}ms`);
}

describe('NAPI startDevServer / stopDevServer', () => {
  test('exports 존재', () => {
    expect(typeof native.startDevServer).toBe('function');
    expect(typeof native.stopDevServer).toBe('function');
  });

  test('HTTP — start → fetch index.html (200, body) → stop', async () => {
    const port = reservePort();
    const handle = native.startDevServer({ rootDir: tmpRoot, port, host: '127.0.0.1' });
    expect(typeof handle).toBe('object');
    try {
      await waitUntilReady(`http://127.0.0.1:${port}/index.html`);
      const res = await fetch(`http://127.0.0.1:${port}/index.html`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body.trim()).toBe('<h1>NAPI serve OK</h1>');
    } finally {
      native.stopDevServer(handle);
    }
  });

  test('HTTPS — cert + key 양쪽 줘서 BoringSSL listener', async () => {
    const port = reservePort();
    const handle = native.startDevServer({
      rootDir: tmpRoot,
      port,
      host: '127.0.0.1',
      certPath,
      keyPath,
    });
    try {
      // self-signed cert 라 verify off.
      const origRejectUnauth = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
      try {
        await waitUntilReady(`https://127.0.0.1:${port}/index.html`);
        const res = await fetch(`https://127.0.0.1:${port}/index.html`);
        expect(res.status).toBe(200);
        const body = await res.text();
        expect(body.trim()).toBe('<h1>NAPI serve OK</h1>');
      } finally {
        if (origRejectUnauth == null) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
        else process.env.NODE_TLS_REJECT_UNAUTHORIZED = origRejectUnauth;
      }
    } finally {
      native.stopDevServer(handle);
    }
  });

  test('stopDevServer idempotent — 두 번 호출해도 throw 없음', () => {
    const port = reservePort();
    const handle = native.startDevServer({ rootDir: tmpRoot, port, host: '127.0.0.1' });
    native.stopDevServer(handle);
    expect(() => native.stopDevServer(handle)).not.toThrow();
  });

  test('cert 만 주고 key 없음 → throw "both"', () => {
    const port = reservePort();
    expect(() =>
      native.startDevServer({ rootDir: tmpRoot, port, host: '127.0.0.1', certPath }),
    ).toThrow(/both/);
  });

  test('rootDir 누락 → throw "rootDir"', () => {
    expect(() => (native.startDevServer as any)({})).toThrow(/rootDir/);
  });

  test('options 누락 → throw "options object"', () => {
    expect(() => (native.startDevServer as any)()).toThrow(/options object/);
  });

  test('non-object handle → stopDevServer throw "handle"', () => {
    expect(() => (native.stopDevServer as any)({ fake: true })).toThrow(/handle/);
    expect(() => (native.stopDevServer as any)(null)).toThrow(/handle/);
  });

  test('port 65536+ → throw (PR-G3: 0 은 OS-assigned 으로 허용)', () => {
    expect(() => native.startDevServer({ rootDir: tmpRoot, port: 70000 })).toThrow(/port/);
  });

  test('port 가 string 등 non-number → throw (F4 type check)', () => {
    expect(() => native.startDevServer({ rootDir: tmpRoot, port: '5173' as any })).toThrow(/port/);
  });

  test('concurrent handles — 두 개 동시 실행 + 독립 stop (F9)', async () => {
    const portA = reservePort();
    const portB = reservePort();
    const handleA = native.startDevServer({ rootDir: tmpRoot, port: portA, host: '127.0.0.1' });
    const handleB = native.startDevServer({ rootDir: tmpRoot, port: portB, host: '127.0.0.1' });
    try {
      await waitUntilReady(`http://127.0.0.1:${portA}/index.html`);
      await waitUntilReady(`http://127.0.0.1:${portB}/index.html`);
      const [resA, resB] = await Promise.all([
        fetch(`http://127.0.0.1:${portA}/index.html`),
        fetch(`http://127.0.0.1:${portB}/index.html`),
      ]);
      expect(resA.status).toBe(200);
      expect(resB.status).toBe(200);
      // A 만 stop 후에도 B 는 작동.
      native.stopDevServer(handleA);
      const resBAfter = await fetch(`http://127.0.0.1:${portB}/index.html`);
      expect(resBAfter.status).toBe(200);
    } finally {
      native.stopDevServer(handleB);
    }
  });

  test('port 0 (OS-assigned ephemeral) + getDevServerPort — 실 bound port 조회 (PR-G3)', async () => {
    const handle = native.startDevServer({ rootDir: tmpRoot, port: 0, host: '127.0.0.1' });
    try {
      const port = native.getDevServerPort(handle);
      expect(typeof port).toBe('number');
      // F1 fix detector: race (stale read) 시 0 반환되면 즉시 fail.
      expect(port).not.toBe(0);
      expect(port).toBeGreaterThan(1024);
      expect(port).toBeLessThan(65536);
      await waitUntilReady(`http://127.0.0.1:${port}/index.html`);
      const res = await fetch(`http://127.0.0.1:${port}/index.html`);
      expect(res.status).toBe(200);
    } finally {
      native.stopDevServer(handle);
    }
  });

  test('getDevServerPort 가 stopped handle 에 throw', () => {
    const port = reservePort();
    const handle = native.startDevServer({ rootDir: tmpRoot, port, host: '127.0.0.1' });
    native.stopDevServer(handle);
    expect(() => native.getDevServerPort(handle)).toThrow(/stopped/);
  });

  test('getDevServerPort 가 non-handle 에 throw', () => {
    expect(() => (native.getDevServerPort as any)({})).toThrow(/handle/);
    expect(() => (native.getDevServerPort as any)(null)).toThrow(/handle/);
  });

  test('quiet:false → banner stderr 출력 (PR-G3 quiet 기능 — 명시 false)', () => {
    // 본 test 는 stderr capture 가 어려우니 동작 자체만 검증 (throw 없음).
    const port = reservePort();
    const handle = native.startDevServer({
      rootDir: tmpRoot,
      port,
      host: '127.0.0.1',
      quiet: false,
    });
    native.stopDevServer(handle);
  });

  // GC-only cleanup (no explicit stopDevServer) — finalize callback 가 자동 정리한다는
  // 점은 코드 review 로만 검증. Bun.gc(true) 가 NAPI external finalizer 를 동기 실행
  // 보장 안 해서 timing 의존 test 는 flaky. 본 인프라 의 contract:
  //   - finalizeHandle 가 handle.shutdown() (server.shutdown + thread.join + deinit + free) +
  //     native_alloc.destroy(handle) 호출.
  //   - stopped atomic flag 가 명시 stop 과 finalizer 의 race 차단.
  // production 사용자에게는 명시 stopDevServer 권장 — finalize 는 GC safety net.
});
