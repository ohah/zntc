import {
  afterAll,
  beforeAll,
  build,
  describe,
  expect,
  join,
  test,
  writeFileSync,
} from '../helpers';
import { createEdgeCombinationFixture, type EdgeCombinationFixture } from './fixture';

describe('엣지 케이스 + 조합 보강: React formats', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('React: AMD + external → define 래핑', async () => {
    writeFileSync(
      join(fixture.dir, 'react-amd.tsx'),
      'import React from "react";\nexport const el = React.createElement("div");',
    );
    const result = await build({
      entryPoints: [join(fixture.dir, 'react-amd.tsx')],
      format: 'amd',
      external: ['react'],
      jsx: 'classic',
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('define(["react"]');
    expect(result.outputFiles[0].text).toContain('function(React)');
  });
});
