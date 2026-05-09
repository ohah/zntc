import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: import.meta.glob > Vite patterns', () => {
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
});
