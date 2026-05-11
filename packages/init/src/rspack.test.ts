import { describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { createRspackConfig, initRspackProject, planRspackInit } from './rspack.ts';

function rspackFixture(): string {
  const root = mkdtempSync(join(tmpdir(), 'zntc-init-rspack-'));
  writeFileSync(
    join(root, 'package.json'),
    JSON.stringify(
      {
        name: 'app',
        private: true,
        type: 'module',
        scripts: { build: 'rspack build' },
        devDependencies: { '@rspack/core': '^2.0.1', '@rspack/cli': '^2.0.1' },
      },
      null,
      2,
    ) + '\n',
  );
  return root;
}

function webpackFixture(): string {
  const root = mkdtempSync(join(tmpdir(), 'zntc-init-webpack-'));
  writeFileSync(
    join(root, 'package.json'),
    JSON.stringify(
      {
        name: 'app',
        private: true,
        type: 'module',
        scripts: { build: 'webpack' },
        devDependencies: { webpack: '^5.94.0', 'webpack-cli': '^5.0.0' },
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

describe('@zntc/init rspack overlay', () => {
  test('auto-detects rspack and scaffolds rspack.config.mjs', () => {
    const root = rspackFixture();
    try {
      const result = initRspackProject({ root, zntcVersion: '^0.1.0' });
      expect(result.bundler).toBe('rspack');
      const configChange = result.changes.find((c) => c.path.endsWith('rspack.config.mjs'));
      expect(configChange?.action).toBe('create');

      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.devDependencies['@zntc/rspack-loader']).toBe('^0.1.0');
      expect(pkg.devDependencies['@zntc/core']).toBe('^0.1.0');

      const config = readFileSync(join(root, 'rspack.config.mjs'), 'utf8');
      expect(config).toBe(createRspackConfig('rspack'));
      expect(config).toContain("loader: '@zntc/rspack-loader'");
    } finally {
      cleanup(root);
    }
  });

  test('auto-detects webpack and produces a webpack.config.mjs', () => {
    const root = webpackFixture();
    try {
      const result = initRspackProject({ root });
      expect(result.bundler).toBe('webpack');
      const configChange = result.changes.find((c) => c.path.endsWith('webpack.config.mjs'));
      expect(configChange?.action).toBe('create');

      const config = readFileSync(join(root, 'webpack.config.mjs'), 'utf8');
      expect(config).toBe(createRspackConfig('webpack'));
    } finally {
      cleanup(root);
    }
  });

  test('--bundler hint wins over auto-detect', () => {
    const root = rspackFixture();
    try {
      const result = initRspackProject({ root, bundler: 'webpack' });
      expect(result.bundler).toBe('webpack');
    } finally {
      cleanup(root);
    }
  });

  test('refuses to overwrite existing rspack.config and surfaces manual instructions', () => {
    const root = rspackFixture();
    try {
      writeFileSync(join(root, 'rspack.config.mjs'), 'export default { mode: "development" };\n');
      const result = initRspackProject({ root });
      const configChange = result.changes.find((c) => c.path.endsWith('rspack.config.mjs'));
      expect(configChange?.action).toBe('manual');
      expect(configChange?.manualInstructions).toContain('@zntc/rspack-loader');
    } finally {
      cleanup(root);
    }
  });

  test('rejects projects without rspack or webpack', () => {
    const root = mkdtempSync(join(tmpdir(), 'zntc-init-rspack-'));
    try {
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'x' }) + '\n');
      expect(() => planRspackInit({ root })).toThrow('@rspack/core or webpack');
    } finally {
      cleanup(root);
    }
  });
});
