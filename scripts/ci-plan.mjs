import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Keep these areas aligned with the suites that consume the plan in ci.yml.
// Directory matching includes the directory itself so submodule pin changes
// (vendor/* and tests/test262) have the same coverage as files below them.
const integrationDirectories = ['src', 'packages', 'tests', 'examples/web', 'build', 'vendor'];
const integrationFiles = new Set([
  'build.zig',
  'build.zig.zon',
  'package.json',
  'bun.lock',
  'bunfig.toml',
  'scripts/ci-install-deps.sh',
  '.gitmodules',
  '.github/workflows/integration.yml',
]);
const e2eDirectories = [
  'src/lexer',
  'src/parser',
  'src/semantic',
  'src/transformer',
  'src/codegen',
  'src/regexp',
  'src/transpile',
  'src/util',
  'src/cli',
  'src/bundler',
  'src/app',
  'src/server',
  'packages/core',
  'packages/shared',
  'packages/web',
  'packages/server',
  'build',
  'vendor',
  'tests',
  'examples/web',
];
const test262Directories = ['src', 'tests/test262', 'build', 'vendor'];
const test262Files = new Set([
  'build.zig',
  'build.zig.zon',
  '.gitmodules',
  '.github/workflows/test262.yml',
]);

// These compiler stages operate on source/AST data rather than host services.
// Keep ordinary compiler and JS fixture changes on the representative targets.
// Everything outside these known areas uses the full platform set: in particular
// build/vendor/toolchain files, NAPI and its loader/platform registry, native
// filesystem/thread/watch/TLS code, package metadata, and CI/release/smoke tools.
// A new source directory or package must be classified before it can opt out.
const portableCompilerDirectories = [
  'src/lexer',
  'src/parser',
  'src/semantic',
  'src/transformer',
  'src/codegen',
  'src/regexp',
];
const representativeDirectories = [
  ...portableCompilerDirectories,
  'src/fixtures',
  'tests',
  'examples',
  'packages/core/test',
  'packages/init',
  'packages/react-native',
  'packages/rspack-loader',
  'packages/server',
  'packages/shared',
  'packages/vite-plugin',
  'packages/wasm',
  'packages/web',
];
const representativeFiles = new Set(['packages/core/index.test.ts', 'packages/core/types.test.ts']);

// This matrix plus the separate artifact-consuming macOS arm64 smoke job
// retain one representative per OS/libc on ordinary PRs and main. Sensitive
// changes, weekly checks, and manual all runs also cover Linux arm64, Intel
// macOS, and Windows ia32. Release also cross-builds Windows arm64 on x64 and
// runs its installed addon/CLI smoke on a native ARM runner, covering all nine.
const smokePlatforms = [
  { platform: 'linux-x64-gnu', os: 'ubuntu-latest', zig_target: 'native', representative: true },
  {
    platform: 'linux-arm64-gnu',
    os: 'ubuntu-24.04-arm',
    zig_target: 'native',
    representative: false,
  },
  {
    platform: 'linux-x64-musl',
    os: 'ubuntu-latest',
    zig_target: 'x86_64-linux-musl',
    smoke_container: 'node:24-alpine',
    representative: true,
  },
  {
    platform: 'linux-arm64-musl',
    os: 'ubuntu-24.04-arm',
    zig_target: 'aarch64-linux-musl',
    smoke_container: 'node:24-alpine',
    representative: false,
  },
  { platform: 'darwin-x64', os: 'macos-15-intel', zig_target: 'native', representative: false },
  { platform: 'win32-x64-msvc', os: 'windows-latest', zig_target: 'native', representative: true },
  // Node 24 dropped win-x86. Keep Node 22/x86 for an actual 32-bit dlopen.
  {
    platform: 'win32-ia32-msvc',
    os: 'windows-latest',
    zig_target: 'x86-windows-msvc',
    node_version: '22',
    node_arch: 'x86',
    representative: false,
  },
];

function within(file, directory) {
  return file === directory || file.startsWith(`${directory}/`);
}

function inDirectories(file, directories) {
  return directories.some((directory) => within(file, directory));
}

function isDocumentation(file) {
  return (
    inDirectories(file, ['docs', 'documents', '.github/ISSUE_TEMPLATE']) ||
    /^[^/]+\.md$/i.test(file) ||
    file === '.github/pull_request_template.md' ||
    /^\.changeset\/[^/]+\.md$/i.test(file) ||
    // Limit package metadata exemptions to the package root. A README or any
    // other Markdown file inside tests/ or a package fixture remains an input.
    /^packages\/[^/]+\/(?:README(?:[._-][^/]*)?\.md|CHANGELOG\.md|LICEN[CS]E(?:\.(?:md|txt))?)$/i.test(
      file,
    )
  );
}

function isShared(file) {
  return (
    file === '.github/workflows/ci.yml' ||
    within(file, '.github/actions') ||
    /^scripts\/ci-[^/]+\.mjs$/.test(file)
  );
}

function isRootTsconfig(file) {
  return /^tsconfig[^/]*\.json$/.test(file);
}

function needsExtendedPlatforms(file) {
  if (file.endsWith('.zig')) return !inDirectories(file, portableCompilerDirectories);
  // Manifest/dependency changes can affect installed native packages even in
  // otherwise portable JS packages or examples. Do not exempt them by directory.
  if (
    /(?:^|\/)(?:package\.json|bun\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$/.test(file)
  ) {
    return true;
  }
  return !(inDirectories(file, representativeDirectories) || representativeFiles.has(file));
}

function validateFiles(files) {
  if (!Array.isArray(files)) {
    throw new TypeError('CI_CHANGED_FILES must be a JSON array of repository-relative paths');
  }
  for (const file of files) {
    if (
      typeof file !== 'string' ||
      file.length === 0 ||
      file.includes('\0') ||
      /^[A-Za-z]:[\\/]/.test(file) ||
      file.split('/').some((part) => part === '' || part === '.' || part === '..')
    ) {
      throw new TypeError('CI_CHANGED_FILES entries must be nonempty repository-relative paths');
    }
  }
}

export function createPlan({
  changedFiles,
  event,
  draft = false,
  suite = 'all',
  eventAction = '',
}) {
  validateFiles(changedFiles);
  if (!['push', 'pull_request', 'workflow_dispatch', 'schedule'].includes(event)) {
    throw new TypeError('CI_EVENT must be push, pull_request, workflow_dispatch, or schedule');
  }
  if (typeof draft !== 'boolean') {
    throw new TypeError('CI_DRAFT must be true or false');
  }
  if (!['all', 'integration', 'test262'].includes(suite)) {
    throw new TypeError('CI_SUITE must be all, integration, or test262');
  }
  if (typeof eventAction !== 'string') {
    throw new TypeError('CI_EVENT_ACTION must be a string');
  }

  const manual = event === 'workflow_dispatch';
  const scheduled = event === 'schedule';
  const files = changedFiles.filter((file) => !isDocumentation(file));
  const extendedPlatforms =
    scheduled || (manual ? suite === 'all' : files.some(needsExtendedPlatforms));
  const runIntegration = !(event === 'pull_request' && draft);
  let core;
  let integration;
  let e2e;
  let test262;

  if (manual || scheduled) {
    core = scheduled || suite === 'all';
    integration = scheduled || suite === 'all' || suite === 'integration';
    e2e = integration;
    test262 = scheduled || suite === 'all' || suite === 'test262';
  } else {
    // Keep the broad core fallback for new/unknown code, including ready_for_review:
    // the shared PR concurrency group can cancel the still-running draft checks.
    core = files.length > 0;
    integration =
      runIntegration &&
      files.some(
        (file) =>
          isShared(file) ||
          inDirectories(file, integrationDirectories) ||
          integrationFiles.has(file) ||
          isRootTsconfig(file),
      );
    e2e =
      integration &&
      files.some(
        (file) =>
          isShared(file) ||
          inDirectories(file, e2eDirectories) ||
          integrationFiles.has(file) ||
          isRootTsconfig(file) ||
          /^src\/[^/]+\.zig$/.test(file),
      );
    test262 = files.some(
      (file) => isShared(file) || inDirectories(file, test262Directories) || test262Files.has(file),
    );
  }

  // Manual Test262 still needs a Debug executable without scheduling macOS or
  // the rest of core CI. Consumers gate jobs on flags before using the matrices.
  const debugOS = core
    ? extendedPlatforms
      ? ['ubuntu-latest', 'macos-latest']
      : ['ubuntu-latest']
    : manual && test262
      ? ['ubuntu-latest']
      : [];
  return {
    core,
    integration,
    e2e,
    test262,
    extended_platforms: extendedPlatforms,
    debug_matrix: { include: debugOS.map((os) => ({ os })) },
    smoke_matrix: {
      include: smokePlatforms
        .filter((entry) => extendedPlatforms || entry.representative)
        .map(({ representative: _representative, ...entry }) => entry),
    },
  };
}

export function planFromEnvironment(env) {
  const rawFiles = env.CI_CHANGED_FILES;
  let changedFiles;
  if (
    (rawFiles === undefined || rawFiles === '') &&
    ['workflow_dispatch', 'schedule'].includes(env.CI_EVENT)
  ) {
    changedFiles = [];
  } else {
    try {
      changedFiles = JSON.parse(rawFiles);
    } catch {
      throw new TypeError('CI_CHANGED_FILES must contain a valid JSON array');
    }
  }
  const draft = env.CI_DRAFT || 'false';
  if (draft !== 'true' && draft !== 'false') {
    throw new TypeError('CI_DRAFT must be true or false');
  }
  return createPlan({
    changedFiles,
    event: env.CI_EVENT,
    draft: draft === 'true',
    suite: env.CI_SUITE || 'all',
    eventAction: env.CI_EVENT_ACTION || '',
  });
}

export function githubOutputs(plan) {
  return (
    Object.entries(plan)
      .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
      .join('\n') + '\n'
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    // Validate the complete input before writing anything. Invalid change data
    // must fail the checks job, never produce an apparently successful skip.
    const plan = planFromEnvironment(process.env);
    if (!process.env.GITHUB_OUTPUT) {
      throw new Error('GITHUB_OUTPUT is required');
    }
    appendFileSync(process.env.GITHUB_OUTPUT, githubOutputs(plan));
    console.log(JSON.stringify(plan, null, 2));
  } catch (error) {
    console.error(`CI plan failed: ${error.message}`);
    process.exitCode = 1;
  }
}
