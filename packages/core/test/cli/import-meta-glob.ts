import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: import.meta.glob', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-glob-'));
    mkdirSync(join(dir, 'modules'), { recursive: true });
    writeFileSync(join(dir, 'modules', 'a.ts'), 'export const setup = () => "a";');
    writeFileSync(join(dir, 'modules', 'b.ts'), 'export const setup = () => "b";');
    writeFileSync(join(dir, 'modules', 'c.ts'), 'export default 42;');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('lazy (default): () => import() 패턴', () => {
    writeFileSync(
      join(dir, 'lazy.ts'),
      'const m = import.meta.glob("./modules/*.ts");\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'lazy.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('() => import(');
    expect(stdout).toContain('./modules/a.ts');
    expect(stdout).not.toContain('await import(');
  });

  test('eager: await import() 패턴', () => {
    writeFileSync(
      join(dir, 'eager.ts'),
      'const m = import.meta.glob("./modules/*.ts", { eager: true });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'eager.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('await import(');
    expect(stdout).not.toContain('() => import(');
  });

  test('import option: .then(m => m.setup) 패턴', () => {
    writeFileSync(
      join(dir, 'named.ts'),
      'const m = import.meta.glob("./modules/*.ts", { import: "setup" });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'named.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('m.setup');
    expect(stdout).toContain('() => import(');
  });

  test('Vite 라우트 패턴: lazy glob → 동적 라우트 맵', () => {
    // Vite에서 가장 흔한 패턴: pages 디렉토리의 모든 컴포넌트를 라우트로 등록
    const viteDir = mkdtempSync(join(tmpdir(), 'zntc-glob-vite-'));
    mkdirSync(join(viteDir, 'pages'), { recursive: true });
    writeFileSync(
      join(viteDir, 'pages', 'Home.tsx'),
      'export default function Home() { return "home"; }',
    );
    writeFileSync(
      join(viteDir, 'pages', 'About.tsx'),
      'export default function About() { return "about"; }',
    );
    writeFileSync(
      join(viteDir, 'pages', 'Contact.tsx'),
      'export default function Contact() { return "contact"; }',
    );
    writeFileSync(
      join(viteDir, 'router.ts'),
      [
        'const pages = import.meta.glob("./pages/*.tsx");',
        'const routes = Object.entries(pages).map(([path, loader]) => ({',
        '  path: path.replace("./pages/", "/").replace(".tsx", ""),',
        '  loader,',
        '}));',
        'export { routes };',
      ].join('\n'),
    );

    const { stdout, exitCode } = runCli(['--bundle', join(viteDir, 'router.ts')]);
    expect(exitCode).toBe(0);
    // lazy import 패턴
    expect(stdout).toContain('() => import(');
    // 3개 페이지 모두 포함
    expect(stdout).toContain('./pages/Home.tsx');
    expect(stdout).toContain('./pages/About.tsx');
    expect(stdout).toContain('./pages/Contact.tsx');
    // Object.entries로 라우트 매핑 코드 유지
    expect(stdout).toContain('Object.entries');

    rmSync(viteDir, { recursive: true, force: true });
  });

  test('Vite i18n 패턴: eager glob + import default', () => {
    // Vite 다국어: locale JSON을 eager + import default로 즉시 로드
    const i18nDir = mkdtempSync(join(tmpdir(), 'zntc-glob-i18n-'));
    mkdirSync(join(i18nDir, 'locales'), { recursive: true });
    writeFileSync(join(i18nDir, 'locales', 'en.ts'), 'export default { hello: "Hello" };');
    writeFileSync(join(i18nDir, 'locales', 'ko.ts'), 'export default { hello: "안녕" };');
    writeFileSync(
      join(i18nDir, 'i18n.ts'),
      'const messages = import.meta.glob("./locales/*.ts", { eager: true, import: "default" });\nexport { messages };',
    );

    const { stdout, exitCode } = runCli(['--bundle', join(i18nDir, 'i18n.ts')]);
    expect(exitCode).toBe(0);
    // eager + import default: (await import()).default
    expect(stdout).toContain('(await import(');
    expect(stdout).toContain(').default');
    expect(stdout).toContain('./locales/en.ts');
    expect(stdout).toContain('./locales/ko.ts');

    rmSync(i18nDir, { recursive: true, force: true });
  });

  test('eager + import: (await import()).setup 패턴', () => {
    writeFileSync(
      join(dir, 'eager-named.ts'),
      'const m = import.meta.glob("./modules/*.ts", { eager: true, import: "setup" });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'eager-named.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('(await import(');
    expect(stdout).toContain(').setup');
  });
});

// ─── UMD/AMD 포맷 ───
