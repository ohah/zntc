// Zig dev server 의 MCP `verify_in_chrome` 도구 회귀 가드.
// dev server 가 자식 프로세스로 `zntc verify --verify-json` 을 spawn 해
// MCP 응답 wrap 까지 한 루프가 정상 동작하는지 사용자 시점에서 검증한다.
//
// 의존성: #3609 의 `zntc verify` CLI 가 머지되어 있어야 한다. spawn 시
// ZNTC_CLI env 로 zntc.mjs 절대 경로 명시 — 모노레포 dev 환경에서는
// PATH 의 `zntc` binstub 가 없으므로 필수.

import { test, expect } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PORTS } from './ports';

const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');
const ZNTC_CLI_MJS = resolve(__dirname, '../../../packages/core/bin/zntc.mjs');
const PORT = PORTS.VERIFY_MCP;

let server: ChildProcess | null = null;
let fixtureDir: string;

async function callMcp(method: string, params: unknown, id = 1): Promise<unknown> {
  const res = await fetch(`http://localhost:${PORT}/mcp`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', method, id, params }),
  });
  return res.json();
}

function parseToolResult(rpc: any): { report: any; isError: boolean } {
  const result = rpc.result;
  const text = result.content[0].text;
  return { report: JSON.parse(text), isError: result.isError === true };
}

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), 'zntc-verify-mcp-'));
  await mkdir(fixtureDir, { recursive: true });
  await writeFile(join(fixtureDir, 'main.ts'), 'console.log("ok");');
  await writeFile(join(fixtureDir, 'ok.html'), '<!doctype html><h1>ok</h1>');
  await writeFile(
    join(fixtureDir, 'pageerror.html'),
    '<!doctype html><script>throw new Error("verify-mcp boom");</script>',
  );

  server = spawn(
    ZNTC_BIN,
    ['--serve', '--bundle', join(fixtureDir, 'main.ts'), '--port', String(PORT)],
    {
      stdio: 'pipe',
      env: { ...process.env, ZNTC_CLI: ZNTC_CLI_MJS },
    },
  );
  await new Promise((resolve) => setTimeout(resolve, 2000));
});

test.afterAll(async () => {
  if (server) {
    server.kill();
    await new Promise((r) => server!.on('close', r));
  }
  await rm(fixtureDir, { recursive: true, force: true });
});

test.describe('MCP verify_in_chrome', () => {
  test('tools/list 가 verify_in_chrome 을 노출한다', async () => {
    const rpc: any = await callMcp('tools/list', undefined);
    const names = rpc.result.tools.map((t: { name: string }) => t.name);
    expect(names).toContain('verify_in_chrome');
  });

  test('정상 페이지는 pass + isError 없음', async () => {
    const rpc = await callMcp('tools/call', {
      name: 'verify_in_chrome',
      arguments: { target: `http://localhost:${PORT}/ok.html` },
    });
    const { report, isError } = parseToolResult(rpc);
    expect(isError).toBe(false);
    expect(report.status).toBe('pass');
    expect(report.events).toEqual([]);
  });

  test('pageerror 가 있으면 isError:true + events 에 pageerror', async () => {
    const rpc = await callMcp('tools/call', {
      name: 'verify_in_chrome',
      arguments: { target: `http://localhost:${PORT}/pageerror.html` },
    });
    const { report, isError } = parseToolResult(rpc);
    expect(isError).toBe(true);
    expect(report.status).toBe('fail');
    expect(
      report.events.some(
        (e: { type: string; message?: string }) =>
          e.type === 'pageerror' && /verify-mcp boom/.test(e.message ?? ''),
      ),
    ).toBe(true);
  });

  test('allowConsoleError 인자가 console.error 만 발생 시 isError 를 막는다', async () => {
    await writeFile(
      join(fixtureDir, 'console-error.html'),
      '<!doctype html><script>console.error("expected");</script>',
    );
    const fail = await callMcp('tools/call', {
      name: 'verify_in_chrome',
      arguments: { target: `http://localhost:${PORT}/console-error.html` },
    });
    const failResult = parseToolResult(fail);
    expect(failResult.isError).toBe(true);

    const ok = await callMcp('tools/call', {
      name: 'verify_in_chrome',
      arguments: {
        target: `http://localhost:${PORT}/console-error.html`,
        allowConsoleError: true,
      },
    });
    const okResult = parseToolResult(ok);
    expect(okResult.isError).toBe(false);
    expect(okResult.report.status).toBe('pass');
  });
});
