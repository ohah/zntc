/**
 * `.env` 파일 로더 (Vite 호환).
 *
 * 4단계 우선순위 (낮은 → 높은) 로 머지:
 *  1. `.env` (general, committed)
 *  2. `.env.local` (general, gitignored)
 *  3. `.env.${mode}` (mode-specific, committed)
 *  4. `.env.${mode}.local` (mode-specific, gitignored)
 *
 * `prefixes` 로 시작하는 키만 반환 (default `["VITE_", "ZTS_"]`).
 * 빈 문자열 prefix `""` 를 포함하면 전체 노출 — 주의해서 사용.
 */

import { readFileSync } from "node:fs";
import { resolve as pathResolve } from "node:path";

/**
 * `.env` 라인 1개를 `KEY=value` 로 파싱. 단순한 dotenv 호환 파서:
 *  - `#` 주석 라인 무시
 *  - `=` 첫 번째만 split — value 안의 `=` 는 보존
 *  - value 가 `"..."` / `'...'` 로 감싸져 있으면 따옴표 제거 (escape sequence 미해석)
 *  - 빈 라인 / 키 없는 라인 무시
 */
function parseDotenvLine(line: string): [string, string] | null {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) return null;
  const eqIdx = trimmed.indexOf("=");
  if (eqIdx <= 0) return null;
  const key = trimmed.slice(0, eqIdx).trim();
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) return null;
  let value = trimmed.slice(eqIdx + 1).trim();
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    value = value.slice(1, -1);
  }
  return [key, value];
}

/** `.env` 파일 1개 파싱. 부재 시 빈 객체. */
function parseDotenvFile(filePath: string): Record<string, string> {
  let content: string;
  try {
    content = readFileSync(filePath, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw err;
  }
  const out: Record<string, string> = {};
  for (const line of content.split(/\r?\n/)) {
    const parsed = parseDotenvLine(line);
    if (parsed) out[parsed[0]] = parsed[1];
  }
  return out;
}

/**
 * `mode` 와 `envDir` 기준으로 `.env*` 파일 4종을 우선순위대로 로드 + 머지하고,
 * `prefixes` 로 시작하는 키만 반환.
 *
 * @param mode `--mode <name>` 으로 전달되는 값. 보통 `"production"` / `"development"`.
 * @param envDir `.env` 파일을 찾을 디렉토리. CLI 의 cwd 기본.
 * @param prefixes 노출할 키 prefix 목록. default `["VITE_", "ZTS_"]`. 단일 string 도 허용.
 */
export function loadEnv(
  mode: string,
  envDir: string,
  prefixes: string | string[] = ["VITE_", "ZTS_"],
): Record<string, string> {
  const prefixList = Array.isArray(prefixes) ? prefixes : [prefixes];
  const dir = pathResolve(envDir);

  // 우선순위: 뒤로 갈수록 덮어씀.
  const files = [`.env`, `.env.local`, `.env.${mode}`, `.env.${mode}.local`];

  const merged: Record<string, string> = {};
  for (const file of files) {
    Object.assign(merged, parseDotenvFile(`${dir}/${file}`));
  }

  // prefix 필터.
  const filtered: Record<string, string> = {};
  for (const [key, value] of Object.entries(merged)) {
    if (prefixList.some((p) => key.startsWith(p))) {
      filtered[key] = value;
    }
  }
  return filtered;
}

/**
 * `loadEnv` 결과 + 빌드 컨텍스트를 `import.meta.env.*` define 으로 변환.
 *
 * `import.meta.env.MODE` / `PROD` / `DEV` / `SSR` 를 자동 주입한다 (Vite 호환).
 * 사용자 정의 키는 모두 `JSON.stringify` 로 직렬화해 ZTS define 에 안전한 리터럴 형태로 전달.
 */
export function envToDefine(env: Record<string, string>, mode: string): Record<string, string> {
  const define: Record<string, string> = {
    "import.meta.env.MODE": JSON.stringify(mode),
    "import.meta.env.PROD": JSON.stringify(mode === "production"),
    "import.meta.env.DEV": JSON.stringify(mode !== "production"),
    "import.meta.env.SSR": JSON.stringify(false),
  };
  for (const [key, value] of Object.entries(env)) {
    define[`import.meta.env.${key}`] = JSON.stringify(value);
  }
  return define;
}
