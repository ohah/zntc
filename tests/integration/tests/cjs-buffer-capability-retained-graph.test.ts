import { describe, expect, test } from 'bun:test';
import { spawnSync as spawnSyncRaw } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'buffer require with a block fallback',
    source: `var buffer = require("buffer");
var Buffer = buffer.Buffer;
if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) var native = buffer;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
module.exports = native;
`,
    expression: 'Buffer.alloc(2).length',
    expected: '2',
    args: [],
  },
  {
    name: 'node buffer require with reordered parenthesized checks',
    source: `var nodeBuffer = require("node:buffer");
var Native = nodeBuffer.Buffer;
if (((Native.allocUnsafeSlow) && (Native.from)) && ((Native.allocUnsafe) && (Native.alloc))) var selected = nodeBuffer;
else exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER";
module.exports = selected;
`,
    expression: 'Buffer.from("ab").toString()',
    expected: 'ab',
    args: ['--minify-identifiers'],
  },
  {
    name: 'block-owned var declaration keeps its function scope',
    source: `var buffer = require("buffer");
var B = buffer.Buffer;
{
  if (B.alloc && B.from && B.allocUnsafe && B.allocUnsafeSlow) var picked = buffer;
  else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
}
module.exports = picked;
`,
    expression: 'Buffer.alloc(3).length',
    expected: '3',
    args: [],
  },
  {
    name: 'multiple declarators retain the selected module object',
    source: `var buffer = require("buffer");
var B = buffer.Buffer;
if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) var picked = buffer, marker = 4;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
module.exports = picked;
`,
    expression: 'Buffer.alloc(4).fill(7).toString("hex")',
    expected: '07070707',
    args: ['--minify-syntax'],
  },
  {
    name: 'function-local var declaration remains owned by the function',
    source: `var buffer = require("buffer");
var B = buffer.Buffer;
function choose() {
  if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) var picked = buffer;
  else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
  return picked;
}
module.exports = choose();
`,
    expression: 'Buffer.alloc(5).length',
    expected: '5',
    args: [],
  },
  {
    name: 'expression fallback and renamed constructor',
    source: `var buffer = require("buffer");
var Constructor = buffer.Buffer;
if (Constructor.from && Constructor.alloc && Constructor.allocUnsafe && Constructor.allocUnsafeSlow) var nativeModule = buffer;
else exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER";
module.exports = nativeModule;
`,
    expression: 'Buffer.from("six").length',
    expected: '3',
    args: ['--minify-identifiers'],
  },
  {
    name: 'nested logical groups preserve every required capability',
    source: `var buffer = require("buffer");
var B = buffer.Buffer;
if ((B.from && B.alloc) && (B.allocUnsafe && B.allocUnsafeSlow)) var picked = buffer;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
module.exports = picked;
`,
    expression: 'Buffer.alloc(6).length',
    expected: '6',
    args: [],
  },
  {
    name: 'node buffer alias with syntax and identifier minification',
    source: `var source = require("node:buffer");
var B = source.Buffer;
if (B.from && B.allocUnsafeSlow && B.alloc && B.allocUnsafe) var target = source;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
module.exports = target;
`,
    expression: 'Buffer.alloc(7).length',
    expected: '7',
    args: ['--minify-syntax', '--minify-identifiers'],
  },
  {
    name: 'kept declaration with independent module statements',
    source: `var buffer = require("buffer");
var B = buffer.Buffer;
var before = "before";
if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) var target = buffer;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
var after = "after";
module.exports = { Buffer: target.Buffer, before, after };
`,
    entryImport: 'import library from "./lib.js";\n',
    expression: 'library.before.length + library.Buffer.alloc(8).length + library.after.length',
    expected: '19',
    args: [],
  },
  {
    name: 'two direct var capability branches are edited together',
    source: `var buffer = require("buffer");
var B = buffer.Buffer;
if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) var first = buffer;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
if (B.allocUnsafeSlow && B.allocUnsafe && B.from && B.alloc) var second = first;
else { exports.Buffer = "DIRECT_VAR_FALLBACK_MARKER"; }
module.exports = second;
`,
    expression: 'Buffer.alloc(9).length',
    expected: '9',
    args: ['--minify-identifiers'],
  },
] as const;

function semanticResyncCount(stderr: string): number {
  const jsonStart = stderr.indexOf('{\n  "profile_version"');
  expect(jsonStart, stderr).toBeGreaterThanOrEqual(0);
  const jsonEnd = stderr.indexOf('\n}\n', jsonStart);
  expect(jsonEnd, stderr).toBeGreaterThan(jsonStart);
  let profile: { phases: Record<string, { count: number }> };
  try {
    profile = JSON.parse(stderr.slice(jsonStart, jsonEnd + 2));
  } catch (error) {
    throw new Error(`invalid profile JSON: ${JSON.stringify(stderr)}: ${String(error)}`);
  }
  return profile.phases['graph.resync.semantic']?.count ?? 0;
}

function runCaptured(command: string, args: string[]) {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-child-'));
  const stdoutPath = join(dir, 'stdout.log');
  const stderrPath = join(dir, 'stderr.log');
  const stderrPipePath = join(dir, 'stderr.pipe');
  writeFileSync(stdoutPath, '');
  writeFileSync(stderrPath, '');
  try {
    const proc = spawnSyncRaw(
      '/bin/sh',
      [
        '-c',
        'stdout_path=$1; stderr_path=$2; stderr_pipe_path=$3; shift 3; mkfifo "$stderr_pipe_path" || exit 125; tee "$stderr_path" <"$stderr_pipe_path" >/dev/null & tee_pid=$!; "$@" >"$stdout_path" 2>"$stderr_pipe_path"; command_status=$?; wait "$tee_pid"; exit "$command_status"',
        'zntc-cjs-buffer-child',
        stdoutPath,
        stderrPath,
        stderrPipePath,
        command,
        ...args,
      ],
      { encoding: 'utf8' },
    );
    return {
      exitCode: proc.status ?? -1,
      stdout: readFileSync(stdoutPath, 'utf8'),
      stderr: readFileSync(stderrPath, 'utf8'),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('CJS Node Buffer capability graph retention', () => {
  test('covers ten distinct direct-var runtime inputs', () => {
    expect(cases).toHaveLength(10);
  });

  for (const entry of cases) {
    test(`${entry.name} avoids post-fold semantic reanalysis`, () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-retained-'));
      const input = join(dir, 'entry.js');
      const modulePath = join(dir, 'lib.js');
      const output = join(dir, 'out.cjs');
      const controlOutput = join(dir, 'control.cjs');
      try {
        writeFileSync(
          input,
          `${'entryImport' in entry ? entry.entryImport : 'import { Buffer } from "./lib.js";\n'}console.log(${entry.expression});\n`,
        );
        writeFileSync(modulePath, entry.source);
        const result = runCaptured(ZNTC_BIN, [
          '--bundle',
          input,
          '--platform=node',
          '--format=cjs',
          '--profile=graph.resync.semantic',
          '--profile-level=detailed',
          '--profile-format=json',
          ...entry.args,
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const profileOutput = `${result.stderr}\n${result.stdout}`;
        const targetResyncs = semanticResyncCount(profileOutput);
        const bundled = readFileSync(output, 'utf8');
        expect(bundled).not.toContain('DIRECT_VAR_FALLBACK_MARKER');

        // Disable only the Node Buffer capability recognizer as a control.
        // Other compiler work for this input may legitimately reanalyze, so
        // compare the target against its own no-fold resync baseline.
        writeFileSync(
          modulePath,
          entry.source.replaceAll('allocUnsafeSlow', 'allocUnsafeSlow_unavailable'),
        );
        const control = runCaptured(ZNTC_BIN, [
          '--bundle',
          input,
          '--platform=node',
          '--format=cjs',
          '--profile=graph.resync.semantic',
          '--profile-level=detailed',
          '--profile-format=json',
          ...entry.args,
          '-o',
          controlOutput,
        ]);
        expect(control.exitCode, control.stderr).toBe(0);
        const controlProfile = `${control.stderr}\n${control.stdout}`;
        expect(targetResyncs, profileOutput).toBeLessThanOrEqual(
          semanticResyncCount(controlProfile),
        );

        const actual = runCaptured('node', [output]);
        expect(actual.exitCode, actual.stderr).toBe(0);
        expect(actual.stdout.trim()).toBe(entry.expected);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });
  }

  test('direct var alternate remains on the conservative analyzer path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-var-alternate-'));
    const input = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    try {
      writeFileSync(
        input,
        `import { Buffer } from "./lib.js";\nconsole.log(Buffer.alloc(2).length);\n`,
      );
      writeFileSync(
        join(dir, 'lib.js'),
        `var buffer = require("buffer");
var Buffer = buffer.Buffer;
if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) var native = buffer;
else var fallback = SafeBuffer;
module.exports = native;
function SafeBuffer() { return "DIRECT_VAR_FALLBACK_MARKER"; }
`,
      );
      const result = runCaptured(ZNTC_BIN, [
        '--bundle',
        input,
        '--platform=node',
        '--format=cjs',
        '--profile=graph.resync.semantic',
        '--profile-level=detailed',
        '--profile-format=json',
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const profileOutput = `${result.stderr}\n${result.stdout}`;
      expect(semanticResyncCount(profileOutput), profileOutput).toBe(1);
      const actual = runCaptured('node', [output]);
      expect(actual.exitCode, actual.stderr).toBe(0);
      expect(actual.stdout.trim()).toBe('2');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
