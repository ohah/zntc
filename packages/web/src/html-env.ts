import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * HTML 안의 EJS 스타일 토큰 `<%= KEY %>` 를 환경변수 값으로 치환.
 *
 * - 토큰 양식: `<%=` (양쪽 공백 허용) `KEY` `%>`. `KEY` 는 `[A-Za-z_][A-Za-z0-9_]*`.
 * - 허용 prefix 외 키는 원본 토큰을 그대로 두고 warning 만 기록. 사용자가 typo / secret 노출
 *   실수를 알 수 있게 하기 위함. (`VITE_*` 같은 다른 prefix 가 HTML 에 그대로 노출되는 것을 방지)
 * - 미발견 키는 빈 문자열로 치환 + warning (Vite/CRA 와 동일 동작).
 * - expression 평가 (`<%= mode === 'prod' ? ... %>`) 는 미지원 — key-only.
 */

export const DEFAULT_HTML_ENV_PREFIX = 'ZNTC_';

const TOKEN_RE = /<%=\s*([A-Za-z_][A-Za-z0-9_]*)\s*%>/g;

export interface TransformHtmlEnvResult {
  html: string;
  changed: boolean;
  warnings: string[];
}

export function transformHtmlEnvTokens(
  html: string,
  env: Record<string, string>,
  prefix: string = DEFAULT_HTML_ENV_PREFIX,
): TransformHtmlEnvResult {
  const warnings: string[] = [];
  let changed = false;

  const next = html.replace(TOKEN_RE, (match, key: string) => {
    if (!key.startsWith(prefix)) {
      warnings.push(
        `html env: token "${match}" uses key "${key}" without allowed prefix "${prefix}" — kept as-is`,
      );
      return match;
    }
    const value = env[key];
    if (value === undefined) {
      warnings.push(`html env: "${key}" not found in environment — replaced with empty string`);
      changed = true;
      return '';
    }
    changed = true;
    return value;
  });

  return { html: next, changed, warnings };
}

/**
 * `<outdir>/index.html` 을 읽고 EJS 토큰을 치환한 결과를 다시 쓴다.
 * ENOENT 는 silent skip — dev mode 에서 entry HTML 이 아직 없을 수 있음.
 * 토큰이 하나도 변하지 않았으면 write 도 생략 (touch 회피).
 */
export function applyHtmlEnvTokens(
  outdir: string,
  env: Record<string, string>,
  prefix: string = DEFAULT_HTML_ENV_PREFIX,
): { warnings: string[] } {
  const htmlPath = join(outdir, 'index.html');
  let html: string;
  try {
    html = readFileSync(htmlPath, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ENOENT') return { warnings: [] };
    throw err;
  }
  const result = transformHtmlEnvTokens(html, env, prefix);
  if (result.changed) writeFileSync(htmlPath, result.html);
  return { warnings: result.warnings };
}
