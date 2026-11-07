import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const addon = process.env.ZNTC_NAPI_PATH ?? resolve(__dirname, '../../../zig-out/lib/zntc.node');
const child = String.raw`
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const addon = process.argv[2];
const entry = process.argv[3];
function check(native) {
  const result = native.buildSync({ entryPoints: [entry], platform: 'node', format: 'cjs', logLevel: 'silent' });
  assert.deepEqual(result.errors, []);
  assert.equal(result.outputFiles.length, 1);
  const module = { exports: {} };
  vm.runInNewContext(Buffer.from(result.outputFiles[0].contents).toString(), { module, exports: module.exports });
  assert.equal(module.exports.answer, 42);
}
if (!isMainThread) {
  const native = require(workerData.addon);
  check(native);
  parentPort.postMessage('ready');
  parentPort.on('message', () => { check(native); parentPort.postMessage('checked'); });
} else if (process.argv[4] === 'workers') {
  const once = require('node:events').once;
  (async () => {
    const first = new Worker(__filename, { workerData: { addon, entry }, argv: [addon, entry] });
    await once(first, 'message');
    const second = new Worker(__filename, { workerData: { addon, entry }, argv: [addon, entry] });
    await once(second, 'message');
    await first.terminate();
    const checked = once(second, 'message');
    second.postMessage('check-after-other-env-cleanup');
    assert.deepEqual(await checked, ['checked']);
    await second.terminate();
    console.log('workers:42');
  })().catch(error => { console.error(error); process.exitCode = 1; });
} else {
  const native = require(addon);
  if (process.argv[4] === 'build') for (let count = 0; count < 4; count++) check(native);
  console.log(process.argv[4] + ':42');
}
`;

function run(runtime: string, mode: string) {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-env-lifetime-'));
  try {
    const script = join(dir, 'child.cjs');
    const entry = join(dir, 'entry.cjs');
    writeFileSync(script, child);
    writeFileSync(entry, 'module.exports = { answer: 42 };');
    return spawnSync(runtime, [script, addon, entry, mode], {
      encoding: 'utf8',
      timeout: 30_000,
      env: { ...process.env, ZNTC_ENV_LIFETIME_WITNESS: 'retained-across-envs' },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('NAPI process-lifetime environment snapshot', () => {
  for (const [name, runtime] of [
    ['Node', 'node'],
    ['Bun', process.execPath],
  ]) {
    for (const mode of ['init', 'build']) {
      test(`${name} ${mode} keeps values and reports no environment snapshot leak`, () => {
        const result = run(runtime!, mode!);
        expect(result.error).toBeUndefined();
        expect(result.status).toBe(0);
        expect(result.stdout.trim()).toBe(`${mode}:42`);
        expect(result.stderr.includes('captureEnvironFromLibc')).toBe(false);
        expect(result.stderr.includes('error(DebugAllocator)')).toBe(false);
      });
    }
  }
  test('Node worker cleanup preserves the snapshot borrowed by another isolate', () => {
    const result = run('node', 'workers');
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe('workers:42');
    expect(result.stderr.includes('captureEnvironFromLibc')).toBe(false);
    expect(result.stderr.includes('error(DebugAllocator)')).toBe(false);
  });
});
