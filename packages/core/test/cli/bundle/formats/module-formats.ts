import { describe, test, expect, runCli } from '../../helpers';
import { useBundleFixture } from '../fixture';

describe('CLI: bundle format and wrappers > module formats', () => {
  const fixture = useBundleFixture();

  test('번들 + --format=cjs', () => {
    const { stdout, exitCode } = runCli(['--bundle', fixture.entryPoint(), '--format=cjs']);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('use strict');
  });

  test('번들 + --format=iife', () => {
    const { stdout, exitCode } = runCli(['--bundle', fixture.entryPoint(), '--format=iife']);
    expect(exitCode).toBe(0);
    expect(stdout.includes('(function') || stdout.includes('(()')).toBe(true);
  });
});
