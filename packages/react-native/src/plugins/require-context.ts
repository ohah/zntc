// require.context (#1579) — ZNTC 가 인지/메타만, 매칭은 host (Bun JSC RegExp)
// 책임. Phase 2.5 의 onResolveContext hook 사용 — 디렉토리 FS scan + filter
// regex 매칭 + 결정적 정렬. importer 기준 상대 경로만, projectRoot 의존성 0.

import { readdirSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';

import type { ZntcPlugin } from '@zntc/core';

/**
 * `require.context(dir, recursive, filter, flags?)` 의 host-side 평가. 디렉토리
 * 가 없으면 graph 가 invalid 처리하지 않도록 빈 배열 응답. 파일 path 는 항상
 * `./` prefix + forward slash (Windows path separator 정규화).
 */
export function createRequireContextPlugin(): ZntcPlugin {
  return {
    name: 'zntc:react-native:require-context',
    setup(build) {
      build.onResolveContext({ filter: /.*/ }, (args) => {
        const { dir, recursive, filter, flags, importer } = args;
        const absDir = resolve(dirname(importer), dir);

        let entries: string[];
        try {
          if (recursive) {
            entries = readdirSync(absDir, { recursive: true, withFileTypes: true })
              .filter((d) => d.isFile())
              .map((d) => {
                const parent = (d as unknown as { parentPath?: string }).parentPath ?? absDir;
                return relative(absDir, join(parent, d.name));
              });
          } else {
            entries = readdirSync(absDir, { withFileTypes: true })
              .filter((d) => d.isFile())
              .map((d) => d.name);
          }
        } catch {
          return { context: [] };
        }

        const re = filter ? new RegExp(filter, flags ?? '') : /^\.\/.*$/;
        const matched = entries
          .map((f) => `./${f.replace(/\\/g, '/')}`)
          .filter((p) => re.test(p))
          .sort();

        return { context: matched };
      });
    },
  };
}
