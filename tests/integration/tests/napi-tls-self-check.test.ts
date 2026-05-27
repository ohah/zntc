// NAPI tlsSelfCheck — BoringSSL static link 가 NAPI binary 안에서 실제로
// 동작하는지 검증 (fix #3894 / #3898 / #3899 의 jacent assertion).
//
// 시나리오:
//   1. openssl 로 self-signed cert/key 생성.
//   2. zig-out/lib/zntc.node 직접 require → tlsSelfCheck 호출.
//   3. valid cert/key → undefined (no throw).
//   4. 없는 path → throw with 'CertLoadFailed' / 'KeyLoadFailed'.
//   5. params 누락 → throw with 명시 메시지.

import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';

const repoRoot = resolve(__dirname, '..', '..', '..');
const requireFromHere = createRequire(__filename);
const native: any = requireFromHere(join(repoRoot, 'zig-out', 'lib', 'zntc.node'));

let tmpDir: string;
let certPath: string;
let keyPath: string;
let mismatchedKeyPath: string;

beforeAll(() => {
  tmpDir = mkdtempSync(join(tmpdir(), 'zntc-napi-tls-'));
  certPath = join(tmpDir, 'cert.pem');
  keyPath = join(tmpDir, 'key.pem');
  mismatchedKeyPath = join(tmpDir, 'mismatch-key.pem');
  execSync(
    `openssl req -x509 -newkey rsa:2048 -keyout ${keyPath} -out ${certPath} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
  );
  // 별도 RSA key — cert 와 mismatch (KeyMismatch path 검증).
  execSync(`openssl genrsa -out ${mismatchedKeyPath} 2048 2>/dev/null`);
});

afterAll(() => {
  if (tmpDir) rmSync(tmpDir, { recursive: true, force: true });
});

describe('NAPI tlsSelfCheck — BoringSSL link/runtime sanity', () => {
  test('tlsSelfCheck export 존재', () => {
    expect(typeof native.tlsSelfCheck).toBe('function');
  });

  test('valid cert + key — undefined (no throw)', () => {
    const result = native.tlsSelfCheck({ certPath, keyPath });
    expect(result).toBeUndefined();
  });

  test('없는 certPath → throw CertLoadFailed', () => {
    expect(() => native.tlsSelfCheck({ certPath: '/nonexistent/cert.pem', keyPath })).toThrow(
      /CertLoadFailed/,
    );
  });

  test('없는 keyPath → throw KeyLoadFailed', () => {
    expect(() => native.tlsSelfCheck({ certPath, keyPath: '/nonexistent/key.pem' })).toThrow(
      /KeyLoadFailed/,
    );
  });

  test('cert ↔ key mismatch → throw (KeyMismatch 또는 KeyLoadFailed)', () => {
    // BoringSSL 의 PrivateKey_file 가 load 단계에서 cert 와 algo 비교 시도 가능 —
    // mismatch 면 load 자체 fail (KeyLoadFailed) 또는 load 후 check_private_key
    // 단계 fail (KeyMismatch). 본 test 는 invalid 결합이 명시 throw 되는 것만 검증.
    expect(() => native.tlsSelfCheck({ certPath, keyPath: mismatchedKeyPath })).toThrow(
      /KeyMismatch|KeyLoadFailed/,
    );
  });

  test('certPath 누락 → throw "certPath" 메시지', () => {
    expect(() => native.tlsSelfCheck({ keyPath } as any)).toThrow(/certPath/);
  });

  test('keyPath 누락 → throw "keyPath" 메시지', () => {
    expect(() => native.tlsSelfCheck({ certPath } as any)).toThrow(/keyPath/);
  });

  test('options 누락 → throw "options object" 메시지', () => {
    expect(() => (native.tlsSelfCheck as any)()).toThrow(/options object/);
  });

  test('argv[0] 가 non-object (string) → throw "must be an object" (F3 review)', () => {
    // type 검증 없으면 후속 getObjectString 이 "field required" 로 throw 되어
    // 사용자가 type 문제를 missing field 로 오해.
    expect(() => (native.tlsSelfCheck as any)('not-an-object')).toThrow(/must be an object/);
  });

  test('argv[0] 가 null → throw "must be an object"', () => {
    expect(() => (native.tlsSelfCheck as any)(null)).toThrow(/must be an object/);
  });
});
