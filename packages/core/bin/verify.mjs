// `zntc verify <path-or-url>` 진입점. 정적 결과물 (`dist/`) 또는 URL 을 헤드리스
// Chromium 에 띄우고 pageerror / console.error / 4xx 응답 / request 실패를
// 수집해 JSON 리포트로 리턴. CI 한 줄로 "번들이 브라우저에서 깨지는지" 검증.
//
// playwright 는 optionalDependency — 미설치 시 친절한 안내 후 exit 64.

import { statSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { isAbsolute, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Exit code contract — runVerify 의 public API. CI 가 의존하므로 변경 시 docs/USAGE.md 동기.
const EXIT_OK = 0;
const EXIT_EVENTS_FOUND = 1;
const EXIT_LOAD_FAILED = 2;
const EXIT_BAD_USAGE = 64;

const PLAYWRIGHT_INSTALL_HINT = [
  'zntc verify requires Playwright to be installed.',
  '',
  '  npm install --save-dev playwright',
  '  npx playwright install chromium',
  '',
].join('\n');

// cwd 의 node_modules 와 verify.mjs 위치 양쪽에서 playwright / @playwright/test 를
// 순차 탐색. 사용자가 자기 프로젝트에 playwright 를 설치한 경우 그쪽 우선.
// require() 가 dynamic import 보다 우선 — @playwright/test 는 CJS/ESM dual 인데
// CJS entry 를 ESM 으로 평가하면 default export 만 노출되고 chromium 같은 named
// export 는 사라진다. require() 는 CJS entry 의 module.exports 전체를 그대로 반환.
async function loadChromium() {
  const requireFromCwd = createRequire(resolve(process.cwd(), 'package.json'));
  for (const name of ['playwright', '@playwright/test']) {
    try {
      const mod = requireFromCwd(name);
      if (mod?.chromium) return mod.chromium;
    } catch {}
    try {
      const mod = await import(name);
      if (mod?.chromium) return mod.chromium;
    } catch {}
  }
  return null;
}

export async function runVerify(opts) {
  const target = normalizeTarget(opts.verifyTarget);
  if (!target) {
    process.stderr.write(
      'zntc verify: missing or invalid target. Usage: zntc verify <path-or-url> [options]\n',
    );
    return { exitCode: EXIT_BAD_USAGE };
  }

  const chromium = await loadChromium();
  if (!chromium) {
    process.stderr.write(PLAYWRIGHT_INSTALL_HINT);
    return { exitCode: EXIT_BAD_USAGE };
  }

  const ignorePatterns = (opts.verifyIgnore || []).map((p) => new RegExp(p));
  const timeout = opts.verifyTimeout ?? 10000;
  const allowConsoleError = opts.verifyAllowConsoleError ?? false;
  const events = [];

  const start = Date.now();
  let browser;
  let loadOk = false;
  let loadFailure = null;

  try {
    browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext();
    const page = await ctx.newPage();

    page.on('pageerror', (err) => {
      events.push({
        type: 'pageerror',
        message: err.message,
        stack: err.stack ?? '',
      });
    });
    page.on('console', (msg) => {
      if (msg.type() !== 'error') return;
      const text = msg.text();
      if (ignorePatterns.some((re) => re.test(text))) return;
      const loc = msg.location();
      events.push({
        type: 'console_error',
        text,
        location: loc?.url ? `${loc.url}:${loc.lineNumber + 1}:${loc.columnNumber + 1}` : '',
      });
    });
    page.on('requestfailed', (req) => {
      const url = req.url();
      if (ignorePatterns.some((re) => re.test(url))) return;
      events.push({
        type: 'request_failed',
        url,
        method: req.method(),
        failure: req.failure()?.errorText ?? '',
      });
    });
    page.on('response', (res) => {
      const status = res.status();
      if (status < 400) return;
      const url = res.url();
      if (ignorePatterns.some((re) => re.test(url))) return;
      events.push({ type: 'response', url, status });
    });

    await page.goto(target.url, { timeout, waitUntil: 'networkidle' });
    loadOk = true;
  } catch (err) {
    loadFailure = err instanceof Error ? err.message : String(err);
  } finally {
    if (browser) await browser.close().catch(() => {});
  }

  const duration_ms = Date.now() - start;
  if (loadFailure) {
    events.push({ type: 'load_failed', message: loadFailure });
  }
  const fatalEvents = events.filter((e) => {
    if (e.type === 'console_error') return !allowConsoleError;
    return true;
  });
  let exitCode = EXIT_OK;
  if (!loadOk) exitCode = EXIT_LOAD_FAILED;
  else if (fatalEvents.length > 0) exitCode = EXIT_EVENTS_FOUND;

  const report = {
    target: target.url,
    status: exitCode === 0 ? 'pass' : 'fail',
    duration_ms,
    events,
  };

  if (opts.verifyReport) {
    writeFileSync(opts.verifyReport, `${JSON.stringify(report, null, 2)}\n`);
  }

  if (opts.verifyJson) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } else {
    formatHuman(report, allowConsoleError);
  }

  return { exitCode };
}

function normalizeTarget(raw) {
  if (!raw) return null;
  if (/^https?:\/\//.test(raw) || raw.startsWith('file://')) {
    return { url: raw };
  }
  const abs = isAbsolute(raw) ? raw : resolve(process.cwd(), raw);
  try {
    const stat = statSync(abs);
    const filePath = stat.isDirectory() ? join(abs, 'index.html') : abs;
    statSync(filePath);
    return { url: pathToFileURL(filePath).href };
  } catch {
    return null;
  }
}

function formatHuman(report, allowConsoleError) {
  const stream = report.status === 'pass' ? process.stdout : process.stderr;
  stream.write(`zntc verify: ${report.status.toUpperCase()} (${report.duration_ms} ms)\n`);
  stream.write(`  target: ${report.target}\n`);
  if (report.events.length === 0) return;
  stream.write(`  ${report.events.length} event(s):\n`);
  for (const e of report.events) {
    if (e.type === 'pageerror') {
      stream.write(`    [pageerror] ${e.message}\n`);
    } else if (e.type === 'console_error') {
      stream.write(`    [console.error] ${e.text}${e.location ? ` @ ${e.location}` : ''}\n`);
    } else if (e.type === 'response') {
      stream.write(`    [HTTP ${e.status}] ${e.url}\n`);
    } else if (e.type === 'request_failed') {
      stream.write(`    [request_failed] ${e.url} (${e.failure})\n`);
    } else if (e.type === 'load_failed') {
      stream.write(`    [load_failed] ${e.message}\n`);
    }
  }
  if (allowConsoleError && report.events.some((e) => e.type === 'console_error')) {
    stream.write('  (--verify-allow-console-error: console errors do not affect exit code)\n');
  }
}
