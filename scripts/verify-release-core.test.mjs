import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import {
  captureCore,
  recordSmoke,
  verifyCore,
  verifyReleaseArtifacts,
} from './verify-release-core.mjs';

const repository = join(dirname(fileURLToPath(import.meta.url)), '..');
const corePackage = JSON.parse(
  readFileSync(join(repository, 'packages/core/package.json'), 'utf8'),
);
const platforms = Object.keys(corePackage.optionalDependencies)
  .filter((name) => name.startsWith('@zntc/core-'))
  .map((name) => name.slice('@zntc/core-'.length));

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'zntc-release-proof-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  function write(path, content) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  write(
    'packages/core/package.json',
    JSON.stringify({
      name: '@zntc/core',
      version: '0.1.10',
      files: ['dist/', 'bin/cli.mjs'],
      optionalDependencies: Object.fromEntries(
        platforms.map((platform) => [`@zntc/core-${platform}`, '0.1.10']),
      ),
    }),
  );
  for (const file of ['index.js', 'index.cjs', 'core/index.d.ts', 'core/index.d.cts']) {
    write(`packages/core/dist/${file}`, `// tested ${file}\n`);
  }
  write('packages/core/bin/cli.mjs', '// tested CLI wrapper\n');
  write('packages/core/README.md', 'tested package README\n');
  write('packages/core/LICENSE', 'tested package license\n');
  write('cli', 'tested native CLI');
  captureCore(root);
  for (const platform of platforms) {
    write(
      `packages/core-${platform}/package.json`,
      JSON.stringify({
        name: `@zntc/core-${platform}`,
        version: '0.1.10',
        files: ['zntc.node', 'NOTICE', 'README.md'],
      }),
    );
    write(`packages/core-${platform}/zntc.node`, `tested native binary ${platform}`);
    write(`packages/core-${platform}/NOTICE`, 'BoringSSL attribution\n');
    write(`packages/core-${platform}/README.md`, `${platform}\n`);
    recordSmoke(root, platform, join(root, 'cli'));
  }
  return { root, write };
}

test('release proof accepts every declared ABI and the exact tested payload', (t) => {
  const { root } = fixture(t);
  verifyReleaseArtifacts(root);
});

test('missing, extra and substituted platform proofs fail closed', (t) => {
  const { root } = fixture(t);
  const file = join(root, 'release-smoke-results', `${platforms[0]}.json`);
  const original = readFileSync(file);
  rmSync(file);
  assert.throws(() => verifyReleaseArtifacts(root), /every declared platform/);
  writeFileSync(file, original);
  const extra = join(root, 'release-smoke-results/unexpected.json');
  copyFileSync(file, extra);
  assert.throws(() => verifyReleaseArtifacts(root), /every declared platform/);
  rmSync(extra);
  const proof = JSON.parse(original);
  proof.platform = platforms[1];
  writeFileSync(file, JSON.stringify(proof));
  assert.throws(() => verifyReleaseArtifacts(root), /platform mismatch/);
});

test('a wrapper rebuilt differently after smoke cannot be published', (t) => {
  const { root, write } = fixture(t);
  write('packages/core/dist/index.cjs', '// a different self-hosted result\n');
  assert.throws(() => verifyReleaseArtifacts(root), /core payload changed/);
});

test('new output files and missing declarations are included in the gate', (t) => {
  const { root, write } = fixture(t);
  write('packages/core/dist/extra.js', '// previously untested\n');
  assert.throws(() => verifyCore(root), /core payload changed/);
  rmSync(join(root, 'packages/core/dist/extra.js'));
  rmSync(join(root, 'packages/core/dist/core/index.d.cts'));
  assert.throws(() => verifyCore(root), /core payload changed/);
});

test('native binary replacement and removed NOTICE fail before publication', (t) => {
  const { root, write } = fixture(t);
  write(`packages/core-${platforms[0]}/zntc.node`, 'older registry binary');
  assert.throws(() => verifyReleaseArtifacts(root), /native package differs/);
  rmSync(join(root, `packages/core-${platforms[1]}/NOTICE`));
  assert.throws(() => recordSmoke(root, platforms[1], join(root, 'cli')), /ENOENT/);
});

test('a new core manifest cannot reuse proofs from an earlier wrapper', (t) => {
  const { root, write } = fixture(t);
  write('packages/core/dist/index.js', '// new wrapper\n');
  captureCore(root);
  assert.throws(() => verifyReleaseArtifacts(root), /different core wrapper/);
});

test('changed package metadata and bin wrappers are protected', (t) => {
  const { root, write } = fixture(t);
  const path = join(root, 'packages/core/package.json');
  const original = readFileSync(path);
  const pkg = JSON.parse(original);
  pkg.main = 'dist/untested.cjs';
  writeFileSync(path, JSON.stringify(pkg));
  assert.throws(() => verifyCore(root), /core payload changed/);
  writeFileSync(path, original);
  write('packages/core/bin/cli.mjs', '// replaced wrapper\n');
  assert.throws(() => verifyCore(root), /core payload changed/);
});

test('unshipped source changes do not invalidate a verified release payload', (t) => {
  const { root, write } = fixture(t);
  write('packages/core/index.ts', '// source is not in the published files list\n');
  verifyReleaseArtifacts(root);
});

test('proofs without a successful CLI result are rejected', (t) => {
  const { root } = fixture(t);
  const path = join(root, 'release-smoke-results', `${platforms[0]}.json`);
  const proof = JSON.parse(readFileSync(path, 'utf8'));
  delete proof.cli;
  writeFileSync(path, JSON.stringify(proof));
  assert.throws(
    () => verifyReleaseArtifacts(root),
    /CLI smoke proof missing|must be of type string/,
  );
});
