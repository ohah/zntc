import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { scanIdentifierConstructors } from '../../../scripts/audit-identifier-constructors.mjs';

const CONSTRUCTOR_FIXTURE = join(import.meta.dir, '../fixtures/identifier-constructor-audit.zig');

describe('identifier constructor source audit', () => {
  test('rejects direct constructors and thirteen compileable tag alias forms', () => {
    const result = scanIdentifierConstructors(
      readFileSync(CONSTRUCTOR_FIXTURE, 'utf8'),
      'src/transformer/audit_probe.zig',
      {},
      new Map(),
    );

    expect(result.violations).toHaveLength(24);
    expect(
      result.violations.filter((violation) => violation.includes('간접 식별자 태그 직접 생성')),
    ).toHaveLength(13);
    expect(result.violations.join('\n')).toContain('identifier_reference 직접 생성');
    expect(result.violations.join('\n')).toContain('assignment_target_identifier 직접 생성');
    expect(result.violations.join('\n')).toContain('binding_identifier 직접 생성');
    expect(result.violations.join('\n')).toContain('jsx_identifier 직접 생성');
    expect(result.violations.join('\n')).toContain('간접 식별자 태그 직접 생성');
    expect(result.violations.join('\n')).toContain('makeBindingIdentifier 직접 호출');
  });

  test('rejects identifier tags assigned through a later variable write', () => {
    const source = `
const Tag = enum { none, identifier_reference, binding_identifier };
fn reassignedTag() void {
  var tag: Tag = .none;
  tag = .identifier_reference;
  const node = .{ .tag = tag };
  _ = node;
}
fn reassignedAliasChain() void {
  var sourceTag: Tag = .none;
  var tag: Tag = .none;
  sourceTag = .binding_identifier;
  tag = sourceTag;
  const node = .{ .tag = tag };
  _ = node;
}
fn conditionalWrite(flag: bool) void {
  var tag: Tag = .none;
  if (flag) {
    tag = .identifier_reference;
  } else {
    tag = .none;
  }
  const node = .{ .tag = tag };
  _ = node;
}
fn overwrittenBySafeTag() void {
  var tag: Tag = .identifier_reference;
  tag = .none;
  const node = .{ .tag = tag };
  _ = node;
}
fn tagWriteAfterUse() void {
  var tag: Tag = .none;
  const node = .{ .tag = tag };
  tag = .identifier_reference;
  _ = node;
}
`;
    const result = scanIdentifierConstructors(
      source,
      'src/transformer/reassigned_tag.zig',
      {},
      new Map(),
    );

    expect(result.violations, result.violations.join('\n')).toHaveLength(3);
    expect(result.violations.join('\n')).toContain(
      'identifier_reference 간접 식별자 태그 직접 생성',
    );
    expect(result.violations.join('\n')).toContain('binding_identifier 간접 식별자 태그 직접 생성');
  });

  test('ignores constructor-shaped text and test-only AST fixtures', () => {
    const source = `
fn safe() void {
  const message = ".tag = .identifier_reference";
  // .tag = .assignment_target_identifier
  _ = message;
}
const Kind = enum { tag, other };
const Result = enum { identifier_reference, other };
fn switchTag(value: Kind) Result {
  return switch (value) {
    .tag => .identifier_reference,
    else => .other,
  };
}
fn aliasSource() void {
  const tag: Result = .identifier_reference;
  _ = tag;
}
const globalTag: Tag = .identifier_reference;
fn safeOtherTag() void {
  const tag: Tag = .none;
  const node = .{ .tag = tag };
  _ = node;
}
fn safeShadowedTag() void {
  const globalTag: Tag = .none;
  const node = .{ .tag = globalTag };
  _ = node;
}
test "fixture only" {
  const node = .{ .tag = .binding_identifier };
  _ = node;
}
`;
    expect(
      scanIdentifierConstructors(source, 'src/transformer/safe.zig', {}, new Map()).violations,
    ).toEqual([]);
  });

  test('test-only function names cannot lend allowlist access to following production code', () => {
    const source = `
test "allowlist spoof" {
  fn makeSyntheticBinding() void {}
}
const node = .{ .tag = .identifier_reference };
`;
    const result = scanIdentifierConstructors(
      source,
      'src/transformer/es_helpers.zig',
      { 'src/transformer/es_helpers.zig::makeSyntheticBinding': 'test-only helper' },
      new Map(),
    );

    expect(result.violations).toHaveLength(1);
    expect(result.violations[0]).toContain('src/transformer/es_helpers.zig::<top>');
  });
});
