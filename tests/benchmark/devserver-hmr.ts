#!/usr/bin/env node
/**
 * Dev server HMR measurement — ZNTC dev / esbuild --serve / Vite (rolldown 기반).
 *
 * dev server 를 띄우고 HMR WebSocket 으로 update event 받기까지 시간 측정.
 * NAPI/CLI 와는 별개의 path:
 *   - ZNTC: `zntc dev` (src/server/dev_server.zig, file_watcher.zig kqueue 사용)
 *   - esbuild: `esbuild --serve` (limited HMR)
 *   - vite: rolldown 기반 dev server (HMR 풀 지원)
 *
 * RFC #3940 Sub-PR-L.0d — ZNTC_PROFILE=all 환경 변수 + SSE listener 가 함께 켜지면
 * iteration 별 phase breakdown 출력. WS = HMR latency, SSE = profile snapshot.
 *
 * Node 24+ native WebSocket 사용 (`ws` 모듈 의존성 없음).
 *
 * 실행:
 *   - WS HMR latency only: node devserver-hmr.mjs (bun build 후)
 *   - + phase profile: ZNTC_PROFILE=all node devserver-hmr.mjs
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { appendFileSync, mkdtempSync, rmSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const ROOT = '/Users/yoonhb/Documents/workspace/zts-codex';
const ZNTC_BIN = join(ROOT, 'zig-out/bin/zntc');
const BENCH_NM = join(ROOT, 'tests/benchmark/node_modules');

const ITERATIONS = 10;
const READY_TIMEOUT_MS = 20_000;
const REBUILD_TIMEOUT_MS = 10_000;
const SETTLE_MS = 250;

const PROFILE_ENV = process.env.ZNTC_PROFILE && process.env.ZNTC_PROFILE !== '';

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

function summarize(arr: number[]) {
  const s = [...arr].sort((a, b) => a - b);
  const n = s.length;
  const median = n % 2 === 1 ? s[(n - 1) >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2;
  return { min: s[0], max: s[n - 1], median, mean: s.reduce((a, b) => a + b, 0) / n };
}

function fmt(n: number) {
  if (n < 10) return n.toFixed(2);
  if (n < 100) return n.toFixed(1);
  return n.toFixed(0);
}
function pad(s: string | number, n: number) {
  return String(s).padStart(n);
}

// 무료 포트 찾기 (race-free 보장은 못하지만 충분)
async function findPort(start: number): Promise<number> {
  const net = await import('node:net');
  for (let p = start; p < start + 100; p++) {
    const ok = await new Promise<boolean>((res) => {
      const srv = net
        .createServer()
        .once('error', () => res(false))
        .once('listening', () => {
          srv.close(() => res(true));
        })
        .listen(p, '127.0.0.1');
    });
    if (ok) return p;
  }
  throw new Error('no free port');
}

interface Fixture {
  name: string;
  build(dir: string): { entry: string };
}

const fixtures: Fixture[] = [
  {
    name: 'tiny',
    build(dir) {
      const entry = join(dir, 'entry.ts');
      writeFileSync(
        join(dir, 'index.html'),
        `<!DOCTYPE html><html><body><script type="module" src="/entry.ts"></script></body></html>\n`,
      );
      writeFileSync(entry, `export const x = 1;\nconsole.log(x);\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
  {
    name: 'lodash',
    build(dir) {
      try {
        symlinkSync(BENCH_NM, join(dir, 'node_modules'), 'dir');
      } catch {}
      const entry = join(dir, 'entry.ts');
      writeFileSync(
        join(dir, 'index.html'),
        `<!DOCTYPE html><html><body><script type="module" src="/entry.ts"></script></body></html>\n`,
      );
      writeFileSync(
        entry,
        `import { groupBy, sortBy, uniq } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq);\n`,
      );
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
];

interface Tool {
  name: string;
  start(dir: string, port: number): { child: ChildProcess; wsUrl: string; sseUrl: string };
}

const tools: Tool[] = [
  {
    name: 'zntc-dev',
    start(dir, port) {
      const child = spawn(ZNTC_BIN, ['dev', '.', '--port', String(port)], {
        cwd: dir,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      return {
        child,
        wsUrl: `ws://127.0.0.1:${port}/__hmr`,
        sseUrl: `http://127.0.0.1:${port}/sse/events`,
      };
    },
  },
];

async function waitWsConnected(url: string, timeoutMs: number): Promise<WebSocket> {
  const t0 = performance.now();
  while (performance.now() - t0 < timeoutMs) {
    try {
      const ws = new WebSocket(url);
      const ok = await new Promise<boolean>((res) => {
        ws.onopen = () => res(true);
        ws.onerror = () => res(false);
        setTimeout(() => res(false), 1000);
      });
      if (ok) return ws;
      try {
        ws.close();
      } catch {}
    } catch {}
    await sleep(100);
  }
  throw new Error(`ws connect timeout: ${url}`);
}

/**
 * SSE listener — bundle_build_done event 의 `profile` 필드 캡처.
 * fetch streaming 으로 background 에서 event 받아 buf 에 누적. caller 가 build 끝났을 때
 * 마지막 profile 읽음.
 */
class SseProfileTap {
  bundleDoneProfiles: Array<Record<string, number>> = [];
  durations: number[] = [];
  private aborted = false;
  private ac = new AbortController();

  start(sseUrl: string): void {
    void this._loop(sseUrl);
  }

  private async _loop(sseUrl: string) {
    try {
      const res = await fetch(sseUrl, { signal: this.ac.signal });
      if (!res.body) return;
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      while (!this.aborted) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value);
        while (buf.includes('\n\n')) {
          const idx = buf.indexOf('\n\n');
          const ev = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const m = ev.match(/data: (.+)/);
          if (!m) continue;
          try {
            const j = JSON.parse(m[1]);
            if (j.type === 'bundle_build_done') {
              this.durations.push(j.duration);
              if (j.profile) this.bundleDoneProfiles.push(j.profile);
            }
          } catch {}
        }
      }
    } catch {}
  }

  stop(): void {
    this.aborted = true;
    try {
      this.ac.abort();
    } catch {}
  }
}

async function measure(tool: Tool, fx: Fixture) {
  const dir = mkdtempSync(join(tmpdir(), `hmr-${tool.name}-${fx.name}-`));
  const { entry } = fx.build(dir);
  const port = await findPort(4400);
  const { child, wsUrl, sseUrl } = tool.start(dir, port);
  const stderrChunks: string[] = [];
  child.stderr?.on('data', (d) => stderrChunks.push(d.toString()));
  child.stdout?.on('data', () => {});

  const sseTap = PROFILE_ENV ? new SseProfileTap() : null;

  try {
    // dev server boot + initial bundle 대기
    const initStart = performance.now();
    const ws = await waitWsConnected(wsUrl, READY_TIMEOUT_MS);
    const initialMs = performance.now() - initStart;
    if (sseTap) sseTap.start(sseUrl);
    await sleep(SETTLE_MS);

    const iters: number[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      let t0 = 0;
      const p = new Promise<void>((res, rej) => {
        const onMsg = (ev: MessageEvent) => {
          // any update-related message counts
          const dt = performance.now() - t0;
          ws.removeEventListener('message', onMsg);
          iters.push(dt);
          res();
        };
        ws.addEventListener('message', onMsg);
        setTimeout(() => rej(new Error(`hmr ${i} timeout`)), REBUILD_TIMEOUT_MS);
      });
      t0 = performance.now();
      appendFileSync(entry, `export const _i${i}=${i};console.log(_i${i});\n`);
      try {
        await p;
      } catch (e) {
        sseTap?.stop();
        return { error: String(e), stderr: stderrChunks.join('').slice(0, 300) };
      }
      await sleep(SETTLE_MS);
    }
    try {
      ws.close();
    } catch {}
    sseTap?.stop();
    return { initialMs, iters, profiles: sseTap?.bundleDoneProfiles ?? [] };
  } finally {
    child.kill('SIGTERM');
    await sleep(200);
    if (!child.killed) child.kill('SIGKILL');
    rmSync(dir, { recursive: true, force: true });
  }
}

/** 여러 iteration 의 profile 들에서 phase 별 median 추출. */
function aggregatePhases(profiles: Array<Record<string, number>>): Array<[string, number]> {
  // initial build 제외 (워밍업) — 가장 큰 첫 entry skip
  const samples = profiles.length > 2 ? profiles.slice(1) : profiles;
  const byPhase: Record<string, number[]> = {};
  for (const p of samples) {
    for (const [k, v] of Object.entries(p)) {
      (byPhase[k] ??= []).push(v);
    }
  }
  const result: Array<[string, number]> = [];
  for (const [k, arr] of Object.entries(byPhase)) {
    const s = summarize(arr);
    result.push([k, s.median]);
  }
  // 큰 phase 부터
  result.sort((a, b) => b[1] - a[1]);
  return result;
}

async function main() {
  console.log('# Dev server HMR benchmark\n');
  console.log(`File touch → WS message 수신 시간 (ms).`);
  console.log(`Iter ${ITERATIONS}, settle ${SETTLE_MS}ms.`);
  if (PROFILE_ENV) {
    console.log(`Profile: ENABLED (ZNTC_PROFILE=${process.env.ZNTC_PROFILE})`);
  }
  console.log();

  for (const fx of fixtures) {
    console.log(`\n## ${fx.name}\n`);
    console.log(`| Tool      | Initial    | HMR median | min   | max   | mean  |`);
    console.log(`|-----------|-----------:|-----------:|------:|------:|------:|`);
    for (const tool of tools) {
      try {
        const r = await measure(tool, fx);
        if ('error' in r) {
          console.log(
            `| ${tool.name.padEnd(9)} | FAIL       | ${r.error.slice(0, 25).padEnd(10)} | -     | -     | -     |`,
          );
          if (r.stderr) console.log(`  stderr: ${r.stderr.slice(0, 200)}`);
          continue;
        }
        const s = summarize(r.iters);
        console.log(
          `| ${tool.name.padEnd(9)} | ${pad(fmt(r.initialMs), 8)}ms | ${pad(fmt(s.median), 8)}ms | ${pad(fmt(s.min), 4)}ms | ${pad(fmt(s.max), 4)}ms | ${pad(fmt(s.mean), 4)}ms |`,
        );
        // Profile breakdown (RFC #3940 Sub-PR-L.0d)
        if (r.profiles && r.profiles.length > 0) {
          const phases = aggregatePhases(r.profiles);
          const top = phases.slice(0, 10);
          console.log(`\n  ${tool.name} phase median (top 10, ${r.profiles.length} samples):`);
          for (const [k, v] of top) {
            console.log(`    ${k.padEnd(40)} ${fmt(v).padStart(8)}ms`);
          }
        }
      } catch (e) {
        console.log(
          `| ${tool.name.padEnd(9)} | ERROR      | ${String(e).slice(0, 25).padEnd(10)} | -     | -     | -     |`,
        );
      }
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
