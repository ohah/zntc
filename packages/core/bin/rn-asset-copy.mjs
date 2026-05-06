// RN production bundle 의 asset 복사. bungae packages/bungae/src/build.ts L100~L260
// + zts-bundler/build.ts copyAssets / plugin-core.ts SCALE_REGEX/IOS_SCALES 이식.
//
// caller (`runRnBundle`) 가 production (dev=false) + `--assets-dest` 명시 시 호출.
// 동작:
//   1. projectRoot 를 walkDir — assetExts 화이트리스트 매칭 file 수집.
//   2. file 마다 scale variant 동일 디렉토리에서 추가 수집 (`@2x.png` 등).
//   3. iOS — IOS_SCALES (1/2/3) 만 통과, `<assetsDest>/<relPath>/<file>` 복사.
//   4. Android — Metro scaleToDrawable 매핑 (1→mdpi/1.5→hdpi/2→xhdpi/3→xxhdpi/4→xxxhdpi),
//      `__<flatRel>_<basename>.<ext>` naming + keep.xml 생성.
//   5. node_modules / .git / dist / build / .next / .turbo / .bun / .DS_Store skip.

import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
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

const DRAWABLE_EXT_RE = /\.(png|jpg|jpeg|gif|webp|bmp|avif|ico|icns|icxl)$/i;

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
 * relative path 의 `/` 를 `_` 로 치환 + 비-alnum 문자 제거 + `__` prefix
 * (node_modules asset 표식 — Metro 가 그대로 따름).
 */
export function androidAssetFileName(relDir, baseName, ext) {
  const flat = relDir.replace(/\//g, '_').replace(/[^a-z0-9_]/gi, '');
  const prefix = flat ? (flat.startsWith('__') ? flat : `__${flat}`) : '__';
  return `${prefix}_${baseName}${ext}`;
}

/** Android `keep.xml` body — drawable 자원 보존 list. */
export function buildKeepXml(drawableNames) {
  const items = drawableNames.map((n) => `@drawable/${n}`).join(',');
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    `<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="${items}" />`,
    '',
  ].join('\n');
}

/**
 * project 안의 asset 파일 walk + scale variant 수집. visited set 으로 같은 파일을
 * 다중 방문 방지 (scale variant 발견 시 둘 다 등록).
 *
 * 반환: `[{ filePath, baseName, scale, ext, relDir }]`. relDir 은 projectRoot
 * 기준 상대 경로 (POSIX `/`).
 */
export function discoverAssets(projectRoot, assetExts) {
  const exts = new Set(
    [...assetExts].map((e) => (e.startsWith('.') ? e.toLowerCase() : `.${e.toLowerCase()}`)),
  );
  const visited = new Set();
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
      if (visited.has(full)) continue;
      visited.add(full);
      const parsed = parseAssetName(entry.name);
      const relDir = relative(projectRoot, dir).replace(/\\/g, '/');
      out.push({ filePath: full, ...parsed, relDir });
    }
  }
  walk(projectRoot);
  return out;
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

/**
 * Android production 복사 — Metro scale-to-drawable folder + flattened name +
 * keep.xml. drawable resource name (확장자 제거) 을 keepNames 에 누적.
 *
 * `assetsDest` 가 명시되면 그 경로 기준, 미지정 시 `<projectRoot>/android/app/src/main/res`.
 */
export function copyAssetsForAndroid(assets, assetsDest) {
  const baseDir = assetsDest;
  const keepNames = new Set();
  let copied = 0;
  for (const a of assets) {
    const folder = getAndroidDrawableFolder(a.scale);
    const targetDir = join(baseDir, folder);
    mkdirSync(targetDir, { recursive: true });
    const fileName = androidAssetFileName(a.relDir, a.baseName, a.ext);
    copyFileSync(a.filePath, join(targetDir, fileName));
    copied++;
    if (DRAWABLE_EXT_RE.test(fileName)) {
      keepNames.add(fileName.replace(DRAWABLE_EXT_RE, ''));
    }
  }
  // keep.xml — `res/raw/keep.xml` 위치. drawable resources 의 ProGuard/R8 미사용
  // 보장.
  if (keepNames.size > 0) {
    const keepDir = join(baseDir, 'raw');
    mkdirSync(keepDir, { recursive: true });
    writeFileSync(join(keepDir, 'keep.xml'), buildKeepXml([...keepNames].sort()));
  }
  return copied;
}

/**
 * Production asset 복사 entry — caller (runRnBundle) 에서 dev=false + assetsDest
 * 명시 시 호출. discoverAssets + platform 분기.
 *
 * @returns 복사된 파일 수.
 */
export function copyRnAssets({ projectRoot, assetsDest, rnPlatform, assetExts }) {
  if (!assetsDest || !existsSync(projectRoot) || !statSync(projectRoot).isDirectory()) {
    return 0;
  }
  const assets = discoverAssets(projectRoot, assetExts);
  if (assets.length === 0) return 0;
  if (rnPlatform === 'android') {
    return copyAssetsForAndroid(assets, assetsDest);
  }
  return copyAssetsForIos(assets, assetsDest);
}
