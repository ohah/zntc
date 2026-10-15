import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5840: Flow object types and interfaces may declare getters and setters
// (`{ get x(): number, set x(v: number): void }`), which Hermes and
// flow-parser accept. The member parser knew the `proto` modifier but not
// `get`/`set`, so it read `get` as the key and failed at `x`. `get`/`set`
// used as a key (`{ get: T }`, `{ get(): R }`) must keep working.
const source = `// @flow
type Obj = { get x(): number, set x(v: number): void };
type Exact = {| get a(): string, +b: number |};
interface I { get y(): string; set y(v: string): void }
type Keys = { get: number, set?: string, get(): void, set<T>(v: T): void };
declare class D { get z(): number; set z(v: number): void }
declare export function f(o: Obj): Keys;
const o: Obj = { get x() { return 1; }, set x(v) {} };
console.log(o.x);
`;

describe('Flow object type accessors (#5840)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--bundle'], ['--target=es5']]) {
    test(`parses and strips ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([join(created.dir, 'entry.js'), ...extra, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe('1\n');
    });
  }
});
