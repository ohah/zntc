// RN production bundle 의 asset 복사. Metro saveAssets/getAssetDestPathAndroid
// 호환 경로를 사용한다.
//
// caller (`runRnBundle`) 가 production (dev=false) + `--assets-dest` 명시 시 호출.
// 동작:
//   1. bundle 안의 `AssetRegistry.registerAsset({...})` 를 읽어 참조된 asset만 수집.
//   2. 각 asset 의 scales 기준으로 원본/`@2x`/`@3x` 파일을 복사.
//   3. iOS — Metro getAssetDestPathIOS 형식으로 복사.
//   4. Android — Metro getResourceIdentifier + drawable/raw 분기 + keep.xml 생성.
//   5. projectRoot walk helper 는 단위 테스트와 저수준 호출용으로만 유지.

import { copyFileSync, existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { basename, dirname, extname, join, relative } from 'node:path';

/** scale variant naming — `@2x.png` / `@3x.png` 등. capture group 1 이 scale 숫자. */
export const SCALE_REGEX = /@(\d+(?:\.\d+)?)x/;
/** iOS 가 native 로 인식하는 scale set. 그 외 (`@4x` 등) 는 production bundle 에서 제외. */
export const IOS_SCALES = new Set([1, 2, 3]);

/** Metro scale → Android drawable folder. Metro `assetPathUtils.js` 와 동일. */
const SCALE_TO_DRAWABLE = {
  0.75: 'ldpi',
  1: 'mdpi',
  1.5: 'hdpi',
  2: 'xhdpi',
  3: 'xxhdpi',
  4: 'xxxhdpi',
};

const SKIP_DIRS = new Set([
  'node_modules',
  '.git',
  '.bungae',
  'dist',
  'build',
  '.next',
  '.turbo',
  '.bun',
  '.DS_Store',
]);

const DRAWABLE_EXT_RE = /\.(gif|jpeg|jpg|png|webp|xml)$/i;

/**
 * Metro 호환 Android drawable folder name. table miss 시 `drawable-{round(160*scale)}dpi`
 * fallback (Metro custom scale). 음수/0 같은 invalid scale 은 `drawable-mdpi` (default).
 */
export function getAndroidDrawableFolder(scale) {
  if (SCALE_TO_DRAWABLE[scale]) return `drawable-${SCALE_TO_DRAWABLE[scale]}`;
  if (Number.isFinite(scale) && scale > 0) return `drawable-${Math.round(160 * scale)}dpi`;
  return 'drawable-mdpi';
}

/**
 * Asset 의 base name (scale variant suffix 제거) 과 scale 추출. `foo@2x.png` →
 * `{ baseName: 'foo', scale: 2 }`, `foo.png` → `{ baseName: 'foo', scale: 1 }`.
 */
export function parseAssetName(filename) {
  const ext = extname(filename);
  const stem = basename(filename, ext);
  const m = stem.match(SCALE_REGEX);
  if (!m) return { baseName: stem, scale: 1, ext };
  return {
    baseName: stem.replace(SCALE_REGEX, ''),
    scale: Number.parseFloat(m[1]),
    ext,
  };
}

/**
 * Metro 의 Android filename convention — `<flatRelPath>_<baseName>.<ext>` 형식.
 * `asset.httpServerLocation` 의 `/assets/` prefix 는 resource identifier 에서 제거된다.
 */
export function androidAssetFileName(relDir, baseName, ext) {
  const sanitize = (value) => value.toLowerCase().replace(/[^a-z0-9_]/g, '');
  const flat = sanitize(relDir.replace(/\//g, '_')).replace(/^(?:assets|assetsunstable_path)_/, '');
  const prefix = flat ? `${flat}_` : '';
  return `${prefix}${sanitize(baseName)}${ext.toLowerCase()}`;
}

export function getAndroidResourceIdentifier(asset) {
  let basePath = asset.httpServerLocation ?? '';
  if (basePath.startsWith('/')) basePath = basePath.slice(1);
  return `${basePath}/${asset.name}`
    .toLowerCase()
    .replace(/\//g, '_')
    .replace(/([^a-z0-9_])/g, '')
    .replace(/^(?:assets|assetsunstable_path)_/, '');
}

/** Android `keep.xml` body — drawable/raw 자원 보존 list. */
export function buildKeepXml(drawableNames) {
  const items = drawableNames.map((n) => (n.startsWith('@') ? n : `@drawable/${n}`)).join(',');
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    `<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="${items}" />`,
    '',
  ].join('\n');
}

/**
 * project 안의 asset 파일 walk + scale variant 수집. 반환:
 * `[{ filePath, baseName, scale, ext, relDir }]`. relDir 은 projectRoot
 * 기준 상대 경로 (POSIX `/`).
 */
export function discoverAssets(projectRoot, assetExts, sourceExts = []) {
  const normalizeExt = (e) => (e.startsWith('.') ? e.toLowerCase() : `.${e.toLowerCase()}`);
  const sourceExtSet = new Set([...sourceExts].map(normalizeExt));
  const exts = new Set([...assetExts].map(normalizeExt));
  for (const ext of sourceExtSet) {
    exts.delete(ext);
  }
  const out = [];

  function walk(dir) {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (SKIP_DIRS.has(entry.name)) continue;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      if (!entry.isFile()) continue;
      const ext = extname(entry.name).toLowerCase();
      if (!exts.has(ext)) continue;
      const parsed = parseAssetName(entry.name);
      const relDir = relative(projectRoot, dir).replace(/\\/g, '/');
      out.push({ filePath: full, ...parsed, relDir });
    }
  }
  walk(projectRoot);
  return out;
}

function findMatchingBrace(source, openIndex) {
  let depth = 0;
  let quote = '';
  let escaped = false;

  for (let i = openIndex; i < source.length; i++) {
    const ch = source[i];

    if (quote) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === quote) {
        quote = '';
      }
      continue;
    }

    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }

    if (ch === '{') {
      depth++;
      continue;
    }

    if (ch === '}') {
      depth--;
      if (depth === 0) return i;
    }
  }

  return -1;
}

function isRegisteredAsset(value) {
  return (
    value &&
    value.__packager_asset === true &&
    typeof value.fileSystemLocation === 'string' &&
    typeof value.httpServerLocation === 'string' &&
    typeof value.name === 'string' &&
    typeof value.type === 'string' &&
    Array.isArray(value.scales)
  );
}

export function extractRegisteredAssets(bundleCode) {
  if (typeof bundleCode !== 'string' || bundleCode.length === 0) return [];

  const assets = [];
  let cursor = 0;
  while (cursor < bundleCode.length) {
    const callIndex = bundleCode.indexOf('registerAsset(', cursor);
    if (callIndex === -1) break;

    let argIndex = callIndex + 'registerAsset('.length;
    while (/\s/.test(bundleCode[argIndex] ?? '')) argIndex++;
    if (bundleCode[argIndex] !== '{') {
      cursor = argIndex + 1;
      continue;
    }

    const endIndex = findMatchingBrace(bundleCode, argIndex);
    if (endIndex === -1) break;
    const objectText = bundleCode.slice(argIndex, endIndex + 1);
    cursor = endIndex + 1;

    if (!objectText.includes('"__packager_asset"')) continue;
    try {
      const asset = JSON.parse(objectText);
      if (isRegisteredAsset(asset)) {
        assets.push({
          ...asset,
          type: asset.type.toLowerCase(),
          scales: asset.scales.filter((s) => Number.isFinite(s) && s > 0),
        });
      }
    } catch {
      // Not a JSON-shaped ZNTC/Metro asset registry call.
    }
  }

  return assets;
}

function sourceFileForScale(asset, scale) {
  const suffix = scale === 1 ? '' : `@${scale}x`;
  return join(asset.fileSystemLocation, `${asset.name}${suffix}.${asset.type}`);
}

/**
 * iOS production 복사 — `<assetsDest>/<relDir>/<file>` 으로. IOS_SCALES (1/2/3) 외
 * scale 은 제외. 같은 baseName 의 scale variant 들은 모두 같은 destDir 에 원래
 * 파일명 그대로.
 */
export function copyAssetsForIos(assets, assetsDest) {
  let copied = 0;
  for (const a of assets) {
    if (!IOS_SCALES.has(a.scale)) continue;
    const destDir = a.relDir ? join(assetsDest, a.relDir) : assetsDest;
    mkdirSync(destDir, { recursive: true });
    copyFileSync(a.filePath, join(destDir, basename(a.filePath)));
    copied++;
  }
  return copied;
}

export function copyRegisteredAssetsForIos(assets, assetsDest) {
  let copied = 0;
  for (const asset of assets) {
    for (const scale of asset.scales) {
      if (!IOS_SCALES.has(scale)) continue;
      const src = sourceFileForScale(asset, scale);
      if (!existsSync(src)) {
        throw new Error(`registered RN asset file not found: ${src}`);
      }
      const suffix = scale === 1 ? '' : `@${scale}x`;
      const destPath = join(
        assetsDest,
        asset.httpServerLocation.slice(1).replace(/\.\.\//g, '_'),
        `${asset.name}${suffix}.${asset.type}`,
      );
      mkdirSync(dirname(destPath), { recursive: true });
      copyFileSync(src, destPath);
      copied++;
    }
  }
  return copied;
}

/**
 * Android production 복사 — Metro scale-to-drawable folder + flattened name +
 * keep.xml. drawable resource name (확장자 제거) 을 keepNames 에 누적.
 *
 * `assetsDest` 가 명시되면 그 경로 기준, 미지정 시 `<projectRoot>/android/app/src/main/res`.
 */
export function copyAssetsForAndroid(assets, assetsDest) {
  const baseDir = assetsDest;
  const keepRefs = new Set();
  let copied = 0;
  for (const a of assets) {
    const isDrawable = DRAWABLE_EXT_RE.test(a.ext);
    const folder = isDrawable ? getAndroidDrawableFolder(a.scale) : 'raw';
    const targetDir = join(baseDir, folder);
    mkdirSync(targetDir, { recursive: true });
    const fileName = androidAssetFileName(a.relDir, a.baseName, a.ext);
    copyFileSync(a.filePath, join(targetDir, fileName));
    copied++;
    const resourceName = fileName.slice(0, fileName.length - extname(fileName).length);
    keepRefs.add(`@${isDrawable ? 'drawable' : 'raw'}/${resourceName}`);
  }
  // keep.xml — `res/raw/keep.xml` 위치. drawable resources 의 ProGuard/R8 미사용
  // 보장.
  if (keepRefs.size > 0) {
    const keepDir = join(baseDir, 'raw');
    mkdirSync(keepDir, { recursive: true });
    writeFileSync(join(keepDir, 'keep.xml'), buildKeepXml([...keepRefs].sort()));
  }
  return copied;
}

export function copyRegisteredAssetsForAndroid(assets, assetsDest) {
  const keepRefs = new Set();
  let copied = 0;

  for (const asset of assets) {
    const isDrawable = DRAWABLE_EXT_RE.test(`.${asset.type}`);
    const resourceName = getAndroidResourceIdentifier(asset);
    for (const scale of asset.scales) {
      const folder = isDrawable ? getAndroidDrawableFolder(scale) : 'raw';
      const src = sourceFileForScale(asset, scale);
      if (!existsSync(src)) {
        throw new Error(`registered RN asset file not found: ${src}`);
      }
      const targetDir = join(assetsDest, folder);
      mkdirSync(targetDir, { recursive: true });
      copyFileSync(src, join(targetDir, `${resourceName}.${asset.type}`));
      copied++;
    }
    keepRefs.add(`@${isDrawable ? 'drawable' : 'raw'}/${resourceName}`);
  }

  if (keepRefs.size > 0) {
    const keepDir = join(assetsDest, 'raw');
    mkdirSync(keepDir, { recursive: true });
    writeFileSync(join(keepDir, 'keep.xml'), buildKeepXml([...keepRefs].sort()));
  }

  return copied;
}

/**
 * Production asset 복사 entry — caller (runRnBundle) 에서 dev=false + assetsDest
 * 명시 시 호출. Metro처럼 bundle 에 등록된 asset 목록만 복사한다.
 *
 * @returns 복사된 파일 수.
 */
export function copyRnAssets({
  assetsDest,
  rnPlatform,
  bundleCode,
}) {
  if (!assetsDest) return 0;
  if (typeof bundleCode !== 'string') {
    throw new Error('RN release asset copy requires bundleCode');
  }
  const registeredAssets = extractRegisteredAssets(bundleCode);
  if (registeredAssets.length === 0) return 0;
  if (rnPlatform === 'android') {
    return copyRegisteredAssetsForAndroid(registeredAssets, assetsDest);
  }
  return copyRegisteredAssetsForIos(registeredAssets, assetsDest);
}
