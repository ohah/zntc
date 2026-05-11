// ZNTC CLI 시작 banner — ASCII 로고 + 그라디언트 + 박스.
// 시각 디자인은 packages/react-native/src/dev-server/logger.ts 의
// `printZntcRnBanner` 와 sync 유지 (양쪽 동시 수정).

const colors = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  gray: '\x1b[90m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
};

const BANNER_WIDTH = 59;

function bannerLine(content) {
  // eslint-disable-next-line no-control-regex
  const visibleLen = content.replace(/\x1b\[[0-9;]*m/g, '').length;
  const padding = Math.max(0, BANNER_WIDTH - visibleLen);
  const left = Math.floor(padding / 2);
  const right = padding - left;
  return `${colors.cyan}    ║${colors.reset}${' '.repeat(left)}${content}${' '.repeat(right)}${colors.cyan}║${colors.reset}`;
}

const ZNTC_ASCII = [
  '███████╗███╗   ██╗████████╗ ██████╗',
  '╚══███╔╝████╗  ██║╚══██╔══╝██╔════╝',
  '  ███╔╝ ██╔██╗ ██║   ██║   ██║     ',
  ' ███╔╝  ██║╚██╗██║   ██║   ██║     ',
  '███████╗██║ ╚████║   ██║   ╚██████╗',
  '╚══════╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝',
];

const ZNTC_GRADIENT = [
  colors.yellow,
  colors.yellow,
  colors.blue,
  colors.blue,
  colors.magenta,
  colors.magenta,
];

const TAGLINES = {
  web: 'Lightning Fast Web Bundler',
  rn: 'Lightning Fast React Native Bundler',
};

/**
 * ZNTC 시작 banner 출력.
 *
 * - `silent: true` 또는 비-TTY 환경에서는 plain 한 줄 (`zntc <flavor> v0.1.0`) 만 출력.
 *   ASCII art 의 ANSI escape 가 CI 로그 / pipe 에서 노이즈가 되는 것을 막는다.
 *
 * @param {{ flavor: 'web' | 'rn', version?: string, silent?: boolean }} opts
 */
export function printZntcBanner({ flavor, version, silent = false }) {
  if (silent) return;
  const tagline = TAGLINES[flavor];
  if (!tagline) throw new Error(`printZntcBanner: unknown flavor "${flavor}"`);

  const versionText = version ? `v${version}` : '';

  if (!process.stdout.isTTY) {
    console.log(`zntc ${flavor}${versionText ? ` ${versionText}` : ''} — ${tagline}`);
    return;
  }

  const logoLines = ZNTC_ASCII.map((line, i) =>
    bannerLine(`${colors.bold}${ZNTC_GRADIENT[i]}${line}${colors.reset}`),
  );
  const lines = [
    '',
    `${colors.cyan}    ╔${'═'.repeat(BANNER_WIDTH)}╗${colors.reset}`,
    bannerLine(''),
    ...logoLines,
    bannerLine(''),
    bannerLine(`${colors.cyan}${tagline}${colors.reset}`),
    bannerLine(`${colors.gray}${versionText}${colors.reset}`),
    bannerLine(''),
    `${colors.cyan}    ╚${'═'.repeat(BANNER_WIDTH)}╝${colors.reset}`,
    '',
  ];
  console.log(lines.join('\n'));
}
