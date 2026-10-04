import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createPlan, githubOutputs, planFromEnvironment } from './ci-plan.mjs';

function flags(plan) {
  return [plan.core, plan.integration, plan.e2e, plan.test262];
}

const all = [true, true, true, true];
const application = [true, true, true, false];
const integrationOnly = [true, true, false, false];
const coreOnly = [true, false, false, false];
const none = [false, false, false, false];

// Expectations are coverage decisions, independent of the path matching code.
// Use both event types so PR/main filters cannot silently drift apart.
const pathCases = [
  ['lexer source', ['src/lexer/scanner.zig'], all],
  ['parser source', ['src/parser/expr.zig'], all],
  ['semantic source', ['src/semantic/analyzer.zig'], all],
  ['transformer source', ['src/transformer/es2020.zig'], all],
  ['code generator', ['src/codegen/emitter.zig'], all],
  ['regexp source', ['src/regexp/parser.zig'], all],
  ['transpile source', ['src/transpile/entry.zig'], all],
  ['utility source', ['src/util/path.zig'], all],
  ['CLI source', ['src/cli/main.zig'], all],
  ['bundler source', ['src/bundler/bundler.zig'], all],
  ['app source', ['src/app/server.zig'], all],
  ['server source', ['src/server/http.zig'], all],
  ['root Zig source', ['src/lib.zig'], all],
  ['Test262 runner without browser E2E', ['src/test262/runner.zig'], [true, true, false, true]],
  ['new source area still gets conformance', ['src/new-area/file.zig'], [true, true, false, true]],
  ['core package', ['packages/core/index.ts'], application],
  ['web package', ['packages/web/src/index.ts'], application],
  ['server package', ['packages/server/src/index.ts'], application],
  ['shared package', ['packages/shared/config.ts'], application],
  ['React Native package', ['packages/react-native/index.ts'], integrationOnly],
  ['Vite adapter', ['packages/vite-plugin/index.ts'], integrationOnly],
  ['Rspack adapter', ['packages/rspack-loader/index.ts'], integrationOnly],
  ['Wasm package', ['packages/wasm/index.ts'], integrationOnly],
  ['init package', ['packages/init/index.ts'], integrationOnly],
  [
    'native package metadata affects packaging',
    ['packages/core-linux-x64-gnu/package.json'],
    integrationOnly,
  ],
  ['integration tests', ['tests/integration/parser.test.ts'], application],
  ['benchmark fixture', ['tests/benchmark/fixtures/small.ts'], application],
  ['Markdown test fixture is code input', ['tests/integration/fixtures/template.md'], application],
  ['test README remains a fixture input', ['tests/fixtures/README.md'], application],
  [
    'package nested README remains a fixture input',
    ['packages/core/test/fixtures/README.md'],
    application,
  ],
  ['Test262 submodule pin', ['tests/test262'], all],
  ['Test262 corpus', ['tests/test262/test/language/comments/hashbang.js'], all],
  ['Test262 Markdown stays covered', ['tests/test262/README.md'], all],
  ['build configuration', ['build.zig'], all],
  ['Zig dependency lock', ['build.zig.zon'], all],
  ['build helper', ['build/napi.zig'], all],
  ['vendor submodule pin', ['vendor/mimalloc'], all],
  ['vendor source', ['vendor/boringssl/ssl/ssl_lib.cc'], all],
  ['submodule configuration', ['.gitmodules'], all],
  ['root package manifest', ['package.json'], application],
  ['Bun lock', ['bun.lock'], application],
  ['Bun configuration', ['bunfig.toml'], application],
  ['root TypeScript configuration', ['tsconfig.base.json'], application],
  ['dependency installer', ['scripts/ci-install-deps.sh'], application],
  ['web example', ['examples/web/src/App.tsx'], application],
  ['other example preserves broad core fallback', ['examples/new-app/main.ts'], coreOnly],
  ['combined CI workflow', ['.github/workflows/ci.yml'], all],
  ['shared action', ['.github/actions/setup-zig/action.yml'], all],
  ['planner implementation', ['scripts/ci-plan.mjs'], all],
  ['planner tests', ['scripts/ci-plan.test.mjs'], all],
  ['shared native verifier', ['scripts/ci-verify-native.mjs'], all],
  ['future CI module', ['scripts/ci-new-helper.mjs'], all],
  [
    'legacy integration workflow including deletion',
    ['.github/workflows/integration.yml'],
    application,
  ],
  [
    'legacy Test262 workflow including deletion',
    ['.github/workflows/test262.yml'],
    [true, false, false, true],
  ],
  ['unrelated workflow', ['.github/workflows/release.yml'], coreOnly],
  ['other script', ['scripts/generate-unicode.py'], coreOnly],
  ['unknown new directory fails toward core coverage', ['future-component/entry.rs'], coreOnly],
  [
    'deleted source needs no file on disk',
    ['src/parser/deleted-file-that-does-not-exist.zig'],
    all,
  ],
  ['documentation directory', ['docs/TESTING.md'], none],
  ['documentation site', ['documents/src/components/Example.tsx'], none],
  ['root Markdown', ['README.md'], none],
  ['issue template', ['.github/ISSUE_TEMPLATE/bug.yml'], none],
  ['PR template', ['.github/pull_request_template.md'], none],
  ['package README', ['packages/core/README.md'], none],
  ['translated package README', ['packages/core/README_KO.md'], none],
  ['package changelog', ['packages/wasm/CHANGELOG.md'], none],
  ['package license', ['packages/core-linux-x64-gnu/LICENSE'], none],
  ['package license text', ['packages/core/LICENSE.txt'], none],
  ['license-named source is not metadata', ['packages/core/LICENSE.ts'], application],
  ['README-named source is not metadata', ['packages/web/README.ts'], application],
  ['release note', ['.changeset/calm-panda.md'], none],
  ['changeset configuration', ['.changeset/config.json'], coreOnly],
  ['unknown nested Markdown is not silently excluded', ['new-area/fixture.md'], coreOnly],
  ['mixed metadata and code', ['packages/core/README.md', 'src/parser/index.zig'], all],
  ['empty change list', [], none],
];

for (const event of ['pull_request', 'push']) {
  for (const [name, changedFiles, expected] of pathCases) {
    test(`${event}: ${name}`, () => {
      assert.deepEqual(flags(createPlan({ changedFiles, event })), expected);
    });
  }
}

// These cases describe the host/packaging boundary, not just current file names.
// Missing/deleted paths must make the same decision without reading the checkout.
const platformCases = [
  ['lexer source', 'src/lexer/scanner.zig', false],
  ['parser source', 'src/parser/expr.zig', false],
  ['parser AST layout', 'src/parser/ast.zig', false],
  ['semantic source', 'src/semantic/analyzer.zig', false],
  ['transformer source', 'src/transformer/es2020.zig', false],
  ['code generator', 'src/codegen/unified_mangler.zig', false],
  ['regexp source', 'src/regexp/parser.zig', false],
  ['compiler directory itself', 'src/parser', false],
  ['deleted portable source', 'src/parser/deleted.zig', false],
  ['compiler fixture', 'src/fixtures/es2020.js', false],
  ['integration regression', 'tests/integration/tests/namespace-shadow-provenance.test.ts', false],
  ['Test262 pin', 'tests/test262', false],
  ['Test262 case', 'tests/test262/test/language/comments/hashbang.js', false],
  ['core API test', 'packages/core/index.test.ts', false],
  ['core typing test', 'packages/core/types.test.ts', false],
  ['core regression fixture', 'packages/core/test/core/browserslist-transpile.ts', false],
  ['web application', 'packages/web/index.ts', false],
  ['server application', 'packages/server/index.ts', false],
  ['shared JS utilities', 'packages/shared/index.ts', false],
  ['React Native JS adapter', 'packages/react-native/index.ts', false],
  ['Vite adapter', 'packages/vite-plugin/index.ts', false],
  ['Rspack adapter', 'packages/rspack-loader/index.ts', false],
  ['project initializer', 'packages/init/index.ts', false],
  ['WASM JS wrapper', 'packages/wasm/index.ts', false],
  ['example app', 'examples/web/src/App.tsx', false],
  ['root README', 'README.md', false],
  ['package README', 'packages/core/README.md', false],
  ['native package README', 'packages/core-darwin-x64/README.md', false],
  ['native package license', 'packages/core-darwin-x64/LICENSE', false],
  ['documentation', 'docs/TESTING.md', false],
  ['native addon entry', 'packages/core/src/napi_entry.zig', true],
  ['native addon implementation', 'packages/core/src/napi/build_sync_entry.zig', true],
  ['native addon test', 'packages/core/napi.test.mjs', true],
  ['native loader', 'packages/core/index.ts', true],
  ['platform registry', 'packages/core/src/platforms.ts', true],
  ['JS CLI host entry', 'packages/core/bin/zntc.mjs', true],
  ['native package metadata', 'packages/core-darwin-x64/package.json', true],
  ['native package directory', 'packages/core-linux-arm64-musl', true],
  ['native allocator', 'src/mimalloc.zig', true],
  ['host entry point', 'src/main.zig', true],
  ['native filesystem', 'src/bundler/fs.zig', true],
  ['native channel', 'src/bundler/mpsc_channel.zig', true],
  ['file watcher', 'src/server/file_watcher.zig', true],
  ['TLS', 'src/server/tls.zig', true],
  ['native CLI', 'src/cli/standalone.zig', true],
  ['native app builder', 'src/app/build.zig', true],
  ['native utility', 'src/util/spin_lock.zig', true],
  ['host transpile options', 'src/transpile/options.zig', true],
  ['Zig build', 'build.zig', true],
  ['Zig dependency lock', 'build.zig.zon', true],
  ['build helper', 'build/boringssl.zig', true],
  ['vendor pin', 'vendor/mimalloc', true],
  ['vendor headers', 'vendor/node-api-headers/include/node_api.h', true],
  ['submodule configuration', '.gitmodules', true],
  ['toolchain versions', '.mise.toml', true],
  ['root manifest', 'package.json', true],
  ['root dependency lock', 'bun.lock', true],
  ['Bun configuration', 'bunfig.toml', true],
  ['core TypeScript configuration', 'packages/core/tsconfig.json', true],
  ['portable package manifest', 'packages/web/package.json', true],
  ['example dependency lock', 'examples/web/package-lock.json', true],
  ['fixture dependency lock', 'tests/integration/fixtures/new-app/pnpm-lock.yaml', true],
  ['fixture Bun dependency lock', 'tests/integration/fixtures/new-app/bun.lock', true],
  ['fixture Yarn dependency lock', 'tests/integration/fixtures/new-app/yarn.lock', true],
  ['Zig outside known compiler stages', 'packages/wasm/src/main.zig', true],
  ['CI workflow', '.github/workflows/ci.yml', true],
  ['release workflow', '.github/workflows/release.yml', true],
  ['build dependency action', '.github/actions/checkout-build-deps/action.yml', true],
  ['package smoke action', '.github/actions/napi-package-smoke/action.yml', true],
  ['planner', 'scripts/ci-plan.mjs', true],
  ['dependency installer', 'scripts/ci-install-deps.sh', true],
  ['native verification', 'scripts/ci-verify-native.mjs', true],
  ['package installation smoke', 'scripts/publish-install-test.ts', true],
  ['release tool', 'scripts/release.ts', true],
  ['new source area', 'src/new-area/file.zig', true],
  ['new native source beside parser', 'src/parser-native/binding.zig', true],
  ['unknown package', 'packages/new-package/index.ts', true],
  ['unknown build tool', 'scripts/new-native-builder.py', true],
  ['unknown configuration', 'new-toolchain.toml', true],
  ['unknown directory', 'future-component/entry.rs', true],
];

for (const event of ['pull_request', 'push']) {
  for (const [name, file, expected] of platformCases) {
    test(`${event} platform selection: ${name}`, () => {
      const plan = createPlan({ changedFiles: [file], event });
      assert.equal(plan.extended_platforms, expected);
      assert.equal(plan.smoke_matrix.include.length, expected ? 7 : 3);
      assert.deepEqual(
        plan.debug_matrix.include,
        plan.core
          ? expected
            ? [{ os: 'ubuntu-latest' }, { os: 'macos-latest' }]
            : [{ os: 'ubuntu-latest' }]
          : [],
      );
    });
  }
}

const portableBundlerFiles = [
  'src/bundler/tree_shaker/cjs_patterns.zig',
  'src/bundler/tree_shaker/module_effects.zig',
  'src/bundler/tree_shaker/import_records.zig',
  'src/bundler/tree_shaker/const_materialize.zig',
  'src/bundler/tree_shaker/re_export_namespace.zig',
  'src/bundler/graph/cycles.zig',
  'src/bundler/graph/import_usage.zig',
];
const extendedBundlerFiles = [
  'src/bundler/graph',
  'src/bundler/tree_shaker',
  'src/bundler/graph.zig',
  'src/bundler/tree_shaker.zig',
  'src/bundler/graph/diagnostics.zig',
  'src/bundler/graph/requested_exports.zig',
  'src/bundler/graph/transform_prepass.zig',
  'src/bundler/graph/loaders.zig',
  'src/bundler/graph/resolve_imports.zig',
  'src/bundler/graph/project_root.zig',
  'src/bundler/resolver.zig',
  'src/bundler/fs.zig',
  'src/bundler/mpsc_channel.zig',
  'src/bundler/graph/new_analysis.zig',
  'src/bundler/tree_shaker/new_analysis.zig',
  // Names alone do not confer portability; the owning directory matters.
  'src/bundler/graph/module_effects.zig',
  'src/bundler/tree_shaker/cycles.zig',
];

for (const event of ['pull_request', 'push']) {
  for (const file of portableBundlerFiles) {
    test(`${event}: reviewed bundler helper ${file} retains every suite on representative targets`, () => {
      const plan = createPlan({ changedFiles: [file], event });
      assert.deepEqual(flags(plan), all);
      assert.equal(plan.extended_platforms, false);
      assert.deepEqual(plan.debug_matrix.include, [{ os: 'ubuntu-latest' }]);
      assert.deepEqual(
        plan.smoke_matrix.include.map((row) => row.platform),
        ['linux-x64-gnu', 'linux-x64-musl', 'win32-x64-msvc'],
      );
      for (const nearMiss of [
        `${file}.extra.zig`,
        `${file}/native.zig`,
        file.replace('.zig', '.ZIG'),
        file.replace('/bundler/', '/bundler/new-area/'),
      ]) {
        assert.equal(
          createPlan({ changedFiles: [nearMiss], event }).extended_platforms,
          true,
          nearMiss,
        );
      }
    });
  }
  for (const file of extendedBundlerFiles) {
    test(`${event}: unreviewed or host-dependent bundler path ${file} remains extended`, () => {
      const plan = createPlan({ changedFiles: [file], event });
      assert.deepEqual(flags(plan), all);
      assert.equal(plan.extended_platforms, true);
      assert.equal(plan.smoke_matrix.include.length, 7);
      assert.deepEqual(plan.debug_matrix.include, [
        { os: 'ubuntu-latest' },
        { os: 'macos-latest' },
      ]);
    });
  }
  test(`${event}: a sensitive change extends a mixed portable bundler change in either order`, () => {
    for (const sensitive of [...extendedBundlerFiles, 'build.zig', 'packages/core/index.ts']) {
      for (const changedFiles of [
        [...portableBundlerFiles, sensitive],
        [sensitive, ...portableBundlerFiles],
      ]) {
        const plan = createPlan({ changedFiles, event });
        assert.deepEqual(flags(plan), all);
        assert.equal(plan.extended_platforms, true, sensitive);
      }
    }
    const portableOnly = createPlan({
      changedFiles: [...portableBundlerFiles, 'README.md'],
      event,
    });
    assert.deepEqual(flags(portableOnly), all);
    assert.equal(portableOnly.extended_platforms, false);
  });
}

test('reviewed bundler paths preserve draft/ready, manual subset, and scheduled coverage', () => {
  for (const file of portableBundlerFiles) {
    const draft = createPlan({ changedFiles: [file], event: 'pull_request', draft: true });
    assert.deepEqual(flags(draft), [true, false, false, true]);
    assert.equal(draft.extended_platforms, false);
    const ready = createPlan({
      changedFiles: [file],
      event: 'pull_request',
      eventAction: 'ready_for_review',
    });
    assert.deepEqual(flags(ready), all);
    assert.equal(ready.extended_platforms, false);
    for (const suite of ['all', 'integration', 'test262']) {
      assert.deepEqual(
        createPlan({ changedFiles: [file], event: 'workflow_dispatch', suite }),
        createPlan({ changedFiles: [], event: 'workflow_dispatch', suite }),
      );
    }
    const scheduled = createPlan({ changedFiles: [file], event: 'schedule' });
    assert.deepEqual(flags(scheduled), all);
    assert.equal(scheduled.extended_platforms, true);
    assert.equal(scheduled.smoke_matrix.include.length, 7);
    assert.deepEqual(scheduled.debug_matrix.include, [
      { os: 'ubuntu-latest' },
      { os: 'macos-latest' },
    ]);
  }
});

test('sensitive paths extend mixed changes while documentation does not', () => {
  const base = { event: 'pull_request', changedFiles: ['src/parser/expr.zig', 'README.md'] };
  assert.equal(createPlan(base).extended_platforms, false);
  const mixed = createPlan({ ...base, changedFiles: [...base.changedFiles, 'build.zig'] });
  assert.equal(mixed.extended_platforms, true);
  assert.deepEqual(flags(mixed), all);
});

test('empty and documentation-only changes do not enable extended platform work', () => {
  for (const event of ['pull_request', 'push']) {
    for (const changedFiles of [[], ['docs/TESTING.md', 'packages/core/README.md']]) {
      const plan = createPlan({ changedFiles, event });
      assert.deepEqual(flags(plan), none);
      assert.equal(plan.extended_platforms, false);
      assert.deepEqual(plan.debug_matrix, { include: [] });
    }
  }
});

test('draft PR retains core and Test262, suppressing all integration consumers', () => {
  const plan = createPlan({
    changedFiles: ['src/parser/expr.zig'],
    event: 'pull_request',
    draft: true,
  });
  assert.deepEqual(flags(plan), [true, false, false, true]);
  assert.deepEqual(plan.debug_matrix, {
    include: [{ os: 'ubuntu-latest' }],
  });
  assert.equal(plan.extended_platforms, false);
});

test('native-sensitive draft PR retains extended core checks without integration consumers', () => {
  const plan = createPlan({ changedFiles: ['build.zig'], event: 'pull_request', draft: true });
  assert.deepEqual(flags(plan), [true, false, false, true]);
  assert.equal(plan.extended_platforms, true);
  assert.deepEqual(plan.debug_matrix.include, [{ os: 'ubuntu-latest' }, { os: 'macos-latest' }]);
  assert.equal(plan.smoke_matrix.include.length, 7);
});

test('push is not suppressed by a draft flag', () => {
  assert.deepEqual(
    flags(createPlan({ changedFiles: ['src/lib.zig'], event: 'push', draft: true })),
    all,
  );
});

for (const eventAction of ['opened', 'synchronize', 'reopened', '']) {
  test(`ordinary PR action ${eventAction || '(unspecified)'} retains all matching suites`, () => {
    assert.deepEqual(
      flags(createPlan({ changedFiles: ['src/lib.zig'], event: 'pull_request', eventAction })),
      all,
    );
  });
}

test('ready_for_review retains core/Test262 when PR concurrency cancels the draft run', () => {
  const changedFiles = ['src/lib.zig'];
  const draft = createPlan({ changedFiles, event: 'pull_request', draft: true });
  assert.deepEqual(flags(draft), [true, false, false, true]);
  const ready = createPlan({
    changedFiles,
    event: 'pull_request',
    eventAction: 'ready_for_review',
  });
  assert.deepEqual(flags(ready), all);
  assert.deepEqual(ready.debug_matrix, {
    include: [{ os: 'ubuntu-latest' }, { os: 'macos-latest' }],
  });
});

test('ready_for_review still respects E2E path targeting', () => {
  const plan = createPlan({
    changedFiles: ['packages/react-native/index.ts'],
    event: 'pull_request',
    eventAction: 'ready_for_review',
  });
  assert.deepEqual(flags(plan), integrationOnly);
});

test('metadata-only draft and ready transitions schedule no heavy suites', () => {
  for (const options of [{ draft: true }, { eventAction: 'ready_for_review' }]) {
    const plan = createPlan({
      changedFiles: ['packages/core/README.md'],
      event: 'pull_request',
      ...options,
    });
    assert.deepEqual(flags(plan), none);
    assert.deepEqual(plan.debug_matrix, { include: [] });
  }
});

for (const [suite, expected, systems] of [
  ['all', all, ['ubuntu-latest', 'macos-latest']],
  ['integration', [false, true, true, false], []],
  ['test262', [false, false, false, true], ['ubuntu-latest']],
]) {
  test(`manual ${suite} is explicit even without changed paths`, () => {
    const plan = createPlan({ changedFiles: [], event: 'workflow_dispatch', suite });
    assert.deepEqual(flags(plan), expected);
    assert.deepEqual(plan.debug_matrix, { include: systems.map((os) => ({ os })) });
    assert.equal(plan.extended_platforms, suite === 'all');
    assert.equal(plan.smoke_matrix.include.length, suite === 'all' ? 7 : 3);
  });
}

test('manual subsets do not expand from supplied sensitive paths', () => {
  for (const suite of ['integration', 'test262']) {
    assert.deepEqual(
      createPlan({ changedFiles: ['build.zig'], event: 'workflow_dispatch', suite }),
      createPlan({ changedFiles: [], event: 'workflow_dispatch', suite }),
    );
  }
});

test('scheduled runs always cover every suite and extended platforms', () => {
  for (const suite of ['all', 'integration', 'test262']) {
    for (const changedFiles of [[], ['README.md'], ['src/parser/expr.zig'], ['build.zig']]) {
      const plan = createPlan({ changedFiles, event: 'schedule', draft: true, suite });
      assert.deepEqual(flags(plan), all);
      assert.equal(plan.extended_platforms, true);
      assert.equal(plan.smoke_matrix.include.length, 7);
      assert.deepEqual(plan.debug_matrix.include, [
        { os: 'ubuntu-latest' },
        { os: 'macos-latest' },
      ]);
    }
  }
});

test('scheduled environment accepts missing or empty change data without suppressing coverage', () => {
  for (const rawFiles of [undefined, '', '[]']) {
    const plan = planFromEnvironment({ CI_EVENT: 'schedule', CI_CHANGED_FILES: rawFiles });
    assert.deepEqual(flags(plan), all);
    assert.equal(plan.extended_platforms, true);
  }
});

test('suite input cannot narrow an ordinary push or PR', () => {
  for (const event of ['push', 'pull_request']) {
    const plan = createPlan({ changedFiles: ['src/lib.zig'], event, suite: 'test262' });
    assert.deepEqual(flags(plan), all);
  }
});

test('ordinary PR/main share three ABI targets alongside the shared macOS arm64 job', () => {
  const plan = createPlan({ changedFiles: ['src/parser/expr.zig'], event: 'pull_request' });
  assert.deepEqual(plan.smoke_matrix, {
    include: [
      { platform: 'linux-x64-gnu', os: 'ubuntu-latest', zig_target: 'native' },
      {
        platform: 'linux-x64-musl',
        os: 'ubuntu-latest',
        zig_target: 'x86_64-linux-musl',
        smoke_container: 'node:24-alpine',
      },
      { platform: 'win32-x64-msvc', os: 'windows-latest', zig_target: 'native' },
    ],
  });
  assert.deepEqual(createPlan({ changedFiles: ['src/parser/expr.zig'], event: 'push' }), plan);
});

test('extended smoke matrix adds arm64 Linux ABIs, Intel macOS, and Windows ia32', () => {
  const plan = createPlan({ changedFiles: ['build.zig'], event: 'push' });
  assert.equal(plan.smoke_matrix.include.length, 7);
  assert.deepEqual(
    plan.smoke_matrix.include.filter((entry) =>
      ['linux-arm64-gnu', 'linux-arm64-musl', 'darwin-x64', 'win32-ia32-msvc'].includes(
        entry.platform,
      ),
    ),
    [
      { platform: 'linux-arm64-gnu', os: 'ubuntu-24.04-arm', zig_target: 'native' },
      {
        platform: 'linux-arm64-musl',
        os: 'ubuntu-24.04-arm',
        zig_target: 'aarch64-linux-musl',
        smoke_container: 'node:24-alpine',
      },
      { platform: 'darwin-x64', os: 'macos-15-intel', zig_target: 'native' },
      {
        platform: 'win32-ia32-msvc',
        os: 'windows-latest',
        zig_target: 'x86-windows-msvc',
        node_version: '22',
        node_arch: 'x86',
      },
    ],
  );
  assert.ok(plan.smoke_matrix.include.every((entry) => !('representative' in entry)));
  assert.deepEqual(createPlan({ changedFiles: ['build.zig'], event: 'pull_request' }), plan);
});

test('plans do not share mutable matrix entries', () => {
  const first = createPlan({ changedFiles: ['src/lib.zig'], event: 'push' });
  first.smoke_matrix.include[0].os = 'changed';
  first.debug_matrix.include.length = 0;
  const next = createPlan({ changedFiles: ['src/lib.zig'], event: 'push' });
  assert.equal(next.smoke_matrix.include[0].os, 'ubuntu-latest');
  assert.equal(next.debug_matrix.include.length, 2);
});

test('environment defaults match push and manual workflow inputs', () => {
  assert.deepEqual(
    flags(
      planFromEnvironment({
        CI_EVENT: 'push',
        CI_CHANGED_FILES: '["src/lib.zig"]',
        CI_DRAFT: '',
        CI_SUITE: '',
      }),
    ),
    all,
  );
  assert.deepEqual(flags(planFromEnvironment({ CI_EVENT: 'workflow_dispatch' })), all);
  assert.deepEqual(flags(planFromEnvironment({ CI_EVENT: 'schedule' })), all);
  assert.deepEqual(
    flags(
      planFromEnvironment({
        CI_EVENT: 'pull_request',
        CI_CHANGED_FILES: '["src/lib.zig"]',
        CI_DRAFT: 'true',
      }),
    ),
    [true, false, false, true],
  );
  assert.deepEqual(
    flags(
      planFromEnvironment({
        CI_EVENT: 'pull_request',
        CI_CHANGED_FILES: '["src/lib.zig"]',
        CI_EVENT_ACTION: 'ready_for_review',
      }),
    ),
    all,
  );
});

for (const [name, rawFiles] of [
  ['missing data', undefined],
  ['empty data', ''],
  ['malformed JSON', '['],
  ['object', '{}'],
  ['null', 'null'],
  ['string', '"src/lib.zig"'],
  ['non-string member', '["src/lib.zig",null]'],
  ['empty path', '[""]'],
  ['absolute path', '["/src/lib.zig"]'],
  ['parent traversal', '["../src/lib.zig"]'],
  ['dot path component', '["./src/lib.zig"]'],
  ['empty path component', '["src//lib.zig"]'],
  ['null byte', '["src/\\u0000.zig"]'],
]) {
  test(`reject ${name} instead of silently skipping coverage`, () => {
    assert.throws(
      () => planFromEnvironment({ CI_EVENT: 'push', CI_CHANGED_FILES: rawFiles }),
      /CI_CHANGED_FILES/,
    );
  });
}

for (const event of ['workflow_dispatch', 'schedule']) {
  test(`${event} still rejects malformed supplied change data`, () => {
    assert.throws(
      () => planFromEnvironment({ CI_EVENT: event, CI_CHANGED_FILES: 'not-json' }),
      /CI_CHANGED_FILES/,
    );
  });
}

for (const [key, value] of [
  ['CI_EVENT', 'release'],
  ['CI_DRAFT', 'yes'],
  ['CI_SUITE', 'unit'],
]) {
  test(`reject unsupported ${key}`, () => {
    assert.throws(
      () => planFromEnvironment({ CI_EVENT: 'push', CI_CHANGED_FILES: '[]', [key]: value }),
      new RegExp(key),
    );
  });
}

test('GitHub output serialization has all flags and one-line JSON matrices', () => {
  const plan = createPlan({ changedFiles: ['src/lib.zig'], event: 'pull_request' });
  const output = githubOutputs(plan);
  assert.ok(output.endsWith('\n'));
  const entries = Object.fromEntries(
    output
      .trimEnd()
      .split('\n')
      .map((line) => {
        const separator = line.indexOf('=');
        return [line.slice(0, separator), JSON.parse(line.slice(separator + 1))];
      }),
  );
  assert.deepEqual(entries, plan);
  assert.equal(output.trimEnd().split('\n').length, 7);
});

test('CLI appends valid outputs and leaves output untouched on invalid input', () => {
  const directory = mkdtempSync(join(tmpdir(), 'zntc-ci-plan-'));
  const output = join(directory, 'github-output');
  const script = fileURLToPath(new URL('./ci-plan.mjs', import.meta.url));
  const env = {
    ...process.env,
    CI_EVENT: 'pull_request',
    CI_DRAFT: 'false',
    CI_SUITE: 'all',
    CI_EVENT_ACTION: 'synchronize',
    CI_CHANGED_FILES: '["src/parser/expr.zig"]',
    GITHUB_OUTPUT: output,
  };
  try {
    writeFileSync(output, 'existing=value\n');
    const valid = spawnSync(process.execPath, [script], { env, encoding: 'utf8' });
    assert.equal(valid.status, 0, valid.stderr);
    const expected = `existing=value\n${githubOutputs(planFromEnvironment(env))}`;
    assert.equal(readFileSync(output, 'utf8'), expected);
    for (const overrides of [
      { CI_CHANGED_FILES: '{' },
      { CI_CHANGED_FILES: '{}' },
      { CI_EVENT: 'release' },
      { CI_DRAFT: 'no' },
      { CI_SUITE: 'unknown' },
    ]) {
      const invalid = spawnSync(process.execPath, [script], {
        env: { ...env, ...overrides },
        encoding: 'utf8',
      });
      assert.equal(invalid.status, 1);
      assert.match(invalid.stderr, /CI plan failed:/);
      assert.equal(readFileSync(output, 'utf8'), expected);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
