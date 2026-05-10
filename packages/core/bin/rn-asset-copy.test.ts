import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  androidAssetFileName,
  buildKeepXml,
  copyRnAssets,
  discoverAssets,
  getAndroidDrawableFolder,
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
  test('빈 relDir — `__<baseName><ext>`', () => {
    expect(androidAssetFileName('', 'logo', '.png')).toBe('___logo.png');
  });

  test('단순 디렉토리 — `__<dir>_<baseName><ext>`', () => {
    expect(androidAssetFileName('src/assets', 'logo', '.png')).toBe('__src_assets_logo.png');
  });

  test('비-alnum 문자 제거', () => {
    expect(androidAssetFileName('src/img-foo', 'icon', '.svg')).toBe('__src_imgfoo_icon.svg');
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
});

describe('copyRnAssets — iOS', () => {
  test('IOS_SCALES (1/2/3) 만 통과 + relDir 보존', () => {
    mkdirSync(join(dir, 'src/assets'), { recursive: true });
    writeFileSync(join(dir, 'src/assets/logo.png'), 'a');
    writeFileSync(join(dir, 'src/assets/logo@2x.png'), 'b');
    writeFileSync(join(dir, 'src/assets/logo@3x.png'), 'c');
    writeFileSync(join(dir, 'src/assets/logo@4x.png'), 'd'); // skip

    const copied = copyRnAssets({
      projectRoot: dir,
      assetsDest: dest,
      rnPlatform: 'ios',
      assetExts: ['.png'],
    });
    expect(copied).toBe(3); // 1x/2x/3x 만, 4x 제외
    expect(existsSync(join(dest, 'src/assets/logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'src/assets/logo@2x.png'))).toBe(true);
    expect(existsSync(join(dest, 'src/assets/logo@3x.png'))).toBe(true);
    expect(existsSync(join(dest, 'src/assets/logo@4x.png'))).toBe(false);
  });

  test('asset 0 — copied 0', () => {
    expect(
      copyRnAssets({ projectRoot: dir, assetsDest: dest, rnPlatform: 'ios', assetExts: ['.png'] }),
    ).toBe(0);
  });
});

describe('copyRnAssets — Android', () => {
  test('Metro scaleToDrawable folder + flat naming + keep.xml', () => {
    mkdirSync(join(dir, 'src/img'), { recursive: true });
    writeFileSync(join(dir, 'src/img/logo.png'), 'a');
    writeFileSync(join(dir, 'src/img/logo@2x.png'), 'b');
    writeFileSync(join(dir, 'src/img/logo@3x.png'), 'c');

    const copied = copyRnAssets({
      projectRoot: dir,
      assetsDest: dest,
      rnPlatform: 'android',
      assetExts: ['.png'],
    });
    expect(copied).toBe(3);
    // 1x → mdpi, 2x → xhdpi, 3x → xxhdpi (Metro 매핑)
    expect(existsSync(join(dest, 'drawable-mdpi/__src_img_logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'drawable-xhdpi/__src_img_logo.png'))).toBe(true);
    expect(existsSync(join(dest, 'drawable-xxhdpi/__src_img_logo.png'))).toBe(true);
    // keep.xml 생성
    const keepPath = join(dest, 'raw/keep.xml');
    expect(existsSync(keepPath)).toBe(true);
    const xml = readFileSync(keepPath, 'utf-8');
    expect(xml).toContain('@drawable/__src_img_logo');
  });

  test('Android — 4x scale 도 통과 (iOS 와 다름)', () => {
    mkdirSync(join(dir, 'a'), { recursive: true });
    writeFileSync(join(dir, 'a/icon@4x.png'), 'x');
    const copied = copyRnAssets({
      projectRoot: dir,
      assetsDest: dest,
      rnPlatform: 'android',
      assetExts: ['.png'],
    });
    expect(copied).toBe(1);
    expect(existsSync(join(dest, 'drawable-xxxhdpi/__a_icon.png'))).toBe(true);
  });

  test('Non-image asset — keep.xml 의 drawable list 에서 제외', () => {
    mkdirSync(join(dir, 'a'), { recursive: true });
    writeFileSync(join(dir, 'a/font.ttf'), 'x');
    copyRnAssets({
      projectRoot: dir,
      assetsDest: dest,
      rnPlatform: 'android',
      assetExts: ['.ttf'],
    });
    // ttf 는 drawable 자원 아님 → keep.xml 미생성
    expect(existsSync(join(dest, 'raw/keep.xml'))).toBe(false);
  });
});

describe('copyRnAssets — guards', () => {
  test('assetsDest falsy — 0 반환', () => {
    expect(
      copyRnAssets({ projectRoot: dir, assetsDest: '', rnPlatform: 'ios', assetExts: ['.png'] }),
    ).toBe(0);
  });

  test('projectRoot 미존재 — 0 반환', () => {
    expect(
      copyRnAssets({
        projectRoot: '/__nope__',
        assetsDest: dest,
        rnPlatform: 'ios',
        assetExts: ['.png'],
      }),
    ).toBe(0);
  });
});
