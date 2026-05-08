import { join, mkdtempSync, rmSync, tmpdir, writeFileSync, ROOT_NODE_MODULES } from '../helpers';

export interface EdgeCombinationFixture {
  dir: string;
  simple: string;
  multiExport: string;
  hasConsole: string;
  projectNodeModules: string;
  cleanup(): void;
}

export function createEdgeCombinationFixture(): EdgeCombinationFixture {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-edge2-'));
  const simple = join(dir, 'simple.ts');
  const multiExport = join(dir, 'multi-export.ts');
  const hasConsole = join(dir, 'has-console.ts');
  writeFileSync(simple, 'export const x = () => 1;');
  writeFileSync(
    multiExport,
    'export const a = 1;\nexport const b = 2;\nexport function add() { return a + b; }',
  );
  writeFileSync(hasConsole, 'console.log("hello");\nexport const v = 1;');
  return {
    dir,
    simple,
    multiExport,
    hasConsole,
    projectNodeModules: ROOT_NODE_MODULES,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}
