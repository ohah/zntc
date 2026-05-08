import { describe, test, expect, runCli } from '../helpers';

describe('CLI: bundle errors', () => {
  test('존재하지 않는 entry → 에러', () => {
    const { exitCode } = runCli(['--bundle', '/nonexistent/entry.ts']);
    expect(exitCode).toBe(1);
  });
});
