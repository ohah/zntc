// 터미널 출력 helpers — ANSI colors + Metro 호환 INFO/WARN/ERROR badge +
// BUNDLE 상태 라인 + ZTS RN startup banner.

export const colors = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  inverse: '\x1b[7m',
  white: '\x1b[37m',
  gray: '\x1b[90m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
} as const;

/** Metro 호환 ` INFO ` cyan inverse bold badge. */
export function logInfo(...args: unknown[]): void {
  console.log(`${colors.inverse}${colors.bold}${colors.cyan} INFO ${colors.reset}`, ...args);
}

export function logWarn(...args: unknown[]): void {
  console.warn(`${colors.inverse}${colors.bold}${colors.yellow} WARN ${colors.reset}`, ...args);
}

export function logError(...args: unknown[]): void {
  console.error(`${colors.inverse}${colors.bold}${colors.red} ERROR ${colors.reset}`, ...args);
}

/**
 * Metro `TerminalReporter._getBundleStatusMessage` 호환 BUNDLE 상태 라인.
 * `done` 녹색 / `failed` 빨강 / `request` 노랑.
 */
export function logBundle(
  phase: 'done' | 'failed' | 'request',
  platform: string,
  subject: string,
  detail?: string,
): void {
  const color = phase === 'done' ? colors.green : phase === 'failed' ? colors.red : colors.yellow;
  const badge = `${color}${colors.inverse}${colors.bold} BUNDLE ${colors.reset}`;
  const tail = detail ? ` ${colors.dim}${detail}${colors.reset}` : '';
  console.log(`${badge} ${colors.dim}[${platform}]${colors.reset} ${subject}${tail}`);
}

const BANNER_WIDTH = 53;

function bannerLine(content: string): string {
  // ANSI escape 제거 후 visible length 측정.
  // eslint-disable-next-line no-control-regex
  const visibleLen = content.replace(/\x1b\[[0-9;]*m/g, '').length;
  const padding = Math.max(0, BANNER_WIDTH - visibleLen);
  const left = Math.floor(padding / 2);
  const right = padding - left;
  return `${colors.cyan}║${colors.reset}${' '.repeat(left)}${content}${' '.repeat(right)}${colors.cyan}║${colors.reset}`;
}

/** ZTS RN dev server 시작 banner. */
export function printZtsRnBanner(version?: string): void {
  const versionText = version ? ` v${version}` : '';
  const lines = [
    '',
    `${colors.cyan}╔${'═'.repeat(BANNER_WIDTH)}╗${colors.reset}`,
    bannerLine(''),
    bannerLine(`${colors.bold}${colors.cyan}@zts/react-native${colors.reset}${versionText}`),
    bannerLine(`${colors.gray}Metro-compatible RN dev server${colors.reset}`),
    bannerLine(''),
    `${colors.cyan}╚${'═'.repeat(BANNER_WIDTH)}╝${colors.reset}`,
    '',
  ];
  console.log(lines.join('\n'));
}
