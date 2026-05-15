import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  buildKeepXml,
  copyRnAssets,
  extractRegisteredAssets,
  getAndroidDrawableFolder,
  getAndroidResourceIdentifier,
  IOS_SCALES,
} from './rn-asset-copy.mjs';

let dir: string;
let dest: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-rn-asset-src-'));
  dest = mkdtempSync(join(tmpdir(), 'zntc-rn-asset-dest-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
  rmSync(dest, { recursive: true, force: true });
});

describe('IOS_SCALES', () => {
  test('1/2/3 만 포함', () => {
    expect(IOS_SCALES.has(1)).toBe(true);
    expect(IOS_SCALES.has(2)).toBe(true);
    expect(IOS_SCALES.has(3)).toBe(true);
    expect(IOS_SCALES.has(4)).toBe(false);
    expect(IOS_SCALES.has(0.5)).toBe(false);
  });
});

describe('getAndroidDrawableFolder — Metro scaleToDrawable 매핑', () => {
  test('표준 scale 매핑 (0.75/1/1.5/2/3/4)', () => {
    expect(getAndroidDrawableFolder(0.75)).toBe('drawable-ldpi');
    expect(getAndroidDrawableFolder(1)).toBe('drawable-mdpi');
    expect(getAndroidDrawableFolder(1.5)).toBe('drawable-hdpi');
    expect(getAndroidDrawableFolder(2)).toBe('drawable-xhdpi');
    expect(getAndroidDrawableFolder(3)).toBe('drawable-xxhdpi');
    expect(getAndroidDrawableFolder(4)).toBe('drawable-xxxhdpi');
  });

  test('비표준 scale — `drawable-{round(160*scale)}dpi` fallback', () => {
    expect(getAndroidDrawableFolder(2.5)).toBe('drawable-400dpi');
    expect(getAndroidDrawableFolder(0.5)).toBe('drawable-80dpi');
  });

  test('invalid scale — `drawable-mdpi` default', () => {
    expect(getAndroidDrawableFolder(0)).toBe('drawable-mdpi');
    expect(getAndroidDrawableFolder(-1)).toBe('drawable-mdpi');
    expect(getAndroidDrawableFolder(Number.NaN)).toBe('drawable-mdpi');
  });
});

describe('Metro registered asset helpers', () => {
  test('getAndroidResourceIdentifier — Metro resource identifier 와 동일', () => {
    expect(
      getAndroidResourceIdentifier({
        httpServerLocation: '/assets/src/assets/tableOrder',
        name: 'imgLayoutB',
      }),
    ).toBe('src_assets_tableorder_imglayoutb');
  });

  test('extractRegisteredAssets — bundle 의 AssetRegistry.registerAsset 목록 추출', () => {
    const asset = {
      __packager_asset: true,
      httpServerLocation: '/assets/src/assets',
      width: 1,
      height: 1,
      scales: [1, 2],
      hash: 'hash',
      name: 'logo',
      type: 'png',
      fileSystemLocation: join(dir, 'src/assets'),
    };
    const bundle = `module.exports = Registry.registerAsset(${JSON.stringify(asset)});`;

    expect(extractRegisteredAssets(bundle)).toEqual([asset]);
  });
});

describe('buildKeepXml', () => {
  test('drawable resource list 가 keep tools attribute 에 포함', () => {
    const xml = buildKeepXml(['__src_logo', '__src_icon']);
    expect(xml).toContain('tools:keep="@drawable/__src_logo,@drawable/__src_icon"');
    expect(xml).toContain('<?xml version="1.0"');
  });

  test('빈 list — keep="" empty', () => {
    expect(buildKeepXml([])).toContain('tools:keep=""');
  });
});

describe('copyRnAssets — iOS', () => {
  test('등록된 asset 의 IOS_SCALES (1/2/3) variant 만 복사, @4x 제외', () => {
    mkdirSync(join(dir, 'src/assets'), { recursive: true });
    writeFileSync(join(dir, 'src/assets/logo.png'), 'a');
    writeFileSync(join(dir, 'src/assets/logo@2x.png'), 'b');
    writeFileSync(join(dir, 'src/assets/logo@3x.png'), 'c');

    const asset = {
      __packager_asset: true,
      httpServerLocation: '/assets/src/assets',
      width: 1,
      height: 1,
      scales: [1, 2, 3, 4],
      hash: 'hash',
      name: 'logo',
      type: 'png',
      fileSystemLocation: join(dir, 'src/assets'),
    };
    const copied = copyRnAssets({
      assetsDest: dest,
      rnPlatform: 'ios',
      bundleCode: `module.exports = Registry.registerAsset(${JSON.stringify(asset)});`,
    });

    // Metro getAssetDestPathIOS — httpServerLocation 기반 `<dest>/assets/src/assets/<file>`.
    expect(copied).toBe(3);
    expect(existsSync(join(dest, 'assets/src/assets/logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'assets/src/assets/logo@2x.png'))).toBe(true);
    expect(existsSync(join(dest, 'assets/src/assets/logo@3x.png'))).toBe(true);
    expect(existsSync(join(dest, 'assets/src/assets/logo@4x.png'))).toBe(false);
  });

  test('등록된 asset 없음 — 0 반환', () => {
    expect(
      copyRnAssets({
        assetsDest: dest,
        rnPlatform: 'ios',
        bundleCode: '/* no registered asset */',
      }),
    ).toBe(0);
  });
});

describe('copyRnAssets — Android', () => {
  test('등록된 asset 만 Metro scaleToDrawable folder + flat naming + keep.xml 로 복사', () => {
    mkdirSync(join(dir, 'src/assets'), { recursive: true });
    mkdirSync(join(dir, 'ios/resigned_payload'), { recursive: true });
    mkdirSync(join(dir, '.github/workflows'), { recursive: true });
    writeFileSync(join(dir, 'src/assets/logo.png'), 'a');
    writeFileSync(join(dir, 'src/assets/logo@2x.png'), 'b');
    writeFileSync(join(dir, 'ios/resigned_payload/AppIcon.png'), 'ios');
    writeFileSync(join(dir, '.github/workflows/ci.yml'), 'ci');

    const asset = {
      __packager_asset: true,
      httpServerLocation: '/assets/src/assets',
      width: 1,
      height: 1,
      scales: [1, 2],
      hash: 'hash',
      name: 'logo',
      type: 'png',
      fileSystemLocation: join(dir, 'src/assets'),
    };
    const copied = copyRnAssets({
      assetsDest: dest,
      rnPlatform: 'android',
      bundleCode: `module.exports = Registry.registerAsset(${JSON.stringify(asset)});`,
    });

    expect(copied).toBe(2);
    expect(existsSync(join(dest, 'drawable-mdpi/src_assets_logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'drawable-xhdpi/src_assets_logo.png'))).toBe(true);
    // 등록되지 않은 file 은 무시 — projectRoot walk path 잔존 회귀 가드.
    expect(existsSync(join(dest, 'drawable-mdpi/ios_resigned_payload_appicon.png'))).toBe(false);
    expect(existsSync(join(dest, 'raw/github_workflows_ci.yml'))).toBe(false);

    const xml = readFileSync(join(dest, 'raw/keep.xml'), 'utf-8');
    expect(xml).toContain('@drawable/src_assets_logo');
  });

  test('비-image asset — raw resource 로 복사하고 keep.xml 에 raw ref 포함', () => {
    mkdirSync(join(dir, 'fonts'), { recursive: true });
    writeFileSync(join(dir, 'fonts/icomoon.ttf'), 'x');

    const asset = {
      __packager_asset: true,
      httpServerLocation: '/assets/fonts',
      width: 0,
      height: 0,
      scales: [1],
      hash: 'hash',
      name: 'icomoon',
      type: 'ttf',
      fileSystemLocation: join(dir, 'fonts'),
    };
    copyRnAssets({
      assetsDest: dest,
      rnPlatform: 'android',
      bundleCode: `Registry.registerAsset(${JSON.stringify(asset)});`,
    });

    expect(existsSync(join(dest, 'raw/fonts_icomoon.ttf'))).toBe(true);
    const xml = readFileSync(join(dest, 'raw/keep.xml'), 'utf-8');
    expect(xml).toContain('@raw/fonts_icomoon');
  });
});

describe('copyRnAssets — guards', () => {
  test('assetsDest falsy — 0 반환', () => {
    expect(
      copyRnAssets({ assetsDest: '', rnPlatform: 'ios', bundleCode: '/* no registered asset */' }),
    ).toBe(0);
  });

  test('bundleCode 없으면 release asset copy 실패', () => {
    expect(() => copyRnAssets({ assetsDest: dest, rnPlatform: 'ios' } as never)).toThrow(
      'RN release asset copy requires bundleCode',
    );
  });
});
