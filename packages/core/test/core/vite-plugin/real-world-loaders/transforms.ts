import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  readFileSync,
  resolve,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from '../helpers';
import type { RollupPlugin } from '../helpers';

describe('vitePlugin 어댑터 - 실전 로더 패턴', () => {
  test('실전 패턴: 환경 변수 치환 플러그인', async () => {
    const envDir = mkdtempSync(join(tmpdir(), 'zntc-vite-env-'));
    writeFileSync(join(envDir, 'index.ts'), 'console.log(import.meta.env.MODE);');

    const envPlugin: RollupPlugin = {
      name: 'rollup-env',
      transform(code, _id) {
        return code.replace('import.meta.env.MODE', '"production"');
      },
    };

    const result = await build({
      entryPoints: [join(envDir, 'index.ts')],
      plugins: [vitePlugin(envPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    rmSync(envDir, { recursive: true, force: true });
  });

  test('실전 패턴: SVG → React 컴포넌트 플러그인', async () => {
    const svgDir = mkdtempSync(join(tmpdir(), 'zntc-vite-svg-'));
    writeFileSync(join(svgDir, 'icon.svg'), '<svg><circle r="10"/></svg>');
    writeFileSync(join(svgDir, 'index.tsx'), 'import Icon from "./icon.svg";\nconsole.log(Icon);');

    const svgPlugin: RollupPlugin = {
      name: 'rollup-svg-react',
      resolveId(source, importer) {
        if (source.endsWith('.svg') && importer) return resolve(svgDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.svg')) {
          const svg = readFileSync(id, 'utf8');
          return `export default function SvgIcon() { return "${svg.replace(/"/g, '\\"')}"; }`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(svgDir, 'index.tsx')],
      plugins: [vitePlugin(svgPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SvgIcon');
    expect(result.outputFiles[0].text).toContain('circle');
    rmSync(svgDir, { recursive: true, force: true });
  });
});
