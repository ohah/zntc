import { type Dirent, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';

export interface NodeRequire {
  (specifier: string): unknown;
}

/**
 * `root` 의 package.json 기준 `require` 로 specifier 를 로드, MODULE_NOT_FOUND
 * 시 fallbackRequire 로 fallback. postcss/sass 같은 optional dev deps 가 app
 * 또는 CLI 어느 쪽에 있는지 모를 때 양쪽 모두 시도.
 */
export function requireFromAppRoot(
  root: string,
  fallbackRequire: NodeRequire,
  specifier: string,
): unknown {
  const requireFromRoot = createRequire(join(root, 'package.json')) as unknown as NodeRequire;
  return requireFromAppOrFallback(requireFromRoot, fallbackRequire, specifier);
}

/**
 * App 의 `require` 로 먼저 시도, MODULE_NOT_FOUND 발생 시 fallback `require` 로
 * 재시도. zntc dev/build pipeline 의 plugin / preprocessor 로딩 (postcss/sass 등)
 * 에서 \"app deps 우선, CLI deps fallback\" 패턴을 명시화.
 */
export function requireFromAppOrFallback(
  requireFromApp: NodeRequire,
  fallbackRequire: NodeRequire,
  specifier: string,
): unknown {
  try {
    return requireFromApp(specifier);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException)?.code;
    if (code !== 'MODULE_NOT_FOUND' && code !== 'ERR_MODULE_NOT_FOUND') throw err;
    return fallbackRequire(specifier);
  }
}

export interface CollectAppFilesOptions {
  /** 이 디렉토리 (절대 또는 상대 경로) 와 일치하는 sub-tree 는 walk 안 함. */
  skipDir?: string | null;
  /**
   * `skipDir` 의 복수형. 둘 다 주면 합집합.
   *
   * (#4674) 탐색 제외와 **복사 제외가 어긋나면** 탐색만 잡은 파일을 나중에 복사본에서
   * 열다가 ENOENT 로 죽는다. 제외 대상이 여러 개인 호출처는 같은 목록을 그대로 넘겨
   * 두 판정이 갈리지 않게 한다.
   */
  skipDirs?: readonly string[] | null;
  /** file 마다 호출, true 면 결과에 포함. default: 모든 파일 포함. */
  predicate?: (path: string) => boolean;
}

const RETURN_TRUE = (): boolean => true;

/**
 * 디렉토리 entries 를 안전하게 read. ENOENT (디렉토리 없음) 만 빈 배열로 swallow,
 * 그 외 (ENOTDIR/EACCES 등) 는 propagate. existsSync TOCTOU 회피 + 중복 stat 제거.
 */
function readEntriesOrEmpty(dir: string): Dirent[] {
  try {
    return readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw err;
  }
}

/**
 * (#4678) 깊이에 무관하게 건너뛸 디렉토리 이름.
 *
 * `.zntc-dev` 는 `zntc dev` 의 기본 산출 디렉토리이고, 그 안에는 dev 서버 서빙용으로
 * **소스 CSS 가 그대로 미러**돼 있다. 루트의 것만 제외하면 하위 앱이 dev 를 돌린
 * `sub/.zntc-dev` 가 새어 들어와 같은 CSS Module 을 두 번 처리한다(실측 +38%).
 *
 * ⚠️ `--outdir` 로 이름을 바꾼 dev 산출물은 여기서 못 막는다 — `zntc build` 는 직전
 * `zntc dev` 가 어떤 outdir 을 썼는지 알 방법이 없다. 알려진 한계이고, 원리적으로
 * 닫으려면 생산자가 자기 산출물을 표시해야 한다(#4678).
 */
const SKIP_DIR_NAMES = new Set(['node_modules', '.git', '.zntc-dev']);

/** (#4678) 깊이 무관 skip 대상인가. 복사·탐색 두 경로가 같은 규칙을 쓰도록 공개한다. */
export function isSkippedDirName(name: string): boolean {
  return SKIP_DIR_NAMES.has(name);
}

function walkFiles(
  dir: string,
  skipResolved: ReadonlySet<string>,
  predicate: (path: string) => boolean,
  out: string[],
): void {
  for (const entry of readEntriesOrEmpty(dir)) {
    if (isSkippedDirName(entry.name)) continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (skipResolved.has(resolve(path))) continue;
      walkFiles(path, skipResolved, predicate, out);
    } else if (entry.isFile() && predicate(path)) {
      out.push(path);
    }
  }
}

/**
 * `dir` 의 모든 파일을 재귀적으로 수집. `node_modules` 와 `.git` 은 자동 skip.
 * 파일 시스템 IO 만 사용 — 외부 모듈 의존 없음.
 *
 * @returns 디렉토리가 없으면 빈 배열 (ENOENT silent). ENOTDIR/EACCES 등 다른 IO 에러는 throw.
 */
export function collectAppFiles(dir: string, options: CollectAppFilesOptions = {}): string[] {
  const skipResolved = new Set<string>();
  if (options.skipDir) skipResolved.add(resolve(options.skipDir));
  for (const d of options.skipDirs ?? []) skipResolved.add(resolve(d));
  const predicate = options.predicate ?? RETURN_TRUE;
  const files: string[] = [];
  walkFiles(dir, skipResolved, predicate, files);
  return files;
}
