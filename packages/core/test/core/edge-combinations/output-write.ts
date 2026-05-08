import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  readFileSync,
  rmSync,
  test,
  writeFileSync,
} from '../helpers';
import { createEdgeCombinationFixture, type EdgeCombinationFixture } from './fixture';

describe('엣지 케이스 + 조합 보강: output and write', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('dropLabels + minify: 라벨 제거 후 압축', () => {
    writeFileSync(
      join(fixture.dir, 'label-min.ts'),
      'DEV: { console.log("dev"); }\nexport const x = 1;',
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'label-min.ts')],
      dropLabels: ['DEV'],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('dev');
  });

  test('sourcemap + minify + target: es5', () => {
    const result = buildSync({
      entryPoints: [fixture.simple],
      sourcemap: true,
      minify: true,
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain('mappings');
  });

  test('write + outdir + format: umd', () => {
    const outdir = join(fixture.dir, 'umd-out');
    const result = buildSync({
      entryPoints: [fixture.simple],
      format: 'umd',
      globalName: 'W',
      outdir,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('typeof define');
    rmSync(outdir, { recursive: true, force: true });
  });
});
