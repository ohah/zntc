import { describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { ZNTC_HMR_CLIENT_CODE } from '../runtime-loader.ts';
import { createAssetPlugin, createSvgComponentModule } from './asset.ts';
import type { PluginConfig } from './types.ts';

interface OnLoadHandler {
  (args: { path: string }): Promise<{ contents?: string } | null> | { contents?: string } | null;
}

interface OnResolveHandler {
  (args: { path: string; importer?: string }): { path?: string } | null;
}

interface CapturedHandler {
  filter: RegExp;
  handler: OnLoadHandler;
}

function captureHandlers(config: PluginConfig): CapturedHandler[] {
  const plugin = createAssetPlugin(config);
  const captured: CapturedHandler[] = [];
  const fakeBuild = {
    onLoad(filter: { filter: RegExp }, handler: OnLoadHandler) {
      captured.push({ filter: filter.filter, handler });
    },
    onResolve() {},
    onResolveContext() {},
    onTransform() {},
  };
  plugin.setup(fakeBuild as never);
  return captured;
}

function captureResolveHandlers(config: PluginConfig): Array<{ filter: RegExp; handler: OnResolveHandler }> {
  const plugin = createAssetPlugin(config);
  const captured: Array<{ filter: RegExp; handler: OnResolveHandler }> = [];
  const fakeBuild = {
    onLoad() {},
    onResolve(filter: { filter: RegExp }, handler: OnResolveHandler) {
      captured.push({ filter: filter.filter, handler });
    },
    onResolveContext() {},
    onTransform() {},
  };
  plugin.setup(fakeBuild as never);
  return captured;
}

describe('createAssetPlugin', () => {
  const baseConfig: PluginConfig = {
    projectRoot: '/abs/project',
    assetExts: ['png', 'jpg'],
    rnPlatform: 'ios',
    sourceExts: ['.ts', '.tsx', '.js', '.jsx'],
  };

  test('HMRClient.js path → ZNTC HMR runtime code 반환 (onLoad)', () => {
    const handlers = captureHandlers(baseConfig);
    expect(handlers.length).toBe(1); // HMRClient.js 만 (sourceExts 에 RN-specific 확장자 0)
    const hmrHandler = handlers[0]!;
    expect(hmrHandler.filter.test('/abs/Libraries/Utilities/HMRClient.js')).toBe(true);
    expect(hmrHandler.filter.test('/abs/foo.ts')).toBe(false);

    const result = hmrHandler.handler({ path: '/abs/Libraries/Utilities/HMRClient.js' });
    expect(result).toEqual({
      contents: ZNTC_HMR_CLIENT_CODE,
    });
  });

  test('HMR runtime source 는 client console wrap flag 를 주입하지 않음', () => {
    const handlers = captureHandlers(baseConfig);
    const result = handlers[0]!.handler({ path: '/abs/Libraries/Utilities/HMRClient.js' });
    expect(result?.contents).toBe(ZNTC_HMR_CLIENT_CODE);
    expect(result?.contents).not.toContain('__ZNTC_FORWARD_CLIENT_LOGS__');
  });

  test('Metro asset resolution — base 파일 없이 @3x 파일만 있어도 logical asset import 해결', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-rn-scale-asset-'));
    try {
      mkdirSync(join(dir, 'src'), { recursive: true });
      const asset3x = join(dir, 'src', 'poster@3x.webp');
      writeFileSync(asset3x, 'webp');

      const handlers = captureResolveHandlers({
        ...baseConfig,
        projectRoot: dir,
        assetExts: ['webp'],
      });

      expect(handlers.length).toBe(1);
      const resolved = handlers[0]!.handler({
        path: './poster.webp',
        importer: join(dir, 'src', 'index.ts'),
      });
      expect(resolved).toEqual({ path: asset3x });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('babelTransformerPath 미지정 — HMRClient.js handler 만 등록 (custom transformer 없음)', () => {
    const handlers = captureHandlers(baseConfig);
    expect(handlers.length).toBe(1);
  });

  test('내장 SVG component transformer — sourceExts 에 .svg 지정 시 등록', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-rn-svg-'));
    try {
      const svgPath = join(dir, 'check-icon.svg');
      writeFileSync(svgPath, '<svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"/></svg>');
      const handlers = captureHandlers({
        ...baseConfig,
        sourceExts: ['ts', 'tsx', 'js', 'jsx', 'svg'],
      });
      expect(handlers.length).toBe(2);
      const svgHandler = handlers[1]!;
      expect(svgHandler.filter.test(svgPath)).toBe(true);
      const result = await svgHandler.handler({ path: svgPath });
      expect(result?.contents).toContain(`import { SvgXml } from 'react-native-svg';`);
      expect(result?.contents).toContain('function SvgCheckIcon(props)');
      expect(result?.contents).toContain('React.createElement(SvgXml');
      expect(result?.contents).toContain('Object.assign({ xml }, props)');
      expect(result?.contents).toContain('export default SvgCheckIcon');
      expect(result?.contents).toContain(
        JSON.stringify('<svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"/></svg>'),
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('내장 SVG component transformer — 사용자 babelTransformerPath 가 있어도 SVG는 ZNTC가 처리', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-rn-svg-builtin-with-custom-'));
    const svgPath = join(dir, 'custom.svg');
    writeFileSync(svgPath, '<svg viewBox="0 0 1 1"/>');
    const handlers = captureHandlers({
      ...baseConfig,
      projectRoot: dir,
      sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.svg'],
      babelTransformerPath: 'react-native-svg-transformer',
    });
    try {
      expect(handlers.length).toBe(2);
      const svgHandler = handlers[1]!;
      expect(svgHandler.filter.test(svgPath)).toBe(true);
      const result = await svgHandler.handler({ path: svgPath });
      expect(result?.contents).toContain('function SvgCustom(props)');
      expect(result?.contents).toContain('export default SvgCustom');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('createSvgComponentModule — JS identifier 로 안전한 component name 생성', () => {
    const code = createSvgComponentModule('<svg/>', '/tmp/24-check.icon.svg');
    expect(code).toContain('function Svg24CheckIcon(props)');
    expect(code).toContain('Svg24CheckIcon.displayName = "Svg24CheckIcon"');
  });

  test('babelTransformerPath 지정 + customExts 0 — HMRClient.js handler 만', () => {
    // sourceExts 가 모두 표준 JS/TS — customExts 빈 string → 등록 skip
    const handlers = captureHandlers({
      ...baseConfig,
      babelTransformerPath: 'react-native-svg-transformer',
    });
    expect(handlers.length).toBe(1);
  });

  test('babelTransformerPath + .svg sourceExt — SVG는 내장 onLoad 만 등록', () => {
    const handlers = captureHandlers({
      ...baseConfig,
      sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.svg'],
      babelTransformerPath: 'react-native-svg-transformer',
    });
    expect(handlers.length).toBe(2);
    const customHandler = handlers[1]!;
    expect(customHandler.filter.test('/abs/icon.svg')).toBe(true);
    expect(customHandler.filter.test('/abs/foo.ts')).toBe(false);
  });

  test('babelTransformerPath transformer — non-SVG customExt 에 Metro projectRoot/dev 옵션 전달', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-rn-custom-transformer-'));
    try {
      writeFileSync(join(dir, 'package.json'), '{"name":"fixture","private":true}');
      mkdirSync(join(dir, 'node_modules', 'fake-transformer'), { recursive: true });
      mkdirSync(join(dir, 'node_modules', '@babel', 'core'), { recursive: true });
      writeFileSync(
        join(dir, 'node_modules', 'fake-transformer', 'package.json'),
        '{"name":"fake-transformer","main":"index.js"}',
      );
      writeFileSync(
        join(dir, 'node_modules', 'fake-transformer', 'index.js'),
        `
module.exports.transform = ({ options }) => {
  if (options.projectRoot !== ${JSON.stringify(dir)}) {
    throw new Error('missing projectRoot');
  }
  if (options.dev !== false || options.hot !== false) {
    throw new Error('dev flag was not forwarded');
  }
  return { code: 'export default "ok";' };
};
`,
      );
      writeFileSync(
        join(dir, 'node_modules', '@babel', 'core', 'index.js'),
        `throw new Error('Babel should not be loaded for code-returning custom transformers');`,
      );
      const customPath = join(dir, 'query.graphql');
      writeFileSync(customPath, 'query Example { id }');

      const handlers = captureHandlers({
        ...baseConfig,
        projectRoot: dir,
        dev: false,
        sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.graphql'],
        babelTransformerPath: 'fake-transformer',
      });
      const result = await handlers[1]!.handler({ path: customPath });
      expect(result?.contents).toBe('export default "ok";');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('customExts 패턴 — JS/TS/JSON 표준 확장자 제외', () => {
    const handlers = captureHandlers({
      ...baseConfig,
      sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json', '.svg', '.graphql'],
      babelTransformerPath: 'any-transformer',
    });
    const customHandler = handlers[2]!;
    expect(customHandler.filter.test('/abs/x.svg')).toBe(false);
    expect(customHandler.filter.test('/abs/x.graphql')).toBe(true);
    expect(customHandler.filter.test('/abs/x.ts')).toBe(false);
    expect(customHandler.filter.test('/abs/x.json')).toBe(false);
    expect(customHandler.filter.test('/abs/x.mjs')).toBe(false);
  });

  test('plugin name 은 zntc:react-native:runtime', () => {
    const plugin = createAssetPlugin(baseConfig);
    expect(plugin.name).toBe('zntc:react-native:runtime');
  });
});
