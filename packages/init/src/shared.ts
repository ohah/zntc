import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const PACKAGE_MANAGERS = ['bun', 'npm', 'pnpm', 'yarn'] as const;
export type PackageManager = (typeof PACKAGE_MANAGERS)[number];

export const PACKAGE_JSON = 'package.json';
export const ZNTC_CONFIG = 'zntc.config.ts';
export const DEFAULT_ZNTC_VERSION = 'latest';

export interface PlannedFile {
  path: string;
  before: string | null;
  after: string;
  changed: boolean;
  /** vite/rspack 처럼 이미 존재하는 사용자 config 파일을 함부로 덮지 않을 때 사용자에게 보여줄 패치 가이드. */
  manualInstructions?: string;
}

export type FileAction = 'create' | 'update' | 'unchanged' | 'manual';

export interface FileChange {
  path: string;
  action: FileAction;
  manualInstructions?: string;
}

export function readText(path: string): string | null {
  try {
    return readFileSync(path, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
    throw error;
  }
}

export function formatJson(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function parsePackageJson(raw: string): Record<string, any> {
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(
      `failed to parse ${PACKAGE_JSON}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

export function ensureObject(value: unknown): Record<string, any> {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, any>;
  }
  return {};
}

export function hasAnyDependency(pkg: Record<string, any>, names: readonly string[]): boolean {
  const deps = ensureObject(pkg.dependencies);
  const dev = ensureObject(pkg.devDependencies);
  const peer = ensureObject(pkg.peerDependencies);
  return names.some((name) => Boolean(deps[name] ?? dev[name] ?? peer[name]));
}

export function addDevDependency(
  pkg: Record<string, any>,
  name: string,
  version: string,
): Record<string, any> {
  const deps = ensureObject(pkg.dependencies);
  const dev = { ...ensureObject(pkg.devDependencies) };
  if (deps[name] || dev[name]) return pkg;
  dev[name] = version;
  return { ...pkg, devDependencies: dev };
}

export function toChange(file: PlannedFile): FileChange {
  if (file.manualInstructions && !file.changed) {
    return { path: file.path, action: 'manual', manualInstructions: file.manualInstructions };
  }
  if (!file.changed) return { path: file.path, action: 'unchanged' };
  return { path: file.path, action: file.before === null ? 'create' : 'update' };
}

export function detectPackageManager(root: string): PackageManager {
  if (existsSync(join(root, 'bun.lock')) || existsSync(join(root, 'bun.lockb'))) return 'bun';
  if (existsSync(join(root, 'pnpm-lock.yaml'))) return 'pnpm';
  if (existsSync(join(root, 'yarn.lock'))) return 'yarn';

  const rawPackageJson = readText(join(root, PACKAGE_JSON));
  if (rawPackageJson) {
    try {
      const packageManager = JSON.parse(rawPackageJson).packageManager;
      if (typeof packageManager === 'string') {
        for (const pm of PACKAGE_MANAGERS) {
          if (packageManager.startsWith(`${pm}@`)) return pm;
        }
      }
    } catch {}
  }

  return 'npm';
}

export function installCommand(pm: PackageManager): string {
  return `${pm} install`;
}

export interface ApplyPlanResult {
  root: string;
  changes: FileChange[];
  dryRun: boolean;
  installCommand: string;
}

export function applyPlan(opts: {
  root: string;
  planned: readonly PlannedFile[];
  dryRun: boolean;
  packageManager?: PackageManager;
}): ApplyPlanResult {
  if (!opts.dryRun) {
    for (const file of opts.planned) {
      if (!file.changed) continue;
      mkdirSync(dirname(file.path), { recursive: true });
      writeFileSync(file.path, file.after);
    }
  }
  const pm = opts.packageManager ?? detectPackageManager(opts.root);
  return {
    root: opts.root,
    changes: opts.planned.map(toChange),
    dryRun: opts.dryRun,
    installCommand: installCommand(pm),
  };
}

export function planOverlayConfig(opts: {
  root: string;
  candidates: readonly string[];
  defaultName: string;
  generate: () => string;
  manualInstructions: string;
  force: boolean;
}): PlannedFile {
  for (const name of opts.candidates) {
    const path = join(opts.root, name);
    const before = readText(path);
    if (before === null) continue;
    if (!opts.force) {
      return {
        path,
        before,
        after: before,
        changed: false,
        manualInstructions: opts.manualInstructions,
      };
    }
    const after = opts.generate();
    return { path, before, after, changed: before !== after };
  }
  const path = join(opts.root, opts.defaultName);
  return { path, before: null, after: opts.generate(), changed: true };
}
