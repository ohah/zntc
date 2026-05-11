import { describe, expect, test } from 'bun:test';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { initWebProject, planWebInit } from './web.ts';

function emptyDir(): string {
  return mkdtempSync(join(tmpdir(), 'zntc-init-web-'));
}

function cleanup(root: string): void {
  rmSync(root, { recursive: true, force: true });
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, 'utf8'));
}

describe('@zntc/init web scaffold', () => {
  test('scaffolds a React starter into an empty dir', () => {
    const root = emptyDir();
    try {
      const result = initWebProject({ root, zntcVersion: '^0.1.0' });
      expect(result.framework).toBe('react');
      expect(result.changes.every((c) => c.action === 'create')).toBe(true);

      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.scripts).toEqual({ dev: 'zntc dev', build: 'zntc build', preview: 'zntc preview' });
      expect(pkg.dependencies.react).toBeDefined();
      expect(pkg.dependencies['react-dom']).toBeDefined();
      expect(pkg.devDependencies['@zntc/core']).toBe('^0.1.0');
      expect(pkg.devDependencies['@types/react']).toBeDefined();

      expect(existsSync(join(root, 'tsconfig.json'))).toBe(true);
      expect(existsSync(join(root, 'index.html'))).toBe(true);
      expect(existsSync(join(root, 'src/main.tsx'))).toBe(true);
      expect(existsSync(join(root, 'src/App.tsx'))).toBe(true);

      const cfg = readFileSync(join(root, 'zntc.config.ts'), 'utf8');
      expect(cfg).toContain('entryPoints: ["src/main.tsx"]');
      expect(cfg).toContain('platform: "browser"');
      expect(cfg).toContain('jsx: "automatic"');
    } finally {
      cleanup(root);
    }
  });

  test('vanilla framework drops React deps and uses .ts entry', () => {
    const root = emptyDir();
    try {
      const result = initWebProject({ root, framework: 'vanilla' });
      expect(result.framework).toBe('vanilla');
      const pkg = readJson(join(root, 'package.json'));
      expect(pkg.dependencies).toBeUndefined();
      expect(pkg.devDependencies['@types/react']).toBeUndefined();
      expect(existsSync(join(root, 'src/main.ts'))).toBe(true);
      expect(existsSync(join(root, 'src/App.tsx'))).toBe(false);

      const cfg = readFileSync(join(root, 'zntc.config.ts'), 'utf8');
      expect(cfg).toContain('entryPoints: ["src/main.ts"]');
      expect(cfg).not.toContain('jsx:');
    } finally {
      cleanup(root);
    }
  });

  test('--name overrides package.json name (default is directory name)', () => {
    const root = emptyDir();
    try {
      initWebProject({ root, name: 'my-app' });
      expect(readJson(join(root, 'package.json')).name).toBe('my-app');
    } finally {
      cleanup(root);
    }
  });

  test('refuses to scaffold when package.json already exists (without --force)', () => {
    const root = emptyDir();
    try {
      writeFileSync(join(root, 'package.json'), '{"name":"existing"}\n');
      expect(() => planWebInit({ root })).toThrow('package.json already exists');
    } finally {
      cleanup(root);
    }
  });

  test('--force overwrites existing files', () => {
    const root = emptyDir();
    try {
      writeFileSync(join(root, 'package.json'), '{"name":"old"}\n');
      const result = initWebProject({ root, name: 'fresh', force: true });
      const pkgChange = result.changes.find((c) => c.path.endsWith('package.json'));
      expect(pkgChange?.action).toBe('update');
      expect(readJson(join(root, 'package.json')).name).toBe('fresh');
    } finally {
      cleanup(root);
    }
  });

  test('dry-run does not write files', () => {
    const root = emptyDir();
    try {
      const result = initWebProject({ root, dryRun: true });
      expect(result.dryRun).toBe(true);
      expect(result.changes.length).toBeGreaterThan(0);
      expect(existsSync(join(root, 'package.json'))).toBe(false);
      expect(existsSync(join(root, 'src/main.tsx'))).toBe(false);
    } finally {
      cleanup(root);
    }
  });

  test('rejects unknown framework via planWebInit', () => {
    const root = emptyDir();
    try {
      expect(() => planWebInit({ root, framework: 'svelte' as any })).toThrow('unsupported framework');
    } finally {
      cleanup(root);
    }
  });
});
