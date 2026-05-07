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

function walkFiles(
  dir: string,
  skipResolved: string | null,
  predicate: (path: string) => boolean,
  out: string[],
): void {
  for (const entry of readEntriesOrEmpty(dir)) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (skipResolved && resolve(path) === skipResolved) continue;
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
  const skipResolved = options.skipDir ? resolve(options.skipDir) : null;
  const predicate = options.predicate ?? RETURN_TRUE;
  const files: string[] = [];
  walkFiles(dir, skipResolved, predicate, files);
  return files;
}
