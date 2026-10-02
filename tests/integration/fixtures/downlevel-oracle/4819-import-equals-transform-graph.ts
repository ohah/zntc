import assert = require('node:assert/strict');

const _Source = 'outer';
const _Source2 = 'outer2';

namespace Source {
  export let value = 40;
  export namespace Inner {
    export let value = 40;
  }
  export function add(delta: number) {
    value += delta;
    return value;
  }
}

namespace Container {
  export namespace Nested {
    export let value = 40;
  }
  import NestedAlias = Nested;
  export function add(delta: number) {
    NestedAlias.value += delta;
    return Nested.value;
  }
}

import Alias = Source;
import DeepAlias = Source.Inner;

function shadow(require: (name: string) => string) {
  return require('shadow');
}

assert.equal(
  shadow((name) => name),
  'shadow',
);
assert.equal(Alias.add(2), 42);
assert.equal(DeepAlias.value + 2, 42);
assert.equal(Container.add(2), 42);
assert.equal(Source.value, 42);
assert.equal(_Source, 'outer');
assert.equal(_Source2, 'outer2');
console.log([Alias.value, Source.value, _Source, _Source2].join('|'));
