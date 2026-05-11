import { describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { createViteConfig, initViteProject, planViteInit } from './vite.ts';

function fixture(extra: Record<string, any> = {}): string {
  const root = mkdtempSync(join(tmpdir(), 'zntc-init-vite-'));
  writeFileSync(
    join(root, 'package.json'),
    JSON.stringify(
      {
        name: 'app',
        private: true,
        type: 'module',
        scripts: { dev: 'vite' },
        devDependencies: { vite: '^8.0.0' },
        ...extra,
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

describe('@zntc/init vite overlay', () => {
  test('adds devDeps and creates a new vite.config.ts when none exists', () => {
    const root = fixture();
    try {
      const result = initViteProject({ root, zntcVersion: '^0.1.0' });
      expect(result.changes.map((c) => c.action)).toEqual(['update', 'create']);

      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.devDependencies['@zntc/core']).toBe('^0.1.0');
      expect(pkg.devDependencies['@zntc/vite-plugin']).toBe('^0.1.0');

      const config = readFileSync(join(root, 'vite.config.ts'), 'utf8');
      expect(config).toBe(createViteConfig());
      expect(config).toContain("import { zntc } from '@zntc/vite-plugin'");
      expect(config).toContain('plugins: [zntc()]');
      expect(config).toContain('esbuild: false');
    } finally {
      cleanup(root);
    }
  });

  test('refuses to overwrite existing vite.config and surfaces manual instructions', () => {
    const root = fixture();
    try {
      const existing = "import { defineConfig } from 'vite';\nexport default defineConfig({});\n";
      writeFileSync(join(root, 'vite.config.ts'), existing);

      const result = initViteProject({ root });
      const configChange = result.changes.find((c) => c.path.endsWith('vite.config.ts'));
      expect(configChange?.action).toBe('manual');
      expect(configChange?.manualInstructions).toContain('@zntc/vite-plugin');
      expect(readFileSync(join(root, 'vite.config.ts'), 'utf8')).toBe(existing);
    } finally {
      cleanup(root);
    }
  });

  test('force overwrites existing vite.config', () => {
    const root = fixture();
    try {
      writeFileSync(join(root, 'vite.config.js'), 'export default {};\n');
      const result = initViteProject({ root, force: true });
      const configChange = result.changes.find((c) => c.path.endsWith('vite.config.js'));
      expect(configChange?.action).toBe('update');
      expect(readFileSync(join(root, 'vite.config.js'), 'utf8')).toBe(createViteConfig());
    } finally {
      cleanup(root);
    }
  });

  test('dry-run does not write files', () => {
    const root = fixture();
    try {
      const before = readFileSync(join(root, 'package.json'), 'utf8');
      const result = initViteProject({ root, dryRun: true });
      expect(result.dryRun).toBe(true);
      expect(readFileSync(join(root, 'package.json'), 'utf8')).toBe(before);
      expect(() => readFileSync(join(root, 'vite.config.ts'), 'utf8')).toThrow();
    } finally {
      cleanup(root);
    }
  });

  test('rejects projects without a vite dependency', () => {
    const root = mkdtempSync(join(tmpdir(), 'zntc-init-vite-'));
    try {
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'x' }) + '\n');
      expect(() => planViteInit({ root })).toThrow('vite dependency not found');
    } finally {
      cleanup(root);
    }
  });

  test('second run is stable when config was just generated', () => {
    const root = fixture();
    try {
      initViteProject({ root });
      const second = initViteProject({ root });
      expect(second.changes.every((c) => c.action === 'unchanged' || c.action === 'manual')).toBe(
        true,
      );
    } finally {
      cleanup(root);
    }
  });
});
