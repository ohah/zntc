import { describe, expect, test } from 'bun:test';
import { runZntc } from './helpers';

// An empty argument (`zntc ""`, an unset shell variable) used to index its
// first byte and panic.
describe('CLI empty argument', () => {
  test('is reported instead of crashing', async () => {
    for (const args of [[''], ['--bundle', ''], ['--bundle', 'entry.js', '']]) {
      const result = await runZntc(args);
      expect(result.exitCode).toBe(1);
      expect(result.stderr).toContain('zntc: empty argument');
      expect(result.stderr).not.toContain('fatal');
    }
  });
});
