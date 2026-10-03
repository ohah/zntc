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

test('draft PR retains core and Test262, suppressing all integration consumers', () => {
  const plan = createPlan({
    changedFiles: ['src/parser/expr.zig'],
    event: 'pull_request',
    draft: true,
  });
  assert.deepEqual(flags(plan), [true, false, false, true]);
  assert.deepEqual(plan.debug_matrix, {
    include: [{ os: 'ubuntu-latest' }, { os: 'macos-latest' }],
  });
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
    assert.equal(plan.smoke_matrix.include.length, 8);
  });
}

test('suite input cannot narrow an ordinary push or PR', () => {
  for (const event of ['push', 'pull_request']) {
    const plan = createPlan({ changedFiles: ['src/lib.zig'], event, suite: 'test262' });
    assert.deepEqual(flags(plan), all);
  }
});

test('PR smoke matrix preserves five actual ABI targets and runtime overrides', () => {
  const plan = createPlan({ changedFiles: ['src/lib.zig'], event: 'pull_request' });
  assert.deepEqual(plan.smoke_matrix, {
    include: [
      { platform: 'linux-x64-gnu', os: 'ubuntu-latest', zig_target: 'native' },
      {
        platform: 'linux-x64-musl',
        os: 'ubuntu-latest',
        zig_target: 'x86_64-linux-musl',
        smoke_container: 'node:24-alpine',
      },
      { platform: 'darwin-arm64', os: 'macos-latest', zig_target: 'native' },
      { platform: 'win32-x64-msvc', os: 'windows-latest', zig_target: 'native' },
      {
        platform: 'win32-ia32-msvc',
        os: 'windows-latest',
        zig_target: 'x86-windows-msvc',
        node_version: '22',
        node_arch: 'x86',
      },
    ],
  });
});

test('main smoke matrix adds both arm64 Linux ABIs and Intel macOS', () => {
  const plan = createPlan({ changedFiles: ['src/lib.zig'], event: 'push' });
  assert.equal(plan.smoke_matrix.include.length, 8);
  assert.deepEqual(
    plan.smoke_matrix.include.filter((entry) =>
      ['linux-arm64-gnu', 'linux-arm64-musl', 'darwin-x64'].includes(entry.platform),
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
    ],
  );
  assert.ok(plan.smoke_matrix.include.every((entry) => !('pr' in entry)));
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

test('manual runs still reject malformed supplied change data', () => {
  assert.throws(
    () => planFromEnvironment({ CI_EVENT: 'workflow_dispatch', CI_CHANGED_FILES: 'not-json' }),
    /CI_CHANGED_FILES/,
  );
});

for (const [key, value] of [
  ['CI_EVENT', 'schedule'],
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
  assert.equal(output.trimEnd().split('\n').length, 6);
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
      { CI_EVENT: 'schedule' },
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
