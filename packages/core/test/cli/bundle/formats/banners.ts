import { describe, test, expect, runCli } from '../../helpers';
import { useBundleFixture } from '../fixture';

describe('CLI: bundle format and wrappers > banners', () => {
  const fixture = useBundleFixture();

  test('번들 + --banner:js + --footer:js (esbuild 호환 alias)', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--banner:js=/* banner */',
      '--footer:js=/* footer */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* banner */');
    expect(stdout).toContain('/* footer */');
  });

  test('번들 + --banner + --footer (정식 형태 — BuildOptions.banner 와 1:1)', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--banner=/* TOP */',
      '--footer=/* BOTTOM */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* TOP */');
    expect(stdout).toContain('/* BOTTOM */');
  });

  test('--banner 가 = 안의 = 도 보존', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--banner=/* key=value */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* key=value */');
  });
});
