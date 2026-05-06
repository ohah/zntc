// zts sourcemap 후처리 — DevTools 의 x_google_ignoreList 확장 + production
// bundle 의 sourceRoot / 절대 경로 옵션. zts 가 emit 한 기존 ignore hint 항목
// 보존 + node_modules + zts internal source (zts: prefix — runtime polyfill /
// babel transform 등) 추가. 잘못된 JSON 이면 rawJson 반환 (caller 가 빈 응답 회피).

import { isAbsolute, resolve } from 'node:path';

/**
 * NAPI 가 emit 한 zts internal source 는 Rolldown virtual module convention
 * 으로 NUL prefix (U+0000) — 예: NUL + 'zts:runtime/spread-array'.
 * regex \\s 는 NUL 미매칭이라 char class [\\x00-\\x20] 로 control range 까지
 * 모두 strip.
 */
function stripVirtualPrefix(src: string): string {
  return src.replace(/^[\x00-\x20]+/, '');
}

/**
 * source string 이 file system path 가 아닌 virtual module 인지 판정 — RFC 3986
 * URI scheme (`zts:` / `http:` / `bun:` 등) prefix 가 있으면 virtual.
 * `useAbsolutePath` 시 file path 만 absolutize 하고 virtual 은 skip.
 */
function isVirtualSource(stripped: string): boolean {
  return /^[a-z][a-z0-9+.-]*:/i.test(stripped);
}

/**
 * source string 이 user code 가 아닌 framework / polyfill 영역인지 판정.
 * Metro `Server._shouldAddModuleToIgnoreList` 기준:
 * - `__prelude__`
 * - `?ctx=` context module
 * - serializer.isThirdPartyModule 기본값인 node_modules path
 *
 * `zts:` prefix 는 NAPI emitter 의 internal source naming 과 sync — 변경 시
 * zts core (Zig 측 emitter) 와 함께 업데이트 필요.
 */
function isFrameworkSource(src: unknown): boolean {
  if (typeof src !== 'string') return false;
  const stripped = stripVirtualPrefix(src);
  return (
    stripped === '__prelude__' ||
    stripped.includes('?ctx=') ||
    /(?:^|[/\\])node_modules[/\\]/.test(stripped) ||
    stripped.startsWith('zts:')
  );
}

export interface SourcemapPathOptions {
  /** Metro `sourcemapSourcesRoot` — sourcemap JSON 의 sourceRoot field. */
  sourceRoot?: string;
  /** Metro `sourcemapUseAbsolutePath` — sources 의 path 를 절대화. virtual module skip. */
  useAbsolutePath?: boolean;
  /** projectRoot — useAbsolutePath 시 base. 미설정 시 process.cwd(). */
  projectRoot?: string;
}

/**
 * sourcemap 후처리 — DevTools `x_google_ignoreList` 확장 + (옵션 시)
 * `sourceRoot` / sources 절대화. JSON round-trip 1회로 모든 변환을 한 패스.
 *
 * 잘못된 JSON 또는 version != 3 이면 rawJson 반환 (caller 가 빈 응답 회피).
 */
export function postProcessSourceMap(rawJson: string, pathOpts?: SourcemapPathOptions): string {
  try {
    const map = JSON.parse(rawJson);
    if (map.version !== 3 || !map.sources) return rawJson;

    // (1) Metro-compatible map shape.
    // zts core 는 library/file output 을 위해 `file` 과 빈 `sourceRoot` 를 emit 한다.
    // RN DevTools 는 loaded script URL (`index.bundle?...`) 을 기준으로 blackbox 처리를
    // 하므로, dev-server map 에서는 Metro 처럼 `file` 을 생략한다. sourceRoot 도
    // 사용자가 명시하지 않은 빈 값이면 생략해 Metro 기본값과 맞춘다.
    delete map.file;
    if (pathOpts?.sourceRoot === undefined && map.sourceRoot === '') {
      delete map.sourceRoot;
    }

    // (2) x_google_ignoreList — 기존 보존 + framework source 추가.
    // Metro-source-map Generator 는 legacy `x_google_ignoreList` 만 직렬화한다.
    // RN DevTools 는 `ignoreList ?? x_google_ignoreList` 순서로 읽기 때문에,
    // Metro shape 과 맞추기 위해 output 에서는 standard `ignoreList` 를 제거한다.
    const existing = new Set<number>(
      [
        ...(Array.isArray(map.x_google_ignoreList) ? map.x_google_ignoreList : []),
        ...(Array.isArray(map.ignoreList) ? map.ignoreList : []),
      ].filter((v): v is number => Number.isInteger(v) && v >= 0),
    );
    for (let i = 0; i < map.sources.length; i++) {
      if (isFrameworkSource(map.sources[i])) existing.add(i);
    }
    if (existing.size > 0) {
      const ignoreList = [...existing].sort((a, b) => a - b);
      map.x_google_ignoreList = ignoreList;
    } else {
      delete map.x_google_ignoreList;
    }
    delete map.ignoreList;

    // (3) path 옵션 (Metro 호환) — sourceRoot field + sources 절대화.
    if (pathOpts) {
      if (pathOpts.sourceRoot !== undefined) {
        map.sourceRoot = pathOpts.sourceRoot;
      }
      if (pathOpts.useAbsolutePath && Array.isArray(map.sources)) {
        const projectRoot = pathOpts.projectRoot ?? process.cwd();
        map.sources = map.sources.map((s: unknown) => {
          if (typeof s !== 'string') return s;
          const stripped = stripVirtualPrefix(s);
          if (isVirtualSource(stripped) || isAbsolute(stripped)) return s;
          return resolve(projectRoot, s);
        });
      }
    }

    return JSON.stringify(map);
  } catch {
    return rawJson;
  }
}

/** @deprecated `postProcessSourceMap(rawJson, opts)` 의 path 옵션 사용. */
export function applyMapPathOptions(rawJson: string, options: SourcemapPathOptions): string {
  return postProcessSourceMap(rawJson, options);
}
