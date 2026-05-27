// NAPI startDevServer 의 quiet 옵션 stderr 동작 잠금 — child process 띄워 stderr
// 와 stdout 을 **별도** 캡처. PR-G4 의 routineLog / critical 분리가 회귀하지 않게
// 명시 검증.
//
// 시나리오:
//   1. quiet:true (default) + valid root → stderr 에 banner / 200 access log
//      없음 (routine silent).
//   2. quiet:true + invalid rootDir → stderr 에 critical 진단 "cannot open
//      directory" (quiet 무관).
//   3. quiet:true + cert valid path 실패 (TLS init 도달) → stderr 에 critical
//      진단 "TLS context init failed" (DevServer.init 의 getLog path 검증).
//   4. quiet:false → stderr 에 banner + 200 access log 출력 (routine 정상 동작).
//
// stream 분리: runScript 가 `{stderr, stdout, status}` 반환. test 가 stream-
// targeted assertion (routine 은 stderr 에서만 검증, critical 도 stderr 검증)
// — F1/F2 review fix.
//
// 메모리 가이드: tests/integration cwd 에서 bun test.

import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const repoRoot = resolve(__dirname, '..', '..', '..');
const napiPath = join(repoRoot, 'zig-out', 'lib', 'zntc.node');

let tmpRoot: string;
let invalidCert: string;
let invalidKey: string;

beforeAll(() => {
  // **napi binary 검증** — stale 또는 missing 시 명확한 에러 (F7 fix).
  if (!existsSync(napiPath)) {
    throw new Error(`NAPI binary not found at ${napiPath} — run \`zig build napi\` first`);
  }

  tmpRoot = mkdtempSync(join(tmpdir(), 'zntc-napi-quiet-'));
  writeFileSync(join(tmpRoot, 'index.html'), '<h1>quiet check</h1>');

  // scenario 3 의 TLS init 도달용 — 둘 다 존재 path 지만 cert 내용 invalid 라
  // SSL_CTX_use_certificate_file 실패 (CertLoadFailed).
  invalidCert = join(tmpRoot, 'bad.crt');
  invalidKey = join(tmpRoot, 'bad.key');
  writeFileSync(invalidCert, 'not a real cert\n');
  writeFileSync(invalidKey, 'not a real key\n');
});

afterAll(() => {
  if (tmpRoot) rmSync(tmpRoot, { recursive: true, force: true });
});

interface RunResult {
  stderr: string;
  stdout: string;
  status: number | null;
}

/**
 * sub-process 로 script 실행. `JSON.stringify` 로 placeholder 안전 inline (F6 fix).
 * stdout / stderr 분리 반환 — caller 가 stream-targeted 검증.
 */
function runScript(
  script: string,
  vars: Record<string, string | boolean | number> = {},
): RunResult {
  const defaults = { __NAPI__: napiPath, __ROOT__: tmpRoot };
  const merged = { ...defaults, ...vars };
  let code = script;
  for (const [key, value] of Object.entries(merged)) {
    // 모든 placeholder 를 JSON.stringify 결과로 치환 — escape / quoting 안전.
    code = code.replaceAll(key, JSON.stringify(value));
  }
  const res = spawnSync('node', ['--no-warnings', '-e', code], {
    encoding: 'utf-8',
    timeout: 10_000,
  });
  return {
    stderr: res.stderr ?? '',
    stdout: res.stdout ?? '',
    status: res.status,
  };
}

describe('NAPI startDevServer — quiet 회귀 잠금 (stderr / stdout 분리 capture)', () => {
  test('quiet:true (default) + valid → stderr 에 banner / 200 access log 없음', () => {
    const res = runScript(`
      const r = require(__NAPI__);
      const handle = r.startDevServer({ rootDir: __ROOT__, port: 0, host: "127.0.0.1" });
      const port = r.getDevServerPort(handle);
      console.log("PORT=" + port);
      setTimeout(async () => {
        await fetch("http://127.0.0.1:" + port + "/index.html");
        r.stopDevServer(handle);
        process.exit(0);
      }, 200);
    `);
    if (res.status !== 0) {
      throw new Error(
        `sub-process crashed: status=${res.status} stderr=${res.stderr} stdout=${res.stdout}`,
      );
    }
    // **stderr** 에 routine log (banner / access) 없어야 — quiet:true 의 핵심.
    expect(res.stderr).not.toContain('zntc dev server');
    expect(res.stderr).not.toContain('Local: http://');
    expect(res.stderr).not.toMatch(/200 \/?index\.html/);
    // **stdout** 의 PORT 출력 sanity.
    expect(res.stdout).toMatch(/PORT=\d+/);
  });

  test('quiet:true + invalid rootDir → critical 진단 stderr (quiet 무관)', () => {
    const res = runScript(
      `
      const r = require(__NAPI__);
      try {
        r.startDevServer({ rootDir: __INVALID__ });
      } catch (e) {
        console.log("THROW=" + e.message);
      }
    `,
      { __INVALID__: '/zntc-nonexistent-' + Date.now() },
    );
    // **stderr** 에 init critical 진단.
    expect(res.stderr).toContain('cannot open directory');
    expect(res.stderr).toContain('error.FileNotFound');
    // **stdout** 에 JS throw 메시지 (NAPI throwError 가 generic 메시지 surface).
    expect(res.stdout).toContain('THROW=');
    expect(res.stdout).toContain('error.FileNotFound');
  });

  test('quiet:true + cert+key valid path 지만 형식 invalid → DevServer.init 의 TLS critical 진단 stderr', () => {
    // F1 review fix — 이전 scenario 3 은 NAPI throwError path 만 잡았고 critical
    // getLog 도달 안 함. 이제 cert+key 둘 다 path 주어 DevServer.init 의 TLS
    // init 분기에 도달, 그 안의 `getLog().print("zntc: TLS context init failed:")`
    // critical path 가 실제로 stderr 에 떴는지 검증.
    const res = runScript(
      `
      const r = require(__NAPI__);
      try {
        r.startDevServer({ rootDir: __ROOT__, certPath: __CERT__, keyPath: __KEY__ });
      } catch (e) {
        console.log("THROW=" + e.message);
      }
    `,
      { __CERT__: invalidCert, __KEY__: invalidKey },
    );
    // **stderr** 의 critical TLS 진단 (DevServer.init 의 getLog path).
    expect(res.stderr).toContain('TLS context init failed');
    expect(res.stderr).toContain('CertLoadFailed');
    // **stdout** 에 JS throw.
    expect(res.stdout).toContain('THROW=');
  });

  test('quiet:false → banner + 200 access log stderr 출력 (routine 정상)', () => {
    const res = runScript(`
      const r = require(__NAPI__);
      const handle = r.startDevServer({ rootDir: __ROOT__, port: 0, host: "127.0.0.1", quiet: false });
      const port = r.getDevServerPort(handle);
      console.log("PORT=" + port);
      setTimeout(async () => {
        await fetch("http://127.0.0.1:" + port + "/index.html");
        r.stopDevServer(handle);
        process.exit(0);
      }, 200);
    `);
    if (res.status !== 0) {
      throw new Error(
        `sub-process crashed: status=${res.status} stderr=${res.stderr} stdout=${res.stdout}`,
      );
    }
    // **stderr** 의 banner (CLI default 동작).
    expect(res.stderr).toContain('zntc dev server');
    expect(res.stderr).toContain('Local: http://');
    // routine access log — stderr 에만.
    expect(res.stderr).toMatch(/200 \/?index\.html/);
  });
});
