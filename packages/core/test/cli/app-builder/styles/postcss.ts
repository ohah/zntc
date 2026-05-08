import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: Vite-style app builder > styles > PostCSS', () => {
  test('JS-imported CSS is linked from HTML and processed by PostCSS', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">PostCSS</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css"; console.log("css");');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '.card { color: red; }\n.card { background: white; }\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-test-postcss', Once(root) { root.append({ selector: '.postcss-ok', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('rel="stylesheet"');
    expect(html).toContain('href="/main.css"');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.postcss-ok');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Tailwind v4 @tailwindcss/postcss app fixture', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-tailwind-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<main class="text-red-500"><script type="module" src="/src/main.ts"></script></main>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '@import "tailwindcss";\n@source "../index.html";\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      'export default { plugins: { "@tailwindcss/postcss": {} } };\n',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.text-red-500');
    expect(css).not.toContain('@import "tailwindcss"');
    rmSync(dir, { recursive: true, force: true });
  });
});
