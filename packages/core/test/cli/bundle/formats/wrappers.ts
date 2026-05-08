import { describe, test, expect, runCli } from '../../helpers';
import { useBundleFixture } from '../fixture';

describe('CLI: bundle format and wrappers > wrappers', () => {
  const fixture = useBundleFixture();

  test('번들 + --intro/--outro wrapper 내부 텍스트 삽입', () => {
    const { stdout, stderr, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      "--intro=console.log('intro');",
      "--outro=console.log('outro');",
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stdout).toContain("console.log('intro');");
    expect(stdout).toContain("console.log('outro');");
    expect(stdout.indexOf("console.log('intro');")).toBeLessThan(stdout.indexOf('Hello'));
    expect(stdout.indexOf('Hello')).toBeLessThan(stdout.indexOf("console.log('outro');"));
  });
});
