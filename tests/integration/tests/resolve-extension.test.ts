import { describe, test, expect } from 'bun:test';
import { createFixture, runZntc, bundleAndRun } from './helpers';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { symlink, mkdir } from 'node:fs/promises';

/**
 * 확장자 불일치 해석(extension-mismatch resolution) 통합 테스트.
 *
 * WHY: TS 는 import 경로를 재작성하지 않아 소스에는 emit 결과물 기준 확장자(`.js`)를
 * 쓰지만 실제 파일은 `.ts` 다 — 이 어긋남이 resolver 에서 깨지지 않는지 회귀 고정.
 */
describe('확장자 불일치 해석', () => {
  test('TS 파일을 .js 확장자로 import (질문의 핵심 케이스)', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'util.ts': `export const v = "ts-as-js";`,
        'entry.ts': `import { v } from "./util.js"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('ts-as-js');
    } finally {
      await cleanup();
    }
  });

  test('확장자 생략 import → .tsx 로 해석', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'comp.tsx': `export const v = "tsx-extensionless";`,
        'entry.ts': `import { v } from "./comp"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('tsx-extensionless');
    } finally {
      await cleanup();
    }
  });

  test('.ts 확장자 직접 표기 (allowImportingTsExtensions 류)', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'direct.ts': `export const v = "direct-ts";`,
        'entry.ts': `import { v } from "./direct.ts"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('direct-ts');
    } finally {
      await cleanup();
    }
  });

  test('.mjs 로 쓴 import → 실제 .mts 로 해석', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'esm.mts': `export const v = "mts-as-mjs";`,
        'entry.ts': `import { v } from "./esm.mjs"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('mts-as-mjs');
    } finally {
      await cleanup();
    }
  });

  test('.cjs 로 쓴 import → 실제 .cts 로 해석', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'legacy.cts': `export const v = "cts-as-cjs";`,
        'entry.ts': `import { v } from "./legacy.cjs"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('cts-as-cjs');
    } finally {
      await cleanup();
    }
  });

  test('.ts 와 .js 가 둘 다 존재하면 정확 매칭(.js)이 우선', async () => {
    // TS→JS emit 결과물 기준으로 경로를 쓰는 게 의도 — 진짜 .js 가 있으면 그게 맞다.
    // 정확 매칭 실패 시에만 .js→.ts 폴백이 발동해야 한다.
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'util.ts': `export const v = "from-ts";`,
        'util.js': `export const v = "from-js-exact";`,
        'entry.ts': `import { v } from "./util.js"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('from-js-exact');
    } finally {
      await cleanup();
    }
  });

  // ─── 까다로운 조합 ───

  test('tsconfig paths 별칭 + 확장자 불일치 (@feat/api.js → src/feature/api.ts)', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'tsconfig.json': JSON.stringify({
          compilerOptions: { baseUrl: '.', paths: { '@feat/*': ['src/feature/*'] } },
        }),
        'src/feature/api.ts': `export const v = "paths-alias-js-to-ts";`,
        'src/entry.ts': `import { v } from "@feat/api.js"; console.log(v);`,
      },
      'src/entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('paths-alias-js-to-ts');
    } finally {
      await cleanup();
    }
  });

  test('디렉토리 import → dir/index.tsx 로 해석', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'widgets/index.tsx': `export const v = "dir-index-tsx";`,
        'entry.ts': `import { v } from "./widgets"; console.log(v);`,
      },
      'entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('dir-index-tsx');
    } finally {
      await cleanup();
    }
  });

  test('깊은 상대경로 + .jsx→.tsx 매핑', async () => {
    const { runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        'src/feature/deep.tsx': `export const v = "deep-jsx-to-tsx";`,
        'src/entry.ts': `import { v } from "../src/feature/deep.jsx"; console.log(v);`,
      },
      'src/entry.ts',
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe('deep-jsx-to-tsx');
    } finally {
      await cleanup();
    }
  });

  // symlink 을 fixture 생성과 번들 사이에 끼워야 해서 bundleAndRun 을 못 씀 →
  // 번들 산출물에 해석 결과가 인라인됐는지로 검증한다.
  test('symlink 된 node_modules 패키지 내부의 .js→.ts 매핑 (monorepo 류, 번들 산출물 검증)', async () => {
    const { dir, cleanup } = await createFixture({
      'pkgsrc/realpkg/package.json': `{"name":"realpkg","version":"1.0.0","main":"index.js"}`,
      'pkgsrc/realpkg/index.js': `export { v } from "./impl.js";`,
      'pkgsrc/realpkg/impl.ts': `export const v = "symlinked-pkg-js-to-ts";`,
      'entry.ts': `import { v } from "realpkg"; console.log(v);`,
    });
    const outFile = join(dir, 'out.js');
    try {
      await mkdir(join(dir, 'node_modules'), { recursive: true });
      await symlink(join(dir, 'pkgsrc/realpkg'), join(dir, 'node_modules/realpkg'));
      const { exitCode } = await runZntc(['--bundle', join(dir, 'entry.ts'), '-o', outFile]);
      expect(exitCode).toBe(0);
      expect(readFileSync(outFile, 'utf8')).toContain('symlinked-pkg-js-to-ts');
    } finally {
      await cleanup();
    }
  });
});
