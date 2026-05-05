import { describe, expect, test } from 'bun:test';
import { parseProfileJson } from './_runner';

describe('benchmark profile JSON parser', () => {
  test('extracts the profile block when other braces are present', () => {
    const parsed = parseProfileJson(`
      warning: object-like text { not: "json" }
      {
        "profile_version": 1,
        "total_ms": 1.25,
        "level": "summary",
        "phases": {
          "shake": { "total_ms": 1.0, "self_ms": 0.5, "count": 1, "pct": 80, "self_pct": 40 }
        }
      }
      trailing { text }
    `);

    expect(parsed.profile_version).toBe(1);
    expect(parsed.total_ms).toBe(1.25);
    expect(parsed.phases.shake?.total_ms).toBe(1);
  });

  test('handles braces inside JSON strings', () => {
    const parsed = parseProfileJson(`
      {
        "profile_version": 1,
        "total_ms": 0,
        "level": "summary {still string}",
        "phases": {}
      }
    `);

    expect(parsed.level).toBe('summary {still string}');
  });
});
