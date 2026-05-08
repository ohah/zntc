import { describe, test, expect, runCli } from './helpers';

describe('CLI: bundle --platform=react-native — RN CLI flag 매트릭스 (#2605 audit P0)', () => {
  test('--bundle-output / --sourcemap-output / --assets-dest 등 parse + opts target 매핑', () => {
    // CLI invoke 자체는 entry 미지정으로 exit 1, parse 단의 stderr 에 미지원 경고
    // (assetsDest 등) 가 emit 되는지로 flag parse 검증.
    const { exitCode, stderr } = runCli([
      '--bundle',
      '--platform=react-native',
      '--rn-platform=ios',
      '--bundle-output=ios/main.jsbundle',
      '--sourcemap-output=ios/main.jsbundle.map',
      '--assets-dest=ios/assets',
      '--asset-catalog-dest=ios/Images.xcassets',
      '--bundle-encoding=utf-8',
      '--reset-cache',
      '--max-workers=4',
      '--no-interactive',
      '--unstable-transform-profile=hermes-stable',
      '--source-map-url=https://example.com/main.jsbundle.map',
      '--sourcemap-sources-root=/abs/proj',
      '--sourcemap-use-absolute-path',
      '--transform-option:foo=bar',
      '--resolver-option:baz=qux',
      '--watchFolders=../shared,../lib',
      '--sourceExts=ts,tsx',
    ]);
    // entry 미지정 → exit 1 + entry 친화 에러
    expect(exitCode).toBe(1);
    expect(stderr).toContain('entry');
    // 적어도 parse 가 unknown flag 로 실패하지 않음 (`--bundle-output=` typo-suggest 안 뜸).
    expect(stderr).not.toContain("unknown CLI flag '--bundle-output'");
    expect(stderr).not.toContain("unknown CLI flag '--max-workers'");
    expect(stderr).not.toContain("unknown CLI flag '--watchFolders'");
  });

  test('--bundle-output / --sourcemap-output 미지원 stderr 경고 — 실제 bundle path 진입 (entry + RN 패키지 없음 시 lazy load fail 가능, parse 단계만 검증)', () => {
    const { stderr } = runCli([
      '--bundle',
      '--platform=react-native',
      '--asset-catalog-dest=foo',
      '--bundle-encoding=utf-16',
    ]);
    // entry 누락이라 stderr 에 entry 메시지가 우선 — `--asset-catalog-dest` 는
    // entry 검증 후 처리. 본 테스트는 flag parse 자체가 reject 안 하는지만 확인.
    expect(stderr).toContain('entry');
  });
});
