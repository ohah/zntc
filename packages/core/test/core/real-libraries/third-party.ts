import { build, describe, expect, test, writeFileSync } from '../helpers';
import { useRealLibraryFixture } from './fixture';

describe('실제 라이브러리 번들링', () => {
  const fixture = useRealLibraryFixture();

  test('lodash-es: tree-shaking으로 번들 크기 축소', async () => {
    writeFileSync(
      fixture.path('lodash-app.ts'),
      'import { chunk } from "lodash-es";\nexport const result = chunk([1,2,3,4], 2);',
    );
    const result = await build({
      entryPoints: [fixture.path('lodash-app.ts')],
      format: 'esm',
      minify: true,
      nodePaths: [fixture.projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text.length).toBeLessThan(50000);
  });
});
