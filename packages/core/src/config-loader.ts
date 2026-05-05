/**
 * zts.config.{ts,mts,cts,mjs,js,cjs,json} 로더.
 *
 * `.ts/.mts/.cts` 는 NAPI `transpile()` 로 self-compile 후 dynamic import.
 * `.mjs/.js/.cjs` 는 직접 dynamic import. `.json` 은 readFileSync + JSON.parse.
 *
 * tmp 파일은 config 옆에 작성해 사용자의 node_modules resolution 을 보존한다
 * (esbuild `esbuild.config.bundled-*.mjs` 패턴).
 */

import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, resolve as pathResolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import type { BuildOptions } from '../index';
import { init, isPlainObject, transpile } from '../index';

/**
 * config 객체 형태 — 모든 BuildOptions 의 부분 집합.
 *
 * `extends` (`#2108`) 는 다른 config 파일을 base 로 상속받는 식별자 — 단일 string
 * 또는 배열. config-loader 가 로드 시 자동 해석하므로 최종 사용자 config 에는
 * 노출되지 않는다 (resolveExtends 가 strip).
 */
export type UserConfig = Partial<BuildOptions> & {
  extends?: string | string[];
};

/**
 * 함수형 config 호출 시 주입되는 컨텍스트 (Vite 호환 형태).
 *
 * - `command`: CLI 모드. `bundle` (default), `serve`, `watch`.
 * - `mode`: `--mode <name>` 으로 지정. 미지정 시 command 별 기본값
 *   (`serve`/`watch` → `development`, 그 외 → `production`).
 * - `env`: `process.env` + `.env*` merge 결과. CLI 경로에서는 `loadEnv()` prefix 필터
 *   결과를 shell env 위에 합쳐 전달한다.
 */
export interface ConfigEnv {
  command: 'bundle' | 'serve' | 'watch';
  mode: string;
  env: Record<string, string | undefined>;
}

/** 함수형 config — `defineConfig(({ command, mode, env }) => ...)` 형태. */
export type UserConfigFn = (env: ConfigEnv) => UserConfig | Promise<UserConfig>;

/** config 파일이 export 가능한 형태 — 객체 또는 함수. */
export type UserConfigInput = UserConfig | UserConfigFn;

/**
 * 자동 탐색 우선순위. 동일 디렉토리에 다중 확장자 존재 시 첫 매치 반환.
 * 사용자가 의도적으로 여러 형식을 두는 경우는 거의 없으므로 silent precedence 로 충분.
 *
 * 같은 배열에서 `TS_EXTS`/`JS_EXTS` 를 derive — 새 확장자 추가 시 한 곳만 고침.
 */
export const CONFIG_EXT_PRIORITY = ['.ts', '.mts', '.cts', '.mjs', '.js', '.cjs', '.json'] as const;

const TS_EXTS = new Set<string>(CONFIG_EXT_PRIORITY.slice(0, 3));
const JS_EXTS = new Set<string>(CONFIG_EXT_PRIORITY.slice(3, 6));

/**
 * config 파일을 로드한다. 확장자에 따라 self-compile 또는 직접 import.
 *
 * 존재 여부는 사전 stat 으로 확인하지 않고 실제 read/import 의 ENOENT 를 catch
 * 한다 — TOCTOU 회피 + 1 syscall 절감.
 *
 * 함수형 config 가 export 됐으면 `env` 인자를 전달해 호출하고 반환된 객체를 사용한다.
 * `env` 미제공 시 적절한 기본값 (`command: "bundle", mode: "production"`) 으로 호출.
 *
 * @throws 파일이 없거나, 확장자가 지원되지 않거나, 컴파일/평가가 실패하면 throw.
 */
export async function loadConfig(filePath: string, env?: ConfigEnv): Promise<UserConfig> {
  const absPath = pathResolve(filePath);
  return loadConfigWithExtends(absPath, env, new Set());
}

/**
 * `extends` 필드 재귀 해석 (#2108).
 *
 * 한 config 가 `extends: "./base"` 또는 `extends: [a, b]` 로 다른 config 를
 * 상속받는다. 머지 규칙:
 *  - 다중 extends 는 왼쪽부터 순차 적용 (오른쪽이 왼쪽 override)
 *  - 마지막에 현재 config 가 모든 extends 를 override
 *  - `mergeUserConfigs` 의 정책 (객체 shallow merge / 배열 mode override / plugins concat) 재사용
 *
 * 순환 참조 감지: `visited` Set 으로 추적 — `A extends B`, `B extends A` 시 throw.
 *
 * extends 경로는 현재 config 디렉토리 기준 상대 경로. 절대 경로도 허용.
 */
async function loadConfigWithExtends(
  absPath: string,
  env: ConfigEnv | undefined,
  visited: Set<string>,
): Promise<UserConfig> {
  if (visited.has(absPath)) {
    throw new Error(
      `@zts/core: circular extends detected at ${absPath} (chain: ${[...visited, absPath].join(' → ')})`,
    );
  }
  visited.add(absPath);

  const raw = await loadModuleDefault<UserConfigInput>(absPath, 'config');

  const resolved = await resolveConfigValue(raw, env, absPath);

  // extends 필드 처리 — 재귀 해석 후 머지.
  const extendsField = resolved.extends;
  if (extendsField === undefined) return resolved;

  const extendsPaths = Array.isArray(extendsField) ? extendsField : [extendsField];
  const baseDir = dirname(absPath);
  let merged: UserConfig = {};
  for (const extPath of extendsPaths) {
    const resolvedExt = pathResolve(baseDir, extPath);
    const base = await loadConfigWithExtends(resolvedExt, env, new Set(visited));
    merged = mergeUserConfigs(merged, base);
  }

  // base들 (모두 머지된 결과) → 현재 config (override)
  const { extends: _extends, ...currentWithoutExtends } = resolved;
  return mergeUserConfigs(merged, currentWithoutExtends as UserConfig);
}

/**
 * 함수형 config / workspace 가 `env` 인자를 안 받았을 때 사용할 기본 컨텍스트.
 *
 * - `command: "bundle"` — production 빌드를 가정 (CLI 주 용도).
 * - `mode: "production"` — `--mode` 미지정 시의 default.
 * - `env: process.env` — `import.meta.env.*` 정적 치환에서도 동일 source 사용.
 *
 * `loadConfig` 와 `loadWorkspace` 가 공유 — 한 곳에서만 default 정의해 drift 방지.
 *
 * @returns 새 `ConfigEnv` 객체 (호출마다 새 참조 — 호출자가 mutate 해도 안전).
 */
export function defaultConfigEnv(): ConfigEnv {
  return {
    command: 'bundle',
    mode: 'production',
    env: process.env,
  };
}

/**
 * 함수형 config 처리. raw 가 함수면 env 와 호출하고 결과를 객체로 반환.
 * env 미제공 시 `defaultConfigEnv()` 사용.
 */
async function resolveConfigValue(
  raw: UserConfigInput,
  env: ConfigEnv | undefined,
  absPath: string,
): Promise<UserConfig> {
  if (typeof raw !== 'function') {
    return raw;
  }
  const result = await raw(env ?? defaultConfigEnv());
  if (!isPlainObject(result)) {
    const got = Array.isArray(result) ? 'array' : typeof result;
    throw new Error(
      `@zts/core: functional config must return an object (got ${got}) from ${absPath}`,
    );
  }
  return result as UserConfig;
}

/**
 * `loadModuleDefault` 가 받는 모듈 종류 라벨.
 *
 * - 에러 메시지에 라벨로 삽입 (`"config file not found"` vs `"workspace file not found"`).
 * - tmp 컴파일 파일명에도 사용 (`.zts-config.bundled-*.mjs` / `.zts-workspace.bundled-*.mjs`).
 *
 * 새 모듈 종류 추가 시 이 union 을 확장하고 호출 사이트도 맞춰 갱신.
 */
export type ModuleKind = 'config' | 'workspace';

/**
 * 임의 모듈 파일 (TS/JS/JSON) 의 default export 를 로드. `loadConfig` 의 디스패치 로직을
 * generic 화 — workspace (#2111) 등 config 와 다른 export shape 에서 재사용.
 *
 * 분기:
 *  - `.json`: `readFileSync` + `JSON.parse`
 *  - `.ts/.mts/.cts`: NAPI `transpile()` self-compile → tmp `.mjs` → dynamic import (cleanup 포함)
 *  - `.mjs/.js/.cjs`: 직접 dynamic import
 *
 * 존재 여부는 사전 stat 으로 확인하지 않고 read/import 의 ENOENT 를 catch — TOCTOU 회피
 * + 1 syscall 절감.
 *
 * @template T 호출자가 기대하는 default export 타입. 런타임 검증은 `allowArray` 외에는 없음.
 * @param absPath 절대 경로.
 * @param kind 모듈 종류 — 에러 메시지/임시 파일명에 사용.
 * @param options `allowArray: true` 면 default export 가 배열일 때도 통과 (workspace 용).
 * @returns default export (또는 default 가 없으면 namespace 객체).
 *
 * @throws `@zts/core: <kind> file not found: <path>` — 파일 부재
 * @throws `@zts/core: failed to parse JSON <kind> ...` — JSON 파싱 실패
 * @throws `@zts/core: <kind> compile failed in ...` — TS self-compile 실패 (ZTS parser 에러)
 * @throws `@zts/core: <kind> must export an object or function (got X)` — default 가 잘못된 타입
 * @throws `@zts/core: unsupported <kind> extension "<ext>"` — 지원 안 하는 확장자
 */
export async function loadModuleDefault<T>(
  absPath: string,
  kind: ModuleKind,
  options?: { allowArray?: boolean },
): Promise<T> {
  const allowArray = options?.allowArray === true;
  const ext = extname(absPath).toLowerCase();
  if (ext === '.json') {
    const raw = readFileOrThrowNotFound(absPath);
    try {
      return JSON.parse(raw) as T;
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      throw new Error(`@zts/core: failed to parse JSON ${kind} ${absPath}: ${reason}`);
    }
  }
  if (TS_EXTS.has(ext)) {
    return (await loadTsModule(absPath, kind, allowArray)) as T;
  }
  if (JS_EXTS.has(ext)) {
    try {
      return await importAndResolveDefault<T>(absPath, { allowArray });
    } catch (err) {
      if (err instanceof Error) {
        err.message = err.message
          .replace('module not found', `${kind} file not found`)
          .replace(
            /module must be an object or function/,
            `${kind} must export an object or function`,
          );
      }
      throw err;
    }
  }
  throw new Error(
    `@zts/core: unsupported ${kind} extension "${ext}" for ${absPath}. Supported: .ts/.mts/.cts/.mjs/.js/.cjs/.json`,
  );
}

async function loadTsModule(
  absPath: string,
  kind: ModuleKind,
  allowArray: boolean,
): Promise<unknown> {
  init();
  const source = readFileOrThrowNotFound(absPath);
  // ZTS parser 는 filename 의 `.cts` 확장자를 보고 CommonJS Script 모드로 진입해
  // 최상위 `export default` 를 거부한다 (`src/parser/parser.zig:283` 부근). 사용자가
  // `.cts` 에 `export default {...}` 를 쓴 의도는 TS 식 ESM 이므로 파싱 단계에서만
  // 가상의 `.ts` 로 호출한다 — 에러 메시지·sourcemap 에는 실제 경로가 그대로 사용된다.
  // FIXME: `transpile()` 에 `moduleType: "module"` 같은 명시 옵션이 추가되면 이전.
  const parseFilename = absPath.endsWith('.cts') ? absPath.slice(0, -4) + '.ts' : absPath;
  const result = transpile(source, {
    filename: parseFilename,
    format: 'esm',
  });
  if (result.errors) {
    throw new Error(`@zts/core: ${kind} compile failed in ${absPath}\n${result.errors}`);
  }

  const tmpName = `.zts-${kind}.bundled-${randomBytes(6).toString('hex')}.mjs`;
  const tmpPath = join(dirname(absPath), tmpName);
  writeFileSync(tmpPath, result.code, 'utf8');
  try {
    return await importAndResolveDefault<unknown>(tmpPath, { allowArray });
  } finally {
    try {
      unlinkSync(tmpPath);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      console.warn(`@zts/core: failed to remove tmp ${kind} ${tmpPath}: ${reason}`);
    }
  }
}

/**
 * 절대 경로를 `file://` URL 로 dynamic import 한 뒤 default export (없으면
 * namespace 객체) 를 반환한다. 함수형 config 도 허용하므로 객체 또는 함수만 통과.
 *
 * `pathToFileURL` 으로 Windows 절대경로 (드라이브 문자) 를 안전하게 처리.
 * config 로더와 CLI 의 `--plugin <path>` 로더가 공유.
 *
 * 같은 프로세스에서 다중 reload 가 필요한 watch (#2107) 는 별도 cache-bust 적용 예정.
 *
 * `options.allowArray` 가 `true` 면 array default export 도 통과 — workspace 처럼
 * top-level array 가 정상인 호출자용. 기본값은 `false` (config/플러그인 호환).
 */
export async function importAndResolveDefault<T = UserConfig>(
  absPath: string,
  options?: { allowArray?: boolean },
): Promise<T> {
  const allowArray = options?.allowArray === true;
  const url = pathToFileURL(absPath).href;
  let mod: Record<string, unknown>;
  try {
    mod = await import(url);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | undefined)?.code;
    if (code === 'ERR_MODULE_NOT_FOUND' || code === 'ENOENT') {
      throw new Error(`@zts/core: module not found: ${absPath}`);
    }
    throw err;
  }
  const value = (mod as { default?: unknown }).default ?? mod;
  const valueType = typeof value;
  const isArray = Array.isArray(value);
  const validObject = valueType === 'object' && value !== null && (allowArray || !isArray);
  if (valueType !== 'function' && !validObject) {
    const got = value === null ? 'null' : isArray ? 'array' : valueType;
    throw new Error(`@zts/core: module must be an object or function (got ${got}) from ${absPath}`);
  }
  return value as T;
}

function readFileOrThrowNotFound(absPath: string): string {
  try {
    return readFileSync(absPath, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      throw new Error(`@zts/core: config file not found: ${absPath}`);
    }
    throw err;
  }
}

/**
 * 파일 부재를 정상 케이스로 처리하는 read. ENOENT/ENOTDIR 면 null, 그 외는 throw.
 * `.env` 같은 optional 파일 로딩 (`load-env.ts`) 에서 사용.
 *
 * ENOTDIR: 부모 경로가 디렉토리가 아닌 케이스 (예: envDir 가 실수로 파일을 가리키는 경우).
 * optional lookup 의 의미상 "없음"과 동등하므로 swallow.
 */
export function readFileIfExists(absPath: string): string | null {
  try {
    return readFileSync(absPath, 'utf8');
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'ENOENT' || code === 'ENOTDIR') return null;
    throw err;
  }
}

/**
 * cwd 에서 `zts.config.*` 자동 탐색. 우선순위는 `CONFIG_EXT_PRIORITY` 참조.
 *
 * 동기 stat (`existsSync`) 사용 — CLI 시작 시 한 번만 호출되므로 비용 무시 가능.
 * parent 디렉토리 traversal 은 모노레포 워크스페이스 (#2111 / Phase 3-4) 에서 처리.
 *
 * Note: Zig CLI (`src/main.zig:293` `applyZtsConfigJson`) 은 현재 `.json` 만
 * 직접 처리한다. 다른 확장자는 JS CLI (`zts.mjs`) 만 자동 탐색하므로 두 경로의
 * 동작이 의도적으로 갈린다. 통합은 #2105 (Phase 2-3 bundler 옵션 매핑) 에서.
 */
export function findConfigPath(cwd: string): string | null {
  for (const ext of CONFIG_EXT_PRIORITY) {
    const candidate = join(cwd, `zts.config${ext}`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * mode-specific config 파일 자동 탐색 — `zts.config.${mode}.{ext}` 형태 (#2110).
 *
 * Vite 의 mode 별 config 패턴: base `zts.config.ts` 가 default, `zts.config.production.ts`
 * 같은 mode-specific 파일이 base 를 부분 override. mode 가 비어있거나 매칭 파일 없으면 null.
 */
export function findModeConfigPath(cwd: string, mode: string): string | null {
  if (!mode) return null;
  for (const ext of CONFIG_EXT_PRIORITY) {
    const candidate = join(cwd, `zts.config.${mode}${ext}`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * base config + mode-specific config 머지. mode 가 base 를 override.
 *
 * 머지 정책 (Vite 호환):
 *  - scalar / string: mode 값이 정의됐으면 그것 사용
 *  - 배열: mode 가 정의됐으면 base 를 완전 대체 (concat 안 함 — 의도 명확화)
 *  - 객체 (`define`/`alias`/`loader`): shallow merge — base 키 + mode 키 (mode 우선)
 *
 * `plugins` 는 concat (Vite 와 일치 — 둘 다 적용).
 */
export function mergeUserConfigs(base: UserConfig, mode: UserConfig): UserConfig {
  const merged: UserConfig = { ...base };

  for (const key of Object.keys(mode) as Array<keyof UserConfig>) {
    const modeVal = mode[key];
    if (modeVal === undefined) continue;

    if (key === 'plugins' && Array.isArray(modeVal) && Array.isArray(merged.plugins)) {
      // plugins 는 concat — base 먼저, mode 추가.
      (merged as Record<string, unknown>).plugins = [...merged.plugins, ...modeVal];
      continue;
    }

    const baseVal = base[key];
    if (
      typeof baseVal === 'object' &&
      baseVal !== null &&
      !Array.isArray(baseVal) &&
      typeof modeVal === 'object' &&
      modeVal !== null &&
      !Array.isArray(modeVal)
    ) {
      // 객체끼리 shallow merge — define/alias/loader 등.
      (merged as Record<string, unknown>)[key] = {
        ...(baseVal as Record<string, unknown>),
        ...(modeVal as Record<string, unknown>),
      };
      continue;
    }

    // scalar / 배열 / 함수 / mode 만 정의됨 — 그대로 override.
    (merged as Record<string, unknown>)[key] = modeVal as unknown;
  }

  return merged;
}
