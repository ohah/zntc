import { join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export interface HookReturnFixture {
  dir: string;
  entry: string;
  app: string;
  cleanup(): void;
}

export function createHookReturnFixture(): HookReturnFixture {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-adapter-'));
  writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
  writeFileSync(join(dir, 'app.ts'), 'import { greet } from "./util";\nconsole.log(greet());');
  writeFileSync(join(dir, 'util.ts'), "export function greet(): string { return 'Hello!'; }");
  return {
    dir,
    entry: join(dir, 'entry.ts'),
    app: join(dir, 'app.ts'),
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}
