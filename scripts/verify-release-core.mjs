import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const manifestName = 'release-core-manifest.json';
const defaultProofDirectory = 'release-smoke-results';

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

export function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

// Hash the payload selected by package.json, including added/deleted files.
// Current release packages use literal file/directory entries, not globs.
function packagePayload(directory) {
  const pkg = readJson(join(directory, 'package.json'));
  const files = new Set(['package.json']);
  function visit(relative) {
    assert(!relative.startsWith('/') && !relative.split('/').includes('..'), 'unsafe package path');
    const full = join(directory, relative);
    const stat = lstatSync(full);
    assert(!stat.isSymbolicLink(), `unexpected package symlink: ${relative}`);
    if (stat.isDirectory()) {
      for (const name of readdirSync(full)) visit(`${relative}/${name}`);
    } else {
      assert(stat.isFile(), `not a regular package file: ${relative}`);
      files.add(relative);
    }
  }
  for (const entry of pkg.files) {
    assert(
      !['*', '?', '[', ']'].some((char) => entry.includes(char)),
      `unsupported release files pattern: ${entry}`,
    );
    visit(entry.replace(/\/$/, ''));
  }
  for (const name of readdirSync(directory)) {
    if (/^(readme|licen[cs]e)(\.|$)/i.test(name)) visit(name);
  }
  return Object.fromEntries([...files].sort().map((name) => [name, sha256(join(directory, name))]));
}

export function captureCore(root) {
  const directory = join(root, 'packages/core');
  for (const required of [
    'dist/index.js',
    'dist/index.cjs',
    'dist/core/index.d.ts',
    'dist/core/index.d.cts',
  ]) {
    assert(lstatSync(join(directory, required)).isFile(), `missing core output: ${required}`);
  }
  const manifest = { schema: 1, files: packagePayload(directory) };
  writeFileSync(join(root, manifestName), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

export function verifyCore(root) {
  const manifest = readJson(join(root, manifestName));
  assert.equal(manifest.schema, 1, 'unsupported release core manifest');
  assert.deepEqual(
    packagePayload(join(root, 'packages/core')),
    manifest.files,
    'release core payload changed',
  );
  return manifest;
}

function expectedPlatforms(root) {
  const pkg = readJson(join(root, 'packages/core/package.json'));
  const prefix = '@zntc/core-';
  const platforms = Object.keys(pkg.optionalDependencies)
    .filter((name) => name.startsWith(prefix))
    .map((name) => name.slice(prefix.length))
    .sort();
  assert(platforms.length > 0, 'no native platforms declared');
  return platforms;
}

export function recordSmoke(root, platform, cliPath) {
  verifyCore(root);
  assert(expectedPlatforms(root).includes(platform), `unexpected release platform: ${platform}`);
  const proof = {
    schema: 1,
    platform,
    coreManifest: sha256(join(root, manifestName)),
    native: packagePayload(join(root, `packages/core-${platform}`)),
    cli: sha256(cliPath),
  };
  const directory = join(root, defaultProofDirectory);
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, `${platform}.json`), `${JSON.stringify(proof, null, 2)}\n`);
  return proof;
}

export function verifyReleaseArtifacts(root, proofDirectory = defaultProofDirectory) {
  verifyCore(root);
  const directory = resolve(root, proofDirectory);
  const platforms = expectedPlatforms(root);
  assert.deepEqual(
    readdirSync(directory).sort(),
    platforms.map((platform) => `${platform}.json`),
    'release smoke proofs must cover every declared platform exactly once',
  );
  const coreManifest = sha256(join(root, manifestName));
  for (const platform of platforms) {
    const proof = readJson(join(directory, `${platform}.json`));
    assert.equal(proof.schema, 1, 'unsupported release smoke proof');
    assert.equal(proof.platform, platform, 'release smoke platform mismatch');
    assert.equal(
      proof.coreManifest,
      coreManifest,
      `${platform}: different core wrapper was tested`,
    );
    assert.match(proof.cli, /^[a-f0-9]{64}$/, `${platform}: CLI smoke proof missing`);
    assert.deepEqual(
      packagePayload(join(root, `packages/core-${platform}`)),
      proof.native,
      `${platform}: native package differs from the installed smoke payload`,
    );
  }
}

function checkedRun(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  assert.equal(
    result.status,
    0,
    `${command} ${args.join(' ')} failed: ${result.error ?? result.stderr}`,
  );
  return result.stdout.trim();
}

function smoke(root, platform) {
  const manifest = verifyCore(root);
  const pkg = readJson(join(root, `packages/core-${platform}/package.json`));
  assert(pkg.os.includes(process.platform), `wrong smoke OS: ${process.platform}`);
  assert(pkg.cpu.includes(process.arch), `wrong smoke architecture: ${process.arch}`);
  if (pkg.libc) {
    const libc = process.report.getReport().header.glibcVersionRuntime ? 'glibc' : 'musl';
    assert(pkg.libc.includes(libc), `wrong smoke libc: ${libc}`);
  }
  const installed = join(root, 'tmp-napi-smoke/node_modules/@zntc');
  for (const [name, hash] of Object.entries(manifest.files)) {
    // npm may normalize package.json; its export paths are exercised by both
    // entry-point tests, while every shipped JS/declaration byte must match.
    if (name !== 'package.json')
      assert.equal(sha256(join(installed, 'core', name)), hash, `installed core differs: ${name}`);
  }
  assert.equal(
    sha256(join(installed, `core-${platform}/zntc.node`)),
    sha256(join(root, `packages/core-${platform}/zntc.node`)),
    'installed addon is not the fresh release binary',
  );
  // The shared action already covers ESM init/transpile/tokenize and CJS
  // init/transpile. Complete the CJS API check against the isolated install.
  const require = createRequire(join(root, 'tmp-napi-smoke/package.json'));
  const cjs = require('@zntc/core');
  cjs.init();
  const tokens = cjs.tokenize('const answer = 42;', { filename: 'input.ts' });
  assert(Array.isArray(tokens) && tokens.length > 0, 'CJS tokenize returned no tokens');

  const cli = join(root, 'release-cli', process.platform === 'win32' ? 'zntc.exe' : 'zntc');
  assert(existsSync(join(root, 'release-cli/NOTICE')), 'CLI artifact is missing NOTICE');
  if (process.platform !== 'win32') chmodSync(cli, 0o755);
  const temp = mkdtempSync(join(tmpdir(), 'zntc-release-cli-'));
  try {
    // The standalone Zig CLI exposes its version in --help; --version belongs
    // to the JS CLI and is not accepted by this artifact.
    assert.match(checkedRun(cli, ['--help'], temp), /^zntc v\d/, 'CLI help/version header missing');
    const source = join(temp, 'input.ts');
    const output = join(temp, 'output.js');
    writeFileSync(source, 'const answer: number = 42; console.log(`release-cli:${answer}`);\n');
    checkedRun(cli, [source, '-o', output], temp);
    assert(!readFileSync(output, 'utf8').includes(': number'), 'CLI did not strip TypeScript');
    assert.equal(
      checkedRun(process.execPath, [output], temp),
      'release-cli:42',
      'CLI output changed behavior',
    );
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
  recordSmoke(root, platform, cli);
  console.log(`release smoke: ${platform} native package and CLI passed`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const [command, platform] = process.argv.slice(2);
  if (command === 'capture') captureCore(root);
  else if (command === 'verify') verifyCore(root);
  else if (command === 'verify-release')
    verifyReleaseArtifacts(root, process.env.ZNTC_RELEASE_PROOF_DIR);
  else if (command === 'smoke') smoke(root, platform);
  else throw new Error('expected capture, verify, smoke <platform>, or verify-release');
}
