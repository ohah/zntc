import { join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export interface BatchEFixture {
  dir: string;
  entry: string;
  pureTest: string;
  cleanup(): void;
}

export function createBatchEFixture(): BatchEFixture {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-batch-e-'));
  const entry = join(dir, 'entry.ts');
  const pureTest = join(dir, 'pure-test.ts');
  writeFileSync(entry, 'DEV: { console.log("dev only"); }\nexport const x = 1;');
  writeFileSync(
    pureTest,
    'import { pureUtil } from "./util";\nconst unused = pureUtil();\nexport const y = 2;',
  );
  writeFileSync(join(dir, 'util.ts'), 'export function pureUtil() { return 42; }');
  return {
    dir,
    entry,
    pureTest,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}
