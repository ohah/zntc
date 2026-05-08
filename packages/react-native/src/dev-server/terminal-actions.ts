// dev server 터미널 키보드 단축키 — Metro 호환 (r/d/j/i/a/c/?). raw mode +
// keypress listener. caller 가 enabled=false 시 cleanup 즉시 반환.

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

import { colors, logInfo, logWarn } from './logger.ts';

export interface TerminalActionsCallbacks {
  /** `r` — RN runtime reload broadcast. */
  onReload(): void;
  /** `d` — Dev menu broadcast. */
  onDevMenu(): void;
  /** `j` — open DevTools (POST /open-debugger). */
  onOpenDevTools(): void;
  /** `c` — clear cache (per-platform state.bundle null 처리 등). */
  onClearCache(): void;
  /**
   * `v` — RN runtime 의 console.log forwarding mute/unmute. 새 상태 반환 (true=ON,
   * false=OFF) — INFO 피드백 메시지에 사용.
   */
  onToggleLogs(): boolean;
}

export interface TerminalActionsOptions {
  /** false 면 listener 등록 안 하고 no-op cleanup. */
  enabled: boolean;
  /** TTY 가 아니면 listener 등록 skip — CI / pipe 환경 호환. */
  stdin?: NodeJS.ReadStream;
  /** 단축키 list 출력 callback (`?`). 미지정 시 INFO badge default. */
  printShortcuts?(): void;
}

/** `?` 응답 — INFO badge + 5칸 들여쓰기 + 앞뒤 빈 줄. */
export function printDefaultShortcuts(): void {
  console.log('');
  logInfo('Available shortcuts:');
  console.log(
    `     ${colors.bold}r${colors.reset} - Reload    ${colors.bold}d${colors.reset} - Dev Menu    ${colors.bold}j${colors.reset} - DevTools`,
  );
  console.log(
    `     ${colors.bold}i${colors.reset} - iOS Sim   ${colors.bold}a${colors.reset} - Android     ${colors.bold}c${colors.reset} - Clear cache`,
  );
  console.log(
    `     ${colors.bold}v${colors.reset} - Toggle console logs           ${colors.bold}?${colors.reset} - Show this help`,
  );
  console.log('');
}

function openIOSSimulator(): void {
  if (process.platform !== 'darwin') {
    logWarn('iOS Simulator is only available on macOS');
    return;
  }
  if (!existsSync('/usr/bin/xcrun')) {
    logWarn('xcrun not found. Install Xcode Command Line Tools.');
    return;
  }
  logInfo('Opening iOS Simulator...');
  const child = spawn('open', ['-a', 'Simulator'], {
    detached: true,
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  child.on('error', () => {
    /* spawn ENOENT/EACCES — silent skip */
  });
  child.unref();
}

// Defense-in-depth: emulator `-list-avds` 는 신뢰할만한 출력이지만 path injection
// 회피용으로 valid AVD name pattern 만 허용.
const AVD_NAME_RE = /^[a-zA-Z0-9._-]+$/;

function openAndroidEmulator(): void {
  const androidHome = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
  if (!androidHome) {
    logWarn('ANDROID_HOME or ANDROID_SDK_ROOT not set');
    return;
  }
  const emulatorPath = join(androidHome, 'emulator', 'emulator');
  if (!existsSync(emulatorPath)) {
    logWarn('Android emulator not found. Check your Android SDK installation.');
    return;
  }

  const list = spawn(emulatorPath, ['-list-avds'], { stdio: ['ignore', 'pipe', 'ignore'] });
  list.on('error', () => {
    /* spawn ENOENT/EACCES */
  });
  let buf = '';
  list.stdout?.on('data', (chunk) => {
    buf += chunk.toString();
  });
  list.on('close', () => {
    const first = buf.split('\n').find((line) => line.trim().length > 0);
    if (!first) {
      logWarn('No Android AVDs found. Create an AVD first.');
      return;
    }
    const avdName = first.trim();
    if (!AVD_NAME_RE.test(avdName)) {
      logWarn('Invalid AVD name');
      return;
    }
    logInfo(`Opening Android Emulator: ${avdName}`);
    const child = spawn(emulatorPath, ['@' + avdName], {
      detached: true,
      stdio: ['ignore', 'ignore', 'ignore'],
    });
    child.on('error', () => {
      /* silent skip */
    });
    child.unref();
  });
}

/**
 * 터미널 raw mode + keypress listener. 반환된 cleanup 호출 시 raw mode 해제 +
 * listener 제거. enabled=false 또는 stdin 비-TTY 시 no-op cleanup.
 *
 * Ctrl+C / Ctrl+D 는 raw mode 에서 자동 SIGINT 안 가서 직접 process.kill 처리.
 */
export function setupTerminalActions(
  callbacks: TerminalActionsCallbacks,
  options: TerminalActionsOptions = { enabled: true },
): () => void {
  const stdin = options.stdin ?? process.stdin;
  if (!options.enabled) return () => {};
  if (!stdin.isTTY) {
    // 사용자가 단축키 안 먹는다고 보고하는 흔한 원인 — wrapper script (npm run /
    // bun run) 가 stdin 을 inherit 안 해서 child 의 isTTY false. silent skip 시
    // 사용자가 디버그 어려움 → 한 번 stderr 알림 (#2605 audit).
    process.stderr.write(
      '[zntc:rn-dev] stdin is not a TTY — keyboard shortcuts (r/d/j/i/a/c/?) disabled\n',
    );
    return () => {};
  }

  const wasRaw = stdin.isRaw;
  let rawModeOk = true;
  if (!wasRaw) {
    try {
      stdin.setRawMode(true);
    } catch (err) {
      rawModeOk = false;
      process.stderr.write(
        `[zntc:rn-dev] setRawMode failed (${(err as Error).message ?? err}) — keyboard shortcuts disabled\n`,
      );
      return () => {};
    }
  }
  // 진단 — `ZNTC_DEBUG_TERMINAL=1` 시 listener 등록 상태 출력. Bun runtime / wrapper
  // script 의 stdin pipe 문제 추적용.
  if (process.env.ZNTC_DEBUG_TERMINAL === '1') {
    process.stderr.write(
      `[zntc:rn-dev:debug] terminal-actions: isTTY=${stdin.isTTY} isRaw=${stdin.isRaw} rawModeOk=${rawModeOk} runtime=${process.versions.bun ? `bun-${process.versions.bun}` : `node-${process.versions.node}`}\n`,
    );
  }
  stdin.resume();
  stdin.setEncoding('utf8');

  const printShortcuts = options.printShortcuts ?? printDefaultShortcuts;

  // Bun runtime 의 stdin 은 setEncoding('utf8') 호출해도 'data' event 가 Buffer 로
  // emit 될 수 있다 (Node 와 다른 동작). bungae graph-bundler/terminal-actions.ts
  // L283-288 가 동일 패턴. string|Buffer 둘 다 받아 toString 으로 정규화.
  const handleKey = (chunk: string | Buffer): void => {
    const key = typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    if (process.env.ZNTC_DEBUG_TERMINAL === '1') {
      // 원본 byte 보존 — UTF-8 invalid sequence 디버깅용. string→Buffer round-trip 회피.
      const hex =
        typeof chunk === 'string'
          ? Buffer.from(chunk, 'utf8').toString('hex')
          : chunk.toString('hex');
      process.stderr.write(
        `[zntc:rn-dev:debug] key received: hex=${hex} len=${key.length} type=${typeof chunk}\n`,
      );
    }
    // Bun event loop edge case — raw mode 가 외부에서 false 로 reset 될 수 있음.
    if (stdin.isTTY && !stdin.isRaw) {
      try {
        stdin.setRawMode(true);
      } catch {
        /* ignore */
      }
    }
    if (key === '\u0003') {
      cleanup();
      process.kill(process.pid, 'SIGINT');
      return;
    }
    if (key === '\u0004') {
      cleanup();
      process.kill(process.pid, 'SIGTERM');
      return;
    }
    switch (key.toLowerCase()) {
      case 'r':
        logInfo('Reloading app...');
        callbacks.onReload();
        break;
      case 'd':
        logInfo('Opening Dev Menu...');
        callbacks.onDevMenu();
        break;
      case 'j':
        logInfo('Opening DevTools...');
        callbacks.onOpenDevTools();
        break;
      case 'i':
        openIOSSimulator();
        break;
      case 'a':
        openAndroidEmulator();
        break;
      case 'c':
        callbacks.onClearCache();
        logInfo('Cache cleared');
        break;
      case 'v': {
        const enabled = callbacks.onToggleLogs();
        logInfo(`Console logs: ${enabled ? 'ON' : 'OFF'}`);
        break;
      }
      case '?':
        printShortcuts();
        break;
      default:
        break;
    }
  };

  stdin.on('data', handleKey);

  let cleanedUp = false;
  function cleanup(): void {
    if (cleanedUp) return;
    cleanedUp = true;
    stdin.removeListener('data', handleKey);
    if (!wasRaw && stdin.isTTY) {
      try {
        stdin.setRawMode(false);
      } catch {
        /* ignore */
      }
    }
    // pause() — process exit 시점에 stdin 이 resumed 상태로 남으면 graceful shutdown
    // 지연. cleanup 시 명시 pause.
    try {
      stdin.pause();
    } catch {
      /* ignore */
    }
  }

  return cleanup;
}
