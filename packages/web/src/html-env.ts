import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * HTML 안의 EJS 스타일 토큰 `<%= KEY %>` 를 환경변수 값으로 치환.
 *
 * - 토큰 양식: `<%=` (양쪽 공백 허용) `KEY` `%>`. `KEY` 는 `[A-Za-z_][A-Za-z0-9_]*`.
 * - 치환 값은 `<`, `>`, `&`, `"` 를 HTML escape 한다 — `.env` 값이 attribute 안 또는 script
 *   안에 들어가 XSS / attribute 깨짐을 만드는 것을 차단. 사용자가 의도적으로 HTML 을
 *   넣고 싶다면 별도 옵션 (현재 미지원) 또는 inline script + import.meta.env 사용.
 * - 허용 prefix 외 키는 원본 토큰을 그대로 두고 warning. typo / secret 노출 실수를 가시화.
 * - 미발견 키는 빈 문자열로 치환 + warning (Vite/CRA 호환).
 * - expression 평가 (`<%= mode === 'prod' ? ... %>`) 는 미지원 — key-only. KEY 시작이
 *   숫자 / 기호여서 regex 가 reject.
 */

export const DEFAULT_HTML_ENV_PREFIX = 'ZNTC_';

const TOKEN_RE = /<%=\s*([A-Za-z_][A-Za-z0-9_]*)\s*%>/g;

const HTML_ESCAPE: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
};

function escapeHtml(value: string): string {
  return value.replace(/[&<>"]/g, (c) => HTML_ESCAPE[c]);
}

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

  const next = html.replace(TOKEN_RE, (match, key: string) => {
    if (!key.startsWith(prefix)) {
      warnings.push(
        `token "${match}" uses key "${key}" without allowed prefix "${prefix}" — kept as-is`,
      );
      return match;
    }
    const value = env[key];
    if (value === undefined) {
      warnings.push(`"${key}" not found in environment — replaced with empty string`);
      return '';
    }
    return escapeHtml(value);
  });

  return { html: next, changed: next !== html, warnings };
}

/**
 * `<outdir>/index.html` 을 읽고 EJS 토큰을 치환한 결과를 다시 쓴다.
 * ENOENT 는 silent skip — dev mode 에서 entry HTML 이 아직 없을 수 있음.
 * `changed=false` 면 write 도 생략 — 같은 결과 재기록으로 인한 mtime 변화 / watcher 트리거 방지.
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
