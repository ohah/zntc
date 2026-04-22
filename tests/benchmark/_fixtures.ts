/**
 * 여러 benchmark runner 가 공유하는 fixture 정의.
 * 각 entry 는 `tests/benchmark/node_modules` 아래 실제 의존성을 참조한다.
 */

export interface CommonFixture {
  name: string;
  entry: string;
  platform?: "node" | "browser";
  format?: "esm" | "cjs";
}

export const COMMON_FIXTURES: CommonFixture[] = [
  {
    name: "effect",
    entry: `import { Effect, pipe } from 'effect';
const p = pipe(Effect.succeed(42), Effect.map((n: number) => n + 1));
Effect.runPromise(p).then(r => console.log(r));`,
  },
  {
    name: "lodash-es",
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';
console.log(groupBy, sortBy, uniq);`,
  },
  {
    name: "zod",
    entry: `import { z } from 'zod';
const schema = z.string().email();
console.log(schema.parse('test@test.com'));`,
  },
  {
    name: "rxjs",
    entry: `import { of, map, filter, toArray } from 'rxjs';
of(1,2,3,4,5).pipe(filter(x=>x%2===0), map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
  },
  {
    name: "three",
    entry: `import { Vector3 } from 'three';
const v = new Vector3(1, 2, 3);
console.log(v.length().toFixed(2));`,
  },
  {
    name: "react",
    entry: `import React from 'react';
const el = React.createElement('div', {id:'t'}, 'hi');
console.log(el.type, el.props.id);`,
  },
];
