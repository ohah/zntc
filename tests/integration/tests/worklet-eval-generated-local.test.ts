import { expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build } from '../../../packages/core/index.ts';

test('worklet method factory locals avoid ten hostile direct-eval names', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-eval-local-'));
  const entry = join(dir, 'entry.js');
  const output = join(dir, 'out.cjs');
  const cases = [
    { name: 'call', expression: "eval('call')" },
    { name: 'render', expression: 'eval("render")' },
    { name: 'update', expression: "eval('up' + 'date')" },
    { name: 'format', expression: 'eval(`format`)' },
    { name: 'measure', expression: "eval(('measure'))" },
    { name: 'commit', expression: "eval('comm\\u0069t')" },
    { name: 'retry', expression: "eval('ret' + `ry`)" },
    { name: 'release', expression: 'eval(`rele` + `ase`)' },
    { name: 'subscribe', expression: "eval('subscr' + 'ibe')" },
    { name: 'read', expression: 'eval((`read`))' },
  ];
  const globals = cases.map(({ name }) => `globalThis.${name} = 'global:${name}';`).join('\n');
  const methods = cases
    .map(({ name, expression }) => `${name}() { "worklet"; return ${expression}; }`)
    .join(',\n');
  const results = cases.map(({ name }) => `object.${name}()`).join(', ');
  writeFileSync(
    entry,
    [globals, `const object = { ${methods} };`, `console.log([${results}].join('|'));`, ''].join(
      '\n',
    ),
  );

  try {
    const result = await build({
      entryPoints: [entry],
      platform: 'node',
      format: 'cjs',
      target: 'esnext',
      workletTransform: true,
      write: false,
    });
    expect(result.errors).toEqual([]);
    expect(result.outputFiles).toHaveLength(1);
    expect(result.outputFiles[0]!.text).toContain('__workletHash');
    writeFileSync(output, result.outputFiles[0]!.text);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(cases.map(({ name }) => `global:${name}`).join('|') + '\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 60_000);
