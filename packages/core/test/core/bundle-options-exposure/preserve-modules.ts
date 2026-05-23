import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

function createPreserveModulesFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-preserve-modules-'));
  writeFileSync(join(dir, 'mod-a.ts'), 'export const a = 1;');
  writeFileSync(join(dir, 'mod-entry.ts'), 'import { a } from "./mod-a";\nexport const b = a + 1;');
  return dir;
}

describe('BundleOptions: 전체 옵션 노출 > preserve modules', () => {
  test('preserveModules: 모듈별 개별 파일 출력', async () => {
    const dir = createPreserveModulesFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'mod-entry.ts')],
        preserveModules: true,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('preserveModulesRoot: 출력 경로 기준', async () => {
    const dir = createPreserveModulesFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'mod-entry.ts')],
        preserveModules: true,
        preserveModulesRoot: dir,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // F8 post-review 회귀 가드: renderChunk plugin hook 의 `chunk_name` 이
  // 실제 *filename 의 stem* 과 동기되어야 한다. 옛 코드는 preserve_modules /
  // explicit_file_name 시 chunkPlaceholderStem 결과 (entry_names 패턴) 만
  // 보내 filename 과 drift — plugin (예: visualizer manifest) 이 chunk_name
  // 으로 path 만들면 실제 파일과 mismatch.
  test('F8: renderChunk 의 chunk_name 이 preserveModules filename stem 과 동기', async () => {
    const dir = createPreserveModulesFixture();
    const capturedNames: string[] = [];
    try {
      const result = await build({
        entryPoints: [join(dir, 'mod-entry.ts')],
        preserveModules: true,
        preserveModulesRoot: dir,
        plugins: [
          {
            name: 'capture-render-chunk',
            setup(build) {
              build.onRenderChunk({ filter: /.*/ }, ({ chunk }) => {
                capturedNames.push(chunk);
                return null;
              });
            },
          },
        ],
      });
      expect(result.errors.length).toBe(0);

      // 각 output 파일의 path stem (ext 제거) 가 renderChunk 가 받은 name 과
      // 정확히 *순수 stem* (확장자 미포함) 으로 일치해야.
      const jsOutputs = result.outputFiles.filter((f) => /\.[mc]?js$/.test(f.path));
      expect(jsOutputs.length).toBeGreaterThanOrEqual(2);

      const filenameStems = jsOutputs.map((f) => f.path.replace(/\.[mc]?js$/, ''));

      // 1:1 invariant — capturedNames cardinality 가 chunks 수와 같아야.
      // renderChunk hook 이 청크당 정확히 1회 호출되는지 가드.
      expect(capturedNames.length).toBe(jsOutputs.length);

      // *순수 stem* 매처 (확장자 포함 형태 reject) — drift 시 'mod-a.js' 같은
      // 확장자 박힌 name 이 들어와도 fail 시켜 회귀 가드 무력화 방지.
      for (const stem of filenameStems) {
        const exactMatch = capturedNames.includes(stem);
        expect(exactMatch).toBe(true);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
