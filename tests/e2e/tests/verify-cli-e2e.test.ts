// `zntc verify <path-or-url>` CLI 의 회귀 가드.
// CLI 진입점 + Playwright loader + exit-code 규약을 사용자 시점에서 검증한다.
// 실제 Playwright import 는 verify.mjs 의 loadChromium 이 tests/e2e/node_modules
// (`@playwright/test` fallback) 에서 chromium 을 찾는다 — cwd=tests/e2e 로 spawn.

import { test, expect } from '@playwright/test';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const ZNTC_MJS = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const E2E_CWD = resolve(__dirname, '..');

interface VerifyResult {
  exitCode: number | null;
  stdout: string;
  stderr: string;
}

function runVerify(args: string[]): Promise<VerifyResult> {
  return new Promise((resolve) => {
    const child = spawn('node', [ZNTC_MJS, 'verify', ...args], {
      stdio: 'pipe',
      cwd: E2E_CWD,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => {
      stdout += d.toString();
    });
    child.stderr.on('data', (d) => {
      stderr += d.toString();
    });
    child.on('close', (code) => {
      resolve({ exitCode: code, stdout, stderr });
    });
  });
}

let fixtureDir: string;

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), 'zntc-verify-cli-'));
});

test.afterAll(async () => {
  await rm(fixtureDir, { recursive: true, force: true });
});

test.describe('zntc verify CLI', () => {
  test('정상 페이지는 exit 0 + pass 리포트', async () => {
    const file = join(fixtureDir, 'ok.html');
    await writeFile(file, '<!doctype html><h1>ok</h1>');
    const r = await runVerify([file, '--verify-json']);
    expect(r.exitCode).toBe(0);
    const report = JSON.parse(r.stdout.trim());
    expect(report.status).toBe('pass');
    expect(report.events).toEqual([]);
  });

  test('pageerror 는 exit 1 + JSON 에 pageerror 이벤트', async () => {
    const file = join(fixtureDir, 'pageerror.html');
    await writeFile(file, '<!doctype html><script>throw new Error("zntc verify boom");</script>');
    const r = await runVerify([file, '--verify-json']);
    expect(r.exitCode).toBe(1);
    const report = JSON.parse(r.stdout.trim());
    expect(report.status).toBe('fail');
    expect(
      report.events.some(
        (e: { type: string; message?: string }) =>
          e.type === 'pageerror' && /zntc verify boom/.test(e.message ?? ''),
      ),
    ).toBe(true);
  });

  test('console.error 는 기본 exit 1, --verify-allow-console-error 면 exit 0', async () => {
    const file = join(fixtureDir, 'console-error.html');
    await writeFile(
      file,
      '<!doctype html><script>console.error("expected console error");</script>',
    );
    const fail = await runVerify([file, '--verify-json']);
    expect(fail.exitCode).toBe(1);
    const ok = await runVerify([file, '--verify-json', '--verify-allow-console-error']);
    expect(ok.exitCode).toBe(0);
  });

  test('존재하지 않는 경로는 exit 64', async () => {
    const r = await runVerify(['/path/does/not/exist.html']);
    expect(r.exitCode).toBe(64);
  });

  test('--verify-report 가 지정되면 JSON 파일로 저장', async () => {
    const file = join(fixtureDir, 'ok-report.html');
    const reportPath = join(fixtureDir, 'report.json');
    await writeFile(file, '<!doctype html><h1>ok</h1>');
    const r = await runVerify([file, '--verify-report', reportPath]);
    expect(r.exitCode).toBe(0);
    const saved = JSON.parse(await readFile(reportPath, 'utf8'));
    expect(saved.status).toBe('pass');
  });

  test('--verify-ignore <pattern> 으로 매칭되는 console.error 는 무시', async () => {
    const file = join(fixtureDir, 'console-ignored.html');
    await writeFile(
      file,
      '<!doctype html><script>console.error("noisy third-party warning");</script>',
    );
    const r = await runVerify([file, '--verify-json', '--verify-ignore', 'noisy third-party']);
    expect(r.exitCode).toBe(0);
    const report = JSON.parse(r.stdout.trim());
    expect(report.events).toEqual([]);
  });
});
