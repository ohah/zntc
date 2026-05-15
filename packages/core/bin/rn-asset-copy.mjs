// RN production bundle 의 asset 복사. Metro saveAssets/getAssetDestPath{IOS,Android}
// 호환 경로를 사용한다 — bundler 가 `--asset-registry` 호출 시 emit 한 asset
// metadata (result.rnAssetMetadata) 를 직접 받아 release 산출물을 자동 prune.
// `runRnBundle` 이 dev=false + `--assets-dest` 명시 시 호출.

import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';

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
 * Metro Android resource-identifier sanitize — lowercase, `/` → `_`, non-alnum
 * 제거, `assets_`/`assetsunstable_path_` prefix 제거. `asset.httpServerLocation`
 * 이 항상 `/assets/...` 또는 `/assetsunstable_path/...` 로 시작하므로 prefix
 * 제거가 resource identifier 의 일부.
 */
function metroSanitizeResourceName(rawPath) {
  return rawPath
    .toLowerCase()
    .replace(/\//g, '_')
    .replace(/[^a-z0-9_]/g, '')
    .replace(/^(?:assets|assetsunstable_path)_/, '');
}

export function getAndroidResourceIdentifier(asset) {
  let basePath = asset.httpServerLocation ?? '';
  if (basePath.startsWith('/')) basePath = basePath.slice(1);
  return metroSanitizeResourceName(`${basePath}/${asset.name}`);
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

function sourceFileForScale(asset, scale) {
  const suffix = scale === 1 ? '' : `@${scale}x`;
  return join(asset.fileSystemLocation, `${asset.name}${suffix}.${asset.type}`);
}

async function copyRegisteredAssetFile(src, destPath) {
  try {
    await copyFile(src, destPath);
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      throw new Error(`registered RN asset file not found: ${src}`);
    }
    throw err;
  }
}

export async function copyRegisteredAssetsForIos(assets, assetsDest) {
  const tasks = [];
  const dirs = new Set();
  for (const asset of assets) {
    for (const scale of asset.scales) {
      if (!IOS_SCALES.has(scale)) continue;
      const src = sourceFileForScale(asset, scale);
      const destPath = join(
        assetsDest,
        asset.httpServerLocation.slice(1).replace(/\.\.\//g, '_'),
        basename(src),
      );
      dirs.add(dirname(destPath));
      tasks.push({ src, destPath });
    }
  }
  await Promise.all([...dirs].map((d) => mkdir(d, { recursive: true })));
  await Promise.all(tasks.map(({ src, destPath }) => copyRegisteredAssetFile(src, destPath)));
  return tasks.length;
}

export async function copyRegisteredAssetsForAndroid(assets, assetsDest) {
  const keepRefs = new Set();
  const dirs = new Set();
  const tasks = [];

  for (const asset of assets) {
    const isDrawable = DRAWABLE_EXT_RE.test(`.${asset.type}`);
    const resourceName = getAndroidResourceIdentifier(asset);
    for (const scale of asset.scales) {
      const folder = isDrawable ? getAndroidDrawableFolder(scale) : 'raw';
      const targetDir = join(assetsDest, folder);
      dirs.add(targetDir);
      tasks.push({
        src: sourceFileForScale(asset, scale),
        destPath: join(targetDir, `${resourceName}.${asset.type}`),
      });
    }
    keepRefs.add(`@${isDrawable ? 'drawable' : 'raw'}/${resourceName}`);
  }

  const keepDir = keepRefs.size > 0 ? join(assetsDest, 'raw') : null;
  if (keepDir) dirs.add(keepDir);

  await Promise.all([...dirs].map((d) => mkdir(d, { recursive: true })));
  await Promise.all(tasks.map(({ src, destPath }) => copyRegisteredAssetFile(src, destPath)));

  if (keepDir) {
    await writeFile(join(keepDir, 'keep.xml'), buildKeepXml([...keepRefs].sort()));
  }

  return tasks.length;
}

/**
 * Production asset 복사 entry — caller (runRnBundle) 에서 dev=false + assetsDest
 * 명시 시 호출. Bundler 가 emit 한 `result.rnAssetMetadata` 를 그대로 받아
 * Metro 호환 경로로 복사.
 *
 * @returns 복사된 파일 수.
 */
export async function copyRnAssets({ assetsDest, rnPlatform, assets }) {
  if (!assetsDest) return 0;
  if (!Array.isArray(assets)) {
    throw new Error('RN release asset copy requires assets metadata array');
  }
  if (assets.length === 0) return 0;
  if (rnPlatform === 'android') {
    return copyRegisteredAssetsForAndroid(assets, assetsDest);
  }
  return copyRegisteredAssetsForIos(assets, assetsDest);
}
