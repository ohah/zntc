/**
 * `zntc.workspace.{ts,mts,cts,mjs,js,cjs,json}` 모노레포 워크스페이스 로더 (#2111).
 *
 * Vitest `vitest.workspace.ts` 패턴 벤치마킹. root 디렉토리에 단일 워크스페이스
 * 파일을 두고, 그 안에서 패키지별 build target 을 정의한다.
 *
 * ```ts
 * export default defineWorkspace([
 *   "./packages/app",          // 디렉토리 — 안의 zntc.config.* 자동 탐색
 *   "./packages/*",             // glob — 매칭 디렉토리들 일괄
 *   { name: "shared", entryPoints: [...] },  // inline — 즉시 워크스페이스화
 * ])
 * ```
 *
 * `--workspace=<name>` 으로 단일 entry 만 빌드 가능. root config (`zntc.config.*`)
 * 와 같은 디렉토리에 두면 root 옵션을 모든 entry 가 상속.
 */

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { basename, join, resolve as pathResolve } from 'node:path';

import { isPlainObject } from '../index';
import {
  type ConfigEnv,
  defaultConfigEnv,
  findConfigPath,
  loadConfig,
  loadModuleDefault,
  type UserConfig,
} from './config-loader.ts';

const CONFIG_EXT_PRIORITY_LOCAL = ['.ts', '.mts', '.cts', '.mjs', '.js', '.cjs', '.json'] as const;

/**
 * 디렉토리 경로 또는 단일 `*` 가 포함된 glob.
 *
 * - `"./packages/app"` — 단일 디렉토리. 안의 `zntc.config.*` 가 있으면 자동 로드.
 * - `"./packages/*"` — trailing wildcard. baseDir 의 직속 디렉토리 모두 매칭 (hidden / `node_modules` 제외).
 * - `"./apps/web-*"` — prefix 매칭도 동일 규칙.
 *
 * `**` (재귀 glob) 은 미지원 — 워크스페이스에서 흔치 않고 perf/edge case 가 늘어 의도적 제외.
 */
export type WorkspaceEntryPath = string;

/**
 * 디렉토리 없이 root cwd 에서 직접 build 되는 inline entry.
 *
 * `name` 은 식별자(필수) — `--workspace=<name>` 필터, 로그 출력에 사용. 그 외 모든 필드는
 * `BuildOptions` (`UserConfig`) 와 동일하며 root config 를 override 한다.
 *
 * @example
 * ```ts
 * export default defineWorkspace([
 *   { name: "shared-utils", entryPoints: ["./shared/utils.ts"], outdir: "./shared/dist" },
 * ]);
 * ```
 */
export type WorkspaceEntryInline = UserConfig & { name: string };

/** workspace 배열 원소 — string path/glob 또는 inline 객체. */
export type WorkspaceEntry = WorkspaceEntryPath | WorkspaceEntryInline;

/** workspace 파일이 export 하는 entries 배열. */
export type Workspace = WorkspaceEntry[];

/**
 * 함수형 workspace — `defineWorkspace((env) => [...])`.
 *
 * `env.command` (`bundle`/`serve`/`watch`), `env.mode`, `env.env` (process.env 기반)
 * 를 받아 동적으로 entries 결정. 비동기 (Promise) 반환 허용.
 */
export type WorkspaceFn = (env: ConfigEnv) => Workspace | Promise<Workspace>;

/** workspace 파일이 default export 가능한 형태 — 배열 또는 함수. */
export type WorkspaceInput = Workspace | WorkspaceFn;

/**
 * Vitest 식 identity 헬퍼. 입력을 그대로 반환 — 타입 추론 / IDE 자동완성을 위해 존재.
 *
 * @param input workspace 정의 — 배열 또는 함수형
 * @returns 입력 그대로 (런타임 변경 없음)
 *
 * @example
 * ```ts
 * import { defineWorkspace } from "@zntc/core";
 *
 * export default defineWorkspace([
 *   "./packages/*",
 *   { name: "shared", entryPoints: ["./shared/index.ts"] },
 * ]);
 * ```
 */
export function defineWorkspace<T extends WorkspaceInput>(input: T): T {
  return input;
}

/**
 * workspace 파일 자동 탐색 우선순위. `CONFIG_EXT_PRIORITY` 와 동일 정책 — 동일 디렉토리에
 * 다중 확장자 존재 시 첫 매치를 반환한다 (`.ts` > `.mts` > `.cts` > `.mjs` > `.js` > `.cjs` > `.json`).
 */
export const WORKSPACE_EXT_PRIORITY: typeof CONFIG_EXT_PRIORITY_LOCAL = CONFIG_EXT_PRIORITY_LOCAL;

/**
 * `cwd` 에서 `zntc.workspace.{ext}` 를 자동 탐색.
 *
 * @param cwd 탐색 시작 디렉토리 (보통 `process.cwd()`)
 * @returns 발견된 절대 경로 또는 `null`
 *
 * 동기 stat (`existsSync`) 사용 — CLI 시작 시 한 번만 호출되므로 무시 가능한 비용.
 * parent traversal 은 안 함 — 모노레포 root 가 아닌 sub-package 안에서 호출되면 `null` 반환.
 */
export function findWorkspacePath(cwd: string): string | null {
  for (const ext of WORKSPACE_EXT_PRIORITY) {
    const p = join(cwd, `zntc.workspace${ext}`);
    if (existsSync(p)) return p;
  }
  return null;
}

/**
 * workspace 파일 로드. `loadModuleDefault` 가 TS/JS/JSON 디스패치 + (tmp 파일) self-compile
 * 까지 처리하므로 호출자는 단일 진입점만 알면 된다. 함수형 export 면 `env` (또는
 * `defaultConfigEnv()`) 와 호출. 결과는 항상 검증된 entries 배열.
 *
 * @param filePath workspace 파일 — 절대 또는 cwd 기준 상대 경로
 * @param env 함수형 workspace 호출 시 주입할 컨텍스트. 미제공 시 `defaultConfigEnv()`.
 * @returns 검증된 entries 배열 (순서 유지)
 *
 * @throws `@zntc/core: workspace must export an array (got X) from <path>` — top-level 배열 아님
 * @throws `@zntc/core: workspace[i] is empty string in <path>` — 빈 문자열 entry
 * @throws `@zntc/core: workspace[i] must be a string or object (got X) in <path>` — 잘못된 타입
 * @throws `@zntc/core: workspace[i] inline entry requires non-empty 'name' in <path>` — inline 인데 name 없음
 *
 * @example
 * ```ts
 * const ws = await loadWorkspace("zntc.workspace.ts", { command: "bundle", mode: "production", env: process.env });
 * // ws: WorkspaceEntry[]
 * ```
 */
export async function loadWorkspace(filePath: string, env?: ConfigEnv): Promise<Workspace> {
  const absPath = pathResolve(filePath);
  const raw = await loadModuleDefault<WorkspaceInput>(absPath, 'workspace', { allowArray: true });

  const entries: unknown =
    typeof raw === 'function' ? await (raw as WorkspaceFn)(env ?? defaultConfigEnv()) : raw;

  if (!Array.isArray(entries)) {
    const got = entries === null ? 'null' : typeof entries;
    throw new Error(`@zntc/core: workspace must export an array (got ${got}) from ${absPath}`);
  }

  for (let i = 0; i < entries.length; i += 1) {
    const e = entries[i];
    if (typeof e === 'string') {
      if (!e.length) {
        throw new Error(`@zntc/core: workspace[${i}] is empty string in ${absPath}`);
      }
      continue;
    }
    if (!isPlainObject(e)) {
      throw new Error(
        `@zntc/core: workspace[${i}] must be a string or object (got ${
          Array.isArray(e) ? 'array' : e === null ? 'null' : typeof e
        }) in ${absPath}`,
      );
    }
    const name = (e as { name?: unknown }).name;
    if (typeof name !== 'string' || !name) {
      throw new Error(
        `@zntc/core: workspace[${i}] inline entry requires non-empty 'name' in ${absPath}`,
      );
    }
  }

  return entries as Workspace;
}

/**
 * 식별 단계 결과 — cwd/name/source 만 확정하고 config 로드는 보류.
 *
 * `loadIdentifiedConfig` 로 후처리하면 `config: UserConfig` 가 채워진 build target 형태로 완성.
 */
export interface IdentifiedWorkspace {
  /** 워크스페이스 식별자 — `--workspace=<name>` 필터 키. */
  name: string;
  /** 매칭/지정된 cwd 절대 경로. */
  cwd: string;
  /** 어떤 entry 형식에서 왔는지. */
  source: 'path' | 'glob' | 'inline';
  /** inline 인 경우 미리 알려진 config (name 필드는 제외). path/glob 는 `null` — 디스크에서 로드 필요. */
  inlineConfig: UserConfig | null;
}

/**
 * entries 를 식별 단계까지만 처리 — `cwd`/`name`/`source` 결정하고 config 로드는 보류.
 *
 * `--workspace=<name>` 필터를 config 로드 **전에** 적용해 비용 큰 TS config self-compile 을
 * 필터링된 N-1 개 entry 에 대해 회피하기 위함. path entry 는 `package.json` 만 읽어 name
 * 결정 (저렴), glob 은 디렉토리 enumerate.
 *
 * dedup: 같은 `cwd` 가 path + glob 양쪽에 매칭되면 **첫 번째 (선언 순서)** 만 유지. 명시적
 * path 가 glob 보다 우선하는 자연스러운 의도 — 사용자가 "all packages 중 app 은 특별 설정"
 * 같은 패턴을 쓸 수 있게.
 *
 * @param entries `loadWorkspace` 가 반환한 검증된 entries 배열
 * @param rootDir workspace 파일이 있는 디렉토리 (절대 경로 권장)
 * @returns 식별된 워크스페이스 목록 (선언 순서 유지, dedup 적용)
 *
 * @throws `@zntc/core: workspace glob '**' is not supported (got '<pattern>')` — `**` glob 사용
 * @throws `@zntc/core: workspace glob with '*' in directory part is not supported (got '<pattern>')` — 디렉토리부 wildcard
 *
 * @example
 * ```ts
 * const ws = await loadWorkspace("zntc.workspace.ts");
 * const ids = identifyWorkspaceEntries(ws, "/repo");
 * const target = filterWorkspaces(ids, "my-app");
 * const resolved = await Promise.all(target.map((w) => loadIdentifiedConfig(w)));
 * ```
 */
export function identifyWorkspaceEntries(
  entries: Workspace,
  rootDir: string,
): IdentifiedWorkspace[] {
  const seen = new Set<string>();
  const out: IdentifiedWorkspace[] = [];
  const push = (w: IdentifiedWorkspace) => {
    if (seen.has(w.cwd)) return;
    seen.add(w.cwd);
    out.push(w);
  };

  for (const entry of entries) {
    if (typeof entry === 'string') {
      if (entry.includes('*')) {
        for (const dir of expandGlob(entry, rootDir)) {
          push({ name: detectPackageName(dir), cwd: dir, source: 'glob', inlineConfig: null });
        }
      } else {
        const abs = pathResolve(rootDir, entry);
        push({ name: detectPackageName(abs), cwd: abs, source: 'path', inlineConfig: null });
      }
      continue;
    }
    const { name, ...rest } = entry;
    push({
      name,
      cwd: rootDir,
      source: 'inline',
      inlineConfig: rest as UserConfig,
    });
  }
  return out;
}

/**
 * 식별된 entry 의 config 를 디스크에서 로드. path/glob 은 `findConfigPath` 로 cwd 안의
 * `zntc.config.*` 자동 탐색 후 `loadConfig` (extends 처리, 함수형 호출 포함). inline 은
 * 이미 갖고 있는 `inlineConfig` 그대로.
 *
 * 비싸다 — TS config 면 NAPI transpile + tmp `.mjs` write/import/unlink. 필터링된 entry
 * 에 대해서만 호출하는 것을 권장 (`identifyWorkspaceEntries` → `filterWorkspaces` → 이 함수).
 *
 * @param w 식별된 워크스페이스 entry
 * @param env `loadConfig` 에 전달할 함수형 config 컨텍스트
 * @returns entry 의 config (inline 또는 디스크 로드 결과). config 파일 없으면 빈 객체 `{}`.
 */
export async function loadIdentifiedConfig(
  w: IdentifiedWorkspace,
  env?: ConfigEnv,
): Promise<UserConfig> {
  if (w.inlineConfig) return w.inlineConfig;
  const configPath = findConfigPath(w.cwd);
  return configPath ? await loadConfig(configPath, env) : {};
}

/**
 * 매우 단순한 glob 확장. **trailing `*`** (또는 `*` 가 들어간 디렉토리명 패턴) 만 지원.
 * `./packages/*`, `./apps/web-*`, `./pkg-*` 등.
 *
 * `**` (재귀) 는 미지원 — 워크스페이스에서 흔치 않고, 도입하면 perf/edge case 가 늘어
 * 보수적으로 제외. 필요 시 사용자 inline 패턴으로 우회 가능.
 *
 * @param pattern entries 의 string entry. wildcard 가 없으면 단일 path 로 fallback.
 * @param rootDir 상대 경로 해석 기준 디렉토리.
 * @returns 매칭된 절대 디렉토리 경로 (정렬됨).
 */
function expandGlob(pattern: string, rootDir: string): string[] {
  if (pattern.includes('**')) {
    throw new Error(
      `@zntc/core: workspace glob '**' is not supported (got '${pattern}'). Use single-level '*' patterns.`,
    );
  }
  const lastSep = pattern.lastIndexOf('/');
  if (lastSep === -1) {
    // 패턴이 단일 segment ("*foo") — rootDir 직속 디렉토리에서 매칭.
    return enumerateDirs(rootDir, pattern);
  }
  const dirPart = pattern.slice(0, lastSep);
  const namePart = pattern.slice(lastSep + 1);
  if (dirPart.includes('*')) {
    throw new Error(
      `@zntc/core: workspace glob with '*' in directory part is not supported (got '${pattern}'). Use trailing-only '*'.`,
    );
  }
  if (!namePart.includes('*')) {
    // glob 인 줄 알았지만 실제로는 정적 경로 — string path 로 처리.
    return [pathResolve(rootDir, pattern)];
  }
  const baseDir = pathResolve(rootDir, dirPart);
  return enumerateDirs(baseDir, namePart);
}

/**
 * `baseDir` 직속 디렉토리 중 `namePattern` (별표 포함) 매칭만 반환. `node_modules` 와
 * dotfile 디렉토리는 항상 제외 — 워크스페이스 의도와 무관.
 */
function enumerateDirs(baseDir: string, namePattern: string): string[] {
  if (!existsSync(baseDir)) return [];
  const matcher = makeStarMatcher(namePattern);
  const out: string[] = [];
  for (const d of readdirSync(baseDir, { withFileTypes: true })) {
    if (!d.isDirectory()) continue;
    if (d.name.startsWith('.')) continue;
    if (d.name === 'node_modules') continue;
    if (matcher(d.name)) out.push(join(baseDir, d.name));
  }
  out.sort();
  return out;
}

/**
 * `*` 가 들어간 단일 segment 패턴을 정규식 매처로 컴파일. `*` → `.*`, regex 메타문자는 escape.
 * `pattern === "*"` 는 fast path 로 항상 true 반환.
 */
function makeStarMatcher(pattern: string): (s: string) => boolean {
  if (pattern === '*') return () => true;
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
  const re = new RegExp('^' + escaped + '$');
  return (s) => re.test(s);
}

/**
 * `absDir/package.json` 의 `name` 필드 또는 디렉토리 basename 으로 워크스페이스 식별자 결정.
 * package.json 부재/파싱 실패는 silent — `basename(absDir)` 으로 fallback (테스트 fixture
 * 디렉토리도 의미 있는 식별자를 갖도록).
 */
function detectPackageName(absDir: string): string {
  const pkgPath = join(absDir, 'package.json');
  if (existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as { name?: unknown };
      if (typeof pkg.name === 'string' && pkg.name) return pkg.name;
    } catch {
      // fall through to dirname
    }
  }
  return basename(absDir);
}

/**
 * `--workspace=<name>` 필터. 매칭 0개면 throw — 사용자 typo 보호 (가능한 후보 노출).
 *
 * `name` 필드를 가진 객체면 모두 받도록 generic — `IdentifiedWorkspace` 든 caller 가 정의한
 * 후속 형태든 동일 동작. config 로드는 비싸므로 `identifyWorkspaceEntries` 결과에 즉시 필터
 * 후 `loadIdentifiedConfig` 호출을 권장.
 *
 * `name` 일치만 사용 — Vitest 의 `--project` 와 동일. glob/regex 매칭은 향후 확장.
 *
 * @param workspaces 식별/해석된 워크스페이스 배열
 * @param filter `--workspace=<name>` 값. `undefined`/빈 문자열이면 전체 그대로 반환.
 * @returns `name === filter` 인 entries (보통 1개). filter 미지정 시 입력 동일 참조 반환.
 *
 * @throws `@zntc/core: --workspace='<filter>' matched 0 entries (available: ...)` — 매칭 실패
 */
export function filterWorkspaces<T extends { name: string }>(
  workspaces: T[],
  filter: string | undefined,
): T[] {
  if (!filter) return workspaces;
  const filtered = workspaces.filter((w) => w.name === filter);
  if (filtered.length === 0) {
    const available = workspaces.map((w) => w.name).join(', ');
    throw new Error(
      `@zntc/core: --workspace='${filter}' matched 0 entries (available: ${available || '<none>'})`,
    );
  }
  return filtered;
}
