/**
 * NAPI publish 의 platform 매트릭스 단일 source.
 *
 * 새 platform 추가 시 (예: musl, riscv, android):
 *   1. 여기에 entry 추가
 *   2. `packages/core-{name}/` skeleton 생성 (package.json + README)
 *   3. `packages/core/index.ts:getPlatformPackage()` 매핑 추가
 *   4. `.github/workflows/release.yml` 매트릭스에 추가 (이 파일과 sync — YAML 정적 한계)
 *   5. `.github/workflows/ci.yml:napi-package-smoke` 매트릭스도 sync
 *
 * win32 정책: napi-rs/swc/oxc 컨벤션 따름 — MSVC 만 publish, mingw/gnu 안 함
 * (GHA windows-latest = MSVC node 라 install 매칭 자체가 의미 없음).
 */

export interface PlatformTarget {
  /** sub-package suffix (e.g. "linux-x64-gnu"). `@zntc/core-${name}` 가 npm 이름. */
  name: string;
  /** npm `os` 필드 — install 매칭. */
  npmOs: 'linux' | 'darwin' | 'win32';
  /** npm `cpu` 필드. */
  npmCpu: 'x64' | 'arm64' | 'ia32';
  /** npm `libc` 필드 (linux 만). */
  npmLibc?: 'glibc' | 'musl';
  /** `zig build napi -Dtarget=<zigTarget>` */
  zigTarget: string;
  /** GitHub Actions runner — release.yml/ci.yml 매트릭스에서도 동일 사용. */
  ghaRunner: string;
}

export const PLATFORMS: PlatformTarget[] = [
  {
    name: 'linux-x64-gnu',
    npmOs: 'linux',
    npmCpu: 'x64',
    npmLibc: 'glibc',
    zigTarget: 'x86_64-linux-gnu',
    ghaRunner: 'ubuntu-latest',
  },
  {
    name: 'linux-arm64-gnu',
    npmOs: 'linux',
    npmCpu: 'arm64',
    npmLibc: 'glibc',
    zigTarget: 'aarch64-linux-gnu',
    ghaRunner: 'ubuntu-24.04-arm',
  },
  {
    name: 'linux-x64-musl',
    npmOs: 'linux',
    npmCpu: 'x64',
    npmLibc: 'musl',
    zigTarget: 'x86_64-linux-musl',
    ghaRunner: 'ubuntu-latest',
  },
  {
    name: 'linux-arm64-musl',
    npmOs: 'linux',
    npmCpu: 'arm64',
    npmLibc: 'musl',
    zigTarget: 'aarch64-linux-musl',
    ghaRunner: 'ubuntu-24.04-arm',
  },
  {
    name: 'darwin-x64',
    npmOs: 'darwin',
    npmCpu: 'x64',
    zigTarget: 'x86_64-macos',
    ghaRunner: 'macos-15-intel',
  },
  {
    name: 'darwin-arm64',
    npmOs: 'darwin',
    npmCpu: 'arm64',
    zigTarget: 'aarch64-macos',
    ghaRunner: 'macos-latest',
  },
  {
    name: 'win32-x64-msvc',
    npmOs: 'win32',
    npmCpu: 'x64',
    zigTarget: 'x86_64-windows-msvc',
    ghaRunner: 'windows-latest',
  },
  {
    name: 'win32-arm64-msvc',
    npmOs: 'win32',
    npmCpu: 'arm64',
    zigTarget: 'aarch64-windows-msvc',
    ghaRunner: 'windows-11-arm',
  },
  {
    name: 'win32-ia32-msvc',
    npmOs: 'win32',
    npmCpu: 'ia32',
    zigTarget: 'x86-windows-msvc',
    ghaRunner: 'windows-latest',
  },
];

export function subPackageName(platform: PlatformTarget): string {
  return `@zntc/core-${platform.name}`;
}

export function subPackageDir(platform: PlatformTarget): string {
  return `packages/core-${platform.name}`;
}

/**
 * findAddon() 의 "Supported: ..." 에러 메시지용 — PLATFORMS 변경 시 자동 반영.
 * 동일 (os, cpu) 에 glibc/musl 둘 다 있으면 "(glibc/musl)" 로 합쳐 표기.
 */
export function formatSupportedPlatforms(): string {
  const groups = new Map<string, string[]>();
  for (const p of PLATFORMS) {
    const key = `${p.npmOs}-${p.npmCpu}`;
    if (!groups.has(key)) groups.set(key, []);
    if (p.npmLibc) groups.get(key)!.push(p.npmLibc);
  }
  return Array.from(groups, ([key, libcs]) =>
    libcs.length > 0 ? `${key} (${libcs.join('/')})` : key,
  ).join(', ');
}
