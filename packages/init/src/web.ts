import { basename, join, resolve } from 'node:path';

import {
  DEFAULT_ZNTC_VERSION,
  PACKAGE_JSON,
  applyPlan,
  formatJson,
  readText,
  type ApplyPlanResult,
  type FileChange,
  type PackageManager,
  type PlannedFile,
} from './shared.ts';

export type WebFramework = 'react' | 'vanilla';

export const WEB_FRAMEWORKS: readonly WebFramework[] = ['react', 'vanilla'];

export interface InitWebOptions {
  root?: string;
  name?: string;
  framework?: WebFramework;
  dryRun?: boolean;
  force?: boolean;
  packageManager?: PackageManager;
  zntcVersion?: string;
}

export interface InitWebResult {
  root: string;
  changes: FileChange[];
  dryRun: boolean;
  installCommand: string;
  framework: WebFramework;
}

const REACT_DEPS = {
  react: '^19.0.0',
  'react-dom': '^19.0.0',
};

const REACT_DEV_DEPS = {
  '@types/react': '^19.0.0',
  '@types/react-dom': '^19.0.0',
  typescript: '^5.6.0',
};

const VANILLA_DEV_DEPS = {
  typescript: '^5.6.0',
};

function entryFile(framework: WebFramework): string {
  return framework === 'react' ? 'src/main.tsx' : 'src/main.ts';
}

function projectName(root: string, name?: string): string {
  return name ?? basename(root);
}

function createPackageJson(
  root: string,
  framework: WebFramework,
  options: { name?: string; zntcVersion: string },
): string {
  const pkg: Record<string, any> = {
    name: projectName(root, options.name),
    version: '0.0.0',
    private: true,
    type: 'module',
    scripts: {
      dev: 'zntc dev',
      build: 'zntc build',
      preview: 'zntc preview',
    },
    devDependencies: {
      '@zntc/core': options.zntcVersion,
    },
  };
  if (framework === 'react') {
    pkg.dependencies = { ...REACT_DEPS };
    pkg.devDependencies = { ...pkg.devDependencies, ...REACT_DEV_DEPS };
  } else {
    pkg.devDependencies = { ...pkg.devDependencies, ...VANILLA_DEV_DEPS };
  }
  return formatJson(pkg);
}

function createTsconfig(framework: WebFramework): string {
  const compilerOptions: Record<string, any> = {
    target: 'ES2022',
    module: 'ESNext',
    moduleResolution: 'Bundler',
    lib: ['ES2022', 'DOM', 'DOM.Iterable'],
    strict: true,
    skipLibCheck: true,
    noEmit: true,
    isolatedModules: true,
    esModuleInterop: true,
    resolveJsonModule: true,
    allowSyntheticDefaultImports: true,
  };
  if (framework === 'react') compilerOptions.jsx = 'react-jsx';
  return formatJson({
    compilerOptions,
    include: ['src/**/*', 'zntc.config.ts'],
  });
}

function createZntcConfig(framework: WebFramework): string {
  const entry = entryFile(framework);
  const compilerLine =
    framework === 'react'
      ? `\n  // React 17+ automatic JSX runtime — @zntc/core 가 _jsx import 자동 삽입.`
      : '';
  return `import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["${entry}"],
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",${framework === 'react' ? '\n  jsx: "automatic",' : ''}
  sourcemap: true,${compilerLine}
});
`;
}

function createIndexHtml(framework: WebFramework, name: string): string {
  const entry = `/${entryFile(framework)}`;
  const body = framework === 'react' ? '    <div id="root"></div>\n' : '    <div id="app"></div>\n';
  return `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${name}</title>
  </head>
  <body>
${body}    <script type="module" src="${entry}"></script>
  </body>
</html>
`;
}

function createReactEntry(): string {
  return `import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./App";

const root = document.getElementById("root");
if (!root) throw new Error("#root not found");

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
`;
}

function createReactApp(): string {
  return `export function App() {
  return (
    <main>
      <h1>ZNTC + React</h1>
      <p>
        Edit <code>src/App.tsx</code> and save — HMR will reflect changes instantly.
      </p>
    </main>
  );
}
`;
}

function createVanillaEntry(): string {
  return `const app = document.getElementById("app");
if (!app) throw new Error("#app not found");

app.innerHTML = \`
  <main>
    <h1>ZNTC web starter</h1>
    <p>Edit <code>src/main.ts</code> and save — HMR will reflect changes instantly.</p>
  </main>
\`;
`;
}

interface ScaffoldFile {
  relPath: string;
  content: string;
}

function scaffoldFiles(
  root: string,
  framework: WebFramework,
  zntcVersion: string,
  name?: string,
): ScaffoldFile[] {
  const files: ScaffoldFile[] = [
    { relPath: PACKAGE_JSON, content: createPackageJson(root, framework, { name, zntcVersion }) },
    { relPath: 'tsconfig.json', content: createTsconfig(framework) },
    { relPath: 'zntc.config.ts', content: createZntcConfig(framework) },
    { relPath: 'index.html', content: createIndexHtml(framework, projectName(root, name)) },
  ];
  if (framework === 'react') {
    files.push({ relPath: 'src/main.tsx', content: createReactEntry() });
    files.push({ relPath: 'src/App.tsx', content: createReactApp() });
  } else {
    files.push({ relPath: 'src/main.ts', content: createVanillaEntry() });
  }
  return files;
}

function planScaffoldFile(root: string, file: ScaffoldFile, force: boolean): PlannedFile {
  const path = join(root, file.relPath);
  const before = readText(path);
  if (before === null) return { path, before, after: file.content, changed: true };
  if (force && before !== file.content) {
    return { path, before, after: file.content, changed: true };
  }
  return { path, before, after: before, changed: false };
}

export function planWebInit(options: InitWebOptions = {}): {
  files: PlannedFile[];
  framework: WebFramework;
} {
  const root = resolve(options.root ?? process.cwd());
  const framework = options.framework ?? 'react';
  if (!WEB_FRAMEWORKS.includes(framework)) {
    throw new Error(`unsupported framework: ${framework}`);
  }
  const force = options.force ?? false;
  const zntcVersion = options.zntcVersion ?? DEFAULT_ZNTC_VERSION;
  const files = scaffoldFiles(root, framework, zntcVersion, options.name);

  const existingPkg = readText(join(root, PACKAGE_JSON));
  if (existingPkg !== null && !force) {
    throw new Error(
      `package.json already exists in ${root}; re-run with --force to overwrite (this is a scaffold mode)`,
    );
  }

  return { files: files.map((f) => planScaffoldFile(root, f, force)), framework };
}

export function initWebProject(options: InitWebOptions = {}): InitWebResult {
  const root = resolve(options.root ?? process.cwd());
  const { files: planned, framework } = planWebInit({ ...options, root });
  const applied: ApplyPlanResult = applyPlan({
    root,
    planned,
    dryRun: options.dryRun ?? false,
    packageManager: options.packageManager,
  });
  return { ...applied, framework };
}
