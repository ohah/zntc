import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';

import {
  colors,
  formatLogBadge,
  logBundle,
  logError,
  logInfo,
  logWarn,
  printZtsRnBanner,
} from './logger.ts';

let logSpy: ReturnType<typeof mock>;
let warnSpy: ReturnType<typeof mock>;
let errorSpy: ReturnType<typeof mock>;
const originalLog = console.log;
const originalWarn = console.warn;
const originalError = console.error;

beforeEach(() => {
  logSpy = mock(() => {});
  warnSpy = mock(() => {});
  errorSpy = mock(() => {});
  console.log = logSpy as never;
  console.warn = warnSpy as never;
  console.error = errorSpy as never;
});

afterEach(() => {
  console.log = originalLog;
  console.warn = originalWarn;
  console.error = originalError;
});

describe('colors — ANSI escape', () => {
  test('기본 escape 시퀀스', () => {
    expect(colors.reset).toBe('\x1b[0m');
    expect(colors.bold).toBe('\x1b[1m');
    expect(colors.cyan).toBe('\x1b[36m');
  });
});

describe('logInfo / logWarn / logError — Metro 호환 badge', () => {
  test('logInfo — cyan inverse bold ` INFO `', () => {
    logInfo('hello');
    expect(logSpy).toHaveBeenCalledTimes(1);
    const args = logSpy.mock.calls[0] as unknown[];
    expect(args[0]).toContain('INFO');
    expect(args[0]).toContain(colors.cyan);
    expect(args[1]).toBe('hello');
  });

  test('logWarn — yellow', () => {
    logWarn('oops');
    const args = warnSpy.mock.calls[0] as unknown[];
    expect(args[0]).toContain('WARN');
    expect(args[0]).toContain(colors.yellow);
  });

  test('logError — red', () => {
    logError('boom');
    const args = errorSpy.mock.calls[0] as unknown[];
    expect(args[0]).toContain('ERROR');
    expect(args[0]).toContain(colors.red);
  });
});

describe('logBundle — Metro `BUNDLE` 상태 라인', () => {
  test('done — green inverse bold + detail tail', () => {
    logBundle('done', 'ios', './index.js', '(2 files, 1.5 KB, 100ms)');
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out).toContain('BUNDLE');
    expect(out).toContain(colors.green);
    expect(out).toContain('[ios]');
    expect(out).toContain('./index.js');
    expect(out).toContain('(2 files, 1.5 KB, 100ms)');
  });

  test('failed — red', () => {
    logBundle('failed', 'android', './entry.js', 'syntax error');
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out).toContain(colors.red);
    expect(out).toContain('syntax error');
  });

  test('request — yellow', () => {
    logBundle('request', 'ios', '/index.bundle?platform=ios&dev=true');
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out).toContain(colors.yellow);
  });

  test('detail 없음 → tail 비워둠', () => {
    logBundle('done', 'ios', './index.js');
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out.endsWith(`./index.js`)).toBe(true);
  });
});

describe('printZtsRnBanner', () => {
  test('version 지정 시 banner 에 포함', () => {
    printZtsRnBanner('0.1.0');
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out).toContain('@zts/react-native');
    expect(out).toContain('v0.1.0');
    expect(out).toContain('Metro-compatible RN dev server');
  });

  test('version 없음 → version 영역 비움', () => {
    printZtsRnBanner();
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out).toContain('@zts/react-native');
    expect(out).not.toMatch(/v\d/);
  });

  test('box drawing characters (║ ╔ ╚)', () => {
    printZtsRnBanner('0.1.0');
    const out = (logSpy.mock.calls[0] as unknown[])[0] as string;
    expect(out).toContain('╔');
    expect(out).toContain('║');
    expect(out).toContain('╚');
  });
});

describe('formatLogBadge — RN client console.log forwarding (#2605 audit P2)', () => {
  test('error → red INVERSE BOLD ERROR', () => {
    const badge = formatLogBadge('error');
    expect(badge).toContain(colors.red);
    expect(badge).toContain(colors.inverse);
    expect(badge).toContain(colors.bold);
    expect(badge).toContain(' ERROR ');
    expect(badge.endsWith(colors.reset)).toBe(true);
  });

  test('warn → yellow', () => {
    expect(formatLogBadge('warn')).toContain(colors.yellow);
  });

  test('debug → magenta', () => {
    expect(formatLogBadge('debug')).toContain(colors.magenta);
  });

  test('info → cyan', () => {
    expect(formatLogBadge('info')).toContain(colors.cyan);
  });

  test('log (default) → white', () => {
    expect(formatLogBadge('log')).toContain(colors.white);
  });

  test('unknown level → white default', () => {
    expect(formatLogBadge('verbose')).toContain(colors.white);
    expect(formatLogBadge('verbose')).toContain(' VERBOSE ');
  });

  test('level uppercase 적용', () => {
    expect(formatLogBadge('error')).toContain(' ERROR ');
    expect(formatLogBadge('Warn')).toContain(' WARN ');
  });
});
