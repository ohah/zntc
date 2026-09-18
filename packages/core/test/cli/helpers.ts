export { afterAll, beforeAll, describe, expect, test } from 'bun:test';
export { execSync, spawn, spawnSync } from 'node:child_process';
export type { ChildProcess } from 'node:child_process';
export { createServer as createNetServer } from 'node:net';
export {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
export { tmpdir } from 'node:os';
export { join, resolve } from 'node:path';

import { spawn, spawnSync } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { createServer as createNetServer } from 'node:net';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { waitForServer as sharedWaitForServer } from '@zntc/test-helpers';

export const BIN_DIR = resolve(import.meta.dir, '../../bin');
export const CLI = resolve(BIN_DIR, 'zntc.mjs');
export const RUNTIME = 'node';
export const PROJECT_ROOT = resolve(import.meta.dir, '../../../..');

// 정본은 `@zntc/test-helpers`. 호출처 (positional `(port, maxRetries, interval, protocol)`)
// 호환을 위해 wrapper 유지 — 옵션화 마이그레이션은 별도 PR.
export async function waitForServer(
  port: number,
  maxRetries = 50,
  interval = 100,
  protocol: 'http' | 'https' = 'http',
) {
  await sharedWaitForServer(port, {
    timeoutMs: maxRetries * interval,
    intervalMs: interval,
    protocol,
  });
}

export async function waitForText(read: () => string, text: string, timeoutMs = 1000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (read().includes(text)) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`Timed out waiting for text: ${text}\nObserved: ${read()}`);
}

let nextTestPort = 50000 + Math.floor(Math.random() * 1000);
export function findFreePort(): number {
  if (nextTestPort > 65000) nextTestPort = 50000;
  return nextTestPort++;
}

export async function occupyPort(port: number) {
  const server = createNetServer();
  await new Promise<void>((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(port, 'localhost', () => {
      server.off('error', rejectListen);
      resolveListen();
    });
  });
  return () => new Promise<void>((resolveClose) => server.close(() => resolveClose()));
}

export function shellQuote(value: string) {
  return "'" + value.replace(/'/g, "'\\''") + "'";
}

/**
 * spawn 되는 CLI 프로세스의 환경을 **달력에 의존하지 않게** 만든다.
 *
 * browserslist 는 `caniuse-lite` 데이터가 6개월보다 오래되면 stderr 에 갱신 안내를 찍는다.
 * 이건 진단이 아니라 시간이 지나면 저절로 나타나는 광고라서, "우리 CLI 가 stderr 에
 * 아무것도 안 찍는다" 를 확인하는 테스트를 **코드 변경 없이** 깨뜨린다. 실제로 2026-08-31
 * 이후 CI 의 NAPI 잡이 이 한 줄 때문에 계속 red 였다.
 *
 * `BROWSERSLIST_IGNORE_OLD_DATA` 는 browserslist 가 공식 지원하는 억제 스위치다. 제품
 * 동작은 그대로 두고(사용자에겐 갱신 안내가 유용하다) **테스트 하네스만** 조용하게 만든다.
 *
 * `options.env` 가 주어지면 환경을 치환하는 기존 규약을 유지한다 — 그 위에 얹기만 한다.
 */
function withDeterministicEnv(env?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ...(env ?? process.env), BROWSERSLIST_IGNORE_OLD_DATA: '1' };
}

export function readRedirectedProcessOutput(
  command: string,
  options: { input?: string; cwd?: string; timeout?: number; env?: NodeJS.ProcessEnv } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-output-'));
  const stdoutPath = join(dir, 'stdout');
  const stderrPath = join(dir, 'stderr');
  const stdinPath = join(dir, 'stdin');
  const stdinRedirect = options.input !== undefined ? ` < ${shellQuote(stdinPath)}` : '';
  if (options.input !== undefined) writeFileSync(stdinPath, options.input);
  const result = spawnSync(
    'sh',
    ['-c', `${command}${stdinRedirect} > ${shellQuote(stdoutPath)} 2> ${shellQuote(stderrPath)}`],
    { cwd: options.cwd, timeout: options.timeout ?? 10000, env: withDeterministicEnv(options.env) },
  );
  const stdout = existsSync(stdoutPath) ? readFileSync(stdoutPath, 'utf8') : '';
  const stderr = existsSync(stderrPath) ? readFileSync(stderrPath, 'utf8') : '';
  rmSync(dir, { recursive: true, force: true });
  return { stdout, stderr, exitCode: result.status ?? 1 };
}

export function runCli(
  args: string[],
  options: { input?: string; cwd?: string; timeout?: number; env?: NodeJS.ProcessEnv } = {},
) {
  const command = [RUNTIME, CLI, ...args].map(shellQuote).join(' ');
  return readRedirectedProcessOutput(command, options);
}

export function runNodeEval(
  code: string,
  options: { cwd?: string; env?: NodeJS.ProcessEnv; timeout?: number } = {},
) {
  const command = [RUNTIME, '-e', code].map(shellQuote).join(' ');
  return readRedirectedProcessOutput(command, options);
}

export function spawnWatchJson(args: string[], cwd: string, logPath: string, errPath: string) {
  const command = [RUNTIME, CLI, ...args, '--watch-json'].map(shellQuote).join(' ');
  return spawn('sh', ['-c', `exec ${command} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`], {
    cwd,
    detached: process.platform !== 'win32',
    stdio: 'ignore',
  });
}

export async function stopSpawnedProcess(proc: ChildProcess) {
  if (proc.pid === undefined) return;
  try {
    if (process.platform === 'win32') proc.kill();
    else process.kill(-proc.pid, 'SIGTERM');
  } catch {
    try {
      proc.kill();
    } catch {}
  }
  if (proc.exitCode !== null || proc.signalCode !== null) return;
  await new Promise<void>((resolveExit) => {
    const timer = setTimeout(resolveExit, 1000);
    proc.once('exit', () => {
      clearTimeout(timer);
      resolveExit();
    });
  });
}

export async function waitForEvent(
  logPath: string,
  predicate: (e: { type: string; [k: string]: unknown }) => boolean,
  timeoutMs: number,
  errPath?: string,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const events = readEvents(logPath);
    if (events.some(predicate)) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  const stdout = existsSync(logPath) ? readFileSync(logPath, 'utf8').trim() : '';
  const stderr = errPath && existsSync(errPath) ? readFileSync(errPath, 'utf8').trim() : '';
  throw new Error(
    [
      `waitForEvent timeout (${timeoutMs}ms)`,
      stdout ? `stdout:\n${stdout}` : 'stdout: <empty>',
      stderr ? `stderr:\n${stderr}` : 'stderr: <empty>',
    ].join('\n'),
  );
}

export function readEvents(logPath: string): Array<{ type: string; [k: string]: unknown }> {
  if (!existsSync(logPath)) return [];
  const lines = readFileSync(logPath, 'utf8').split('\n').filter(Boolean);
  return lines
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}
