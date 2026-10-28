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

const fallbackFunctionCases = [
  {
    name: 'dead plain top-level fallback declaration',
    declarations: `function SafeBuffer() { return "fallback"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'direct eval alone keeps a removed fallback declaration live',
    declarations: `function SafeBuffer() { return "fallback"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `eval("globalThis.sawSafeBuffer = typeof SafeBuffer === 'function'"); module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length, globalThis.sawSafeBuffer);`,
    expected: '1 true',
    liveFallback: true,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'fallback declaration before the capability branch',
    declarations: `function SafeBuffer() { return "fallback"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: true,
  },
  {
    name: 'dead async top-level fallback declaration',
    declarations: `async function SafeBuffer() { return "fallback"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'dead generator top-level fallback declaration',
    declarations: `function* SafeBuffer() { yield "fallback"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'duplicate fallback declarations share the removed edge',
    declarations: `function SafeBuffer() { return "first"; } function SafeBuffer() { return "second"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'multiple exported fallback functions lose only fallback references',
    declarations: `function SafeBuffer() { return "fallback"; } function SlowBuffer() { return "slow"; }`,
    alternate: `exports.Buffer = SafeBuffer; exports.Slow = SlowBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'dead fallback factory drops its transitive function read',
    declarations: `function SafeBuffer() { return "fallback"; } function FallbackFactory() { return SafeBuffer(); }`,
    alternate: `exports.Buffer = FallbackFactory;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'module exports fallback property is removed by exact reference',
    declarations: `function SafeBuffer() { return "fallback"; }`,
    alternate: `module.exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'static var fallback function initializer remains on the retained graph',
    declarations: `var SafeBuffer = function() { return "fallback"; }; function unrelated() { return 2; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = buffer;`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length);`,
    expected: '1',
    liveFallback: false,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'dynamic root without a removed fallback name stays on the retained graph',
    declarations: `function SafeBuffer() { return "fallback"; }`,
    alternate: `exports.Buffer = "fallback";`,
    tail: `eval("globalThis.sawSafeBuffer = typeof SafeBuffer === 'function'"); module.exports = { Buffer: buffer.Buffer, fallback: SafeBuffer };`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length, lib.fallback(), globalThis.sawSafeBuffer);`,
    expected: '1 fallback true',
    liveFallback: true,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'direct eval module retains the graph and a live fallback export',
    alternate: `exports.Buffer = FallbackAlias;`,
    declarations: `function SafeBuffer() { return "fallback"; } var FallbackAlias = SafeBuffer;`,
    tail: `eval("globalThis.sawSafeBuffer = typeof SafeBuffer === 'function'"); module.exports = { Buffer: buffer.Buffer, fallback: SafeBuffer };`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length, lib.fallback(), globalThis.sawSafeBuffer);`,
    expected: '1 fallback true',
    liveFallback: true,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'with scope retains the graph and a live fallback export',
    alternate: `exports.Buffer = FallbackAlias;`,
    declarations: `function SafeBuffer() { return "fallback"; } var FallbackAlias = SafeBuffer;`,
    tail: `with ({}) { globalThis.sawSafeBuffer = typeof SafeBuffer === 'function'; } module.exports = { Buffer: buffer.Buffer, fallback: SafeBuffer };`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length, lib.fallback(), globalThis.sawSafeBuffer);`,
    expected: '1 fallback true',
    liveFallback: true,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
  {
    name: 'independent module export keeps a live fallback binding',
    declarations: `function SafeBuffer() { return "live"; }`,
    alternate: `exports.Buffer = SafeBuffer;`,
    tail: `module.exports = { Buffer: buffer.Buffer, fallback: SafeBuffer };`,
    entry: `import lib from "./lib.js"; console.log(lib.Buffer.alloc(1).length, lib.fallback());`,
    expected: '1 live',
    liveFallback: true,
    expectedResyncs: 0,
    declarationsBeforeBranch: false,
  },
] as const;

const dynamicRootBindingCases = [
  {
    name: 'function read hidden in eval string',
    declarations: `function hidden() { return "function"; }`,
    body: `eval("globalThis.observed = hidden()");`,
    expected: 'function',
  },
  {
    name: 'const read hidden in eval string',
    declarations: `const hidden = "const";`,
    body: `eval("globalThis.observed = hidden");`,
    expected: 'const',
  },
  {
    name: 'let read hidden in eval string',
    declarations: `let hidden = "let";`,
    body: `eval("globalThis.observed = hidden");`,
    expected: 'let',
  },
  {
    name: 'var initializer read hidden in eval string',
    declarations: `var hidden = "var-init";`,
    body: `eval("globalThis.observed = hidden");`,
    expected: 'var-init',
  },
  {
    name: 'split var writer read hidden in eval string',
    declarations: `var hidden; if (true) hidden = "var-write";`,
    body: `eval("globalThis.observed = hidden");`,
    expected: 'var-write',
  },
  {
    name: 'duplicate function declarations read hidden in eval string',
    declarations: `function hidden() { return "first"; } function hidden() { return "last"; }`,
    body: `eval("globalThis.observed = hidden()");`,
    expected: 'last',
  },
  {
    name: 'class read hidden in eval string',
    declarations: `class Hidden { static value() { return "class"; } }`,
    body: `eval("globalThis.observed = Hidden.value()");`,
    expected: 'class',
  },
  {
    name: 'nested eval closes over a top-level const',
    declarations: `const hidden = "nested"; function observe() { eval("globalThis.observed = hidden"); }`,
    body: `observe();`,
    expected: 'nested',
  },
  {
    name: 'eval inside with reads the outer function binding',
    declarations: `function hidden() { return "with"; }`,
    body: `with ({}) { eval("globalThis.observed = hidden()"); }`,
    expected: 'with',
  },
  {
    name: 'eval observes a later branch assignment',
    declarations: `let hidden = "before"; if (true) hidden = "after";`,
    body: `eval("globalThis.observed = hidden");`,
    expected: 'after',
  },
  {
    name: 'eval observes each of multiple exact writers',
    declarations: `var hidden = "first";`,
    body: `eval("globalThis.observed = hidden"); hidden = "middle"; eval("globalThis.observed += ' ' + hidden"); hidden = "last"; eval("globalThis.observed += ' ' + hidden");`,
    expected: 'first middle last',
  },
  {
    name: 'with lookup keeps an outer binding with no direct eval',
    declarations: `var hidden = "with-only";`,
    body: `with ({}) { globalThis.observed = hidden; }`,
    expected: 'with-only',
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

  test('folds top-level fallback-function cases and keeps dynamic-scope bindings live', () => {
    expect(fallbackFunctionCases).toHaveLength(14);
    for (const entry of fallbackFunctionCases) {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-fallback-function-'));
      const input = join(dir, 'entry.js');
      const modulePath = join(dir, 'lib.js');
      const output = join(dir, 'out.cjs');
      try {
        writeFileSync(input, `${entry.entry}\n`);
        const branch =
          `var buffer = require("buffer");\n` +
          `var B = buffer.Buffer;\n` +
          `if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }\n` +
          `else { ${entry.alternate} }\n`;
        const source = entry.declarationsBeforeBranch
          ? `${entry.declarations}\n${branch}${entry.tail}\n`
          : `${branch}${entry.declarations}\n${entry.tail}\n`;
        writeFileSync(modulePath, source);
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
        expect(result.exitCode, `${entry.name}: ${result.stderr}`).toBe(0);
        const profileOutput = `${result.stderr}\n${result.stdout}`;
        expect(semanticResyncCount(profileOutput), `${entry.name}: ${profileOutput}`).toBe(
          entry.expectedResyncs,
        );
        const bundled = readFileSync(output, 'utf8');
        if (!entry.liveFallback) expect(bundled, entry.name).not.toContain('SafeBuffer');
        else expect(bundled, entry.name).toContain('SafeBuffer');

        const actual = runCaptured('node', [output]);
        expect(actual.exitCode, `${entry.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout.trim(), entry.name).toBe(entry.expected);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('dynamic root bindings and exact writers survive without semantic reanalysis', () => {
    expect(dynamicRootBindingCases).toHaveLength(12);
    for (const entry of dynamicRootBindingCases) {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-dynamic-root-'));
      const input = join(dir, 'entry.js');
      const modulePath = join(dir, 'lib.js');
      const output = join(dir, 'out.cjs');
      try {
        writeFileSync(
          input,
          `import { Buffer } from "./lib.js"; console.log(Buffer.alloc(1).length, globalThis.observed);\n`,
        );
        writeFileSync(
          modulePath,
          `var buffer = require("buffer");\n` +
            `var B = buffer.Buffer;\n` +
            `if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }\n` +
            `else { exports.Buffer = SafeBuffer; }\n` +
            `${entry.declarations}\n${entry.body}\nmodule.exports = buffer;\n`,
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
        expect(result.exitCode, `${entry.name}: ${result.stderr}`).toBe(0);
        const profileOutput = `${result.stderr}\n${result.stdout}`;
        expect(semanticResyncCount(profileOutput), `${entry.name}: ${profileOutput}`).toBe(0);

        const actual = runCaptured('node', [output]);
        expect(actual.exitCode, `${entry.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout.trim(), entry.name).toBe(`1 ${entry.expected}`);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('direct eval observes each pure top-level writer in an imported ESM module', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-dynamic-esm-writers-'));
    const input = join(dir, 'entry.js');
    const modulePath = join(dir, 'lib.js');
    const output = join(dir, 'out.mjs');
    try {
      writeFileSync(
        input,
        `import { included } from "./lib.js"; console.log(included, globalThis.firstObserved, globalThis.middleObserved, globalThis.lastObserved);\n`,
      );
      writeFileSync(
        modulePath,
        `let hidden = "first";\n` +
          `eval("globalThis.firstObserved = hidden");\n` +
          `hidden = "middle";\n` +
          `eval("globalThis.middleObserved = hidden");\n` +
          `hidden = "last";\n` +
          `eval("globalThis.lastObserved = hidden");\n` +
          `export const included = true;\n`,
      );
      const result = runCaptured(ZNTC_BIN, [
        '--bundle',
        input,
        '--platform=node',
        '--format=esm',
        '--minify-syntax',
        '--profile=graph.resync.semantic',
        '--profile-level=detailed',
        '--profile-format=json',
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = runCaptured('node', [output]);
      expect(actual.exitCode, actual.stderr).toBe(0);
      expect(actual.stdout.trim()).toBe('true first middle last');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
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

  test('direct var alternate removes only the dead initializer and preserves its hoisted binding', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-var-alternate-'));
    const input = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    try {
      writeFileSync(
        input,
        `import lib from "./lib.js";\nconsole.log(lib.Buffer.alloc(2).length, lib.fallback === undefined);\n`,
      );
      writeFileSync(
        join(dir, 'lib.js'),
        `var buffer = require("buffer");
var Buffer = buffer.Buffer;
if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) var native = buffer;
else var fallback = SafeBuffer;
module.exports = { Buffer: native.Buffer, fallback: fallback };
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
      expect(semanticResyncCount(profileOutput), profileOutput).toBe(0);
      const actual = runCaptured('node', [output]);
      expect(actual.exitCode, actual.stderr).toBe(0);
      expect(actual.stdout.trim()).toBe('2 true');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  test('direct var alternate with a non-identifier initializer stays on analyzer path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cjs-buffer-var-call-alternate-'));
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
else var fallback = makeFallback();
module.exports = native;
function makeFallback() { return "fallback"; }
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
