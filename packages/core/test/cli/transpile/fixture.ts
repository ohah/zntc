import { afterAll, beforeAll, join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export function useTranspileFixture() {
  let dir = '';

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-transpile-'));
    writeFileSync(join(dir, 'input.ts'), 'const x: number = 1;\nconsole.log(x);');
    writeFileSync(
      join(dir, 'types.ts'),
      'interface Foo { bar: string; }\ntype Baz = number;\nconst y = 42;',
    );
    writeFileSync(join(dir, 'jsx.tsx'), 'export default () => <div>hello</div>;');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  return {
    get dir() {
      return dir;
    },
    path(name: string) {
      return join(dir, name);
    },
  };
}
