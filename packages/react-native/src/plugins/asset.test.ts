import { describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { ZNTC_HMR_CLIENT_CODE } from '../runtime-loader.ts';
import { createAssetPlugin, createSvgComponentModule } from './asset.ts';
import type { PluginConfig } from './types.ts';

interface OnLoadHandler {
  (args: { path: string }): Promise<{ contents?: string } | null> | { contents?: string } | null;
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
      contents: ZNTC_HMR_CLIENT_CODE.replace(/__ZNTC_FORWARD_CLIENT_LOGS__/g, 'false'),
    });
  });

  test('forwardClientLogs=true — HMR runtime flag true 로 치환', () => {
    const handlers = captureHandlers({ ...baseConfig, forwardClientLogs: true });
    const result = handlers[0]!.handler({ path: '/abs/Libraries/Utilities/HMRClient.js' });
    expect(result?.contents).toContain('typeof true');
    expect(result?.contents).not.toContain('__ZNTC_FORWARD_CLIENT_LOGS__');
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

  test('내장 SVG component transformer — 사용자 babelTransformerPath 가 있으면 등록하지 않음', () => {
    const handlers = captureHandlers({
      ...baseConfig,
      sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.svg'],
      babelTransformerPath: 'react-native-svg-transformer',
    });
    expect(handlers.length).toBe(2);
    expect(handlers[1]!.filter.test('/abs/icon.svg')).toBe(true);
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

  test('babelTransformerPath + customExts (.svg) — 두 번째 onLoad 등록', () => {
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

  test('customExts 패턴 — JS/TS/JSON 표준 확장자 제외', () => {
    const handlers = captureHandlers({
      ...baseConfig,
      sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json', '.svg', '.graphql'],
      babelTransformerPath: 'any-transformer',
    });
    const customHandler = handlers[1]!;
    expect(customHandler.filter.test('/abs/x.svg')).toBe(true);
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
