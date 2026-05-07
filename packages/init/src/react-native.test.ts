import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import {
  createReactNativeConfig,
  detectPackageManager,
  initReactNativeProject,
  planReactNativeInit,
} from './react-native.ts';

function fixture(): string {
  const root = mkdtempSync(join(tmpdir(), 'zntc-init-'));
  writeFileSync(
    join(root, 'package.json'),
    JSON.stringify(
      {
        name: 'app',
        private: true,
        scripts: {
          start: 'react-native start',
          ios: 'react-native run-ios',
        },
        dependencies: {
          react: '19.0.0',
          'react-native': '0.85.1',
        },
      },
      null,
      2,
    ) + '\n',
  );
  return root;
}

function cleanup(root: string): void {
  rmSync(root, { recursive: true, force: true });
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, 'utf8'));
}

describe('@zntc/init React Native overlay', () => {
  test('patches package.json with ZNTC-first scripts and Metro fallback', () => {
    const root = fixture();
    try {
      const result = initReactNativeProject({ root, zntcVersion: '^0.1.0' });
      expect(result.dryRun).toBe(false);
      expect(result.changes.map((c) => c.action)).toEqual(['update', 'create']);

      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.devDependencies['@zntc/core']).toBe('^0.1.0');
      expect(pkg.devDependencies['@zntc/react-native']).toBe('^0.1.0');
      expect(pkg.scripts.start).toBe('zntc dev --platform=react-native --rn-platform=ios index.js');
      expect(pkg.scripts['start:metro']).toBe('react-native start');
      expect(pkg.scripts['bundle:ios']).toContain('zntc --bundle index.js');
      expect(pkg.scripts['bundle:ios']).toContain('--bundle-output ios/main.jsbundle');
      expect(pkg.scripts['bundle:ios']).toContain('--assets-dest ios');
      expect(pkg.scripts['bundle:android']).toContain('--assets-dest android/app/src/main/res');
      expect(pkg.scripts['bundle:metro:ios']).toContain('react-native bundle --platform ios');
      expect(readFileSync(join(root, 'zntc.config.ts'), 'utf8')).toBe(createReactNativeConfig());
      expect(createReactNativeConfig()).not.toContain('inlineRequires');
      expect(createReactNativeConfig()).not.toContain('bundleType');
    } finally {
      cleanup(root);
    }
  });

  test('supports android as default start platform', () => {
    const root = fixture();
    try {
      initReactNativeProject({ root, defaultPlatform: 'android' });
      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.scripts.start).toContain('--rn-platform=android');
    } finally {
      cleanup(root);
    }
  });

  test('does not duplicate ZNTC packages already declared in dependencies', () => {
    const root = fixture();
    try {
      const pkg = readJson(join(root, 'package.json'));
      pkg.dependencies['@zntc/core'] = '^0.1.0';
      pkg.dependencies['@zntc/react-native'] = '^0.1.0';
      writeFileSync(join(root, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');

      initReactNativeProject({ root, zntcVersion: 'latest' });
      const updated = readJson(join(root, 'package.json'));
      expect(updated.dependencies['@zntc/core']).toBe('^0.1.0');
      expect(updated.dependencies['@zntc/react-native']).toBe('^0.1.0');
      expect(updated.devDependencies).toBeUndefined();
    } finally {
      cleanup(root);
    }
  });

  test('can skip Metro fallback scripts', () => {
    const root = fixture();
    try {
      initReactNativeProject({ root, metroFallback: false });
      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.scripts['start:metro']).toBeUndefined();
      expect(pkg.scripts['bundle:metro:ios']).toBeUndefined();
      expect(pkg.scripts['bundle:metro:android']).toBeUndefined();
    } finally {
      cleanup(root);
    }
  });

  test('dry-run returns planned changes without writing files', () => {
    const root = fixture();
    try {
      const before = readFileSync(join(root, 'package.json'), 'utf8');
      const result = initReactNativeProject({ root, dryRun: true });
      expect(result.dryRun).toBe(true);
      expect(result.changes.map((c) => c.action)).toEqual(['update', 'create']);
      expect(readFileSync(join(root, 'package.json'), 'utf8')).toBe(before);
      expect(() => readFileSync(join(root, 'zntc.config.ts'), 'utf8')).toThrow();
    } finally {
      cleanup(root);
    }
  });

  test('second run is stable', () => {
    const root = fixture();
    try {
      initReactNativeProject({ root });
      const second = initReactNativeProject({ root });
      expect(second.changes.map((c) => c.action)).toEqual(['unchanged', 'unchanged']);
    } finally {
      cleanup(root);
    }
  });

  test('does not overwrite existing zntc.config.ts unless force is enabled', () => {
    const root = fixture();
    try {
      writeFileSync(join(root, 'zntc.config.ts'), 'export default { custom: true };\n');
      initReactNativeProject({ root });
      expect(readFileSync(join(root, 'zntc.config.ts'), 'utf8')).toBe(
        'export default { custom: true };\n',
      );

      initReactNativeProject({ root, force: true });
      expect(readFileSync(join(root, 'zntc.config.ts'), 'utf8')).toBe(createReactNativeConfig());
    } finally {
      cleanup(root);
    }
  });

  test('rejects non React Native projects', () => {
    const root = mkdtempSync(join(tmpdir(), 'zntc-init-'));
    try {
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'web' }) + '\n');
      expect(() => planReactNativeInit({ root })).toThrow('react-native dependency not found');
    } finally {
      cleanup(root);
    }
  });

  test('detects package manager from lockfiles', () => {
    const root = fixture();
    try {
      expect(detectPackageManager(root)).toBe('npm');
      const pkg = readJson(join(root, 'package.json'));
      pkg.packageManager = 'yarn@4.12.0';
      writeFileSync(join(root, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');
      expect(detectPackageManager(root)).toBe('yarn');
      writeFileSync(join(root, 'pnpm-lock.yaml'), '');
      expect(detectPackageManager(root)).toBe('pnpm');
      writeFileSync(join(root, 'bun.lock'), '');
      expect(detectPackageManager(root)).toBe('bun');
    } finally {
      cleanup(root);
    }
  });
});

describe('@zntc/init bin bootstrap', () => {
  test('prints actionable setup error when built dist is missing', () => {
    const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
    const binSource = readFileSync(join(packageRoot, 'bin/zntc-init.mjs'), 'utf8');
    const sandbox = mkdtempSync(join(tmpdir(), 'zntc-init-bin-'));

    try {
      mkdirSync(join(sandbox, 'bin'));
      const sandboxedBin = join(sandbox, 'bin/zntc-init.mjs');
      writeFileSync(sandboxedBin, binSource);

      const result = spawnSync('node', [sandboxedBin, '--help'], {
        cwd: sandbox,
        encoding: 'utf8',
      });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain('error: @zntc/init JS bundle is missing');
      expect(result.stderr).toContain('help: run `bun run --cwd packages/init build`');
      expect(result.stderr).not.toContain('ERR_MODULE_NOT_FOUND');
    } finally {
      rmSync(sandbox, { recursive: true, force: true });
    }
  });
});
