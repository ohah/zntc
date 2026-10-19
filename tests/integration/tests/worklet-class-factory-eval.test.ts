import { expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build } from '../../../packages/core/index.ts';

test('Worklet class factory bindings avoid ten hostile direct-eval names', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-class-factory-eval-'));
  const entry = join(dir, 'entry.js');
  const output = join(dir, 'out.cjs');
  const cases = [
    { className: 'C0', expression: "eval('C0__classFactory')" },
    { className: 'C1', expression: 'eval("C1__classFactory")' },
    { className: 'C2', expression: "eval('C2__' + 'classFactory')" },
    { className: 'C3', expression: 'eval(`C3__classFactory`)' },
    { className: 'C4', expression: "eval(('C4__classFactory'))" },
    { className: 'C5', expression: "eval('C5__classFact\\u006fry')" },
    { className: 'C6', expression: "eval('C6__' + `classFactory`)" },
    { className: 'C7', expression: 'eval(`C7__` + `classFactory`)' },
    { className: 'C8', expression: 'eval((`C8__classFactory`))' },
    { className: 'C9', expression: "eval('C9' + '__classFactory')" },
  ];
  const source = cases
    .flatMap(({ className, expression }, index) => [
      `globalThis[${JSON.stringify(`${className}__`)} + 'classFactory'] = 'global:${index}';`,
      `class ${className} { __workletClass = true; read() { return ${expression}; } }`,
      `const Recreated${index} = ${className}[${JSON.stringify(`${className}__`)} + 'classFactory']();`,
      `console.log(new Recreated${index}().read());`,
    ])
    .join('\n');
  writeFileSync(entry, source);

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
    const outputCode = result.outputFiles[0]!.text;
    for (const { className } of cases) {
      expect(outputCode).toContain(`function ${className}__classFactory2()`);
    }
    writeFileSync(output, outputCode);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(cases.map((_, index) => `global:${index}`).join('\n') + '\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 60_000);
