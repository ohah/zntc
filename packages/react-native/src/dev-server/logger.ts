// 터미널 출력 helpers — ANSI colors + Metro 호환 INFO/WARN/ERROR badge +
// BUNDLE 상태 라인 + ZNTC RN startup banner.

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
  // 16-color 엔 진짜 amber/orange 가 없어 bright-yellow→yellow→bright-red 로
  // warm 근사. 256-color 는 미지원 터미널서 무색으로 떨어져 보편 16-color 사용.
  brightYellow: '\x1b[93m',
  brightRed: '\x1b[91m',
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
 * RN runtime 의 console.log 를 dev server 터미널로 forward 시 사용 — Metro 호환
 * level 별 색상 INVERSE BOLD badge. error=red / warn=yellow / debug=magenta /
 * info=cyan / log=white. bungae graph-bundler/utils.ts 패턴 동등.
 */
export function formatLogBadge(level: string): string {
  const color =
    level === 'error'
      ? colors.red
      : level === 'warn'
        ? colors.yellow
        : level === 'debug'
          ? colors.magenta
          : level === 'info'
            ? colors.cyan
            : colors.white;
  return `${color}${colors.inverse}${colors.bold} ${level.toUpperCase()} ${colors.reset}`;
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

const BANNER_WIDTH = 59;

function bannerLine(content: string): string {
  // ANSI escape 제거 후 visible length 측정.
  // eslint-disable-next-line no-control-regex
  const visibleLen = content.replace(/\x1b\[[0-9;]*m/g, '').length;
  const padding = Math.max(0, BANNER_WIDTH - visibleLen);
  const left = Math.floor(padding / 2);
  const right = padding - left;
  return `${colors.cyan}    ║${colors.reset}${' '.repeat(left)}${content}${' '.repeat(right)}${colors.cyan}║${colors.reset}`;
}

// 지구라트 로고 — 단 사이가 띈 적층 바(햄버거식, zntc-logo.svg 와 동일).
// half-block `▀` 로 한 줄에 바+여백 → 절반 높이·컴팩트. banner.mjs 와
// sync 유지 (양쪽 동시 수정).
export const ZNTC_ASCII = [
  '▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
] as const;

// 명시 타입 필수: --isolatedDeclarations 는 export const 초기값의
// property access (colors.brightYellow) 를 추론 못 함 (TS9013).
export const ZNTC_GRADIENT: readonly string[] = [
  colors.brightYellow,
  colors.brightYellow,
  colors.yellow,
  colors.brightRed,
  colors.brightRed,
];

// ZNTC_ASCII[i] 는 ZNTC_GRADIENT[i] 로 색칠 — desync 시 undefined 가
// visibleLen 을 오염시켜 줄 정렬이 깨진다. import 시점 fail-fast.
if (ZNTC_ASCII.length !== ZNTC_GRADIENT.length) {
  throw new Error(
    `ZNTC banner: ZNTC_ASCII(${ZNTC_ASCII.length}) / ZNTC_GRADIENT(${ZNTC_GRADIENT.length}) 길이 불일치`,
  );
}

/** ZNTC RN dev server 시작 banner — ASCII 로고 + 그라디언트 + 박스. */
export function printZntcRnBanner(version?: string): void {
  const versionText = version ? `v${version}` : '';
  const logoLines = ZNTC_ASCII.map((line, i) =>
    bannerLine(`${colors.bold}${ZNTC_GRADIENT[i]}${line}${colors.reset}`),
  );
  const lines = [
    '',
    `${colors.cyan}    ╔${'═'.repeat(BANNER_WIDTH)}╗${colors.reset}`,
    bannerLine(''),
    ...logoLines,
    bannerLine(''),
    bannerLine(`${colors.cyan}Lightning Fast React Native Bundler${colors.reset}`),
    bannerLine(`${colors.gray}${versionText}${colors.reset}`),
    bannerLine(''),
    `${colors.cyan}    ╚${'═'.repeat(BANNER_WIDTH)}╝${colors.reset}`,
    '',
  ];
  console.log(lines.join('\n'));
}
