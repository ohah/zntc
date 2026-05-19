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
  // 16-color 엔 진짜 amber/orange 가 없어 bright-yellow→yellow→bright-red 로
  // warm 근사. 256-color 는 미지원 터미널서 무색으로 떨어져 보편 16-color 사용.
  brightYellow: '\x1b[93m',
  brightRed: '\x1b[91m',
};

/**
 * 색상(ANSI) 출력 사용 여부. NO_COLOR / FORCE_COLOR 관례(no-color.org,
 * supports-color) 준수: `NO_COLOR` 가 비어있지 않으면 무조건 비활성,
 * `FORCE_COLOR` 가 "0"/"false" 가 아니면(빈 문자열 포함 — supports-color 관례상
 * 활성) 무조건 활성, 둘 다 없으면 TTY 여부.
 */
export function shouldUseColor() {
  const { NO_COLOR, FORCE_COLOR } = process.env;
  if (NO_COLOR) return false;
  if (FORCE_COLOR !== undefined) return FORCE_COLOR !== '0' && FORCE_COLOR !== 'false';
  return Boolean(process.stdout.isTTY);
}

/**
 * `zntc --color` / `--no-color` 를 NO_COLOR/FORCE_COLOR env 로 환원해 shouldUseColor()
 * 단일 경로로 합류시킨다. 명시 flag 는 **반대편 env 를 제거**해 기존 env 보다
 * 우선한다 (`NO_COLOR=1 zntc --color` → 색상 ON). `color` 미지정(undefined) 시
 * env 무변경 → 기존 NO_COLOR/FORCE_COLOR/TTY 자동 판정 유지.
 *
 * @param {boolean | undefined} color  opts.color (true=강제, false=억제, undefined=자동)
 * @param {Record<string, string | undefined>} env  기본 process.env (테스트는 주입)
 */
export function applyColorPreference(color, env = process.env) {
  if (color === true) {
    delete env.NO_COLOR;
    env.FORCE_COLOR = '1';
  } else if (color === false) {
    delete env.FORCE_COLOR;
    env.NO_COLOR = '1';
  }
}

const BANNER_WIDTH = 59;

function bannerLine(content) {
  // eslint-disable-next-line no-control-regex
  const visibleLen = content.replace(/\x1b\[[0-9;]*m/g, '').length;
  const padding = Math.max(0, BANNER_WIDTH - visibleLen);
  const left = Math.floor(padding / 2);
  const right = padding - left;
  return `${colors.cyan}    ║${colors.reset}${' '.repeat(left)}${content}${' '.repeat(right)}${colors.cyan}║${colors.reset}`;
}

// 지구라트 로고 — zntc-logo.svg / favicon 과 동일: 단 사이가 띈 적층 바
// (햄버거식). half-block `▀` 로 한 줄에 바+여백을 담아 절반 높이·컴팩트.
// ZNTC_GRADIENT 와 index 1:1. bannerLine 이 각 줄을 박스 중앙 정렬.
export const ZNTC_ASCII = [
  '▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
  '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀',
];

export const ZNTC_GRADIENT = [
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

const TAGLINES = {
  web: 'Lightning Fast Web Bundler',
  rn: 'Lightning Fast React Native Bundler',
};

/**
 * ZNTC 시작 banner 출력.
 *
 * - `silent: true` 또는 색상 비활성 환경(비-TTY / NO_COLOR / `--no-color`)에서는
 *   plain 한 줄 (`zntc <flavor> v0.1.0`) 만 출력. ASCII art 의 ANSI escape 가 CI
 *   로그 / pipe 에서 노이즈가 되는 것을 막는다.
 *
 * @param {{ flavor: 'web' | 'rn', version?: string, silent?: boolean }} opts
 */
export function printZntcBanner({ flavor, version, silent = false }) {
  if (silent) return;
  const tagline = TAGLINES[flavor];
  if (!tagline) throw new Error(`printZntcBanner: unknown flavor "${flavor}"`);

  const versionText = version ? `v${version}` : '';

  if (!shouldUseColor()) {
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
