// OutputFile 의 contract 검증 — esbuild API 동등:
//   `contents: Uint8Array` (NAPI buffer, byte-level safe)
//   `text: string` (lazy `TextDecoder` getter, reference-aware cache)
//
// 회귀 가드 대상 (배포 안 한 1.0 cleanup 흐름):
//   1. NAPI 가 `napi_create_buffer_copy` 로 contents 노출 (string 아님)
//   2. JS layer 가 `attachTextGetter` 로 lazy text getter 부착
//   3. cached text 가 `file.contents` reassign 시 reference 비교로 자동 invalidate
//      → `postProcessCssOutputs` 의 lightningcss minify 가 in-place 갱신 후에도
//        `file.text` 가 새 byte sequence 를 반영해야 한다.

import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('OutputFile shape contract — contents (Uint8Array) + lazy text getter', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-output-shape-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const greet = (n: string) => `hi, ${n}`;\n');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('buildSync: outputFiles[i].contents 는 Uint8Array, text 는 string getter', () => {
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    const file = result.outputFiles[0];

    expect(file.contents).toBeInstanceOf(Uint8Array);
    expect(typeof file.text).toBe('string');
    expect(file.text.length).toBeGreaterThan(0);
  });

  test('build: outputFiles[i].contents 는 Uint8Array, text 는 string getter', async () => {
    const result = await build({ entryPoints: [join(dir, 'entry.ts')] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    const file = result.outputFiles[0];

    expect(file.contents).toBeInstanceOf(Uint8Array);
    expect(typeof file.text).toBe('string');
    expect(file.text.length).toBeGreaterThan(0);
  });

  test('text 는 contents 의 UTF-8 decode 와 byte-equivalent', () => {
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    const file = result.outputFiles[0];

    const decoded = new TextDecoder('utf-8').decode(file.contents);
    expect(file.text).toBe(decoded);
  });

  test('text 는 lazy + 같은 contents reference 면 동일 string instance 반환 (cache)', () => {
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    const file = result.outputFiles[0];

    const first = file.text;
    const second = file.text;
    // 같은 reference — cached
    expect(second).toBe(first);
  });

  test('contents reassign 후 text 가 새 byte sequence 를 반영 (cache invalidation)', () => {
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    const file = result.outputFiles[0];

    const originalText = file.text;
    // postProcessCssOutputs 의 lightningcss minify 시나리오 — file.contents 를 직접 reassign.
    file.contents = new TextEncoder().encode('// replaced contents');
    expect(file.text).toBe('// replaced contents');
    expect(file.text).not.toBe(originalText);
  });

  test('sourcemap 도 contents/text contract 동일', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
    });
    const smFile = result.outputFiles.find((f) => f.path.endsWith('.map'));
    expect(smFile).toBeDefined();
    expect(smFile!.contents).toBeInstanceOf(Uint8Array);
    const map = JSON.parse(smFile!.text);
    expect(map.version).toBe(3);
  });

  test('write: false 면 outputFiles 만 반환 (디스크 write 없음)', () => {
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')], write: false });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    expect(result.outputFiles[0].contents).toBeInstanceOf(Uint8Array);
  });
});
