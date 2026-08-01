// #4602 — 엔진 이름 target(`safari11`, `chrome80,safari14`)이 JS API 에서 조용히 무시되던 회귀.
//
// `build()` 는 `target` 을 그냥 **삭제**해 다운레벨이 일어나지 않았고(무진단·exit 0),
// `transpile()` 은 native DTO 의 `target` 이 ES enum 이라 `invalid options JSON` 으로 죽었다.
// CLI 는 같은 입력을 정상 처리한다 — 같은 옵션이 표면에 따라 다른 결과를 내면 안 된다.
//
// ⚠️ 이 테스트들은 **다운레벨이 실제로 일어났는지**(출력에 `?.` 가 남았는지)로 판정한다.
// "예외가 안 났다" 만 보면 옛 동작(조용한 무시)도 통과한다 — 그게 원래 버그다.

import {
  build,
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  transpile,
  writeFileSync,
} from './helpers';

/** optional chaining 은 es2020 부터 — 그 이전 타겟이면 다운레벨되어 `?.` 가 사라진다. */
const SRC = 'declare const o: any;\nexport const v = o?.a?.b;\n';

function bundleWithTarget(target: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-4602-'));
  try {
    writeFileSync(join(dir, 'entry.ts'), SRC);
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      bundle: true,
      format: 'esm',
      target,
    });
    return r.outputFiles.map((f) => f.text).join('\n');
  } finally {
    rmSync(dir, { recursive: true });
  }
}

describe('@zntc/core 엔진 이름 target (#4602)', () => {
  // 엔진 이름·매트릭스·browserslist 표기·operator 표기 — CLI 가 받는 형태를 모두 덮는다.
  // 예전엔 이 전부가 "다운레벨 없음" 으로 조용히 지나갔다.
  for (const target of [
    'safari11',
    'chrome60',
    'node12',
    'ios12',
    'chrome80,safari14',
    'safari 11',
    'chrome >= 87',
  ]) {
    test(`build: '${target}' 가 실제로 다운레벨된다`, () => {
      expect(bundleWithTarget(target)).not.toContain('?.');
    });

    test(`transpile: '${target}' 가 실제로 다운레벨된다`, () => {
      const r = transpile(SRC, { target, filename: 'entry.ts' });
      expect(r.code).not.toContain('?.');
    });
  }

  // 대조군 — 최신 타겟은 다운레벨하지 않아야 한다. 이게 없으면 "항상 다운레벨" 로 바꿔도
  // 위 테스트가 전부 통과해 가드가 공허해진다.
  test('build: esnext 는 다운레벨하지 않는다 (대조군)', () => {
    expect(bundleWithTarget('esnext')).toContain('?.');
  });

  test('transpile: esnext 는 다운레벨하지 않는다 (대조군)', () => {
    expect(transpile(SRC, { target: 'esnext', filename: 'entry.ts' }).code).toContain('?.');
  });

  // ES 버전 타겟 회귀 방지 — 엔진 경로를 추가하면서 기존 경로가 깨지지 않았는지.
  test('build: es2019 (ES 버전) 은 종전대로 다운레벨된다', () => {
    expect(bundleWithTarget('es2019')).not.toContain('?.');
  });

  // 해석 불가는 **명확히 throw** 해야 한다. 조용히 esnext 로 떨어지면 원래 버그로 되돌아간다.
  for (const bad of ['safari-11', 'nope99']) {
    test(`build: 해석 불가 target '${bad}' 은 throw 한다`, () => {
      expect(() => bundleWithTarget(bad)).toThrow(/unknown target/);
    });
  }

  test('async build 도 엔진 이름 target 을 적용한다', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-4602-async-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), SRC);
      const r = await build({
        entryPoints: [join(dir, 'entry.ts')],
        bundle: true,
        format: 'esm',
        target: 'safari11',
        write: false,
      });
      expect((r.outputFiles ?? []).map((f) => f.text).join('\n')).not.toContain('?.');
    } finally {
      rmSync(dir, { recursive: true });
    }
  });

  // browserslist 가 명시되면 그쪽이 더 구체적이므로 우선한다 — 엔진 target 이 덮어쓰면 안 된다.
  test('browserslist 가 있으면 엔진 target 이 그것을 덮어쓰지 않는다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-4602-bl-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), SRC);
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        bundle: true,
        format: 'esm',
        // browserslist 는 최신 → 다운레벨 없음. target 은 구버전 → 다운레벨.
        // browserslist 가 이기므로 `?.` 가 남아야 한다.
        browserslist: 'chrome 120',
        target: 'safari11',
      });
      expect(r.outputFiles.map((f) => f.text).join('\n')).toContain('?.');
    } finally {
      rmSync(dir, { recursive: true });
    }
  });
});
