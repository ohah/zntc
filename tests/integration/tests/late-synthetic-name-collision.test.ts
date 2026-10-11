import { afterEach, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

// #5451: late naming 의 작업용 이름(`_newTarget`·`_super`·`_state`)이 소스 바인딩과 같으면
// 편집기가 이름으로 바인딩을 찾기 때문에 생성 바인딩이 소스 심볼과 엮이거나
// DuplicateBinding 으로 중단된다. 작업용 이름은 충돌을 피하고 최종 이름은 원래 이름에서 정한다.
const cases = [
  {
    name: 'derived and base constructors declare their own _newTarget',
    source: `
      class B { constructor() { this.b = 1; } }
      class D extends B { constructor() { const _newTarget = 'u'; super(); this.v = _newTarget; this.t = new.target === D; } }
      class E { constructor() { const _newTarget = 'e'; this.v = _newTarget; this.t = new.target === E; } }
      const d = new D();
      const e = new E();
      console.log(d.b, d.v, d.t, e.v, e.t);
    `,
    expected: '1 u true e true',
  },
  {
    name: 'static super call next to a source _super',
    source: `
      class Base { static s() { return 'base'; } }
      class D extends Base { static t() { const _super = 'u-s'; return super.s() + _super; } }
      console.log(D.t());
    `,
    expected: 'baseu-s',
  },
  {
    name: 'generator loop next to a source _state',
    source: `
      function* gen() { let _state = 'user-state'; for (const x of [1]) yield x + _state; }
      console.log([...gen()].join());
    `,
    expected: '1user-state',
  },
] as const;

describe('late synthetic names next to same-named source bindings (#5451)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const minify of [false, true]) {
      test(`${fixture.name}, es5${minify ? ', minify' : ''}`, async () => {
        const created = await createFixture({ 'input.mjs': fixture.source });
        cleanup = created.cleanup;
        const output = join(created.dir, 'out.js');
        const result = await runZntc([
          join(created.dir, 'input.mjs'),
          '--target=es5',
          ...(minify ? ['--minify'] : []),
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = await runNode(output);
        expect(run.stdout.trim()).toBe(fixture.expected);
      });
    }
  }
});
