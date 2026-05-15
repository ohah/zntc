import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  androidAssetFileName,
  buildKeepXml,
  copyAssetsForAndroid,
  copyAssetsForIos,
  copyRnAssets,
  discoverAssets,
  extractRegisteredAssets,
  getAndroidDrawableFolder,
  getAndroidResourceIdentifier,
  IOS_SCALES,
  parseAssetName,
  SCALE_REGEX,
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

describe('SCALE_REGEX / IOS_SCALES — bungae plugin-core 호환', () => {
  test('SCALE_REGEX — `@2x` / `@3x` / `@1.5x` 매칭', () => {
    expect('foo@2x.png'.match(SCALE_REGEX)?.[1]).toBe('2');
    expect('icon@3x'.match(SCALE_REGEX)?.[1]).toBe('3');
    expect('img@1.5x.svg'.match(SCALE_REGEX)?.[1]).toBe('1.5');
  });

  test('SCALE_REGEX — scale 표기 없으면 null', () => {
    expect('foo.png'.match(SCALE_REGEX)).toBeNull();
  });

  test('IOS_SCALES — 1/2/3 만 포함', () => {
    expect(IOS_SCALES.has(1)).toBe(true);
    expect(IOS_SCALES.has(2)).toBe(true);
    expect(IOS_SCALES.has(3)).toBe(true);
    expect(IOS_SCALES.has(4)).toBe(false);
    expect(IOS_SCALES.has(0.5)).toBe(false);
  });
});

describe('parseAssetName', () => {
  test('scale 없는 단순 파일', () => {
    expect(parseAssetName('foo.png')).toEqual({ baseName: 'foo', scale: 1, ext: '.png' });
  });

  test('scale 있는 파일', () => {
    expect(parseAssetName('icon@2x.png')).toEqual({ baseName: 'icon', scale: 2, ext: '.png' });
    expect(parseAssetName('logo@3x.svg')).toEqual({ baseName: 'logo', scale: 3, ext: '.svg' });
  });

  test('소수점 scale (1.5)', () => {
    expect(parseAssetName('img@1.5x.png')).toEqual({ baseName: 'img', scale: 1.5, ext: '.png' });
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

describe('androidAssetFileName — Metro flat naming', () => {
  test('빈 relDir — `<baseName><ext>`', () => {
    expect(androidAssetFileName('', 'logo', '.png')).toBe('logo.png');
  });

  test('단순 디렉토리 — `<dir>_<baseName><ext>`', () => {
    expect(androidAssetFileName('src/assets', 'logo', '.png')).toBe('src_assets_logo.png');
  });

  test('비-alnum 문자 제거', () => {
    expect(androidAssetFileName('src/img-foo', 'icon', '.svg')).toBe('src_imgfoo_icon.svg');
  });

  test('Android resource 호환을 위해 대문자를 소문자로 정규화', () => {
    expect(androidAssetFileName('src/assets/tableOrder', 'imgLayoutB', '.PNG')).toBe(
      'src_assets_tableorder_imglayoutb.png',
    );
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

describe('discoverAssets', () => {
  test('assetExts 매칭 file 만 수집, node_modules / .git skip', () => {
    writeFileSync(join(dir, 'logo.png'), 'a');
    writeFileSync(join(dir, 'data.json'), 'b');
    mkdirSync(join(dir, 'node_modules'), { recursive: true });
    writeFileSync(join(dir, 'node_modules/skip.png'), 'c');
    mkdirSync(join(dir, '.git'), { recursive: true });
    writeFileSync(join(dir, '.git/skip.png'), 'd');
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'src/icon.svg'), 'e');

    const result = discoverAssets(dir, ['.png', '.svg']);
    const names = result.map((r) => r.filePath.replace(`${dir}/`, '')).sort();
    expect(names).toEqual(['logo.png', 'src/icon.svg']);
  });

  test('relDir — projectRoot 기준 POSIX 상대 경로', () => {
    mkdirSync(join(dir, 'a/b'), { recursive: true });
    writeFileSync(join(dir, 'a/b/icon.png'), 'x');
    const result = discoverAssets(dir, ['.png']);
    expect(result[0]?.relDir).toBe('a/b');
  });

  test('빈 디렉토리 / 매칭 없음 — 빈 array', () => {
    expect(discoverAssets(dir, ['.png'])).toEqual([]);
  });

  test('확장자 case-insensitive', () => {
    writeFileSync(join(dir, 'LOGO.PNG'), 'x');
    const result = discoverAssets(dir, ['.png']);
    expect(result.length).toBe(1);
  });

  test('sourceExts 와 겹치는 확장자는 asset copy 에서 제외', () => {
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'src/icon.svg'), '<svg />');
    writeFileSync(join(dir, 'src/logo.png'), 'png');

    const result = discoverAssets(dir, ['.svg', '.png'], ['.svg']);
    const names = result.map((r) => r.filePath.replace(`${dir}/`, '')).sort();
    expect(names).toEqual(['src/logo.png']);
  });
});

describe('copyRnAssets — iOS', () => {
  test('IOS_SCALES (1/2/3) 만 통과 + relDir 보존', () => {
    mkdirSync(join(dir, 'src/assets'), { recursive: true });
    writeFileSync(join(dir, 'src/assets/logo.png'), 'a');
    writeFileSync(join(dir, 'src/assets/logo@2x.png'), 'b');
    writeFileSync(join(dir, 'src/assets/logo@3x.png'), 'c');
    writeFileSync(join(dir, 'src/assets/logo@4x.png'), 'd'); // skip

    const copied = copyAssetsForIos(discoverAssets(dir, ['.png']), dest);
    expect(copied).toBe(3); // 1x/2x/3x 만, 4x 제외
    expect(existsSync(join(dest, 'src/assets/logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'src/assets/logo@2x.png'))).toBe(true);
    expect(existsSync(join(dest, 'src/assets/logo@3x.png'))).toBe(true);
    expect(existsSync(join(dest, 'src/assets/logo@4x.png'))).toBe(false);
  });

  test('asset 0 — copied 0', () => {
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
  test('Metro scaleToDrawable folder + flat naming + keep.xml', () => {
    mkdirSync(join(dir, 'src/img'), { recursive: true });
    writeFileSync(join(dir, 'src/img/logo.png'), 'a');
    writeFileSync(join(dir, 'src/img/logo@2x.png'), 'b');
    writeFileSync(join(dir, 'src/img/logo@3x.png'), 'c');

    const copied = copyAssetsForAndroid(discoverAssets(dir, ['.png']), dest);
    expect(copied).toBe(3);
    // 1x → mdpi, 2x → xhdpi, 3x → xxhdpi (Metro 매핑)
    expect(existsSync(join(dest, 'drawable-mdpi/src_img_logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'drawable-xhdpi/src_img_logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'drawable-xxhdpi/src_img_logo.png'))).toBe(true);
    // keep.xml 생성
    const keepPath = join(dest, 'raw/keep.xml');
    expect(existsSync(keepPath)).toBe(true);
    const xml = readFileSync(keepPath, 'utf-8');
    expect(xml).toContain('@drawable/src_img_logo');
  });

  test('Android — 4x scale 도 통과 (iOS 와 다름)', () => {
    mkdirSync(join(dir, 'a'), { recursive: true });
    writeFileSync(join(dir, 'a/icon@4x.png'), 'x');
    const copied = copyAssetsForAndroid(discoverAssets(dir, ['.png']), dest);
    expect(copied).toBe(1);
    expect(existsSync(join(dest, 'drawable-xxxhdpi/a_icon.png'))).toBe(true);
  });

  test('Non-image asset — raw resource 로 복사하고 keep.xml 에 raw ref 포함', () => {
    mkdirSync(join(dir, 'a'), { recursive: true });
    writeFileSync(join(dir, 'a/font.ttf'), 'x');
    copyAssetsForAndroid(discoverAssets(dir, ['.ttf']), dest);
    expect(existsSync(join(dest, 'raw/a_font.ttf'))).toBe(true);
    const xml = readFileSync(join(dest, 'raw/keep.xml'), 'utf-8');
    expect(xml).toContain('@raw/a_font');
  });

  test('Android raw asset — yml 은 drawable 이 아니라 raw 로 복사', () => {
    mkdirSync(join(dir, 'pods/Foo.framework.dSYM/Contents/Resources'), { recursive: true });
    writeFileSync(join(dir, 'pods/Foo.framework.dSYM/Contents/Resources/foo.yml'), 'x');
    const copied = copyAssetsForAndroid(discoverAssets(dir, ['.yml']), dest);

    expect(copied).toBe(1);
    expect(existsSync(join(dest, 'raw/pods_fooframeworkdsym_contents_resources_foo.yml'))).toBe(
      true,
    );
    expect(
      existsSync(join(dest, 'drawable-mdpi/pods_fooframeworkdsym_contents_resources_foo.yml')),
    ).toBe(false);
  });

  test('sourceExts 와 겹치는 svg 는 Android drawable 로 복사하지 않음', () => {
    mkdirSync(join(dir, 'src/img'), { recursive: true });
    writeFileSync(join(dir, 'src/img/icon.svg'), '<svg />');
    writeFileSync(join(dir, 'src/img/logo.png'), 'png');

    const copied = copyAssetsForAndroid(discoverAssets(dir, ['.svg', '.png'], ['.svg']), dest);

    expect(copied).toBe(1);
    expect(existsSync(join(dest, 'drawable-mdpi/src_img_icon.svg'))).toBe(false);
    expect(existsSync(join(dest, 'drawable-mdpi/src_img_logo.png'))).toBe(true);
  });

  test('bundleCode 가 있으면 등록된 asset 만 Metro naming 으로 복사', () => {
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
    expect(existsSync(join(dest, 'drawable-mdpi/ios_resigned_payload_appicon.png'))).toBe(false);
    expect(existsSync(join(dest, 'raw/github_workflows_ci.yml'))).toBe(false);
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
