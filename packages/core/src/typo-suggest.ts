/**
 * Typo 검출 및 "did you mean ...?" 제안 (#2109).
 *
 * `levenshtein` 으로 알려진 옵션 키와 비교해 거리 ≤ threshold 인 가장 가까운
 * 키를 제안. config 파일의 unknown 키, CLI flag 의 unknown name 둘 다 사용.
 */

/** Wagner-Fischer DP, single-row 메모리. */
function levenshtein(a: string, b: string): number {
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  // 짧은 쪽을 열로 — 메모리 절감.
  const [s, l] = a.length <= b.length ? [a, b] : [b, a];

  let prev = Array.from<number>({ length: s.length + 1 });
  let curr = Array.from<number>({ length: s.length + 1 });
  for (let i = 0; i <= s.length; i++) prev[i] = i;

  for (let i = 1; i <= l.length; i++) {
    curr[0] = i;
    for (let j = 1; j <= s.length; j++) {
      const cost = l.charCodeAt(i - 1) === s.charCodeAt(j - 1) ? 0 : 1;
      curr[j] = Math.min(
        prev[j] + 1, // 삭제
        curr[j - 1] + 1, // 삽입
        prev[j - 1] + cost, // 치환
      );
    }
    [prev, curr] = [curr, prev];
  }
  return prev[s.length];
}

/**
 * `unknown` 과 가장 가까운 `known` 키 중 거리 `<= threshold` 인 것 반환.
 *
 * threshold 기본 2 — 짧은 키 (3자 이하) 는 거리 2 만 허용해도 false positive 가
 * 많아질 수 있으므로 길이별로 자동 조정 (`Math.min(threshold, ceil(len/3))`).
 *
 * 다중 매치 시 가장 짧은 거리, 동률이면 알파벳순.
 */
export function suggestKey(
  unknown: string,
  known: readonly string[],
  threshold: number = 2,
): string | null {
  if (!unknown || known.length === 0) return null;
  // 매우 짧은 unknown 은 false positive 우려 — 거리 1 까지만.
  const adjusted = Math.min(threshold, Math.max(1, Math.ceil(unknown.length / 3)));

  let best: string | null = null;
  let bestDist = adjusted + 1;

  for (const candidate of known) {
    const d = levenshtein(unknown, candidate);
    if (d > adjusted) continue;
    if (d < bestDist || (d === bestDist && best !== null && candidate < best)) {
      best = candidate;
      bestDist = d;
    }
  }
  return best;
}

/**
 * config 객체의 모든 키를 검사해 unknown 발견 시 console.warn 으로 경고 + 제안.
 *
 * `silent: true` 면 출력 안 하고 `{ unknown, suggestion }` 배열만 반환 — 테스트용.
 */
export function warnUnknownKeys(
  config: Record<string, unknown>,
  known: readonly string[],
  options: { silent?: boolean; sourceLabel?: string } = {},
): Array<{ unknown: string; suggestion: string | null }> {
  const result: Array<{ unknown: string; suggestion: string | null }> = [];
  const knownSet = new Set(known);

  for (const key of Object.keys(config)) {
    if (knownSet.has(key)) continue;
    const suggestion = suggestKey(key, known);
    result.push({ unknown: key, suggestion });
    if (!options.silent) {
      const where = options.sourceLabel ? ` (${options.sourceLabel})` : "";
      const hint = suggestion ? ` — did you mean '${suggestion}'?` : "";
      console.warn(`@zts/core: unknown config key '${key}'${where}${hint}`);
    }
  }
  return result;
}

/**
 * 알려진 BuildOptions / TranspileOptions / config-only 키 (`extends` 등) 통합 목록.
 *
 * `BuildOptions` 타입에서 자동 추출하지 못해 (TS 타입 → 런타임 변환 미구현)
 * 수동 동기화. 새 옵션 추가 시 이 리스트에 함께 추가.
 *
 * 단일 source of truth 화는 #2112 (Phase 3-5 schema sync) 의 책임 — 그 PR 이
 * `BuildOptions` ↔ Zig DTO 양방향 검증을 도입하면서 이 리스트도 자동 생성 가능.
 */
export const KNOWN_CONFIG_KEYS: readonly string[] = [
  // ─── 진입 ───
  "entryPoints",
  "outdir",
  "outfile",
  "outbase",
  // ─── 포맷 / 타겟 ───
  "format",
  "platform",
  "target",
  "browserslist",
  // ─── JSX ───
  "jsx",
  "jsxDev",
  "jsxFactory",
  "jsxFragment",
  "jsxImportSource",
  "jsxInJs",
  "jsxSideEffects",
  // ─── Minify ───
  "minify",
  "minifyWhitespace",
  "minifyIdentifiers",
  "minifySyntax",
  // ─── Sourcemap ───
  "sourcemap",
  "sourcemapMode",
  "sourcemapDebugIds",
  "sourcesContent",
  "sourceRoot",
  // ─── 모듈 / Resolve ───
  "external",
  "alias",
  "define",
  "loader",
  "conditions",
  "resolveExtensions",
  "mainFields",
  "packagesExternal",
  "preserveSymlinks",
  // ─── Bundle 출력 ───
  "splitting",
  "outputExports",
  "preserveModules",
  "preserveModulesRoot",
  "inlineDynamicImports",
  "manualChunks",
  "metafile",
  "treeShaking",
  "shimMissingExports",
  "keepNames",
  // ─── Drop ───
  "drop",
  "dropConsole",
  "dropDebugger",
  "dropLabels",
  // ─── 코드 주입 ───
  "banner",
  "footer",
  "intro",
  "outro",
  "inject",
  "pure",
  "legalComments",
  // ─── Naming ───
  "entryNames",
  "chunkNames",
  "assetNames",
  // ─── TypeScript / decorator ───
  "experimentalDecorators",
  "emitDecoratorMetadata",
  "useDefineForClassFields",
  "verbatimModuleSyntax",
  "tsconfigPath",
  "tsconfigRaw",
  // ─── Rollup 호환 ───
  "globalName",
  "globals",
  "publicPath",
  // ─── Charset / quote ───
  "charsetUtf8",
  "asciiOnly",
  "quotes",
  // ─── 기타 ───
  "flow",
  "plugins",
  "logLevel",
  "logLimit",
  "lineLimit",
  "ignoreAnnotations",
  "watchDelay",
  "jobs",
  // ─── config-only ───
  "extends",
];
