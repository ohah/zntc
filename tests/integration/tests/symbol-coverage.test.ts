// 트랜스포머가 새로 만든 **사용자 변수** 식별자는 모두 원래 심볼을 가져야 한다 (#4760 게이트).
//
// 심볼이 빠지면 심볼 기준 리네임(es5 블록 스코핑·번들 이름 충돌 회피)이 그 노드만 옛 이름으로
// 남겨 없는 변수를 가리키고, **다른 변수의** 심볼이 붙으면 엉뚱한 변수를 따라간다. 식별자 생성은
// `scripts/audit-identifier-constructors.mjs` 가 분류 생성 함수로만 하게 막지만, 그 함수에 원래
// 노드를 잘못(`.none`·다른 노드) 넘기는 것까지는 못 막는다 — 이 테스트가 그 값 수준을 지킨다.
//
// 다운레벨 오라클의 JS·TypeScript·Flow fixture 전체 × 타깃에서 단일 파일 변환을 돌려 누락 검사기
// (`ZNTC_DEBUG_SYMBOL_COVERAGE`) 와 합성 변수까지 포함한 exact identity 감사가 깨끗한지 본다.
// transform 직후 exact 검사와 minify 후 최종 AST 재분석 identity 검사를 함께 확인한다.
import { describe, test, expect } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  closeSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import ts from 'typescript';
import { ZNTC_BIN, ZNTC_JS_CLI } from './helpers';

const FIXTURE_DIR = join(import.meta.dir, '../fixtures/downlevel-oracle');
const TARGETS = [
  { name: 'es5', arg: '--target=es5' },
  { name: 'es2015', arg: '--target=es2015' },
  { name: 'es2017', arg: '--target=es2017' },
  { name: 'es2022', arg: '--target=es2022' },
  { name: 'esnext', arg: '--target=esnext' },
  { name: 'hermes', arg: '--platform=react-native' },
];
const MINIFY_TARGETS = TARGETS;
const MINIFY_MODES = [
  ['--minify-syntax'],
  ['--minify-identifiers'],
  ['--minify-syntax', '--minify-identifiers'],
] as const;
const EXACT_ZERO_COUNTERS = [
  'invalid_id',
  'invalid_reference_node',
  'unreachable_reference',
  'ambiguous_ast_parent',
  'cyclic_ast_edges',
  'invalid_ast_root',
  'invalid_ast_edge',
  'invalid_ast_layout',
  'shadowed_external_reference',
  'duplicate_reference',
  'identity_mismatch',
  'binding_scope_mismatch',
  'binding_scope_unknown',
  'invalid_scope',
  'reference_scope_mismatch',
  'reference_statement_mismatch',
  'reference_scope_statement_alias',
  'reference_node_use_alias',
  'declaration_scope_mismatch',
  'declaration_identity_mismatch',
  'declaration_anchor_mismatch',
  'scope_map_mismatch',
  'scope_owner_mismatch',
  'scope_owner_parent_mismatch',
  'duplicate_scope_owner',
  'namespace_iife_param_mismatch',
  'enum_iife_param_mismatch',
  'helper_symbol_mismatch',
  'scope_resolution_mismatch',
  'invisible_reference',
  'reference_count_mismatch',
  'write_count_mismatch',
  'missing_binding',
  'missing_reference',
  'unclassified_reference',
];
const STRICT_ZERO_COUNTERS = [
  'missing_binding',
  'invalid_id',
  'name_mismatch',
  'missing_reference',
  'identity_mismatch',
  'invalid_scope',
  'scope_unknown',
  'scope_ambiguous',
  'unclassified',
  'invisible_reference',
  'duplicate_reference',
  'orphan_symbols',
  'cyclic_ast_edges',
];
const STRICT_METRIC_FIELDS = ['bound', 'external', 'scope_mismatch', 'marked_synthetic'] as const;
const STRICT_BOOLEAN_FIELDS = ['consistent', 'symbol_identity_complete'] as const;
const STRICT_REPORT_FIELDS = [
  ...STRICT_METRIC_FIELDS,
  ...STRICT_ZERO_COUNTERS,
  ...STRICT_BOOLEAN_FIELDS,
] as const;
const EXACT_SINGLETON_FIELDS = [
  ['generated_bindings', '\\d+'],
  ['generated_references', '\\d+'],
  ['external', '\\d+'],
  ['declaration_anchors_checked', '\\d+'],
  ['namespace_iife_params', '\\d+'],
  ['enum_iife_params', '\\d+'],
  ['clean', '\\d+'],
  ['legacy_debt_fingerprint', '[0-9a-fA-F]+'],
  ['schema_fingerprint', '[0-9a-fA-F]+'],
] as const;
const EXACT_REPORT_SCHEMA_FINGERPRINT = 'eb9b778e9933c134';
const EXACT_OBSERVATION_FIELD_COUNT = 7;
const EXACT_DIAGNOSTIC_FIELD_COUNT = 16;
const EXACT_SCHEMA_FIELDS = new Set<string>([
  'invariant_counter_count',
  'observation_field_count',
  'diagnostic_field_count',
  ...EXACT_SINGLETON_FIELDS.map(([field]) => field),
  ...EXACT_ZERO_COUNTERS,
]);
const POST_MINIFY_OBSERVATION_FIELDS = [
  'bindings',
  'references',
  'external',
  'helpers',
  'preserved_transform_refs',
] as const;
const POST_MINIFY_ZERO_COUNTERS = [
  'invalid_binding_id',
  'invalid_reference_id',
  'missing_binding_id',
  'missing_reference_id',
  'dangling_reference_id',
  'wrong_reference_target',
  'shadowed_external_reference',
  'unproven_external_reference',
] as const;
const POST_MINIFY_SCHEMA_FIELDS = new Set<string>([
  ...POST_MINIFY_OBSERVATION_FIELDS,
  ...POST_MINIFY_ZERO_COUNTERS,
  'clean',
]);
const SOURCE_SCOPE_OWNER_ZERO_COUNTERS = [
  'scope_owner_mismatch',
  'scope_owner_parent_mismatch',
  'duplicate_scope_owner',
];
const SOURCE_SCOPE_OWNER_SCHEMA_FIELDS = new Set<string>(SOURCE_SCOPE_OWNER_ZERO_COUNTERS);

function expectCjsWrapperModuleParamMatchesBody(bundle: string, moduleId: string) {
  const escapedModuleId = moduleId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const wrapper = bundle.match(
    new RegExp(`"${escapedModuleId}"\\(([^,]+),\\s*([^)]+)\\) \\{([\\s\\S]*?)\\n\\t\\}\\n\\}\\);`),
  );
  expect(wrapper, `${moduleId}: CommonJS wrapper missing`).not.toBeNull();
  const moduleParam = wrapper?.[2].trim();
  expect(wrapper?.[3], `${moduleId}: wrapper body missing`).toContain(`${moduleParam}.exports`);
}

function exactKnownValueProblems(identity: string): string[] {
  const expectations = [
    ['invariant_counter_count', EXACT_ZERO_COUNTERS.length],
    ['observation_field_count', EXACT_OBSERVATION_FIELD_COUNT],
    ['diagnostic_field_count', EXACT_DIAGNOSTIC_FIELD_COUNT],
  ] as const;
  const problems = expectations.flatMap(([field, expected]) => {
    const value = identity.match(new RegExp(`(?:^| )${field}=(\\d+)(?: |$)`))?.[1];
    return value === undefined || Number(value) !== expected
      ? [`${field}=${value ?? 'missing'}, expected ${expected}`]
      : [];
  });
  const schemaFingerprint = identity
    .match(/(?:^| )schema_fingerprint=([0-9a-fA-F]+)(?: |$)/)?.[1]
    ?.toLowerCase();
  if (schemaFingerprint !== EXACT_REPORT_SCHEMA_FINGERPRINT) {
    problems.push(
      `schema_fingerprint=${schemaFingerprint ?? 'missing'}, expected ${EXACT_REPORT_SCHEMA_FINGERPRINT}`,
    );
  }
  for (const [field, valuePattern] of EXACT_SINGLETON_FIELDS) {
    const matches =
      identity.match(new RegExp('(?:^| )' + field + `=(${valuePattern})(?=\\s|$)`, 'g')) ?? [];
    if (matches.length !== 1) {
      problems.push(field + ' occurrences=' + matches.length + ', expected 1');
    }
  }
  for (const counter of EXACT_ZERO_COUNTERS) {
    const matches = identity.match(new RegExp('(?:^| )' + counter + '=(\\d+)(?=\\s|$)', 'g')) ?? [];
    if (matches.length !== 1) {
      problems.push(counter + ' occurrences=' + matches.length + ', expected 1');
      continue;
    }
    const value = matches[0].match(/=(\d+)/)?.[1] ?? 'missing';
    if (value !== '0') problems.push(counter + '=' + value + ', expected 0');
  }
  return problems;
}

function exactSchemaProblems(identity: string): string[] {
  const isReportLine =
    identity.startsWith('zntc: symbol-identity ') ||
    identity.startsWith('zntc: symbol-identity-prepass ');
  const payloadMarker = ': generated_bindings=';
  const payloadMarkerIndex = isReportLine ? identity.lastIndexOf(payloadMarker) : -1;
  if (isReportLine && payloadMarkerIndex === -1) {
    return ['missing exact report payload'];
  }
  const payload = payloadMarkerIndex === -1 ? identity : identity.slice(payloadMarkerIndex + 2);
  const problems = exactKnownValueProblems(payload);
  const counts = new Map<string, number>();
  const values = new Map<string, string>();
  for (const token of payload.trim().split(/\s+/)) {
    const match = token.match(/^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/);
    if (!match) {
      problems.push('malformed exact report field ' + token);
      continue;
    }
    const [, field, value] = match;
    counts.set(field, (counts.get(field) ?? 0) + 1);
    values.set(field, value);
    if (!EXACT_SCHEMA_FIELDS.has(field)) {
      problems.push('unexpected exact report field ' + field);
      continue;
    }
    const valuePattern =
      field === 'legacy_debt_fingerprint' || field === 'schema_fingerprint'
        ? /^[0-9a-fA-F]+$/
        : /^\d+$/;
    if (!valuePattern.test(value)) {
      problems.push('malformed exact report value ' + field + '=' + value);
    }
  }

  for (const field of EXACT_SCHEMA_FIELDS) {
    const occurrences = counts.get(field) ?? 0;
    if (occurrences !== 1) {
      problems.push(field + ' occurrences=' + occurrences + ', expected 1');
    } else if (field === 'clean' && values.get(field) !== '1') {
      problems.push('clean=' + values.get(field) + ', expected 1');
    }
  }
  return problems;
}

function postMinifySchemaProblems(report: string): string[] {
  const isReportLine = report.startsWith('zntc: symbol-identity-post-minify ');
  const payloadMarker = ': bindings=';
  const payloadMarkerIndex = isReportLine ? report.lastIndexOf(payloadMarker) : -1;
  if (isReportLine && payloadMarkerIndex === -1) {
    return ['missing post-minify report payload'];
  }
  if (!isReportLine) return ['missing post-minify report'];

  const payload = report.slice(payloadMarkerIndex + 2);
  const counts = new Map<string, number>();
  const values = new Map<string, string>();
  const problems: string[] = [];
  for (const token of payload.trim().split(/\s+/)) {
    const match = token.match(/^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/);
    if (!match) {
      problems.push('malformed post-minify report field ' + token);
      continue;
    }
    const [, field, value] = match;
    counts.set(field, (counts.get(field) ?? 0) + 1);
    values.set(field, value);
    if (!POST_MINIFY_SCHEMA_FIELDS.has(field)) {
      problems.push('unexpected post-minify report field ' + field);
    } else if (!/^\d+$/.test(value)) {
      problems.push('malformed post-minify report value ' + field + '=' + value);
    }
  }

  for (const field of POST_MINIFY_SCHEMA_FIELDS) {
    const occurrences = counts.get(field) ?? 0;
    if (occurrences !== 1) {
      problems.push(field + ' occurrences=' + occurrences + ', expected 1');
      continue;
    }
    if (POST_MINIFY_ZERO_COUNTERS.includes(field as (typeof POST_MINIFY_ZERO_COUNTERS)[number])) {
      if (values.get(field) !== '0')
        problems.push(field + '=' + values.get(field) + ', expected 0');
    } else if (field === 'clean' && values.get(field) !== '1') {
      problems.push('clean=' + values.get(field) + ', expected 1');
    }
  }
  return problems;
}

function postMinifyAuditProblems(stderr: string): string[] {
  const audits = stderr
    .split(/\r?\n/)
    .filter((line) => line.startsWith('zntc: symbol-identity-post-minify '));
  if (audits.length !== 1) {
    return [`post-minify reports=${audits.length}, expected 1`];
  }
  return postMinifySchemaProblems(audits[0]);
}

function strictSchemaProblems(report: string): string[] {
  if (!report.startsWith('zntc: synthetic-coverage ')) return ['missing strict report'];
  const payloadStart = report.lastIndexOf(': bound=');
  if (payloadStart === -1) return ['missing strict report payload'];

  const expectedFields = new Set<string>(STRICT_REPORT_FIELDS);
  const counts = new Map<string, number>();
  const values = new Map<string, string>();
  const problems: string[] = [];
  const payload = report.slice(payloadStart + 2);
  for (const token of payload.trim().split(/\s+/)) {
    const match = token.match(/^([A-Za-z_][A-Za-z0-9_]*)=(\d+)$/);
    if (!match) {
      problems.push(`malformed strict report field ${token}`);
      continue;
    }
    const [, field, value] = match;
    counts.set(field, (counts.get(field) ?? 0) + 1);
    values.set(field, value);
    if (!expectedFields.has(field)) problems.push(`unexpected strict report field ${field}`);
  }

  for (const field of STRICT_REPORT_FIELDS) {
    const occurrences = counts.get(field) ?? 0;
    if (occurrences !== 1) {
      problems.push(`${field} occurrences=${occurrences}, expected 1`);
      continue;
    }
    const value = values.get(field);
    const expected = STRICT_ZERO_COUNTERS.includes(field as (typeof STRICT_ZERO_COUNTERS)[number])
      ? '0'
      : STRICT_BOOLEAN_FIELDS.includes(field as (typeof STRICT_BOOLEAN_FIELDS)[number])
        ? '1'
        : undefined;
    if (expected !== undefined && value !== expected) {
      problems.push(`${field}=${value ?? 'missing'}, expected ${expected}`);
    }
  }
  return problems;
}

function scopeOwnerCounterProblems(audit: string): string[] {
  return SOURCE_SCOPE_OWNER_ZERO_COUNTERS.flatMap((counter) => {
    const matches = audit.match(new RegExp(`(?:^| )${counter}=(\\d+)(?=\\s|$)`, 'g')) ?? [];
    if (matches.length !== 1) return [`${counter} occurrences=${matches.length}, expected 1`];
    const value = matches[0].match(/=(\d+)/)?.[1] ?? 'missing';
    return value === '0' ? [] : [`${counter}=${value}, expected 0`];
  });
}

function scopeOwnerAuditProblems(audit: string): string[] {
  const isReportLine = audit.startsWith('zntc: symbol-source-scope-owner ');
  const payloadMarkers = [
    ': scope_owner_mismatch=',
    ': scope_owner_parent_mismatch=',
    ': duplicate_scope_owner=',
  ];
  const payloadMarkerIndex = isReportLine
    ? Math.max(...payloadMarkers.map((marker) => audit.lastIndexOf(marker)))
    : -1;
  if (isReportLine && payloadMarkerIndex === -1) {
    return ['missing source scope-owner audit payload'];
  }
  const payload = payloadMarkerIndex === -1 ? audit : audit.slice(payloadMarkerIndex + 2);
  const problems = scopeOwnerCounterProblems(payload);
  const counts = new Map<string, number>();
  for (const token of payload.trim().split(/\s+/)) {
    const match = token.match(/^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/);
    if (!match) {
      problems.push('malformed source scope-owner field ' + token);
      continue;
    }
    const [, field, value] = match;
    counts.set(field, (counts.get(field) ?? 0) + 1);
    if (!SOURCE_SCOPE_OWNER_SCHEMA_FIELDS.has(field)) {
      problems.push('unexpected source scope-owner field ' + field);
    } else if (!/^\d+$/.test(value)) {
      problems.push('malformed source scope-owner value ' + field + '=' + value);
    }
  }
  for (const field of SOURCE_SCOPE_OWNER_SCHEMA_FIELDS) {
    const occurrences = counts.get(field) ?? 0;
    if (occurrences !== 1) {
      problems.push(field + ' occurrences=' + occurrences + ', expected 1');
    }
  }
  return problems;
}

// The exact audit above owns transform-aware binding-scope validation. The
// synthetic diagnostic intentionally uses a simpler emitted-scope trace, so
// its raw scope_mismatch counter can include retained source scopes for
// lowered `var` bindings. Its unbound references are external only when exact
// NodeIndex provenance points to an analyzer-unresolved or explicit-global node.

// Fail closed if a new source extension would otherwise be omitted from the matrix.
function collectFixtures(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) return collectFixtures(path);
      if (!entry.isFile()) throw new Error(`unsupported downlevel-oracle fixture entry: ${path}`);
      if (!/\.(?:mjs|js|cjs|ts|mts|cts|tsx|jsx|flow)$/.test(entry.name)) {
        throw new Error(`unsupported downlevel-oracle fixture extension: ${path}`);
      }
      return [path];
    })
    .sort();
}

function fixtureContentFingerprint(files: string[], directory: string): string {
  const fingerprint = createHash('sha256');
  for (const file of files) {
    fingerprint
      .update(relative(directory, file).replaceAll('\\', '/'))
      .update('\0')
      .update(readFileSync(file))
      .update('\0');
  }
  return fingerprint.digest('hex');
}

function runCoverage(
  file: string,
  target: (typeof TARGETS)[number],
  outDir: string,
  minifyIdentifiers = false,
): { stderr: string; exitCode: number } {
  const stderrPath = join(outDir, 'stderr.log');
  const isFlow = file.endsWith('.flow.mjs') || file.endsWith('.flow');
  const stderrFd = openSync(stderrPath, 'w');
  const proc = spawnSync(
    ZNTC_BIN,
    [
      file,
      target.arg,
      ...(isFlow ? ['--flow'] : []),
      ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
      '-o',
      join(outDir, 'out.js'),
    ],
    {
      env: {
        ...process.env,
        ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      stdio: ['ignore', 'ignore', stderrFd],
    },
  );
  closeSync(stderrFd);
  return {
    stderr: readFileSync(stderrPath, 'utf8'),
    exitCode: proc.status ?? -1,
  };
}

function transformIdentityAuditProblems(stderr: string): string[] {
  const lines = stderr.split(/\r?\n/);
  const problems: string[] = [];
  const exact = lines.filter((line) => line.startsWith('zntc: symbol-identity '));
  if (exact.length !== 1) {
    problems.push(`exact identity reports=${exact.length}, expected 1`);
  } else {
    problems.push(...exactSchemaProblems(exact[0]));
  }

  const owners = lines.filter((line) => line.startsWith('zntc: symbol-source-scope-owner '));
  if (owners.length !== 1) {
    problems.push(`source scope-owner reports=${owners.length}, expected 1`);
  } else {
    problems.push(...scopeOwnerAuditProblems(owners[0]));
  }

  const coverage = lines.filter((line) => line.startsWith('zntc: symbol-coverage '));
  if (coverage.length !== 1) {
    problems.push(`symbol coverage reports=${coverage.length}, expected 1`);
  } else {
    const match = coverage[0].match(/(?:^| )missing=(\d+) wrong=(\d+)(?: |$)/);
    if (!match) {
      problems.push(`malformed symbol coverage report: ${coverage[0]}`);
    } else if (match[1] !== '0' || match[2] !== '0') {
      problems.push(`symbol coverage missing=${match[1]} wrong=${match[2]}`);
    }
  }

  const strict = lines.filter((line) => line.startsWith('zntc: synthetic-coverage '));
  if (strict.length !== 1) {
    problems.push(`strict synthetic coverage reports=${strict.length}, expected 1`);
  } else {
    problems.push(...strictSchemaProblems(strict[0]));
  }
  return problems;
}

describe('symbol identity coverage gate (#4819)', () => {
  const fixtures = collectFixtures(FIXTURE_DIR);

  // Pin the matrix surface; deriving the expected run count only from these
  // arrays would let a removed fixture or target silently shrink the gate.
  test('oracle fixture and target inventory cannot shrink silently', () => {
    const fixtureNames = fixtures.map((file) => relative(FIXTURE_DIR, file).replaceAll('\\', '/'));
    const fixtureInventory = createHash('sha256')
      .update(fixtureNames.join('\n') + '\n')
      .digest('hex');
    expect(fixtureNames).toHaveLength(298);
    expect(fixtureInventory).toBe(
      'e87df13e5570d8a5f69589ee7758090627a211ad12ab003968362d28a75bf879',
    );
    expect(fixtureContentFingerprint(fixtures, FIXTURE_DIR)).toBe(
      '72466bb609b5ea43fd2562d6e6777c540f704c22c3ffa937c082f5b5aff7d423',
    );
    expect(TARGETS).toEqual([
      { name: 'es5', arg: '--target=es5' },
      { name: 'es2015', arg: '--target=es2015' },
      { name: 'es2017', arg: '--target=es2017' },
      { name: 'es2022', arg: '--target=es2022' },
      { name: 'esnext', arg: '--target=esnext' },
      { name: 'hermes', arg: '--platform=react-native' },
    ]);
    expect(MINIFY_TARGETS).toEqual(TARGETS);
    expect(MINIFY_MODES).toEqual([
      ['--minify-syntax'],
      ['--minify-identifiers'],
      ['--minify-syntax', '--minify-identifiers'],
    ]);
  });

  test('oracle fixture fingerprint changes when a case body is removed', () => {
    const directory = mkdtempSync(join(tmpdir(), 'zntc-symcov-content-fingerprint-'));
    const fixture = join(directory, 'case.mjs');
    try {
      writeFileSync(fixture, 'const sourceBinding = 1; console.log(sourceBinding);\n');
      const namesBefore = collectFixtures(directory).map((file) => relative(directory, file));
      const fingerprintBefore = fixtureContentFingerprint(collectFixtures(directory), directory);

      writeFileSync(fixture, 'console.log(1);\n');
      const namesAfter = collectFixtures(directory).map((file) => relative(directory, file));
      const fingerprintAfter = fixtureContentFingerprint(collectFixtures(directory), directory);

      expect(namesAfter).toEqual(namesBefore);
      expect(fingerprintAfter).not.toBe(fingerprintBefore);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test('report selection ignores marker text embedded in diagnostic paths', () => {
    const lines = [
      'zntc: symbol-source-scope-owner /tmp/symbol-coverage-worktree/input.mjs: scope_owner_mismatch=0 scope_owner_parent_mismatch=0 duplicate_scope_owner=0',
      'zntc: symbol-coverage /tmp/symbol-coverage-worktree/input.mjs: new_user_idents=0 missing=0 wrong=0',
      'zntc: symbol-identity /tmp/symbol-coverage-worktree/input.mjs: clean=1',
      'zntc: symbol-identity-detail /tmp/zntc: symbol-identity /tmp/input.mjs: clean=1',
      'zntc: synthetic-coverage-detail /tmp/zntc: synthetic-coverage /tmp/input.mjs: symbol_identity_complete=1',
      'zntc: symbol-source-scope-owner-detail /tmp/zntc: symbol-source-scope-owner /tmp/input.mjs: scope_owner_mismatch=0 scope_owner_parent_mismatch=0 duplicate_scope_owner=0',
    ];
    expect(lines.filter((line) => line.startsWith('zntc: symbol-coverage '))).toEqual([lines[1]]);
    expect(lines.filter((line) => line.startsWith('zntc: symbol-identity '))).toEqual([lines[2]]);
    expect(lines.filter((line) => line.startsWith('zntc: synthetic-coverage '))).toEqual([]);
    expect(lines.filter((line) => line.startsWith('zntc: symbol-source-scope-owner '))).toEqual([
      lines[0],
    ]);
  });

  test('source scope-owner gate rejects wrong owner kinds with a valid parent', () => {
    const clean =
      'zntc: symbol-source-scope-owner input.js: scope_owner_mismatch=0 scope_owner_parent_mismatch=0 duplicate_scope_owner=0';
    expect(scopeOwnerAuditProblems(clean)).toEqual([]);
    expect(
      scopeOwnerAuditProblems(clean.replace('scope_owner_mismatch=0', 'scope_owner_mismatch=1')),
    ).toContain('scope_owner_mismatch=1, expected 0');
    expect(
      scopeOwnerAuditProblems(
        clean.replace('scope_owner_parent_mismatch=0', 'scope_owner_parent_mismatch=1'),
      ),
    ).toContain('scope_owner_parent_mismatch=1, expected 0');
    expect(
      scopeOwnerAuditProblems(clean.replace('duplicate_scope_owner=0', 'duplicate_scope_owner=1')),
    ).toContain('duplicate_scope_owner=1, expected 0');
    expect(scopeOwnerAuditProblems(clean.replace(' duplicate_scope_owner=0', ''))).toContain(
      'duplicate_scope_owner occurrences=0, expected 1',
    );
    expect(
      scopeOwnerAuditProblems(
        clean.replace('duplicate_scope_owner=0', 'duplicate_scope_owner=0 duplicate_scope_owner=0'),
      ),
    ).toContain('duplicate_scope_owner occurrences=2, expected 1');
    expect(
      scopeOwnerAuditProblems(
        clean.replace('duplicate_scope_owner=0', 'duplicate_scope_owner=bad'),
      ),
    ).toContain('malformed source scope-owner value duplicate_scope_owner=bad');
    expect(scopeOwnerAuditProblems(clean.replace('scope_owner_mismatch=0 ', ''))).toContain(
      'scope_owner_mismatch occurrences=0, expected 1',
    );
    expect(
      scopeOwnerAuditProblems(
        clean.replace('scope_owner_mismatch=0', 'scope_owner_mismatch=0 scope_owner_mismatch=0'),
      ),
    ).toContain('scope_owner_mismatch occurrences=2, expected 1');
    expect(scopeOwnerAuditProblems(clean + ' future_scope_owner=0')).toContain(
      'unexpected source scope-owner field future_scope_owner',
    );
    expect(scopeOwnerAuditProblems(clean + ' malformed')).toContain(
      'malformed source scope-owner field malformed',
    );
    expect(
      scopeOwnerAuditProblems(clean.replace('scope_owner_mismatch=0', 'scope_owner_mismatch=bad')),
    ).toContain('malformed source scope-owner value scope_owner_mismatch=bad');
    const pathWithCounterText =
      'zntc: symbol-source-scope-owner /tmp/input: scope_owner_mismatch=3.js: scope_owner_mismatch=0 scope_owner_parent_mismatch=0 duplicate_scope_owner=0';
    expect(scopeOwnerAuditProblems(pathWithCounterText)).toEqual([]);
    expect(
      scopeOwnerAuditProblems('zntc: symbol-source-scope-owner input.js: missing=0'),
    ).toContain('missing source scope-owner audit payload');
  });

  test('Flow component wrapper owns its synthetic implementation function scope', () => {
    const file = join(FIXTURE_DIR, '4819-flow-component.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-component-owner-'));
    try {
      for (const target of TARGETS) {
        const { stderr, exitCode } = runCoverage(file, target, outDir);
        expect(exitCode, `${target.name}: ${stderr}`).toBe(0);
        const audits = stderr
          .split('\n')
          .filter((line) => line.startsWith('zntc: symbol-source-scope-owner '));
        expect(audits, `${target.name}: ${stderr}`).toHaveLength(1);
        expect(scopeOwnerAuditProblems(audits[0]), `${target.name}: ${stderr}`).toEqual([]);
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('dynamic body wrapper keeps exact scopes after moving object-rest defaults (#4819)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-dynamic-param-body-scope-'));
    const file = join(dir, 'input.mjs');
    const outDir = join(dir, 'out');
    mkdirSync(outDir);
    try {
      writeFileSync(
        file,
        [
          'let outside = 3;',
          'function run({ a, ...rest }, value = outside) {',
          '  var outside = 4;',
          '  eval("outside");',
          '  return [a, value, outside, rest.b];',
          '}',
          'function sameName({ a, ...rest }, value = outside) {',
          '  var outside = 4, a;',
          '  eval("a");',
          '  return [a, value, outside, rest.b];',
          '}',
          'function sameNameClosure({ a, ...rest }, read = () => a) {',
          '  var a;',
          '  eval("a = 11");',
          '  return [a, read(), rest.b];',
          '}',
          'function* generator({ a, ...rest }, value = outside) {',
          '  var outside = 4, a;',
          '  eval("a = 9; outside");',
          '  yield [a, value, outside, rest.b];',
          '}',
          'function parameterEval({ a, ...rest }, value = eval("outside")) {',
          '  var outside = 4;',
          '  eval("outside");',
          '  return [a, value, outside, rest.b];',
          '}',
          'function parenthesizedParameterEval({ a, ...rest }, value = ((eval))("outside")) {',
          '  var outside = 4;',
          '  return [a, value, outside, rest.b];',
          '}',
          'function escapedParameterEval({ a, ...rest }, value = \\u0065val("outside")) {',
          '  var outside = 4;',
          '  return [a, value, outside, rest.b];',
          '}',
          'console.log(JSON.stringify([run({ a: 1, b: 2 }), sameName({ a: 7, b: 8 }), sameNameClosure({ a: 12, b: 13 }), Array.from(generator({ a: 1, b: 2 })), parameterEval({ a: 1, b: 2 }), parenthesizedParameterEval({ a: 1, b: 2 }), escapedParameterEval({ a: 1, b: 2 })]));',
        ].join('\n'),
      );
      const baseline = spawnSync('node', [file], { encoding: 'utf8' });
      expect(baseline.status, baseline.stderr).toBe(0);

      const { stderr, exitCode } = runCoverage(file, TARGETS[2], outDir);
      expect(exitCode, stderr).toBe(0);
      const exact = stderr.split(/\r?\n/).find((line) => line.startsWith('zntc: symbol-identity '));
      expect(exact, stderr).toBeDefined();
      expect(exactSchemaProblems(exact ?? ''), stderr).toEqual([]);
      expect(exact, stderr).toMatch(/clean=1(?:\s|$)/);

      const owner = stderr
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-source-scope-owner '));
      expect(owner, stderr).toBeDefined();
      expect(scopeOwnerAuditProblems(owner ?? ''), stderr).toEqual([]);

      const synthetic = stderr
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: synthetic-coverage '));
      expect(synthetic, stderr).toBeDefined();
      expect(strictSchemaProblems(synthetic ?? ''), stderr).toEqual([]);
      expect(synthetic, stderr).toMatch(/consistent=1(?:\s|$).*symbol_identity_complete=1(?:\s|$)/);

      const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(baseline.stdout);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('with in a function body keeps moved defaults outside the body environment (#4819)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-dynamic-param-with-scope-'));
    const file = join(dir, 'input.js');
    const outDir = join(dir, 'out');
    mkdirSync(outDir);
    try {
      writeFileSync(
        file,
        [
          'var outside = 3;',
          'function run({ a, ...rest }, value = outside) {',
          '  var outside = 4;',
          '  with ({ outside: 9 }) { value = outside; }',
          '  return [a, value, outside, rest.b];',
          '}',
          'console.log(JSON.stringify(run({ a: 1, b: 2 })));',
        ].join('\n'),
      );
      const baseline = spawnSync('node', [file], { encoding: 'utf8' });
      expect(baseline.status, baseline.stderr).toBe(0);

      const { stderr, exitCode } = runCoverage(file, TARGETS[2], outDir);
      expect(exitCode, stderr).toBe(0);
      const exact = stderr.split(/\r?\n/).find((line) => line.startsWith('zntc: symbol-identity '));
      expect(exact, stderr).toBeDefined();
      expect(exactSchemaProblems(exact ?? ''), stderr).toEqual([]);
      expect(exact, stderr).toMatch(/clean=1(?:\s|$)/);

      const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(baseline.stdout);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('classic JSX pragma factory and fragment preserve nested lexical identities', () => {
    const fixtures = [
      '4819-classic-jsx-shadowed-factory.tsx',
      '4819-classic-jsx-member-factory.tsx',
    ];
    const expected =
      '{"tag":"div","children":[{"tag":"Fragment","children":[{"tag":"span","children":[]}]}]}\n';
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-classic-jsx-symbols-'));
    try {
      for (const fixture of fixtures) {
        for (const target of TARGETS) {
          const { stderr, exitCode } = runCoverage(join(FIXTURE_DIR, fixture), target, outDir);
          expect(exitCode, `${fixture} ${target.name}: ${stderr}`).toBe(0);
          const exact = stderr
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: symbol-identity '));
          expect(exact, `${fixture} ${target.name}: ${stderr}`).toBeDefined();
          expect(exactSchemaProblems(exact ?? ''), `${fixture} ${target.name}: ${stderr}`).toEqual(
            [],
          );
          expect(exact, `${fixture} ${target.name}: ${stderr}`).toMatch(/clean=1(?:\s|$)/);

          const synthetic = stderr
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: synthetic-coverage '));
          expect(synthetic, `${fixture} ${target.name}: ${stderr}`).toBeDefined();
          expect(
            strictSchemaProblems(synthetic ?? ''),
            `${fixture} ${target.name}: ${stderr}`,
          ).toEqual([]);
          expect(synthetic, `${fixture} ${target.name}: ${stderr}`).toMatch(
            /consistent=1(?:\s|$).*symbol_identity_complete=1(?:\s|$)/,
          );

          const runtime = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
          expect(runtime.status, `${fixture} ${target.name}: ${runtime.stderr}`).toBe(0);
          expect(runtime.stdout, `${fixture} ${target.name}`).toBe(expected);
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  }, 60_000);

  test('downleveled static class self references keep exact identities after identifier minification', () => {
    const fixtures = [
      '4790-object-rest-decl-contexts.mjs',
      '4801-static-block-this-boundaries.mjs',
      '4801-static-field-arrow-this.mjs',
      '4801-static-field-super.mjs',
      '4801-static-private-this.mjs',
      '4819-static-private-accessor-logical.mjs',
      '4819-static-private-accessor-one-sided.mjs',
      '4819-static-private-accessor-pair.mjs',
      '4819-static-private-accessor-update.mjs',
      '4819-static-private-call-receiver.mjs',
    ];
    const targets = [TARGETS[1], TARGETS[2]];
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-static-class-minify-'));
    try {
      for (const fixture of fixtures) {
        const file = join(FIXTURE_DIR, fixture);
        const baseline = spawnSync('node', [file], { encoding: 'utf8' });
        expect(baseline.status, `${fixture}: ${baseline.stderr}`).toBe(0);
        for (const target of targets) {
          const { stderr, exitCode } = runCoverage(file, target, outDir, true);
          expect(exitCode, `${fixture} ${target.name}: ${stderr}`).toBe(0);

          const exact = stderr
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: symbol-identity '));
          expect(exact, `${fixture} ${target.name}: ${stderr}`).toBeDefined();
          expect(exactSchemaProblems(exact ?? ''), `${fixture} ${target.name}: ${exact}`).toEqual(
            [],
          );
          expect(exact, `${fixture} ${target.name}`).toMatch(/clean=1(?:\s|$)/);
          expect(postMinifyAuditProblems(stderr), `${fixture} ${target.name}: ${stderr}`).toEqual(
            [],
          );

          const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
          expect(actual.status, `${fixture} ${target.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, `${fixture} ${target.name}`).toBe(baseline.stdout);
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  }, 60_000);

  test('지원하지 않는 오라클 fixture 확장자는 조용히 건너뛰지 않는다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-symcov-unknown-extension-'));
    try {
      writeFileSync(join(dir, 'fixture.unknown'), '');
      expect(() => collectFixtures(dir)).toThrow(/unsupported downlevel-oracle fixture extension/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('exact report schema detects omitted or reclassified invariant fields', () => {
    const complete = [
      `invariant_counter_count=${EXACT_ZERO_COUNTERS.length}`,
      `observation_field_count=${EXACT_OBSERVATION_FIELD_COUNT}`,
      `diagnostic_field_count=${EXACT_DIAGNOSTIC_FIELD_COUNT}`,
      'generated_bindings=1',
      'generated_references=2',
      'external=3',
      'declaration_anchors_checked=4',
      'namespace_iife_params=4',
      'enum_iife_params=5',
      'clean=1',
      'legacy_debt_fingerprint=cbf29ce484222325',
      `schema_fingerprint=${EXACT_REPORT_SCHEMA_FINGERPRINT}`,
    ]
      .concat(EXACT_ZERO_COUNTERS.map((counter) => counter + '=0'))
      .join(' ');
    expect(exactSchemaProblems(complete)).toEqual([]);
    for (const counter of EXACT_ZERO_COUNTERS) {
      const corrupted = complete.replace(`${counter}=0`, `${counter}=1`);
      expect(corrupted, `exact invariant ${counter} was not present exactly as expected`).not.toBe(
        complete,
      );
      expect(
        exactSchemaProblems(corrupted),
        `exact invariant ${counter} must fail closed`,
      ).toContain(`${counter}=1, expected 0`);
    }
    expect(
      exactSchemaProblems(
        complete.replace(
          `schema_fingerprint=${EXACT_REPORT_SCHEMA_FINGERPRINT}`,
          'schema_fingerprint=0000000000000001',
        ),
      ),
    ).toContain('schema_fingerprint=0000000000000001, expected ' + EXACT_REPORT_SCHEMA_FINGERPRINT);
    expect(exactSchemaProblems(complete.replace(' clean=1', ' clean=0'))).toContain(
      'clean=0, expected 1',
    );
    expect(exactSchemaProblems(complete + ' future_counter=0')).toContain(
      'unexpected exact report field future_counter',
    );
    expect(exactSchemaProblems(complete + ' malformed')).toContain(
      'malformed exact report field malformed',
    );
    expect(
      exactSchemaProblems(complete.replace(' external=3', ' external=not-a-number')),
    ).toContain('malformed exact report value external=not-a-number');
    expect(
      exactSchemaProblems(
        complete.replace(
          'invariant_counter_count=' + EXACT_ZERO_COUNTERS.length,
          'invariant_counter_count=999',
        ),
      ),
    ).toContain('invariant_counter_count=999, expected ' + EXACT_ZERO_COUNTERS.length);
    expect(
      exactSchemaProblems(
        complete.replace(
          ` observation_field_count=${EXACT_OBSERVATION_FIELD_COUNT}`,
          ` observation_field_count=${EXACT_OBSERVATION_FIELD_COUNT} observation_field_count=${EXACT_OBSERVATION_FIELD_COUNT}`,
        ),
      ),
    ).toContain('observation_field_count occurrences=2, expected 1');
    const reportPayload = 'generated_bindings=1 ' + complete.replace('generated_bindings=1 ', '');
    const reportWithMarkerInPath =
      'zntc: symbol-identity /tmp/input: generated_bindings=3.js: ' + reportPayload;
    expect(exactSchemaProblems(reportWithMarkerInPath)).toEqual([]);
    const prepassReport =
      'zntc: symbol-identity-prepass /tmp/input: generated_bindings=3.js: ' + reportPayload;
    expect(exactSchemaProblems(prepassReport)).toEqual([]);
    expect(
      exactSchemaProblems(prepassReport.replace(' invalid_id=0', ' invalid_id=0 invalid_id=1')),
    ).toContain('invalid_id occurrences=2, expected 1');
    expect(exactSchemaProblems('zntc: symbol-identity input.js: clean=1')).toContain(
      'missing exact report payload',
    );
    expect(exactSchemaProblems(complete.replace(' write_count_mismatch=0', ''))).toContain(
      'write_count_mismatch occurrences=0, expected 1',
    );
    expect(
      exactSchemaProblems(
        complete.replace(
          ' write_count_mismatch=0',
          ' write_count_mismatch=0 write_count_mismatch=0',
        ),
      ),
    ).toContain('write_count_mismatch occurrences=2, expected 1');
    expect(
      exactSchemaProblems(complete.replace(' write_count_mismatch=0', ' write_count_mismatch=1')),
    ).toContain('write_count_mismatch=1, expected 0');
    expect(exactSchemaProblems(complete.replace(' declaration_scope_mismatch=0', ''))).toContain(
      'declaration_scope_mismatch occurrences=0, expected 1',
    );
    expect(
      exactSchemaProblems(
        complete.replace(' declaration_scope_mismatch=0', ' declaration_scope_mismatch=1'),
      ),
    ).toContain('declaration_scope_mismatch=1, expected 0');
    expect(
      exactSchemaProblems(
        complete.replace(' declaration_identity_mismatch=0', ' declaration_identity_mismatch=1'),
      ),
    ).toContain('declaration_identity_mismatch=1, expected 0');
    expect(exactSchemaProblems(complete.replace(' namespace_iife_params=4', ''))).toContain(
      'namespace_iife_params occurrences=0, expected 1',
    );
    expect(
      exactSchemaProblems(
        complete.replace(' generated_bindings=1', ' generated_bindings=1 generated_bindings=0'),
      ),
    ).toContain('generated_bindings occurrences=2, expected 1');
    expect(exactSchemaProblems(complete.replace(' clean=1', ' clean=1 clean=0'))).toContain(
      'clean occurrences=2, expected 1',
    );
    expect(
      exactSchemaProblems(complete.replace(' legacy_debt_fingerprint=cbf29ce484222325', '')),
    ).toContain('legacy_debt_fingerprint occurrences=0, expected 1');
    const invalidInvariantCounterCount = EXACT_ZERO_COUNTERS.length + 1;
    expect(
      exactSchemaProblems(
        complete.replace(
          /invariant_counter_count=\d+/,
          `invariant_counter_count=${invalidInvariantCounterCount}`,
        ),
      ),
    ).toContain(
      `invariant_counter_count=${invalidInvariantCounterCount}, expected ${EXACT_ZERO_COUNTERS.length}`,
    );
    const invalidObservationFieldCount = EXACT_OBSERVATION_FIELD_COUNT + 1;
    expect(
      exactSchemaProblems(
        complete.replace(
          /observation_field_count=\d+/,
          `observation_field_count=${invalidObservationFieldCount}`,
        ),
      ),
    ).toContain(
      `observation_field_count=${invalidObservationFieldCount}, expected ${EXACT_OBSERVATION_FIELD_COUNT}`,
    );
    const invalidDiagnosticFieldCount = EXACT_DIAGNOSTIC_FIELD_COUNT + 1;
    expect(
      exactSchemaProblems(
        complete.replace(
          /diagnostic_field_count=\d+/,
          `diagnostic_field_count=${invalidDiagnosticFieldCount}`,
        ),
      ),
    ).toContain(
      `diagnostic_field_count=${invalidDiagnosticFieldCount}, expected ${EXACT_DIAGNOSTIC_FIELD_COUNT}`,
    );
  });

  test('strict report schema rejects missing, duplicate, malformed, and unknown fields', () => {
    const complete = [
      ...STRICT_METRIC_FIELDS.map((field) => `${field}=1`),
      ...STRICT_ZERO_COUNTERS.map((field) => `${field}=0`),
      ...STRICT_BOOLEAN_FIELDS.map((field) => `${field}=1`),
    ].join(' ');
    const report = `zntc: synthetic-coverage fixture.mjs: ${complete}`;

    expect(strictSchemaProblems(report)).toEqual([]);
    for (const counter of STRICT_ZERO_COUNTERS) {
      const corrupted = report.replace(`${counter}=0`, `${counter}=1`);
      expect(corrupted, `strict invariant ${counter} was not present exactly as expected`).not.toBe(
        report,
      );
      expect(
        strictSchemaProblems(corrupted),
        `strict invariant ${counter} must fail closed`,
      ).toContain(`${counter}=1, expected 0`);
    }
    expect(
      strictSchemaProblems(`zntc: synthetic-coverage /tmp/zntc: bound=7.js: ${complete}`),
    ).toEqual([]);
    expect(
      strictSchemaProblems(`zntc: synthetic-coverage-detail fixture.mjs: ${complete}`),
    ).toContain('missing strict report');
    expect(strictSchemaProblems(report.replace(' missing_binding=0', ''))).toContain(
      'missing_binding occurrences=0, expected 1',
    );
    expect(
      strictSchemaProblems(
        report.replace(' missing_binding=0', ' missing_binding=0 missing_binding=1'),
      ),
    ).toContain('missing_binding occurrences=2, expected 1');
    expect(
      strictSchemaProblems(report.replace(' consistent=1', ' consistent=1 consistent=0')),
    ).toContain('consistent occurrences=2, expected 1');
    expect(strictSchemaProblems(report.replace(' consistent=1', ' consistent=0'))).toContain(
      'consistent=0, expected 1',
    );
    expect(strictSchemaProblems(report.replace(' symbol_identity_complete=1', ''))).toContain(
      'symbol_identity_complete occurrences=0, expected 1',
    );
    expect(strictSchemaProblems(report + ' future_counter=0')).toContain(
      'unexpected strict report field future_counter',
    );
    expect(strictSchemaProblems(report + ' malformed')).toContain(
      'malformed strict report field malformed',
    );
    expect(strictSchemaProblems('zntc: synthetic-coverage fixture.mjs: no-report')).toContain(
      'missing strict report payload',
    );
  });

  test('post-minify report schema rejects missing, duplicate, malformed, and unknown fields', () => {
    const complete = [
      ...POST_MINIFY_OBSERVATION_FIELDS.map((field) => `${field}=1`),
      ...POST_MINIFY_ZERO_COUNTERS.map((field) => `${field}=0`),
      'clean=1',
    ].join(' ');
    const report = `zntc: symbol-identity-post-minify fixture.mjs: ${complete}`;

    expect(postMinifySchemaProblems(report)).toEqual([]);
    for (const counter of POST_MINIFY_ZERO_COUNTERS) {
      const corrupted = report.replace(`${counter}=0`, `${counter}=1`);
      expect(
        corrupted,
        `post-minify invariant ${counter} was not present exactly as expected`,
      ).not.toBe(report);
      expect(
        postMinifySchemaProblems(corrupted),
        `post-minify invariant ${counter} must fail closed`,
      ).toContain(`${counter}=1, expected 0`);
    }
    expect(postMinifySchemaProblems(report.replace(' references=1', ''))).toContain(
      'references occurrences=0, expected 1',
    );
    expect(
      postMinifySchemaProblems(
        report.replace(
          ' wrong_reference_target=0',
          ' wrong_reference_target=0 wrong_reference_target=1',
        ),
      ),
    ).toContain('wrong_reference_target occurrences=2, expected 1');
    expect(
      postMinifySchemaProblems(
        report.replace(' dangling_reference_id=0', ' dangling_reference_id=1'),
      ),
    ).toContain('dangling_reference_id=1, expected 0');
    expect(postMinifySchemaProblems(report.replace(' clean=1', ' clean=0'))).toContain(
      'clean=0, expected 1',
    );
    expect(postMinifySchemaProblems(report.replace(' clean=1', ' clean=10'))).toContain(
      'clean=10, expected 1',
    );
    expect(postMinifySchemaProblems(report.replace(' helpers=1', ' helpers=bad'))).toContain(
      'malformed post-minify report value helpers=bad',
    );
    expect(postMinifySchemaProblems(report + ' future_counter=0')).toContain(
      'unexpected post-minify report field future_counter',
    );
    expect(postMinifySchemaProblems(report + ' malformed')).toContain(
      'malformed post-minify report field malformed',
    );
    expect(
      postMinifySchemaProblems('zntc: symbol-identity-post-minify fixture.mjs: no-report'),
    ).toContain('missing post-minify report payload');
    const reportWithMarkerInPath =
      'zntc: symbol-identity-post-minify /tmp/input: bindings=42.js: ' + complete;
    expect(postMinifySchemaProblems(reportWithMarkerInPath)).toEqual([]);
    expect(postMinifyAuditProblems(report)).toEqual([]);
    expect(postMinifyAuditProblems('')).toContain('post-minify reports=0, expected 1');
    expect(postMinifyAuditProblems(report + '\n' + report)).toContain(
      'post-minify reports=2, expected 1',
    );
  });

  test('minify transform-stage gate requires exact identity and scope reports', () => {
    expect(transformIdentityAuditProblems('')).toEqual([
      'exact identity reports=0, expected 1',
      'source scope-owner reports=0, expected 1',
      'symbol coverage reports=0, expected 1',
      'strict synthetic coverage reports=0, expected 1',
    ]);
  });

  test('the emitted exact report matches the locked schema', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-exact-report-schema-'));
    try {
      const { stderr, exitCode } = runCoverage(
        join(FIXTURE_DIR, '4760-block-eval.mjs'),
        TARGETS[0],
        outDir,
      );
      expect(exitCode, stderr).toBe(0);
      const reports = stderr
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity '));
      expect(reports, stderr).toHaveLength(1);
      expect(exactSchemaProblems(reports[0])).toEqual([]);
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('bundler prepass exact gate labels target-lowered modules as reanalyzed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-prepass-exact-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(join(dir, 'dep.ts'), 'export namespace Data { export const value = 42; }');
    writeFileSync(
      join(dir, 'entry.tsx'),
      [
        "import { Data } from './dep';",
        'function render(h: (tag: string, props: unknown, child: number) => number) {',
        '  return <main>{Data.value}</main>;',
        '}',
        'console.log(render((_tag, _props, child) => child));',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.tsx',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--jsx=classic',
          '--jsx-factory=h',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const sourceScopeOwnerAudits = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-source-scope-owner '));
      expect(sourceScopeOwnerAudits, proc.stderr).toHaveLength(2);
      for (const audit of sourceScopeOwnerAudits) {
        expect(scopeOwnerAuditProblems(audit), proc.stderr).toEqual([]);
      }

      const reports = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(reports, proc.stderr).toHaveLength(2);
      for (const report of reports) {
        expect(exactSchemaProblems(report), report).toEqual([]);
      }

      const dependency = reports.find((line) => line.includes('dep.ts'));
      const reanalyzed = reports.find((line) => line.includes('entry.tsx'));
      expect(dependency, reports.join('\n')).toBeDefined();
      expect(reanalyzed, reports.join('\n')).toBeDefined();
      const graphModes = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(graphModes, proc.stderr).toHaveLength(2);
      expect(graphModes.find((line) => line.includes('dep.ts'))).toContain(
        'semantic_graph=reanalyzed',
      );
      expect(graphModes.find((line) => line.includes('entry.tsx'))).toContain(
        'semantic_graph=reanalyzed',
      );
      expect(Number(dependency?.match(/namespace_iife_params=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      expect(Number(reanalyzed?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('styled-components display-name transform retains its exact prepass graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-styled-prepass-exact-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'index.ts'),
      [
        "import styled from 'styled-components';",
        'export const Button = styled.button`color: red;`;',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ compiler: { styledComponents: { namespace: 'audit' } } }),
    );
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { verbatimModuleSyntax: true, useDefineForClassFields: false },
      }),
    );
    try {
      const proc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'index.ts',
          '--external',
          'styled-components',
          '--use-define-for-class-fields=false',
          '--verbatim-module-syntax',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const reports = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(reports, proc.stderr).toHaveLength(1);
      expect(exactSchemaProblems(reports[0])).toEqual([]);

      const modes = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(modes, proc.stderr).toHaveLength(1);
      expect(modes[0], proc.stderr).toContain('semantic_graph=retained');

      const bundle = readFileSync(output, 'utf8');
      expect(bundle).toContain('withConfig');
      expect(bundle).toContain('audit__');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('bundler React Refresh retains exact prepass graph and component identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-prepass-exact-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(join(dir, 'entry.jsx'), 'export function App() { return 42; }');
    try {
      const proc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'entry.jsx',
          '--react-refresh=true',
          '--platform=node',
          '--format=cjs',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const reports = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(reports, proc.stderr).toHaveLength(1);
      expect(exactSchemaProblems(reports[0])).toEqual([]);
      expect(Number(reports[0].match(/clean=(\d+)/)?.[1] ?? 0)).toBe(1);

      const modes = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(modes, proc.stderr).toHaveLength(1);
      expect(modes[0], proc.stderr).toContain('semantic_graph=retained');

      writeFileSync(
        join(dir, 'run.cjs'),
        [
          'globalThis.__refreshRegistrations = [];',
          'globalThis.$RefreshReg$ = (component, name) => __refreshRegistrations.push([name, typeof component]);',
          "const bundle = require('./out.cjs');",
          'console.log(bundle.App(), JSON.stringify(__refreshRegistrations));',
        ].join('\n'),
      );
      const actual = spawnSync('node', [join(dir, 'run.cjs')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 [["App","function"]]\n');

      writeFileSync(join(dir, 'entry.jsx'), 'export function App() { return eval("42"); }');
      const evalProc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'entry.jsx',
          '--react-refresh=true',
          '--platform=node',
          '--format=cjs',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(evalProc.status, evalProc.stderr).toBe(0);
      const evalMode = (evalProc.stderr ?? '')
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(evalMode, evalProc.stderr).toContain('semantic_graph=reanalyzed');
      const evalReport = (evalProc.stderr ?? '')
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(evalReport, evalProc.stderr).toMatch(/clean=1(?:\s|$)/);
      const evalActual = spawnSync('node', [join(dir, 'run.cjs')], { encoding: 'utf8' });
      expect(evalActual.status, evalActual.stderr).toBe(0);
      expect(evalActual.stdout).toBe('42 [["App","function"]]\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('styled-components CSS-prop import retains exact identity and module metadata', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-styled-css-prop-prepass-'));
    const packageDir = join(dir, 'node_modules', 'styled-components');
    mkdirSync(packageDir, { recursive: true });
    writeFileSync(
      join(packageDir, 'package.json'),
      JSON.stringify({ name: 'styled-components', version: '0.0.0-test', main: 'index.js' }),
    );
    writeFileSync(
      join(packageDir, 'index.js'),
      [
        'const styled = (tag) => (style) => (props) => ({ tag, style, props });',
        "styled.main = (style) => (props) => ({ tag: 'main', style, props });",
        'module.exports = styled;',
        'module.exports.default = styled;',
        'module.exports.__esModule = true;',
        '',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'index.tsx'),
      [
        "const _styled = 'root collision';",
        "const _styled_0 = 'component collision';",
        'function h(Component, props) { return Component(props); }',
        'export function App(_styled2, _styled_0) {',
        '  return <main css={{ color: "red" }} title={_styled2} data-user={_styled_0} />;',
        '}',
        '',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ compiler: { styledComponents: { cssProp: true, namespace: 'audit' } } }),
    );
    try {
      for (const minify of [false, true]) {
        const output = join(dir, `out-${minify ? 'minified' : 'plain'}.cjs`);
        const proc = spawnSync(
          'bun',
          [
            ZNTC_JS_CLI,
            '--bundle',
            'index.tsx',
            '--target=esnext',
            '--platform=node',
            '--format=cjs',
            '--jsx=classic',
            '--jsx-factory=h',
            '--external',
            'styled-components',
            ...(minify ? ['--minify-identifiers'] : []),
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        const stderr = proc.stderr ?? '';
        expect(proc.status, stderr).toBe(0);

        const report = stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity-prepass '));
        expect(report, stderr).toBeDefined();
        expect(exactSchemaProblems(report!), stderr).toEqual([]);
        expect(report, stderr).toMatch(/clean=1(?:\s|$)/);

        const mode = stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
        expect(mode, stderr).toContain('semantic_graph=retained');

        const bundle = readFileSync(output, 'utf8');
        expect(bundle).toContain('styled-components');
        const runner = join(dir, `run-${minify ? 'minified' : 'plain'}.cjs`);
        writeFileSync(
          runner,
          `const { App } = require(${JSON.stringify(output)});\n` +
            "console.log(JSON.stringify(App('parameter', 'nested collision')));\n",
        );
        const actual = spawnSync('node', [runner], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(
          '{"tag":"main","style":{"color":"red"},"props":{"title":"parameter","data-user":"nested collision"}}\n',
        );
      }

      writeFileSync(
        join(dir, 'eval.tsx'),
        [
          'function h(Component, props) { return Component(props); }',
          'export function App() {',
          '  eval("0");',
          '  return <main css={{ color: "blue" }} />;',
          '}',
          '',
        ].join('\n'),
      );
      const evalOutput = join(dir, 'eval.cjs');
      const evalProc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'eval.tsx',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=classic',
          '--jsx-factory=h',
          '--external',
          'styled-components',
          '-o',
          evalOutput,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      const evalStderr = evalProc.stderr ?? '';
      expect(evalProc.status, evalStderr).toBe(0);
      const evalMode = evalStderr
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(evalMode, evalStderr).toContain('semantic_graph=reanalyzed');
      const evalReport = evalStderr
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(evalReport, evalStderr).toMatch(/clean=1(?:\s|$)/);
      const evalRunner = join(dir, 'run-eval.cjs');
      writeFileSync(
        evalRunner,
        `const { App } = require(${JSON.stringify(evalOutput)});\n` +
          'console.log(JSON.stringify(App()));\n',
      );
      const evalActual = spawnSync('node', [evalRunner], { encoding: 'utf8' });
      expect(evalActual.status, evalActual.stderr).toBe(0);
      expect(evalActual.stdout).toBe('{"tag":"main","style":{"color":"blue"},"props":null}\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('styled-components define replacement keeps semantic reanalysis enabled', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-styled-prepass-define-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'index.ts'),
      [
        "import styled from 'styled-components';",
        'export const Button = styled.button`color: red;`;',
        'export const BuildValue = __ZNTC_SYMBOL_GATE__;',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ compiler: { styledComponents: { namespace: 'audit' } } }),
    );
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { verbatimModuleSyntax: true } }),
    );
    try {
      const proc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'index.ts',
          '--external',
          'styled-components',
          '--define:__ZNTC_SYMBOL_GATE__=123',
          '--verbatim-module-syntax',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const reports = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(reports, proc.stderr).toHaveLength(1);
      expect(exactSchemaProblems(reports[0])).toEqual([]);

      const modes = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(modes, proc.stderr).toHaveLength(1);
      expect(modes[0], proc.stderr).toContain('semantic_graph=reanalyzed');

      const bundle = readFileSync(output, 'utf8');
      expect(bundle).toContain('123');
      expect(bundle).toContain('withConfig');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 exponentiation lowering reserves generated Math across modules', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-exponentiation-global-'));
    const cases = [
      {
        name: 'binary',
        source: 'function square(value) { return (() => value ** 2)(); }',
        graph: 'retained',
        output: '36 undefined 3 undefined\n',
      },
      {
        name: 'binary-shadow',
        source: [
          'const Math = { pow(left, right) { return left + right; } };',
          'globalThis.shadowMath = Math;',
          'function square(value) { return (() => value ** 2)(); }',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '36 undefined 3 3\n',
      },
      {
        name: 'binary-var-math-shadow',
        source: [
          'var Math = { pow(left, right) { return left + right; } };',
          'globalThis.shadowMath = Math;',
          'function square(value) { return (() => value ** 2)(); }',
        ].join('\n'),
        graph: 'retained',
        shadowedExternal: true,
        output: '36 undefined 3 3\n',
      },
      {
        name: 'assignment',
        source: 'function square(input) { var value = input; return (() => (value **= 2))(); }',
        graph: 'retained',
        output: '36 undefined 3 undefined\n',
      },
      {
        name: 'assignment-shadow',
        source: [
          'const Math = { pow(left, right) { return left + right; } };',
          'globalThis.shadowMath = Math;',
          'function square(input) { var value = input; return (() => (value **= 2))(); }',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '36 undefined 3 3\n',
      },
      {
        name: 'assignment-var-math-shadow',
        source: [
          'var Math = { pow(left, right) { return left + right; } };',
          'globalThis.shadowMath = Math;',
          'function square(input) { var value = input; return (() => (value **= 2))(); }',
        ].join('\n'),
        graph: 'retained',
        shadowedExternal: true,
        output: '36 undefined 3 3\n',
      },
      {
        name: 'assignment-computed-target',
        source: [
          'function square(input) {',
          '  var keyEvaluations = 0;',
          '  var box = { value: input };',
          "  function getKey() { keyEvaluations++; return 'value'; }",
          '  var result = (() => (box[getKey()] **= 2))();',
          '  globalThis.targetEvaluations = keyEvaluations;',
          '  return result;',
          '}',
        ].join('\n'),
        graph: 'retained',
        output: '36 1 3 undefined\n',
      },
      {
        name: 'assignment-member-target',
        source: [
          'function square(input) {',
          '  var box = { value: input };',
          '  return (() => (box.value **= 2))();',
          '}',
        ].join('\n'),
        graph: 'retained',
        output: '36 undefined 3 undefined\n',
      },
    ];
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        "import './power.mjs';",
        "import { Math as mathValue } from './user-math.mjs';",
        'console.log(globalThis.squareResult, globalThis.targetEvaluations, mathValue.pow(1, 2), globalThis.shadowMath && globalThis.shadowMath.pow(1, 2));',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'user-math.mjs'),
      'export const Math = { pow(left, right) { return left + right; } };',
    );
    try {
      for (const fixture of cases) {
        writeFileSync(
          join(dir, 'power.mjs'),
          [fixture.source, 'globalThis.squareResult = square(6);'].join('\n'),
        );
        for (const minifyIdentifiers of [false, true]) {
          const variantOutput = join(
            dir,
            `out.${fixture.name}.${minifyIdentifiers ? 'minified' : 'plain'}.cjs`,
          );
          const args = ['--bundle', 'entry.mjs', '--target=es5', '--platform=node', '--format=cjs'];
          if (minifyIdentifiers) args.push('--minify-identifiers');
          args.push('-o', variantOutput);
          const proc = spawnSync(ZNTC_BIN, args, {
            cwd: dir,
            env: minifyIdentifiers
              ? { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' }
              : process.env,
            encoding: 'utf8',
          });
          expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

          if (minifyIdentifiers) {
            const report = (proc.stderr ?? '')
              .split(/\r?\n/)
              .find(
                (line) =>
                  line.startsWith('zntc: symbol-identity-prepass ') && line.includes('power.mjs'),
              );
            expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
            if (fixture.graph === 'retained') {
              for (const counter of EXACT_ZERO_COUNTERS) {
                const expected =
                  fixture.shadowedExternal && counter === 'shadowed_external_reference' ? 1 : 0;
                expect(
                  Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
                  `${fixture.name}: ${report}`,
                ).toBe(expected);
              }
              expect(report, fixture.name).toMatch(
                fixture.shadowedExternal ? /clean=0(?:\s|$)/ : /clean=1(?:\s|$)/,
              );
            }

            const graphMode = (proc.stderr ?? '')
              .split(/\r?\n/)
              .find(
                (line) =>
                  line.startsWith('zntc: symbol-identity-prepass-mode ') &&
                  line.includes('power.mjs'),
              );
            expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
              `semantic_graph=${fixture.graph}`,
            );
          }

          const actual = spawnSync('node', [variantOutput], { encoding: 'utf8' });
          expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, fixture.name).toBe(fixture.output);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 exponentiation renames only the enclosing nested Math binding', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-exponentiation-nested-math-'));
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        "import './power.mjs';",
        'console.log(globalThis.squareResult, globalThis.shadowMath.pow(1, 2), globalThis.unrelatedMathResult);',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'power.mjs'),
      [
        'function square(value) {',
        '  var Math = { pow(left, right) { return left + right; } };',
        '  globalThis.shadowMath = Math;',
        '  function unrelated() {',
        '    var Math = { pow(left, right) { return left + right; } };',
        '    return Math.pow(1, 2);',
        '  }',
        '  globalThis.unrelatedMathResult = unrelated();',
        '  function power(input) { return (() => input ** 2)(); }',
        '  return power(value);',
        '}',
        'globalThis.squareResult = square(6);',
      ].join('\n'),
    );
    try {
      for (const minifyIdentifiers of [false, true]) {
        const output = join(dir, `out.${minifyIdentifiers ? 'minified' : 'plain'}.cjs`);
        const args = ['--bundle', 'entry.mjs', '--target=es5', '--platform=node', '--format=cjs'];
        if (minifyIdentifiers) args.push('--minify-identifiers');
        args.push('-o', output);
        const proc = spawnSync(ZNTC_BIN, args, {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, `${minifyIdentifiers ? 'minified' : 'plain'}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const report = lines.find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('power.mjs'),
        );
        expect(report, `${minifyIdentifiers ? 'minified' : 'plain'}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          const expected = counter === 'shadowed_external_reference' ? 1 : 0;
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${counter}: ${report}`,
          ).toBe(expected);
        }
        expect(report).toMatch(/clean=0(?:\s|$)/);

        const graphMode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('power.mjs'),
        );
        expect(graphMode, `${proc.stderr}`).toContain('semantic_graph=retained');

        const emitted = readFileSync(output, 'utf8');
        if (!minifyIdentifiers) {
          expect(emitted).toMatch(/Math\.pow\(/);
          expect(emitted).toMatch(/Math\$\d+/);
          expect(emitted).toMatch(/var Math =/);
        }

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe('36 3 3\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  test('ES5 exponentiation nested shadow is safe in the per-module linker path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-exponentiation-preserve-math-'));
    const outdir = join(dir, 'dist');
    writeFileSync(
      join(dir, 'entry.js'),
      [
        'import { square } from "./power.js";',
        'console.log(square(6), globalThis.shadowMath.pow(1, 2), globalThis.unrelatedMathResult);',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'power.js'),
      [
        'export function square(value) {',
        '  var Math = { pow(left, right) { return left + right; } };',
        '  globalThis.shadowMath = Math;',
        '  function unrelated() {',
        '    var Math = { pow(left, right) { return left + right; } };',
        '    return Math.pow(1, 2);',
        '  }',
        '  globalThis.unrelatedMathResult = unrelated();',
        '  return (() => value ** 2)();',
        '}',
      ].join('\n'),
    );
    try {
      const output = join(dir, 'out');
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          join(dir, 'entry.js'),
          '--preserve-modules',
          `--preserve-modules-root=${dir}`,
          '--outdir',
          output,
          '--target=es5',
          '--platform=node',
          '--format=esm',
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' }, encoding: 'utf8' },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const powerOutput = join(output, 'power.js');
      const emitted = readFileSync(powerOutput, 'utf8');
      expect(emitted).toMatch(/var Math\$\d+/);
      expect(emitted).toMatch(/var Math =/);
      writeFileSync(join(output, 'package.json'), '{"type":"module"}');

      const actual = spawnSync('node', [join(output, 'entry.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('36 3 3\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 exponentiation under direct eval preserves operators and visible names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-exponentiation-direct-eval-'));
    writeFileSync(
      join(dir, 'input.js'),
      [
        'function __getMath() { return { pow(left, right) { return left + right; } }; }',
        'function power(value) {',
        '  var Math = { pow(left, right) { return left + right; } };',
        "  var evalVisibleMath = eval('Math');",
        "  var evalVisibleHelper = eval('typeof __getMath2');",
        '  return [value ** 2, evalVisibleMath === Math, evalVisibleHelper];',
        '}',
        'class PrivatePower {',
        '  #value = 6;',
        '  run() {',
        '    var Math = { pow(left, right) { return left + right; } };',
        "    var evalVisibleMath = eval('Math');",
        '    this.#value **= 2;',
        '    return [this.#value, evalVisibleMath === Math];',
        '  }',
        '}',
        'console.log(JSON.stringify([power(6), new PrivatePower().run()]));',
      ].join('\n'),
    );
    try {
      const output = join(dir, 'output.cjs');
      const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
        cwd: dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      expect(proc.status, proc.stderr).toBe(0);
      expect(proc.stderr).toContain('exponentiation is emitted unchanged');
      expect(proc.stderr).toMatch(/symbol-coverage .* missing=0 wrong=0/);
      const identity = proc.stderr
        .split('\n')
        .find((line) => line.startsWith('zntc: symbol-identity '));
      expect(identity, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), counter).toBe(
          0,
        );
      }
      const emitted = readFileSync(output, 'utf8');
      expect(emitted).toMatch(/\*\*\s*2/);
      expect(emitted).not.toMatch(/Math\.pow\(/);
      expect(emitted).not.toMatch(/function __getMath2\(\)/);
      expect(emitted).toMatch(/function __getMath\(\) \{/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('[[36,true,"undefined"],[36,true]]\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('bundled ES5 exponentiation under direct eval preserves operators and visible names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-exponentiation-bundled-eval-'));
    writeFileSync(
      join(dir, 'entry.mjs'),
      ["import { power } from './power.mjs';", 'console.log(JSON.stringify(power(6)));'].join('\n'),
    );
    writeFileSync(
      join(dir, 'power.mjs'),
      [
        'export function power(value) {',
        '  var Math = { pow(left, right) { return left + right; } };',
        "  var evalVisibleMath = eval('Math');",
        "  var evalVisibleHelper = eval('typeof __getMath');",
        '  var result = value;',
        '  result **= 2;',
        '  return [value ** 2, result, evalVisibleMath === Math, evalVisibleHelper];',
        '}',
      ].join('\n'),
    );
    try {
      for (const minifyWhitespace of [false, true]) {
        const output = join(dir, `bundle.${minifyWhitespace ? 'min' : 'plain'}.cjs`);
        const args = ['--bundle', 'entry.mjs', '--target=es5', '--platform=node', '--format=cjs'];
        if (minifyWhitespace) args.push('--minify-whitespace');
        args.push('-o', output);
        const proc = spawnSync(ZNTC_BIN, args, {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, proc.stderr).toBe(0);
        expect(proc.stderr).toContain('exponentiation is emitted unchanged');

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const report = lines.find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('power.mjs'),
        );
        expect(report, proc.stderr).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), counter).toBe(
            0,
          );
        }
        const graphMode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('power.mjs'),
        );
        expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe('[36,36,true,"undefined"]\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 exponentiation preserves ** when dynamic root lookup can observe generated names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-exponentiation-dynamic-root-'));
    writeFileSync(
      join(dir, 'input.js'),
      [
        'var Math = { pow(left, right) { return left + right; } };',
        "eval('Math');",
        'var value = 6;',
        'value **= 2;',
        'console.log(value);',
      ].join('\n'),
    );
    try {
      const output = join(dir, 'output.cjs');
      const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
        cwd: dir,
        encoding: 'utf8',
      });
      expect(proc.status, proc.stderr).toBe(0);
      expect(proc.stderr).toContain('exponentiation is emitted unchanged');
      const emitted = readFileSync(output, 'utf8');
      expect(emitted).toMatch(/\*\*\s*2/);
      expect(emitted).not.toMatch(/Math\.pow\(/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('36\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 nullish coalescing retains exact graphs and evaluates left expressions once', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-nullish-graph-'));
    const cases = [
      {
        name: 'identifier-left',
        graph: 'retained',
        source: [
          'function choose(value) { return (() => (value ?? 7))(); }',
          'globalThis.result = choose(0);',
        ].join('\n'),
        output: '0 0\n',
      },
      {
        name: 'call-left',
        graph: 'retained',
        source: [
          'globalThis.calls = 0;',
          'function getValue() { globalThis.calls = globalThis.calls + 1; return null; }',
          'function choose() { return getValue() ?? 7; }',
          'globalThis.result = choose();',
        ].join('\n'),
        output: '7 1\n',
      },
      {
        name: 'optional-chain-left',
        graph: 'reanalyzed',
        source: [
          'function choose(box) { return box?.value ?? 7; }',
          'globalThis.result = choose(null);',
        ].join('\n'),
        output: '7 0\n',
      },
    ];
    writeFileSync(
      join(dir, 'entry.mjs'),
      ["import './power.mjs';", 'console.log(globalThis.result, globalThis.calls || 0);'].join(
        '\n',
      ),
    );
    try {
      for (const fixture of cases) {
        writeFileSync(join(dir, 'power.mjs'), fixture.source);
        for (const minifyIdentifiers of [false, true]) {
          const output = join(
            dir,
            `out.${fixture.name}.${minifyIdentifiers ? 'min' : 'plain'}.cjs`,
          );
          const args = ['--bundle', 'entry.mjs', '--target=es5', '--platform=node', '--format=cjs'];
          if (minifyIdentifiers) args.push('--minify-identifiers');
          args.push('-o', output);
          const proc = spawnSync(ZNTC_BIN, args, {
            cwd: dir,
            env: minifyIdentifiers
              ? { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' }
              : process.env,
            encoding: 'utf8',
          });
          expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

          if (minifyIdentifiers) {
            const report = (proc.stderr ?? '')
              .split(/\r?\n/)
              .find(
                (line) =>
                  line.startsWith('zntc: symbol-identity-prepass ') && line.includes('power.mjs'),
              );
            expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
            if (fixture.graph === 'retained') {
              for (const counter of EXACT_ZERO_COUNTERS) {
                expect(
                  Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
                  `${fixture.name}: ${report}`,
                ).toBe(0);
              }
              expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);
            }

            const graphMode = (proc.stderr ?? '')
              .split(/\r?\n/)
              .find(
                (line) =>
                  line.startsWith('zntc: symbol-identity-prepass-mode ') &&
                  line.includes('power.mjs'),
              );
            expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
              `semantic_graph=${fixture.graph}`,
            );
          }

          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, fixture.name).toBe(fixture.output);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native and ES5 for-of lowering retain exact loop and helper scopes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-of-catch-scope-'));
    const file = join(FIXTURE_DIR, '4819-for-of-iterator-close.mjs');
    try {
      for (const target of [
        { name: 'es2015', arg: '--target=es2015', graph: 'retained' },
        { name: 'es5', arg: '--target=es5', graph: 'retained' },
      ]) {
        const output = join(dir, `${target.name}.cjs`);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            file,
            target.arg,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') &&
              line.includes('4819-for-of-iterator-close.mjs'),
          );
        expect(report, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${target.name}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes('4819-for-of-iterator-close.mjs'),
          );
        expect(graphMode, `${target.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${target.graph}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe('1,2 return:2 3,4,5\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 generator for-of destructuring keeps exact iterator temp identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-generator-for-of-temp-identity-'));
    const file = join(FIXTURE_DIR, 'forof-gen-destructure-head.mjs');
    const output = join(dir, 'output.js');
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [file, '--target=es5', '--minify-identifiers', '-o', output],
        {
          env: {
            ...process.env,
            ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const lines = (proc.stderr ?? '').split(/\r?\n/);
      const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
      expect(identity, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${identity}`,
        ).toBe(0);
      }
      const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
      expect(strict, proc.stderr).toBeDefined();
      for (const counter of ['missing_binding', 'unclassified', 'orphan_symbols']) {
        expect(Number(strict?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1)).toBe(0);
      }
      expect(strict).toMatch(/symbol_identity_complete=1(?:\s|$)/);
      const postMinify = lines.find((line) =>
        line.startsWith('zntc: symbol-identity-post-minify '),
      );
      expect(postMinify, proc.stderr).toMatch(
        /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
      );

      const reference = spawnSync('node', [file], { encoding: 'utf8' });
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(reference.status, reference.stderr).toBe(0);
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(reference.stdout);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('lowered for-await temps keep exact identities through async wrapper relocation', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-await-wrapper-symbols-'));
    const file = join(FIXTURE_DIR, 'forawait-basic.mjs');
    try {
      for (const target of ['--target=es5', '--target=es2015']) {
        const output = join(dir, `${target.slice('--target='.length)}.mjs`);
        const proc = spawnSync(ZNTC_BIN, [file, target, '--minify-identifiers', '-o', output], {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, `${target}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target} ${counter}: ${identity}`,
          ).toBe(0);
        }
        expect(Number(identity?.match(/generated_bindings=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

        const postMinify = lines.find((line) =>
          line.startsWith('zntc: symbol-identity-post-minify '),
        );
        expect(postMinify, `${target}: ${proc.stderr}`).toMatch(
          /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target).toBe('1,2,3\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('for-await catch parameter keeps exact identity beside an outer _err', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-await-catch-err-identity-'));
    const file = join(dir, 'entry.mjs');
    const source = [
      "const _err = 'outer';",
      'const iterable = {',
      "  next() { return Promise.reject(new Error('iterator failed')); },",
      '  return() { return Promise.resolve({ done: true }); },',
      '};',
      'iterable[Symbol.asyncIterator] = function () { return this; };',
      'async function run() {',
      '  try {',
      '    for await (const value of iterable) { void value; }',
      '  } catch (caught) {',
      '    console.log(`${_err}:${caught.message}`);',
      '  }',
      '}',
      'run();',
    ].join('\n');
    writeFileSync(file, source);

    try {
      const reference = spawnSync('node', [file], { encoding: 'utf8' });
      expect(reference.status, reference.stderr).toBe(0);
      expect(reference.stdout).toBe('outer:iterator failed\n');

      for (const { name, target, minify } of [
        { name: 'es2017', target: '--target=es2017', minify: false },
        { name: 'es5-minify', target: '--target=es5', minify: true },
        { name: 'es2015-minify', target: '--target=es2015', minify: true },
      ]) {
        const output = join(dir, `${name}.mjs`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target, ...(minify ? ['--minify-identifiers'] : []), '-o', output],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${name}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${name} ${counter}: ${identity}`,
          ).toBe(0);
        }
        expect(identity, `${name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);

        const emitted = readFileSync(output, 'utf8');
        if (!minify) expect(emitted).toMatch(/catch\s*\(_err\)/);
        if (minify) {
          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${name}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );
        }

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, name).toBe(reference.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 generator while and do-while extraction preserve per-iteration closures', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-generator-loop-callers-'));
    const file = join(FIXTURE_DIR, '4819-generator-loop-callers.mjs');
    try {
      const reference = spawnSync('node', [file], { encoding: 'utf8' });
      expect(reference.status, reference.stderr).toBe(0);

      for (const minified of [false, true]) {
        const output = join(dir, minified ? 'minified.js' : 'plain.js');
        const proc = spawnSync(
          ZNTC_BIN,
          [file, '--target=es5', ...(minified ? ['--minify-identifiers'] : []), '-o', output],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${minified ? 'minified' : 'plain'}: ${proc.stderr}`).toBe(0);

        const identity = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, proc.stderr).toBeDefined();
        expect(exactSchemaProblems(identity ?? ''), proc.stderr).toEqual([]);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout, minified ? 'minified' : 'plain').toBe(reference.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('for-of catch parameter keeps exact identity beside an outer _err', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-of-catch-err-identity-'));
    const file = join(dir, 'entry.mjs');
    const source = [
      "const _err = 'outer';",
      'const iterable = {',
      '  [Symbol.iterator]() {',
      "    return { next() { throw new Error('iterator failed'); } };",
      '  },',
      '};',
      'try {',
      '  for (const value of iterable) { void value; }',
      '} catch (caught) {',
      '  console.log(`${_err}:${caught.message}`);',
      '}',
    ].join('\n');
    writeFileSync(file, source);

    try {
      const reference = spawnSync('node', [file], { encoding: 'utf8' });
      expect(reference.status, reference.stderr).toBe(0);
      expect(reference.stdout).toBe('outer:iterator failed\n');

      for (const minify of [false, true]) {
        const name = minify ? 'es5-minify' : 'es5';
        const output = join(dir, `${name}.mjs`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, '--target=es5', ...(minify ? ['--minify-identifiers'] : []), '-o', output],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${name}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${name} ${counter}: ${identity}`,
          ).toBe(0);
        }
        expect(identity, `${name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);

        const emitted = readFileSync(output, 'utf8');
        if (!minify) expect(emitted).toMatch(/catch\s*\(_err\)/);
        if (minify) {
          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${name}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );
        }

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, name).toBe(reference.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('extracted async function for-await temps keep identity and error state', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-await-extracted-async-symbols-'));
    const fixtures = [
      'forawait-arguments-in-body.mjs',
      'forawait-in-async-method-this.mjs',
      'forawait-reenter-after-throw.mjs',
      'forawait-return-closes.mjs',
    ];
    try {
      for (const fixture of fixtures) {
        const file = join(FIXTURE_DIR, fixture);
        const reference = spawnSync('node', [file], { encoding: 'utf8' });
        expect(reference.status, `${fixture}: ${reference.stderr}`).toBe(0);

        for (const target of ['--target=es5', '--target=es2015', '--target=es2022']) {
          const output = join(dir, `${fixture}-${target.slice('--target='.length)}.mjs`);
          const proc = spawnSync(ZNTC_BIN, [file, target, '--minify-identifiers', '-o', output], {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          });
          expect(proc.status, `${fixture} ${target}: ${proc.stderr}`).toBe(0);

          const lines = (proc.stderr ?? '').split(/\r?\n/);
          const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, `${fixture} ${target}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture} ${target} ${counter}: ${identity}`,
            ).toBe(0);
          }

          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${fixture} ${target}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );

          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${fixture} ${target}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, `${fixture} ${target}`).toBe(reference.stdout);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('using for-of head temps keep identity through generator and for-await extraction', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-using-loop-head-symbols-'));
    const fixtures = [
      '4730-using-26.mjs',
      '4730-using-28.mjs',
      '4730-using-30.mjs',
      'forawait-await-using-head.mjs',
    ];
    try {
      for (const fixture of fixtures) {
        const file = join(FIXTURE_DIR, fixture);
        const reference = spawnSync('node', [file], { encoding: 'utf8' });
        expect(reference.status, `${fixture}: ${reference.stderr}`).toBe(0);

        for (const target of TARGETS) {
          const output = join(dir, `${fixture}-${target.name}.mjs`);
          const proc = spawnSync(
            ZNTC_BIN,
            [file, target.arg, '--minify-identifiers', '-o', output],
            {
              env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              encoding: 'utf8',
            },
          );
          expect(proc.status, `${fixture} ${target.name}: ${proc.stderr}`).toBe(0);

          const lines = (proc.stderr ?? '').split(/\r?\n/);
          const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, `${fixture} ${target.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture} ${target.name} ${counter}: ${identity}`,
            ).toBe(0);
          }

          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${fixture} ${target.name}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );

          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${fixture} ${target.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, `${fixture} ${target.name}`).toBe(reference.stdout);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('bundled using helper references survive same-name function parameters', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-4819-using-helper-shadow-'));
    const input = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      input,
      `globalThis.events = [];\nfunction run(Symbol, __using, __callDispose) {\n  const key = globalThis.Symbol.dispose;\n  using _stack = { [key]() { events.push('outer-dispose'); } };\n  { using _error = { [key]() { events.push('inner-dispose'); } }; events.push('inner'); }\n  events.push('outer');\n}\nrun(null, null, null);\nconsole.log(events.join(','));\n`,
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--target=es2022', '--platform=node', '--format=cjs', '-o', output],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' }, encoding: 'utf8' },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const identity = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, proc.stderr).toContain('clean=1');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('inner,inner-dispose,outer,outer-dispose\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('bundled using helpers keep names visible to direct eval', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-4819-using-helper-eval-'));
    const input = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      input,
      `globalThis.events = [];\nfunction userUsing(stack, value) { events.push('user-using'); return value; }\nfunction userDispose() { events.push('user-dispose'); }\nfunction run(__using, __callDispose) {\n  events.push(eval('typeof __callDispose'));\n  using resource = { [globalThis.Symbol.dispose]() { events.push('actual-dispose'); } };\n  events.push('body');\n}\nrun(userUsing, userDispose);\nconsole.log(events.join(','));\n`,
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--target=es2022', '--platform=node', '--format=cjs', '-o', output],
        { encoding: 'utf8' },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('function,body,actual-dispose\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('split and preserved using helpers keep direct-eval-visible names distinct', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-4819-split-using-helper-eval-'));
    const input = join(dir, 'entry.js');
    const lazyA = join(dir, 'lazy-a.js');
    const lazyB = join(dir, 'lazy-b.js');
    const output = join(dir, 'out');
    writeFileSync(
      input,
      `globalThis.events = [];\nfunction userUsing(stack, value) { events.push('user-using'); return value; }\nfunction userDispose() { events.push('user-dispose'); }\nPromise.all([import('./lazy-a.js'), import('./lazy-b.js')]).then(([a, b]) => {\n  a.run(userUsing, userDispose);\n  b.run(userUsing, userDispose);\n  console.log(events.join(','));\n});\n`,
    );
    writeFileSync(
      lazyA,
      `export function run(__using, __callDispose) {\n  events.push(eval('typeof __callDispose'));\n  using resource = { [globalThis.Symbol.dispose]() { events.push('a-dispose'); } };\n  events.push('a-body');\n}\n`,
    );
    writeFileSync(
      lazyB,
      `export function run(__using, __callDispose) {\n  events.push(eval('typeof __callDispose'));\n  using resource = { [globalThis.Symbol.dispose]() { events.push('b-dispose'); } };\n  events.push('b-body');\n}\n`,
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--splitting', '--outdir', output, '--format=esm', '--target=es2022'],
        { encoding: 'utf8' },
      );
      expect(proc.status, proc.stderr).toBe(0);
      expect(proc.stderr).not.toContain('error(DebugAllocator)');
      const emittedFiles = readdirSync(output);
      expect(emittedFiles.filter((file) => file.startsWith('lazy-'))).toHaveLength(2);
      expect(emittedFiles.some((file) => file.startsWith('chunk-'))).toBe(true);
      writeFileSync(join(output, 'package.json'), JSON.stringify({ type: 'module' }));

      const actual = spawnSync('node', [join(output, 'entry.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('function,a-body,a-dispose,function,b-body,b-dispose\n');

      const preservedOutput = join(dir, 'preserved');
      const preserved = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--preserve-modules',
          `--preserve-modules-root=${dir}`,
          '--outdir',
          preservedOutput,
          '--format=esm',
          '--target=es2022',
        ],
        { encoding: 'utf8' },
      );
      expect(preserved.status, preserved.stderr).toBe(0);
      expect(readdirSync(preservedOutput).filter((file) => file.startsWith('lazy-'))).toHaveLength(
        2,
      );
      writeFileSync(join(preservedOutput, 'package.json'), JSON.stringify({ type: 'module' }));

      const preservedActual = spawnSync('node', [join(preservedOutput, 'entry.js')], {
        encoding: 'utf8',
      });
      expect(preservedActual.status, preservedActual.stderr).toBe(0);
      expect(preservedActual.stdout).toBe('function,a-body,a-dispose,function,b-body,b-dispose\n');

      const preservedCjsOutput = join(dir, 'preserved-cjs');
      const preservedCjs = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--preserve-modules',
          `--preserve-modules-root=${dir}`,
          '--outdir',
          preservedCjsOutput,
          '--format=cjs',
          '--target=es2022',
        ],
        { encoding: 'utf8' },
      );
      expect(preservedCjs.status, preservedCjs.stderr).toBe(0);

      const preservedCjsActual = spawnSync('node', [join(preservedCjsOutput, 'entry.js')], {
        encoding: 'utf8',
      });
      expect(preservedCjsActual.status, preservedCjsActual.stderr).toBe(0);
      expect(preservedCjsActual.stdout).toBe(
        'function,a-body,a-dispose,function,b-body,b-dispose\n',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('private for-in/of target temps retain their explicit loop-head binding', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-private-loop-target-symbols-'));
    const fixtures = ['4819-static-private-write-targets.mjs', 'forof-private-left-target.mjs'];
    try {
      for (const fixture of fixtures) {
        const file = join(FIXTURE_DIR, fixture);
        const reference = spawnSync('node', [file], { encoding: 'utf8' });
        expect(reference.status, `${fixture}: ${reference.stderr}`).toBe(0);

        for (const target of TARGETS) {
          const output = join(dir, `${fixture}-${target.name}.mjs`);
          const proc = spawnSync(
            ZNTC_BIN,
            [file, target.arg, '--minify-identifiers', '-o', output],
            {
              env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              encoding: 'utf8',
            },
          );
          expect(proc.status, `${fixture} ${target.name}: ${proc.stderr}`).toBe(0);

          const lines = (proc.stderr ?? '').split(/\r?\n/);
          const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, `${fixture} ${target.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture} ${target.name} ${counter}: ${identity}`,
            ).toBe(0);
          }

          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${fixture} ${target.name}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );

          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${fixture} ${target.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, `${fixture} ${target.name}`).toBe(reference.stdout);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('Flow match parameter temps stay in their generated function scope', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-flow-match-param-symbols-'));
    const file = join(FIXTURE_DIR, 'flow-match-symbols.flow.mjs');
    try {
      for (const target of TARGETS) {
        const output = join(dir, `${target.name}.mjs`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--flow', '--minify-identifiers', '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${identity}`,
          ).toBe(0);
        }
        const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
        expect(strict, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of ['missing_binding', 'unclassified', 'orphan_symbols']) {
          expect(
            Number(strict?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${strict}`,
          ).toBe(0);
        }
        expect(strict, `${target.name}: ${strict}`).toMatch(/symbol_identity_complete=1(?:\s|$)/);

        const postMinify = lines.find((line) =>
          line.startsWith('zntc: symbol-identity-post-minify '),
        );
        expect(postMinify, `${target.name}: ${proc.stderr}`).toMatch(
          /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe('4,3,5,99\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('simple anonymous ES5 classes bind their generated constructor self-read', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-anonymous-class-self-symbols-'));
    const file = join(FIXTURE_DIR, 'iife-collapse-identity.mjs');
    const reference = spawnSync('node', [file], { encoding: 'utf8' });
    try {
      expect(reference.status, reference.stderr).toBe(0);
      for (const target of TARGETS) {
        const output = join(dir, `${target.name}.mjs`);
        const proc = spawnSync(ZNTC_BIN, [file, target.arg, '--minify-identifiers', '-o', output], {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${identity}`,
          ).toBe(0);
        }
        const postMinify = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity-post-minify '));
        expect(postMinify, `${target.name}: ${proc.stderr}`).toMatch(
          /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe(reference.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('anonymous static-field class wrappers preserve class-self identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-anonymous-static-field-self-symbols-'));
    const file = join(FIXTURE_DIR, '4801-static-field-arrow-this.mjs');
    const reference = spawnSync('node', [file], { encoding: 'utf8' });
    try {
      expect(reference.status, reference.stderr).toBe(0);
      for (const target of TARGETS) {
        const output = join(dir, `${target.name}.mjs`);
        const minifyIdentifiers = target.name === 'es5' || target.name === 'esnext';
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, ...(minifyIdentifiers ? ['--minify-identifiers'] : []), '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${identity}`,
          ).toBe(0);
        }
        const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
        expect(strict, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of ['missing_binding', 'unclassified', 'orphan_symbols']) {
          expect(
            Number(strict?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${strict}`,
          ).toBe(0);
        }
        expect(strict, `${target.name}: ${strict}`).toMatch(/symbol_identity_complete=1(?:\s|$)/);
        if (minifyIdentifiers) {
          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${target.name}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe(reference.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('anonymous static-block wrappers bind distinct class-self symbols', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-anonymous-static-block-self-symbols-'));
    const file = join(FIXTURE_DIR, '4819-anonymous-class-static-block-id.mjs');
    const runAndReadClasses = (path: string) =>
      spawnSync(
        'node',
        [
          '--input-type=module',
          '-e',
          `await import((await import('node:url')).pathToFileURL(process.argv[1]).href);
const classes = globalThis.__zntcAnonymousClassSelfs;
console.log(classes.map((value) => value.readValue()).join(',') + ':' + (classes.length === 2 && classes[0] !== classes[1]));`,
          path,
        ],
        { encoding: 'utf8' },
      );
    const reference = runAndReadClasses(file);
    try {
      expect(reference.status, reference.stderr).toBe(0);
      expect(reference.stdout).toMatch(/\n10,20:true\n$/);
      for (const target of TARGETS) {
        const output = join(dir, `${target.name}.mjs`);
        const minifyIdentifiers = target.name === 'es5' || target.name === 'esnext';
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, ...(minifyIdentifiers ? ['--minify-identifiers'] : []), '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${identity}`,
          ).toBe(0);
        }
        const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
        expect(strict, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of ['missing_binding', 'unclassified', 'orphan_symbols']) {
          expect(
            Number(strict?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name} ${counter}: ${strict}`,
          ).toBe(0);
        }
        expect(strict, `${target.name}: ${strict}`).toMatch(/symbol_identity_complete=1(?:\s|$)/);
        if (minifyIdentifiers) {
          const postMinify = lines.find((line) =>
            line.startsWith('zntc: symbol-identity-post-minify '),
          );
          expect(postMinify, `${target.name}: ${proc.stderr}`).toMatch(
            /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
          );
        }
        const actual = runAndReadClasses(output);
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe(reference.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native and ES5 for-in lowering retain exact loop-head and closure scopes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-in-capture-scope-'));
    const file = join(FIXTURE_DIR, '4819-for-in-loop-capture.mjs');
    try {
      for (const target of [
        { name: 'es2015', arg: '--target=es2015', graph: 'retained' },
        { name: 'es5', arg: '--target=es5', graph: 'retained' },
      ]) {
        const output = join(dir, target.name + '.cjs');
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            file,
            target.arg,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, target.name + ': ' + proc.stderr).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') &&
              line.includes('4819-for-in-loop-capture.mjs'),
          );
        expect(report, target.name + ': ' + proc.stderr).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(counter + '=(\\d+)'))?.[1] ?? -1),
            target.name + ': ' + report,
          ).toBe(0);
        }
        expect(report, target.name + ': ' + report).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes('4819-for-in-loop-capture.mjs'),
          );
        expect(graphMode, target.name + ': ' + proc.stderr).toContain(
          'semantic_graph=' + target.graph,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, target.name + ': ' + actual.stderr).toBe(0);
        expect(actual.stdout, target.name).toBe('first,second,inherited\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native classes retain exact scopes only when all class features stay native', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-native-class-scopes-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(
      entry,
      [
        'class Base { label: string = "base"; }',
        'class Derived extends Base {',
        '  static #count: number = 0;',
        '  #value: number;',
        '  static { this.#count += 1; }',
        '  constructor(value: number) { super(); this.#value = value; }',
        '  #format(separator: string): string { return `${this.label}${separator}${this.#value}:${Derived.#count}`; }',
        '  read(): string { return this.#format(":"); }',
        '  static count(): number { return this.#count; }',
        '}',
        'const value = new Derived(7);',
        'console.log(value.read(), Derived.count());',
      ].join('\n'),
    );
    const cases = [
      { name: 'es2022', arg: '--target=es2022', graph: 'retained' },
      // ES2015 still supports class syntax, but must lower fields, private
      // members, and static blocks. ES5 also lowers the class boundary.
      { name: 'es2015', arg: '--target=es2015', graph: 'reanalyzed' },
      { name: 'es5', arg: '--target=es5', graph: 'reanalyzed' },
    ];
    try {
      for (const target of cases) {
        const output = join(dir, `${target.name}.cjs`);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            target.arg,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
          );
        expect(report, `${target.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${target.name}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(graphMode, `${target.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${target.graph}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe('base:7:1 1\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native class retention rejects each unsupported class feature that the target must lower', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-class-resync-boundaries-'));
    const cases = [
      {
        name: 'multiple-methods-with-computed-key',
        target: '--target=es5',
        source:
          'var key = "other"; class C { read() { return 7; } [key]() { return 8; } } console.log(new C().read());',
        stdout: '7\n',
      },
      {
        name: 'public-field',
        target: '--target=es2015',
        source:
          'class C { value: number = 7; read() { return this.value; } } console.log(new C().read());',
        stdout: '7\n',
      },
      {
        name: 'private-field',
        target: '--target=es2015',
        source: 'class C { #value: number = 7; read() { return 7; } } console.log(new C().read());',
        stdout: '7\n',
      },
      {
        name: 'private-method',
        target: '--target=es2015',
        source:
          'class C { #hidden() { return 7; } read() { return 7; } } console.log(new C().read());',
        stdout: '7\n',
      },
      {
        name: 'static-block',
        target: '--target=es2015',
        source:
          'class C { static { globalThis.classStaticValue = 7; } } console.log(globalThis.classStaticValue);',
        stdout: '7\n',
      },
    ];
    try {
      for (const fixture of cases) {
        const entry = join(dir, `${fixture.name}.ts`);
        const output = join(dir, `${fixture.name}.cjs`);
        writeFileSync(entry, fixture.source);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            fixture.target,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') &&
              line.includes(`${fixture.name}.ts`),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${fixture.name}: ${report}`).toMatch(/clean=1(?:\s|$)/);
        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes(`${fixture.name}.ts`),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain('semantic_graph=reanalyzed');
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native for-of and for-in retain graphs only with audited companion syntax', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-of-resync-boundaries-'));
    const cases = [
      {
        name: 'optional-chain',
        target: '--target=es2015',
        graph: 'retained',
        source: [
          'const values: Array<number | undefined> = [1, undefined];',
          'for (const value of values) console.log(value?.toFixed(0));',
        ].join('\n'),
        stdout: '1\nundefined\n',
      },
      {
        name: 'for-await',
        target: '--target=es2015',
        graph: 'reanalyzed',
        source: [
          'async function collect(values: AsyncIterable<number>) {',
          '  const output: number[] = [];',
          '  for await (const value of values) output.push(value);',
          '  return output;',
          '}',
          "collect([1, 2]).then(values => console.log(values.join(',')));",
        ].join('\n'),
        stdout: '1,2\n',
      },
      {
        name: 'unrelated-lexical-for-in',
        target: '--target=es5',
        source: [
          'var source = { first: 1 };',
          'for (let key in source) console.log(key);',
          'const outside = 2;',
          'console.log(outside);',
        ].join('\n'),
        stdout: 'first\n2\n',
      },
      {
        name: 'unrelated-lexical-lowering',
        target: '--target=es5',
        source: [
          'var values = [1];',
          'for (var value of values) console.log(value);',
          'const outside = 2;',
          'console.log(outside);',
        ].join('\n'),
        stdout: '1\n2\n',
      },
      {
        name: 'additional-runtime-helper-for-in',
        target: '--target=es5',
        source: [
          'var match = /(?<word>\\w+)/.exec("hello");',
          'var source = { first: 1 };',
          'for (const key in source) console.log(match.groups.word, key);',
        ].join('\n'),
        stdout: 'hello first\n',
      },
      {
        name: 'additional-runtime-helper',
        target: '--target=es5',
        source: [
          'var match = /(?<word>\\w+)/.exec("hello");',
          'for (var value of [match.groups.word]) console.log(value);',
        ].join('\n'),
        stdout: 'hello\n',
      },
    ];
    try {
      for (const fixture of cases) {
        const entry = join(dir, `${fixture.name}.ts`);
        const output = join(dir, `${fixture.name}.cjs`);
        writeFileSync(entry, fixture.source);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            fixture.target ?? '--target=es2015',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') &&
              line.includes(`${fixture.name}.ts`),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${fixture.name}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes(`${fixture.name}.ts`),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph ?? 'reanalyzed'}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 simple lexical for headers retain exact identities; closure capture keeps reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-retained-lexical-for-'));
    // ES5 loop-head TDZ and const-assignment behavior are not repaired here;
    // negative cases assert graph selection only.
    const cases: Array<{
      name: string;
      graph: string;
      source: string;
      stdout?: string;
      compareRuntime?: boolean;
    }> = [
      {
        name: 'simple-let-header-with-outer-shadow',
        graph: 'retained',
        source: [
          'var index = 41;',
          'var total = 0;',
          'for (let index = 0; index < 3; index++) { total += index; }',
          'console.log(total, index);',
        ].join('\n'),
        stdout: '3 41\n',
      },
      {
        name: 'closure-captures-let-header',
        graph: 'reanalyzed',
        source: [
          'var readers = [];',
          'for (let index = 0; index < 2; index++) { readers.push(function () { return index; }); }',
          'console.log(readers[0](), readers[1]());',
        ].join('\n'),
        stdout: '0 1\n',
      },
      {
        name: 'multiple-simple-let-header-bindings',
        graph: 'retained',
        source: [
          'var index = 41;',
          'var step = 99;',
          'var total = 0;',
          'for (let index = 0, step = index + 1; index < 3; index++) { total += step; }',
          'console.log(total, index, step);',
        ].join('\n'),
        stdout: '3 41 99\n',
      },
      {
        name: 'uninitialized-let-header-binding-keeps-reanalysis',
        graph: 'reanalyzed',
        source: [
          'var total = 0;',
          'for (let index, step = 1; index < 2; index++) { total += step; }',
          'console.log(total);',
        ].join('\n'),
        stdout: '0\n',
      },
      {
        name: 'self-referencing-let-header-requires-resync',
        graph: 'reanalyzed',
        compareRuntime: false,
        source: [
          'var index = 41;',
          'try { for (let index = index; index < 1; index++) {} }',
          'catch (error) { console.log(error instanceof ReferenceError); }',
        ].join('\n'),
      },
      {
        name: 'forward-let-header-reference-requires-resync',
        graph: 'reanalyzed',
        compareRuntime: false,
        source: [
          'try { for (let first = later, later = 1; first < 1; first++) {} }',
          'catch (error) { console.log(error instanceof ReferenceError); }',
        ].join('\n'),
      },
      {
        name: 'destructured-let-header-binding-keeps-reanalysis',
        graph: 'reanalyzed',
        source: [
          'var total = 0;',
          'for (let [index] = [0]; index < 1; index++) { total += index; }',
          'console.log(total);',
        ].join('\n'),
        stdout: '0\n',
      },
      {
        name: 'body-local-let-keeps-reanalysis',
        graph: 'reanalyzed',
        source: [
          'var total = 0;',
          'for (let index = 0; index < 2; index++) { let local = index; total += local; }',
          'console.log(total);',
        ].join('\n'),
        stdout: '1\n',
      },
      {
        name: 'multiple-simple-const-header-bindings-with-outer-shadow',
        graph: 'retained',
        source: [
          'var index = 41;',
          'var step = 99;',
          'var total = 0;',
          'for (const index = 0, step = index + 1; index < 1;) { total += step; break; }',
          'index++; step++;',
          'console.log(total, index, step);',
        ].join('\n'),
        stdout: '1 42 100\n',
      },
      {
        name: 'const-header-write-keeps-reanalysis',
        graph: 'reanalyzed',
        compareRuntime: false,
        source: [
          'try { for (const index = 0; index < 1; index++) {} }',
          'catch (error) { console.log(error instanceof TypeError); }',
        ].join('\n'),
      },
    ];
    try {
      for (const fixture of cases) {
        const entry = join(dir, `${fixture.name}.ts`);
        const output = join(dir, `${fixture.name}.cjs`);
        writeFileSync(entry, fixture.source);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const report = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') &&
            line.includes(`${fixture.name}.ts`),
        );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${fixture.name}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') &&
            line.includes(`${fixture.name}.ts`),
        );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        if (fixture.compareRuntime !== false)
          expect(actual.stdout, fixture.name).toBe(fixture.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 optional catch binding retains exact graphs only for audited bodies', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-optional-catch-retained-'));
    const cases = [
      {
        name: 'optional-catch-only',
        graph: 'retained',
        source: [
          'var _a = 41;',
          'try { throw 7; } catch { console.log("caught"); }',
          'console.log(_a);',
        ].join('\n'),
        stdout: 'caught\n41\n',
      },
      {
        name: 'optional-chain-static-tail',
        graph: 'retained',
        source: [
          'var value = { nested: { leaf: 9 } };',
          'try { throw 1; } catch { console.log(value?.nested.leaf); }',
          'value = null;',
          'try { throw 1; } catch { console.log(value?.nested.leaf); }',
        ].join('\n'),
        stdout: '9\nundefined\n',
      },
      {
        name: 'optional-chain-computed-tail-retained',
        graph: 'retained',
        source: [
          'var value = { nested: { leaf: 9 } };',
          'var keys = 0;',
          'function key() { keys++; return "leaf"; }',
          'try { throw 1; } catch { console.log(value?.nested[key()], keys); }',
          'value = null;',
          'try { throw 1; } catch { console.log(value?.nested[key()], keys); }',
        ].join('\n'),
        stdout: '9 1\nundefined 1\n',
      },
    ];
    try {
      for (const fixture of cases) {
        const entry = join(dir, `${fixture.name}.js`);
        const output = join(dir, `${fixture.name}.cjs`);
        writeFileSync(entry, fixture.source);
        const native = spawnSync('node', ['-e', fixture.source], { encoding: 'utf8' });
        expect(native.status, `${fixture.name}: ${native.stderr}`).toBe(0);
        expect(native.stdout, fixture.name).toBe(fixture.stdout);

        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') &&
              line.includes(`${fixture.name}.js`),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${fixture.name}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes(`${fixture.name}.js`),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 arrow-only bundler lowering retains exact output scopes and lexical captures', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function captured(_this, _arguments) {',
        '  return (() => (() => this.Math.PI)())();',
        '}',
        'function argument(_this, _arguments) {',
        '  return (() => (() => arguments[0])())();',
        '}',
        'console.log(captured.call(globalThis, 7, 8), argument(42, 8));',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('3.141592653589793 42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('node5 arrow lowering preserves nested new.target and exact symbol identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-new-target-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function Outer(_newTarget) {',
        '  this.read = () => () => [new.target, _newTarget];',
        '  this.normal = () => function() { return new.target; };',
        '}',
        'function Derived() {}',
        'var constructed = Reflect.construct(Outer, [7], Derived);',
        'var called = {}; Outer.call(called, 8);',
        'console.log(constructed.read()()[0] === Derived, constructed.read()()[1], called.read()()[0], called.normal()());',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=node5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('true 7 undefined undefined\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('es5 new.target lowering keeps the semantic reanalysis boundary', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-new-target-reanalyzed-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      ['function Foo() { return () => new.target; }', 'console.log(new Foo()() === Foo);'].join(
        '\n',
      ),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');
      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('true\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native RN parameter new.target factory bindings retain exact output scopes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-rn-param-new-target-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function Foo(_newTarget = 11, value = () => () => [new.target, _newTarget, eval("typeof _newTarget2")]) {',
        '  var captured = value()();',
        '  this.name = value.name;',
        '  this.target = captured[0];',
        '  this.parameter = captured[1];',
        '  this.evalName = captured[2];',
        '}',
        'class Derived extends Foo {}',
        'class NativeBase { constructor(_newTarget = 13, value = () => () => [new.target, _newTarget, eval("typeof _newTarget2")]) { var captured = value()(); this.target = captured[0]; this.parameter = captured[1]; this.evalName = captured[2]; } }',
        'class NativeDerived extends NativeBase {}',
        'class ExplicitNativeDerived extends NativeBase { constructor(value = () => new.target) { super(); this.explicitTarget = value(); } }',
        'var plain = new Foo();',
        'var derived = Reflect.construct(Foo, [undefined, undefined], Derived);',
        'var nativeDerived = new NativeDerived();',
        'var explicitNativeDerived = new ExplicitNativeDerived();',
        'console.log(plain.target === Foo, derived.target === Derived, plain.parameter, plain.name, plain.evalName, nativeDerived.target === NativeDerived, nativeDerived.parameter, nativeDerived.evalName, explicitNativeDerived.explicitTarget === ExplicitNativeDerived);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--platform=react-native',
          '--rn-version=0.80',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('true true 11 value undefined true 13 undefined true\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 arrow lowering retains ordinary binary expressions with exact identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-binary-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function calculate(value) { return (() => value + 1)(); }',
        'console.log(calculate(41));',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 arrows retain target-native conditional, sequence, and assignment expressions', () => {
    const cases = [
      {
        name: 'conditional',
        source: [
          'function select(value) { return (() => value ? 42 : 0)(); }',
          'console.log(select(true));',
        ].join('\n'),
      },
      {
        name: 'sequence',
        source: [
          'function sequence(value) { return (() => (value, 42))(); }',
          'console.log(sequence(0));',
        ].join('\n'),
      },
      {
        name: 'simple assignment',
        source: [
          'function assign(value) { return (() => (value = 42))(); }',
          'console.log(assign(0));',
        ].join('\n'),
      },
      {
        name: 'native compound assignment',
        source: [
          'function assign(value) { return (() => (value += 41))(); }',
          'console.log(assign(1));',
        ].join('\n'),
      },
    ];
    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-${fixture.name}-retained-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain('semantic_graph=retained');
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe('42\n');
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('ES5 arrows retain ordinary object literal properties with exact identity', () => {
    const cases = [
      {
        name: 'explicit property',
        source: [
          'function make(value) { return (() => ({ answer: value }))(); }',
          'console.log(make(42).answer);',
        ].join('\n'),
      },
      {
        name: 'shorthand property',
        source: [
          'function make(value) { return (() => ({ value }))(); }',
          'console.log(make(42).value);',
        ].join('\n'),
      },
    ];
    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-object-${fixture.name}-retained-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain('semantic_graph=retained');
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe('42\n');
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('ES5 arrows retain untagged template literals with exact identity', () => {
    const cases = [
      {
        name: 'no substitution',
        source: [
          'function label() { return (() => `answer`)(); }',
          'console.log(label(), typeof label());',
        ].join('\n'),
        output: 'answer string\n',
      },
      {
        name: 'empty head interpolation',
        source: [
          'function label(value) { return (() => `${value}`)(); }',
          'console.log(label(42), typeof label(42));',
        ].join('\n'),
        output: '42 string\n',
      },
      {
        name: 'ordered multiple substitutions',
        source: [
          'var count = 0;',
          'function label() { return (() => `${++count}-${++count}`)(); }',
          'console.log(label(), count);',
        ].join('\n'),
        output: '1-2 2\n',
      },
    ];
    for (const fixture of cases) {
      const dir = mkdtempSync(
        join(tmpdir(), `zntc-bundle-arrow-template-${fixture.name}-retained-`),
      );
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain('semantic_graph=retained');
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('ES5 downlevel forms with generated state use audited graph paths or semantic resync', () => {
    const cases = [
      {
        name: 'exponentiation',
        graph: 'retained',
        source: 'function square(value) { return (() => value ** 2)(); }\nconsole.log(square(6));',
        output: '36\n',
      },
      {
        name: 'exponentiation with Math shadow',
        graph: 'reanalyzed',
        source: [
          'const Math = { pow(left, right) { return left + right; } };',
          'function square(value) { return (() => value ** 2)(); }',
          'console.log(square(6));',
        ].join('\n'),
        output: '36\n',
      },
      {
        name: 'nullish coalescing',
        graph: 'retained',
        source:
          'function choose(value) { return (() => value ?? 7)(); }\nconsole.log(choose(null));',
        output: '7\n',
      },
      {
        name: 'exponentiation assignment',
        graph: 'retained',
        source: [
          'function square(value) { var result = value; return (() => (result **= 2))(); }',
          'console.log(square(6));',
        ].join('\n'),
        output: '36\n',
      },
      {
        name: 'exponentiation assignment with Math shadow',
        graph: 'reanalyzed',
        source: [
          'const Math = { pow(left, right) { return left + right; } };',
          'function square(input) { var value = input; return (() => (value **= 2))(); }',
          'console.log(square(6));',
        ].join('\n'),
        output: '36\n',
      },
      {
        name: 'nullish assignment',
        graph: 'retained',
        source: [
          'function choose(value) { var result = value; return (() => (result ??= 7))(); }',
          'console.log(choose(null), choose(2));',
        ].join('\n'),
        output: '7 2\n',
      },
      {
        name: 'logical AND assignment',
        graph: 'retained',
        source: [
          'function choose(value) { var result = value; return (() => (result &&= 7))(); }',
          'console.log(choose(0), choose(2));',
        ].join('\n'),
        output: '0 7\n',
      },
      {
        name: 'logical OR assignment',
        graph: 'retained',
        source: [
          'function choose(value) { var result = value; return (() => (result ||= 7))(); }',
          'console.log(choose(0), choose(2));',
        ].join('\n'),
        output: '7 2\n',
      },
      {
        name: 'logical assignment member target',
        graph: 'retained',
        source: [
          'function choose(value) { var box = { value: value }; return (() => (box.value ||= 7))(); }',
          'console.log(choose(0));',
        ].join('\n'),
        output: '7\n',
      },
      {
        name: 'logical assignment computed member target',
        graph: 'retained',
        source: [
          'var calls = 0; var box = { value: 0 };',
          'function getBox() { calls++; return box; }',
          'function getKey() { calls++; return "value"; }',
          'function choose() { return (() => (getBox()[getKey()] ||= 7))(); }',
          'console.log(choose(), calls, box.value);',
        ].join('\n'),
        output: '7 2 7\n',
      },
      {
        name: 'nullish assignment computed member target',
        graph: 'retained',
        source: [
          'var calls = 0; var box = { value: null };',
          'function getBox() { calls++; return box; }',
          'function getKey() { calls++; return "value"; }',
          'function choose() { return (() => (getBox()[getKey()] ??= 9))(); }',
          'console.log(choose(), calls, box.value);',
        ].join('\n'),
        output: '9 2 9\n',
      },
      {
        name: 'simple optional member access',
        graph: 'retained',
        source: [
          'function read(value) { return value?.field; }',
          'console.log(read(null), read({ field: 42 }));',
        ].join('\n'),
        output: 'undefined 42\n',
      },
      {
        name: 'simple optional member access in a downleveled arrow',
        graph: 'retained',
        source: [
          'var read = value => value?.field;',
          'console.log(read(null), read({ field: 42 }));',
        ].join('\n'),
        output: 'undefined 42\n',
      },
      {
        name: 'optional member access with captured receiver',
        graph: 'retained',
        source: [
          'var calls = 0; var receiver = null;',
          'function getReceiver() { calls++; return receiver; }',
          'function read() { return getReceiver()?.field; }',
          'console.log(read()); receiver = { field: 42 }; console.log(read(), calls);',
        ].join('\n'),
        output: 'undefined\n42 2\n',
      },
      {
        name: 'computed optional member access',
        graph: 'retained',
        source: [
          'var calls = 0; function key() { calls++; return "field"; }',
          'function read(value) { return value?.[key()]; }',
          'console.log(read(null), read({ field: 42 }), calls);',
        ].join('\n'),
        output: 'undefined 42 1\n',
      },
      {
        name: 'optional member call',
        graph: 'retained',
        source: [
          'var calls = 0; function argument() { calls++; return 5; }',
          'function read(value) { return value?.method(argument()); }',
          'var receiver = { n: 37, method: function (value) { return this.n + value; } };',
          'console.log(read(null), read(receiver), calls);',
        ].join('\n'),
        output: 'undefined 42 1\n',
      },
      {
        name: 'optional member call with captured receiver',
        graph: 'retained',
        source: [
          'var gets = 0; var calls = 0; var receiver = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { calls++; return 5; }',
          'function read() { return getReceiver()?.method(argument()); }',
          'console.log(read());',
          'receiver = { n: 37, method: function (value) { return this.n + value; } };',
          'console.log(read(), gets, calls);',
        ].join('\n'),
        output: 'undefined\n42 2 1\n',
      },
      {
        name: 'computed optional member call',
        graph: 'retained',
        source: [
          'var keys = 0; var calls = 0;',
          'function key() { keys++; return "method"; }',
          'function argument() { calls++; return 5; }',
          'function read(value) { return value?.[key()](argument()); }',
          'var receiver = { n: 37, method: function (value) { return this.n + value; } };',
          'console.log(read(null), read(receiver), keys, calls);',
        ].join('\n'),
        output: 'undefined 42 1 1\n',
      },
      {
        name: 'optional call on member',
        graph: 'retained',
        source: [
          'var calls = 0; function argument() { calls++; return 5; }',
          'function read(value) { return value.method?.(argument()); }',
          'var absent = { n: 37, method: null };',
          'var receiver = { n: 37, method: function (value) { return this.n + value; } };',
          'console.log(read(absent), read(receiver), calls);',
        ].join('\n'),
        output: 'undefined 42 1\n',
      },
      {
        name: 'optional call with optional receiver',
        graph: 'retained',
        source: [
          'function read(value) { return value?.method?.(); }',
          'var receiver = { n: 42, method: function () { return this.n; } };',
          'console.log(read(null), read({ method: null }), read(receiver));',
        ].join('\n'),
        output: 'undefined undefined 42\n',
      },
      {
        name: 'computed optional call on member',
        graph: 'retained',
        source: [
          'var keys = 0; var calls = 0;',
          'function key() { keys++; return "method"; }',
          'function argument() { calls++; return 5; }',
          'function read(value) { return value[key()]?.(argument()); }',
          'var absent = { n: 37, method: null };',
          'var receiver = { n: 37, method: function (value) { return this.n + value; } };',
          'console.log(read(absent), read(receiver), keys, calls);',
        ].join('\n'),
        output: 'undefined 42 2 1\n',
      },
      {
        name: 'optional call with captured receiver',
        graph: 'retained',
        source: [
          'var gets = 0; var calls = 0; var receiver = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { calls++; return 5; }',
          'function read() { return getReceiver().method?.(argument()); }',
          'receiver = { n: 37, method: null };',
          'console.log(read());',
          'receiver.method = function (value) { return this.n + value; };',
          'console.log(read(), gets, calls);',
        ].join('\n'),
        output: 'undefined\n42 2 1\n',
      },
      {
        name: 'optional call on standalone function',
        graph: 'retained',
        source: [
          'var args = 0; var calls = 0;',
          'function argument() { args++; return 5; }',
          'function answer(value) { calls++; return value + 37; }',
          'function read(method) { return method?.(argument()); }',
          'console.log(read(null), args, calls);',
          'console.log(read(answer), args, calls);',
        ].join('\n'),
        output: 'undefined 0 0\n42 1 1\n',
      },
      {
        name: 'optional call on an ordinary source call result',
        graph: 'retained',
        source: [
          'var gets = 0; var args = 0; var calls = 0;',
          'function argument() { args++; return 5; }',
          'function getTarget(enabled) { gets++; return enabled ? function (value) { calls++; return value + 37; } : null; }',
          'function read(enabled) { return getTarget(enabled)?.(argument()); }',
          'console.log(read(false), gets, args, calls);',
          'console.log(read(true), gets, args, calls);',
        ].join('\n'),
        output: 'undefined 1 0 0\n42 2 1 1\n',
      },
      {
        name: 'nested optional calls on an ordinary source call result',
        graph: 'retained',
        source: [
          'var gets = 0; var firstCalls = 0; var finalCalls = 0; var args = 0; var callable = false;',
          'function argument() { args++; return 5; }',
          'function getTarget(enabled) {',
          '  gets++;',
          '  return enabled ? function () {',
          '    firstCalls++;',
          '    return callable ? function (value) { finalCalls++; return value + 37; } : null;',
          '  } : null;',
          '}',
          'function read(enabled) { return getTarget(enabled)?.()?.(argument()); }',
          'console.log(read(false), gets, firstCalls, finalCalls, args);',
          'console.log(read(true), gets, firstCalls, finalCalls, args);',
          'callable = true;',
          'console.log(read(true), gets, firstCalls, finalCalls, args);',
        ].join('\n'),
        output: 'undefined 1 0 0 0\nundefined 2 1 0 0\n42 3 2 1 1\n',
      },
      {
        name: 'nested optional calls on an untracked global call result',
        graph: 'reanalyzed',
        source: [
          'globalThis.getTarget = function () { return function () { return function () { return 42; }; }; };',
          'function read() { return globalThis.getTarget()?.()?.(); }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'optional call on an untracked global call result',
        graph: 'reanalyzed',
        source: [
          'globalThis.getTarget = function () { return function () { return 42; }; };',
          'function read() { return globalThis.getTarget()?.(); }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'ordinary call tail after an optional call result',
        graph: 'retained',
        source: [
          'var gets = 0; var calls = 0; var args = 0; var tails = 0;',
          'function argument() { args++; return 5; }',
          'function getTarget(enabled) { gets++; return enabled ? function () { calls++; return function (value) { tails++; return value + 37; }; } : null; }',
          'function read(enabled) { return getTarget(enabled)?.()(argument()); }',
          'console.log(read(false), gets, calls, args, tails);',
          'console.log(read(true), gets, calls, args, tails);',
        ].join('\n'),
        output: 'undefined 1 0 0 0\n42 2 1 1 1\n',
      },
      {
        name: 'ordinary member tail after an optional member call result',
        graph: 'retained',
        source: [
          'var gets = 0; var methodGets = 0; var calls = 0; var args = 0; var receiver = null; var method = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { args++; return 5; }',
          'function read() { return getReceiver()?.method?.(argument()).value; }',
          'console.log(read(), gets, methodGets, args, calls);',
          'receiver = { n: 37, get method() { methodGets++; return method; } };',
          'method = function (value) { calls++; return { value: this.n + value }; };',
          'console.log(read(), gets, methodGets, args, calls);',
          'method = null;',
          'console.log(read(), gets, methodGets, args, calls);',
          'receiver = undefined;',
          'console.log(read(), gets, methodGets, args, calls);',
        ].join('\n'),
        output: 'undefined 1 0 0 0\n42 2 1 1 1\nundefined 3 2 1 1\nundefined 4 2 1 1\n',
      },
      {
        name: 'ordinary call tail after an optional member call result',
        graph: 'retained',
        source: [
          'var gets = 0; var methodGets = 0; var calls = 0; var args = 0; var tailArgs = 0; var receiver = null; var method = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { args++; return 5; }',
          'function tailArgument() { tailArgs++; return 7; }',
          'function read() { return getReceiver()?.method?.(argument()).next(tailArgument()); }',
          'console.log(read(), gets, methodGets, args, tailArgs, calls);',
          'receiver = { n: 37, get method() { methodGets++; return method; } };',
          'method = function (value) { calls++; return { value: this.n + value, next: function (tail) { return this.value + tail; } }; };',
          'console.log(read(), gets, methodGets, args, tailArgs, calls);',
          'method = null;',
          'console.log(read(), gets, methodGets, args, tailArgs, calls);',
          'receiver = undefined;',
          'console.log(read(), gets, methodGets, args, tailArgs, calls);',
        ].join('\n'),
        output: 'undefined 1 0 0 0 0\n49 2 1 1 1 1\nundefined 3 2 1 1 1\nundefined 4 2 1 1 1\n',
      },
      {
        name: 'optional call tail after an optional member call result',
        graph: 'retained',
        source: [
          'var gets = 0; var methodGets = 0; var nextGets = 0; var calls = 0; var tails = 0; var args = 0; var tailArgs = 0; var receiver = null; var method = null; var next = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { args++; return 5; }',
          'function tailArgument() { tailArgs++; return 7; }',
          'function read() { return getReceiver()?.method?.(argument()).next?.(tailArgument()); }',
          'console.log(read(), gets, methodGets, nextGets, args, tailArgs, calls, tails);',
          'receiver = { n: 37, get method() { methodGets++; return method; } };',
          'method = function (value) { calls++; return { value: this.n + value, get next() { nextGets++; return next; } }; };',
          'next = function (tail) { tails++; return this.value + tail; };',
          'console.log(read(), gets, methodGets, nextGets, args, tailArgs, calls, tails);',
          'next = null;',
          'console.log(read(), gets, methodGets, nextGets, args, tailArgs, calls, tails);',
          'method = null;',
          'console.log(read(), gets, methodGets, nextGets, args, tailArgs, calls, tails);',
          'receiver = undefined;',
          'console.log(read(), gets, methodGets, nextGets, args, tailArgs, calls, tails);',
          'receiver = { n: 37, get method() { methodGets++; return method; } }; method = function () { calls++; return null; };',
          'try { read(); } catch (error) { console.log(error.name, gets, methodGets, nextGets, args, tailArgs, calls, tails); }',
        ].join('\n'),
        output:
          'undefined 1 0 0 0 0 0 0\n49 2 1 1 1 1 1 1\nundefined 3 2 2 2 1 2 1\nundefined 4 3 2 2 1 2 1\nundefined 5 3 2 2 1 2 1\nTypeError 6 4 2 3 1 3 1\n',
      },
      {
        name: 'optional call tail after an untracked optional member call result',
        graph: 'reanalyzed',
        source: [
          'var args = 0;',
          'globalThis.getReceiver = function () { return null; };',
          'function tailArgument() { args++; return 7; }',
          'function read() { return getReceiver()?.method?.().next?.(tailArgument()); }',
          'console.log(read(), args);',
          'globalThis.getReceiver = function () { return { method: null }; };',
          'console.log(read(), args);',
          'globalThis.getReceiver = function () { return { method: function () { return { value: 42, next: function (tail) { return this.value + tail; } }; } }; };',
          'console.log(read(), args);',
        ].join('\n'),
        output: 'undefined 0\nundefined 0\n49 1\n',
      },
      {
        name: 'optional call tail on the result of an optional member call',
        graph: 'retained',
        source: [
          'var gets = 0; var methodGets = 0; var calls = 0; var tails = 0; var args = 0; var tailArgs = 0; var receiver = null; var method = null; var returned = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { args++; return 5; }',
          'function tailArgument() { tailArgs++; return 7; }',
          'function read() { return getReceiver()?.method?.(argument())?.(tailArgument()); }',
          'console.log(read(), gets, methodGets, args, tailArgs, calls, tails);',
          'receiver = { n: 37, get method() { methodGets++; return method; } };',
          'method = null;',
          'console.log(read(), gets, methodGets, args, tailArgs, calls, tails);',
          'method = function (value) { calls++; if (this.n !== 37) throw new Error("wrong method this"); return returned; };',
          'returned = function (tail) { "use strict"; tails++; return this === undefined ? 12 : -1; };',
          'console.log(read(), gets, methodGets, args, tailArgs, calls, tails);',
          'returned = null;',
          'console.log(read(), gets, methodGets, args, tailArgs, calls, tails);',
          'receiver = undefined;',
          'console.log(read(), gets, methodGets, args, tailArgs, calls, tails);',
        ].join('\n'),
        output:
          'undefined 1 0 0 0 0 0\nundefined 2 1 0 0 0 0\n12 3 2 1 1 1 1\nundefined 4 3 2 1 2 1\nundefined 5 3 2 1 2 1\n',
      },
      {
        name: 'optional call tail on the result of an untracked optional member call',
        graph: 'reanalyzed',
        source: [
          'var args = 0; var tailArgs = 0;',
          'globalThis.getReceiver = function () { return null; };',
          'function argument() { args++; return 5; }',
          'function tailArgument() { tailArgs++; return 7; }',
          'function read() { return getReceiver()?.method?.(argument())?.(tailArgument()); }',
          'console.log(read(), args, tailArgs);',
          'globalThis.getReceiver = function () { return { method: null }; };',
          'console.log(read(), args, tailArgs);',
          'globalThis.getReceiver = function () { return { method: function () { return function (tail) { "use strict"; return this === undefined ? 12 : -1; }; } }; };',
          'console.log(read(), args, tailArgs);',
        ].join('\n'),
        output: 'undefined 0 0\nundefined 0 0\n12 1 1\n',
      },
      {
        name: 'ordinary member tail after an untracked optional member call result',
        graph: 'reanalyzed',
        source: [
          'globalThis.getReceiver = function () { return { method: function () { return { value: 42 }; } }; };',
          'function read() { return getReceiver()?.method?.().value; }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'ordinary call tail after an untracked optional member call',
        graph: 'reanalyzed',
        source: [
          'globalThis.getTarget = function () { return function () { return 42; }; };',
          'function read() { return globalThis.getTarget?.()(); }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'ordinary call tail after an optional call on an untracked call result',
        graph: 'reanalyzed',
        source: [
          'globalThis.getTarget = function () { return function () { return function () { return 42; }; }; };',
          'function read() { return globalThis.getTarget()?.()(); }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'optional indirect eval remains on reanalysis path',
        graph: 'reanalyzed',
        source: [
          'function read() { var localOnly = 42; return eval?.("typeof localOnly"); }',
          'console.log(read());',
        ].join('\n'),
        output: 'undefined\n',
      },
      {
        name: 'chained optional member call',
        graph: 'retained',
        source: [
          'var gets = 0; var calls = 0;',
          'var receiver = { child: { answer: 42, method: function () { calls++; return this.answer; } } };',
          'function getReceiver() { gets++; return receiver; }',
          'function read() { return getReceiver()?.child.method(); }',
          'console.log(read(), gets, calls);',
          'receiver = null;',
          'console.log(read(), gets, calls);',
        ].join('\n'),
        output: '42 1 1\nundefined 2 1\n',
      },
      {
        name: 'chained optional member receiver',
        graph: 'retained',
        source: [
          'var gets = 0; var calls = 0;',
          'var receiver = { child: { n: 37, method: function () { calls++; return this.n; } } };',
          'function getReceiver() { gets++; return receiver; }',
          'function read() { return getReceiver()?.child?.method?.(); }',
          'console.log(read(), gets, calls);',
          'receiver = { child: null };',
          'console.log(read(), gets, calls);',
          'receiver = null;',
          'console.log(read(), gets, calls);',
        ].join('\n'),
        output: '37 1 1\nundefined 2 1\nundefined 3 1\n',
      },
      {
        name: 'chained computed optional member receiver',
        graph: 'retained',
        source: [
          'var gets = 0; var keys = 0; var calls = 0;',
          'var receiver = { child: { n: 37, method: function () { calls++; return this.n; } } };',
          'function getReceiver() { gets++; return receiver; }',
          'function key() { keys++; return "child"; }',
          'function read() { return getReceiver()?.[key()]?.method?.(); }',
          'console.log(read(), gets, keys, calls);',
          'receiver = { child: null };',
          'console.log(read(), gets, keys, calls);',
          'receiver = { child: { n: 42, method: null } };',
          'console.log(read(), gets, keys, calls);',
          'receiver = null;',
          'console.log(read(), gets, keys, calls);',
        ].join('\n'),
        output: '37 1 1 1\nundefined 2 2 1\nundefined 3 3 1\nundefined 4 3 1\n',
      },
      {
        name: 'chained computed optional receiver preserves parameter identity',
        graph: 'retained',
        source: [
          'var gets = 0; var receiver = { first: { value: 41 }, second: { value: 42 } };',
          'function getReceiver() { gets++; return receiver; }',
          'function read(key) { return getReceiver()?.[key]?.value; }',
          'console.log(read("first"), read("second"), gets);',
          'receiver = null;',
          'console.log(read("first"), gets);',
        ].join('\n'),
        output: '41 42 2\nundefined 3\n',
      },
      {
        name: 'chained optional member with computed tails',
        graph: 'retained',
        source: [
          'var gets = 0; var keys = 0; var methodKeys = 0; var calls = 0;',
          'var receiver = { child: { selected: { answer: 42, method: function () { calls++; return this.answer; } } } };',
          'function getReceiver() { gets++; return receiver; }',
          'function key() { keys++; return "selected"; }',
          'function methodKey() { methodKeys++; return "method"; }',
          'function read() { return getReceiver()?.child[key()][methodKey()](); }',
          'console.log(read(), gets, keys, methodKeys, calls);',
          'receiver = null;',
          'console.log(read(), gets, keys, methodKeys, calls);',
          'receiver = { child: null };',
          'try { read(); } catch (error) { console.log(error.name, gets, keys, methodKeys, calls); }',
          'receiver = { child: { selected: null } };',
          'try { read(); } catch (error) { console.log(error.name, gets, keys, methodKeys, calls); }',
        ].join('\n'),
        output: '42 1 1 1 1\nundefined 2 1 1 1\nTypeError 3 2 1 1\nTypeError 4 3 2 1\n',
      },
      {
        name: 'computed optional tail with untracked member receiver',
        graph: 'reanalyzed',
        source: [
          'globalThis.receiver = { child: { answer: 42, method: function () { return this.answer; } } };',
          'var keys = 0;',
          'function key() { keys++; return "method"; }',
          'function read() { return globalThis.receiver?.child[key()](); }',
          'console.log(read(), keys);',
        ].join('\n'),
        output: '42 1\n',
      },
      {
        name: 'optional call with nested receiver',
        graph: 'retained',
        source: [
          'var factories = 0; var invocations = 0; var receiver = { n: 37, method: null };',
          'function factory() { factories++; return function () { invocations++; return receiver; }; }',
          'function read() { return factory()().method?.(); }',
          'console.log(read(), factories, invocations);',
          'receiver.method = function () { return this.n + 5; };',
          'console.log(read(), factories, invocations);',
        ].join('\n'),
        output: 'undefined 1 1\n42 2 2\n',
      },
      {
        name: 'optional call with nested optional receiver',
        graph: 'retained',
        source: [
          'function factory() { return function () { return { method: function () { return 42; } }; }; }',
          'function read() { return factory()?.().method?.(); }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'optional member call result feeds an optional member access',
        graph: 'retained',
        source: [
          'var gets = 0; var methodGets = 0; var calls = 0; var args = 0; var receiver = null; var method = null;',
          'function getReceiver() { gets++; return receiver; }',
          'function argument() { args++; return 5; }',
          'function read() { return getReceiver()?.method?.(argument())?.value; }',
          'console.log(read(), gets, methodGets, args, calls);',
          'receiver = { n: 37, get method() { methodGets++; return method; } };',
          'console.log(read(), gets, methodGets, args, calls);',
          'method = function (value) { calls++; return { value: this.n + value }; };',
          'console.log(read(), gets, methodGets, args, calls);',
          'method = function () { calls++; return null; };',
          'console.log(read(), gets, methodGets, args, calls);',
          'receiver = null;',
          'console.log(read(), gets, methodGets, args, calls);',
          'receiver = undefined;',
          'console.log(read(), gets, methodGets, args, calls);',
          'receiver = { n: 37, get method() { methodGets++; return method; } }; method = undefined;',
          'console.log(read(), gets, methodGets, args, calls);',
        ].join('\n'),
        output:
          'undefined 1 0 0 0\nundefined 2 1 0 0\n42 3 2 1 1\nundefined 4 3 2 2\nundefined 5 3 2 2\nundefined 6 3 2 2\nundefined 7 4 2 2\n',
      },
      {
        name: 'optional member and call chain rooted at an unbound global',
        graph: 'reanalyzed',
        source: [
          'globalThis.getReceiver = function () { return { method: function () { return { value: 42 }; } }; };',
          'function read() { return getReceiver()?.method?.()?.value; }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'destructuring assignment',
        graph: 'retained',
        source: [
          'function assign(value) { var result = 0; (() => ([result] = value))(); return result; }',
          'console.log(assign([42]));',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'computed object property',
        source: [
          'function make(key, value) { return (() => ({ [key]: value }))(); }',
          'console.log(make("answer", 42).answer);',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'object spread',
        source: [
          'var source = { answer: 42 };',
          'function make() { return (() => ({ ...source }))(); }',
          'console.log(make().answer);',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'object method',
        graph: 'retained',
        source: [
          'function make(value) { return (() => ({ answer() { return value; } }))(); }',
          'console.log(make(42).answer());',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'destructured arrow parameter',
        graph: 'retained',
        source: [
          'function make(value) { return (({ answer }) => (() => answer)())({ answer: value }); }',
          'console.log(make(42));',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'destructured catch binding',
        source: [
          'function read(value) { try { throw value; } catch ({ answer }) { return (() => answer)(); } }',
          'console.log(read({ answer: 42 }));',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'tagged template',
        graph: 'retained',
        source: [
          'function tag(parts, value) { return parts[0] + value; }',
          'function render(value) { return (() => tag`answer:${value}`)(); }',
          'console.log(render(42));',
        ].join('\n'),
        output: 'answer:42\n',
      },
    ];
    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-${fixture.name}-resync-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        const expectedGraph =
          fixture.graph ??
          (fixture.name === 'object method' ||
          fixture.name === 'computed object property' ||
          fixture.name === 'object spread'
            ? 'retained'
            : 'reanalyzed');
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${expectedGraph}`,
        );
        if (expectedGraph === 'retained') {
          const report = (proc.stderr ?? '')
            .split(/\r?\n/)
            .find(
              (line) =>
                line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
            );
          expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            const expected =
              fixture.shadowedExternal && counter === 'shadowed_external_reference' ? 1 : 0;
            expect(
              Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture.name}: ${counter}: ${report}`,
            ).toBe(expected);
          }
          expect(report, fixture.name).toMatch(
            fixture.shadowedExternal ? /clean=0(?:\s|$)/ : /clean=1(?:\s|$)/,
          );
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  }, 30_000);

  test('direct eval keeps ES5 arrow lowering on the semantic resync path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-eval-resync-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      ['function dynamic(_this) { return (() => eval("1"))(); }', 'console.log(dynamic(8));'].join(
        '\n',
      ),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('1\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 lexical declarations keep arrow lowering on the semantic resync path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-lexical-resync-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function read() {',
        '  let value = 41;',
        '  return () => value + 1;',
        '}',
        'console.log(read()());',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('TypeScript type erasure and ES5 arrow lowering retain exact semantic identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-typed-arrow-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.ts'),
      [
        'type Numeric<T> = T extends number ? T : never;',
        'interface Marker { readonly value: number }',
        'type Result = Numeric<number>;',
        'function read<T extends number>(value: T): Result {',
        '  var result: Result = value as number;',
        '  return (() => result)();',
        '}',
        'var output: Result = read(42);',
        'console.log(output);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${report}`,
        ).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native function and top-level await keep TypeScript erasure on the edited semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-await-retained-'));
    const output = join(dir, 'out.cjs');
    const esmOutput = join(dir, 'tla-out.mjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Resolver = { resolve(value: number): number };',
        'async function compute(Promise: Resolver, value: number) {',
        '  const result: number = await Promise.resolve(value);',
        '  return result;',
        '}',
        'compute({ resolve: (value) => value + 1 }, 41).then(value => console.log(value));',
      ].join('\n'),
    );

    const run = (target: string, format = 'cjs', outputPath = output) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          `--format=${format}`,
          '--minify-identifiers',
          '-o',
          outputPath,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    try {
      const native = run('--target=es2022');
      expect(native.status, native.stderr).toBe(0);
      const nativeMode = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(nativeMode, native.stderr).toContain('semantic_graph=retained');
      const nativeReport = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeReport, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeReport}`,
        ).toBe(0);
      }
      expect(nativeReport).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('42\n');

      // Downlevel async transforms replace the source function body and must
      // remain on the established semantic reanalysis path.
      const downlevel = run('--target=es2015');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const downlevelMode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(downlevelMode, downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('42\n');

      // Native TLA keeps the parser's exact async-module fact and graph.
      writeFileSync(
        input,
        [
          'type Numeric = number;',
          'const Promise = { resolve(value: Numeric): Numeric { return value + 1; } };',
          'const result: Numeric = await Promise.resolve(41);',
          'console.log(result);',
        ].join('\n'),
      );
      const topLevelAwait = run('--target=es2022', 'esm', esmOutput);
      expect(topLevelAwait.status, topLevelAwait.stderr).toBe(0);
      const topLevelAwaitMode = (topLevelAwait.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(topLevelAwaitMode, topLevelAwait.stderr).toContain('semantic_graph=retained');
      const topLevelAwaitReport = (topLevelAwait.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(topLevelAwaitReport, topLevelAwait.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(topLevelAwaitReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${topLevelAwaitReport}`,
        ).toBe(0);
      }
      expect(topLevelAwaitReport).toMatch(/clean=1(?:\s|$)/);
      const topLevelAwaitOutput = spawnSync('node', [esmOutput], { encoding: 'utf8' });
      expect(topLevelAwaitOutput.status, topLevelAwaitOutput.stderr).toBe(0);
      expect(topLevelAwaitOutput.stdout).toBe('42\n');

      // TLA downleveling moves await into a generated async IIFE and still
      // requires the established post-transform semantic analysis.
      const loweredTopLevelAwait = run('--target=es2019', 'esm', esmOutput);
      expect(loweredTopLevelAwait.status, loweredTopLevelAwait.stderr).toBe(0);
      const loweredMode = (loweredTopLevelAwait.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(loweredMode, loweredTopLevelAwait.stderr).toContain('semantic_graph=reanalyzed');
      const loweredOutput = spawnSync('node', [esmOutput], { encoding: 'utf8' });
      expect(loweredOutput.status, loweredOutput.stderr).toBe(0);
      expect(loweredOutput.stdout).toBe('42\n');

      // The same downlevel veto must hold when neither the ESM export deferral
      // nor the IIFE async-factory path applies.
      const loweredCjsTopLevelAwait = run('--target=es2019', 'cjs');
      expect(loweredCjsTopLevelAwait.status, loweredCjsTopLevelAwait.stderr).toBe(0);
      const loweredCjsMode = (loweredCjsTopLevelAwait.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(loweredCjsMode, loweredCjsTopLevelAwait.stderr).toContain('semantic_graph=reanalyzed');
      const loweredCjsOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(loweredCjsOutput.status, loweredCjsOutput.stderr).toBe(0);
      expect(loweredCjsOutput.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native sync generators keep TypeScript erasure on the edited semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-generator-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Count = number;',
        'function* numbers(start: Count) {',
        '  var sent: Count = yield start;',
        '  for (const value of [sent, sent + 1]) yield value;',
        '  return sent;',
        '}',
        'var iterator = numbers(41);',
        'var first = iterator.next();',
        'var second = iterator.next(42);',
        'var third = iterator.next();',
        'var fourth = iterator.next();',
        'console.log(first.value, first.done, second.value, second.done, third.value, third.done, fourth.value, fourth.done);',
      ].join('\n'),
    );

    const run = (target: string) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    const graphMode = (stderr: string | null) =>
      stderr
        ?.split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );

    try {
      const native = run('--target=es2015');
      expect(native.status, native.stderr).toBe(0);
      expect(graphMode(native.stderr), native.stderr).toContain('semantic_graph=retained');
      const report = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('41 false 42 false 43 false 42 true\n');

      // Downlevel state-machine and per-iteration loop bindings keep their
      // exact SymbolIds and ScopeIds without running a replacement analyzer.
      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expect(graphMode(downlevel.stderr), downlevel.stderr).toContain('semantic_graph=retained');
      const downlevelReport = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(downlevelReport, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(downlevelReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${downlevelReport}`,
        ).toBe(0);
      }
      expect(downlevelReport).toMatch(/clean=1(?:\s|$)/);
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('41 false 42 false 43 false 42 true\n');

      // Direct eval observes source names, so it stays on semantic reanalysis.
      writeFileSync(
        input,
        [
          'function* values() {',
          '  var sourceName = 41;',
          "  eval('console.log(sourceName + 1)');",
          '  yield sourceName;',
          '}',
          'var iterator = values();',
          'console.log(iterator.next().value);',
        ].join('\n'),
      );
      const directEval = run('--target=es5');
      expect(directEval.status, directEval.stderr).toBe(0);
      expect(graphMode(directEval.stderr), directEval.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      const directEvalOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(directEvalOutput.status, directEvalOutput.stderr).toBe(0);
      expect(directEvalOutput.stdout).toBe('42\n41\n');

      // Generator methods are outside this bounded graph-retention slice.
      writeFileSync(
        input,
        [
          'var object = { *values() { yield 42; } };',
          'console.log(object.values().next().value);',
        ].join('\n'),
      );
      const generatorMethod = run('--target=es5');
      expect(generatorMethod.status, generatorMethod.stderr).toBe(0);
      expect(graphMode(generatorMethod.stderr), generatorMethod.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      const generatorMethodOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(generatorMethodOutput.status, generatorMethodOutput.stderr).toBe(0);
      expect(generatorMethodOutput.stdout).toBe('42\n');

      // Async generators remain conservative even for a native-capable target.
      writeFileSync(
        input,
        [
          'type Count = number;',
          'async function* numbers(start: Count) { yield start; }',
          'numbers(42).next().then(result => console.log(result.value, result.done));',
        ].join('\n'),
      );
      const asyncGenerator = run('--target=es2022');
      expect(asyncGenerator.status, asyncGenerator.stderr).toBe(0);
      expect(graphMode(asyncGenerator.stderr), asyncGenerator.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      const asyncOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(asyncOutput.status, asyncOutput.stderr).toBe(0);
      expect(asyncOutput.stdout).toBe('42 false\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES2017 for-await loop lowering retains its exact semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es2017-for-await-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.js');
    writeFileSync(
      input,
      [
        'async function consume(values) {',
        '  let total = 0;',
        '  for await (const value of values) total += value;',
        '  console.log(total);',
        '}',
        'consume([20, 22]);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es2017',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const mode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, proc.stderr).toContain('semantic_graph=retained');
      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${report}`,
        ).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const execution = spawnSync('node', [output], { encoding: 'utf8' });
      expect(execution.status, execution.stderr).toBe(0);
      expect(execution.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('for-await lowering retains only the supported async-function semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-for-await-retained-'));
    const output = join(dir, 'out.cjs');
    const esmOutput = join(dir, 'tla-out.mjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'type Values = AsyncIterable<Numeric>;',
        'const source: Values = {',
        '  [Symbol.asyncIterator]() {',
        '    let value = 0;',
        '    return {',
        '      async next() {',
        '        value += 1;',
        '        return { value, done: false };',
        '      },',
        '      async return() {',
        "        console.log('closed');",
        '        return { value: undefined, done: true };',
        '      },',
        '    };',
        '  },',
        '};',
        'async function consume(iterable: Values) {',
        '  let total: Numeric = 0;',
        '  for await (const value of iterable) {',
        '    total += value;',
        '    if (total >= 3) break;',
        '  }',
        '  console.log(total);',
        '}',
        'consume(source);',
      ].join('\n'),
    );

    const run = (target: string, format = 'cjs', outputPath = output) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          `--format=${format}`,
          '--minify-identifiers',
          '-o',
          outputPath,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    try {
      const native = run('--target=es2018');
      expect(native.status, native.stderr).toBe(0);
      const nativeMode = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(nativeMode, native.stderr).toContain('semantic_graph=retained');
      const nativeReport = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeReport, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeReport}`,
        ).toBe(0);
      }
      expect(nativeReport).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('closed\n3\n');

      const downlevel = run('--target=es2017');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const downlevelMode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(downlevelMode, downlevel.stderr).toContain('semantic_graph=retained');
      const downlevelReport = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(downlevelReport, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(downlevelReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${downlevelReport}`,
        ).toBe(0);
      }
      expect(downlevelReport).toMatch(/clean=1(?:\s|$)/);
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('closed\n3\n');

      // ES2015 also lowers async/await itself, which changes the enclosing
      // function scope and must continue through semantic reanalysis.
      const loweredAsync = run('--target=es2015');
      expect(loweredAsync.status, loweredAsync.stderr).toBe(0);
      const loweredAsyncMode = (loweredAsync.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(loweredAsyncMode, loweredAsync.stderr).toContain('semantic_graph=reanalyzed');
      const loweredAsyncOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(loweredAsyncOutput.status, loweredAsyncOutput.stderr).toBe(0);
      expect(loweredAsyncOutput.stdout).toBe('closed\n3\n');

      // A module-level for-await is also TLA; native targets keep both the
      // async-module fact and the source iteration scope.
      writeFileSync(
        input,
        [
          'type Numeric = number;',
          'type Values = AsyncIterable<Numeric>;',
          'const source: Values = {',
          '  [Symbol.asyncIterator]() {',
          '    let value = 0;',
          '    return {',
          '      async next() {',
          '        value += 1;',
          '        return { value, done: false };',
          '      },',
          '      async return() {',
          "        console.log('closed');",
          '        return { value: undefined, done: true };',
          '      },',
          '    };',
          '  },',
          '};',
          'let total: Numeric = 0;',
          'for await (const value of source) {',
          '  total += value;',
          '  if (total >= 3) break;',
          '}',
          'console.log(total);',
        ].join('\n'),
      );
      const nativeTopLevel = run('--target=es2022', 'esm', esmOutput);
      expect(nativeTopLevel.status, nativeTopLevel.stderr).toBe(0);
      const nativeTopLevelMode = (nativeTopLevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(nativeTopLevelMode, nativeTopLevel.stderr).toContain('semantic_graph=retained');
      const nativeTopLevelReport = (nativeTopLevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeTopLevelReport, nativeTopLevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeTopLevelReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeTopLevelReport}`,
        ).toBe(0);
      }
      expect(nativeTopLevelReport).toMatch(/clean=1(?:\s|$)/);
      const nativeTopLevelOutput = spawnSync('node', [esmOutput], { encoding: 'utf8' });
      expect(nativeTopLevelOutput.status, nativeTopLevelOutput.stderr).toBe(0);
      expect(nativeTopLevelOutput.stdout).toBe('closed\n3\n');

      const loweredTopLevel = run('--target=es2017', 'esm', esmOutput);
      expect(loweredTopLevel.status, loweredTopLevel.stderr).toBe(0);
      const loweredTopLevelMode = (loweredTopLevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(loweredTopLevelMode, loweredTopLevel.stderr).toContain('semantic_graph=reanalyzed');
      const loweredTopLevelOutput = spawnSync('node', [esmOutput], { encoding: 'utf8' });
      expect(loweredTopLevelOutput.status, loweredTopLevelOutput.stderr).toBe(0);
      expect(loweredTopLevelOutput.stdout).toBe('closed\n3\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native destructuring retains binding and assignment identities while ES5 reanalyzes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-destructuring-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Pair = [number, number];',
        'type Values = { left: number; right: number };',
        'const pair: Pair = [20, 22];',
        'const [first, second]: Pair = pair;',
        'const source: Values = { left: first, right: second };',
        'const { left, right: renamedRight }: Values = source;',
        "const selectedKey: 'left' = 'left';",
        'const { [selectedKey]: computedLeft }: Values = source;',
        'type Nested = { coords: Pair };',
        'const nestedSource: Nested = { coords: pair };',
        'const { coords: [nestedLeft, nestedRight] }: Nested = nestedSource;',
        'function add({ left: a, right: b }: Values) {',
        '  const [x, y]: Pair = [a, b];',
        '  return x + y;',
        '}',
        'let assignedLeft = 0;',
        'let assignedRight = 0;',
        '({ left: assignedLeft, right: assignedRight } = source);',
        'let total = 0;',
        'for (const { left: current } of [{ left: first }, { left: second }]) total += current;',
        'console.log(add({ left: assignedLeft, right: assignedRight }), nestedLeft + nestedRight, computedLeft, left, renamedRight, total);',
      ].join('\n'),
    );

    const run = (target: string) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    try {
      const native = run('--target=es2015');
      expect(native.status, native.stderr).toBe(0);
      const nativeMode = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(nativeMode, native.stderr).toContain('semantic_graph=retained');
      const nativeReport = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeReport, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeReport}`,
        ).toBe(0);
      }
      expect(nativeReport).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('42 42 20 20 22 42\n');

      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const downlevelMode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(downlevelMode, downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('42 42 20 20 22 42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native and ES5 destructuring defaults and array rest retain supported identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-destructuring-defaults-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Values = [number | undefined, number, number];',
        'var values: Values = [undefined, 20, 30];',
        'var [head = 11, ...tail]: Values = values;',
        'var assigned = 0;',
        'var assignedTail: number[] = [];',
        '[assigned = 17, ...assignedTail] = [undefined, 40, 50];',
        "console.log(head, tail.join(','), assigned, assignedTail.join(','));",
      ].join('\n'),
    );

    const run = (target: string) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    const mode = (stderr: string) =>
      stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
    try {
      const native = run('--target=es2015');
      expect(native.status, native.stderr).toBe(0);
      expect(mode(native.stderr ?? ''), native.stderr).toContain('semantic_graph=retained');
      const nativeReport = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeReport, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeReport}`,
        ).toBe(0);
      }
      expect(nativeReport).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('11 20,30 17 40,50\n');

      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expect(mode(downlevel.stderr ?? ''), downlevel.stderr).toContain('semantic_graph=retained');
      const downlevelReport = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(downlevelReport, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(downlevelReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${downlevelReport}`,
        ).toBe(0);
      }
      expect(downlevelReport).toMatch(/clean=1(?:\s|$)/);
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('11 20,30 17 40,50\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 var destructuring declarations retain exact semantic identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-var-destructuring-retained-'));
    const input = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    const run = (source: string) => {
      writeFileSync(input, source);
      return spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    };
    const mode = (stderr: string) =>
      stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
    const assertOutput = (expected: string) => {
      const result = spawnSync('node', [output], { encoding: 'utf8' });
      expect(result.status, result.stderr).toBe(0);
      expect(result.stdout).toBe(expected);
    };

    try {
      const retainedCases = [
        {
          name: 'program-scope array binding',
          source: 'var [left, right] = [20, 22]; console.log(left + right);',
          expected: '42\n',
        },
        {
          name: 'function var hoisted from nested block',
          source: [
            'function read(input: number[]) {',
            '  { var [head, ...tail] = input; }',
            '  return head + tail.length;',
            '}',
            'console.log(read([10, 20, 30]));',
          ].join('\n'),
          expected: '12\n',
        },
        {
          name: 'array default and rest helpers',
          source: [
            'var source: (number | undefined)[] = [undefined, 20, 30];',
            'var [head = 11, ...tail] = source;',
            "console.log(head, tail.join(','));",
          ].join('\n'),
          expected: '11 20,30\n',
        },
        {
          name: 'computed nested object default and rest helper',
          source: [
            "var key = 'selected';",
            'var source = { selected: { value: 4 }, extra: 7 };',
            'var { [key]: { value = 3 } = {}, ...rest } = source;',
            'console.log(value, rest.extra);',
          ].join('\n'),
          expected: '4 7\n',
        },
        {
          name: 'computed destructuring key stays captured through nested default reads',
          source: [
            "var selected = 'first';",
            'var source = {',
            "  get first() { selected = 'second'; return { value: 5 }; },",
            '  second: { value: 9 },',
            '};',
            'var { [selected]: { value = 3 } = {}, ...rest } = source;',
            'console.log(value, selected, rest.second.value);',
          ].join('\n'),
          expected: '5 second 9\n',
          nativeOracle: true,
        },
      ];

      for (const fixture of retainedCases) {
        const proc = run(fixture.source);
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        expect(mode(proc.stderr ?? ''), `${fixture.name}: ${proc.stderr}`).toContain(
          'semantic_graph=retained',
        );
        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
          );
        expect(report, fixture.name).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name} ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report).toMatch(/generated_bindings=[1-9]\d*/);
        expect(report).toMatch(/generated_references=[1-9]\d*/);
        expect(report).toMatch(/clean=1(?:\s|$)/);
        if ('nativeOracle' in fixture) {
          const native = spawnSync('node', ['-e', fixture.source], { encoding: 'utf8' });
          expect(native.status, `${fixture.name}: ${native.stderr}`).toBe(0);
          expect(native.stdout).toBe(fixture.expected);
        }
        assertOutput(fixture.expected);
      }

      const reanalyzedCases = [
        {
          name: 'lexical let binding',
          source: 'let [value] = [7]; console.log(value);',
          expected: '7\n',
        },
        {
          name: 'parameter pattern with nested default',
          source: 'function get([value = 7]: number[]) { return value; } console.log(get([]));',
          expected: '7\n',
        },
        {
          name: 'for-of declaration head',
          source: 'var sum = 0; for (var [value] of [[7], [8]]) sum += value; console.log(sum);',
          expected: '15\n',
        },
      ];

      for (const fixture of reanalyzedCases) {
        const proc = run(fixture.source);
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        expect(mode(proc.stderr ?? ''), `${fixture.name}: ${proc.stderr}`).toContain(
          'semantic_graph=reanalyzed',
        );
        assertOutput(fixture.expected);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 destructuring assignments retain exact semantic identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-destructuring-assignment-retained-'));
    const input = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    const run = (source: string) => {
      writeFileSync(input, source);
      return spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    };
    const mode = (stderr: string) =>
      stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
    const assertOutput = (expected: string) => {
      const result = spawnSync('node', [output], { encoding: 'utf8' });
      expect(result.status, result.stderr).toBe(0);
      expect(result.stdout).toBe(expected);
    };

    try {
      const retainedCases = [
        {
          name: 'nested object assignment writes existing symbols',
          source: [
            'var left = 0; var deep = 0;',
            '({ left, nested: { value: deep } } = { left: 3, nested: { value: 4 } });',
            'console.log(left, deep);',
          ].join('\n'),
          expected: '3 4\n',
        },
        {
          name: 'nested function assignment uses function-scoped temps',
          source: [
            'function assign(input) {',
            '  var _a = 99; var left = 0; var deep = 0;',
            '  { ({ left, nested: { value: deep } } = input); }',
            "  return [left, deep, _a].join(',');",
            '}',
            'console.log(assign({ left: 3, nested: { value: 4 } }));',
          ].join('\n'),
          expected: '3,4,99\n',
        },
        {
          name: 'array default and rest assignment',
          source: [
            'var first = 0; var rest: number[] = [];',
            '[first = 5, ...rest] = [undefined, 8, 9];',
            "console.log(first, rest.join(','));",
          ].join('\n'),
          expected: '5 8,9\n',
        },
        {
          name: 'computed object key with default and object rest',
          source: [
            "var key = 'answer'; var answer = 0; var rest: Record<string, number> = {};",
            '({ [key]: answer = 5, ...rest } = { answer: 42, extra: 9 });',
            'console.log(answer, rest.extra);',
          ].join('\n'),
          expected: '42 9\n',
        },
        {
          name: 'computed assignment key stays captured through nested default reads',
          source: [
            "var selected = 'first'; var value = 0; var rest = {};",
            'var source = {',
            "  get first() { selected = 'second'; return { value: 5 }; },",
            '  second: { value: 9 },',
            '};',
            '({ [selected]: { value = 3 } = {}, ...rest } = source);',
            'console.log(value, selected, rest.second.value);',
          ].join('\n'),
          expected: '5 second 9\n',
          nativeOracle: true,
        },
      ];

      for (const fixture of retainedCases) {
        const proc = run(fixture.source);
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        expect(mode(proc.stderr ?? ''), `${fixture.name}: ${proc.stderr}`).toContain(
          'semantic_graph=retained',
        );
        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
          );
        expect(report, fixture.name).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name} ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report).toMatch(/generated_bindings=[1-9]\d*/);
        expect(report).toMatch(/generated_references=[1-9]\d*/);
        expect(report).toMatch(/clean=1(?:\s|$)/);
        if ('nativeOracle' in fixture) {
          const native = spawnSync('node', ['-e', fixture.source], { encoding: 'utf8' });
          expect(native.status, `${fixture.name}: ${native.stderr}`).toBe(0);
          expect(native.stdout).toBe(fixture.expected);
        }
        assertOutput(fixture.expected);
      }

      const loopHead = run(
        'var total = 0; var value = 0; for ([value] of [[7], [8]]) total += value; console.log(total);',
      );
      expect(loopHead.status, loopHead.stderr).toBe(0);
      expect(mode(loopHead.stderr ?? ''), loopHead.stderr).toContain('semantic_graph=reanalyzed');
      assertOutput('15\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 destructuring parameters without defaults or rest retain exact identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-destructuring-parameter-retained-'));
    const input = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    const run = (source: string) => {
      writeFileSync(input, source);
      return spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    };
    const mode = (stderr: string) =>
      stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
    const assertOutput = (expected: string) => {
      const result = spawnSync('node', [output], { encoding: 'utf8' });
      expect(result.status, result.stderr).toBe(0);
      expect(result.stdout).toBe(expected);
    };

    try {
      const retainedCases = [
        {
          name: 'direct array parameter pattern',
          source:
            'function sum([left, right]) { return left + right; } console.log(sum([20, 22]));',
          expected: '42\n',
        },
        {
          name: 'typed object parameter pattern',
          source: [
            'type Values = { left: number; right: number };',
            'function sum({ left, right }: Values) { return left + right; }',
            'console.log(sum({ left: 20, right: 22 }));',
          ].join('\n'),
          expected: '42\n',
        },
        {
          name: 'nested function parameter temp scope',
          source: [
            'function read({ nested: { value } }) {',
            '  var _a = 99;',
            '  { return value + _a; }',
            '}',
            'console.log(read({ nested: { value: 3 } }));',
          ].join('\n'),
          expected: '102\n',
        },
      ];

      for (const fixture of retainedCases) {
        const proc = run(fixture.source);
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        expect(mode(proc.stderr ?? ''), `${fixture.name}: ${proc.stderr}`).toContain(
          'semantic_graph=retained',
        );
        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
          );
        expect(report, fixture.name).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name} ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report).toMatch(/generated_bindings=[1-9]\d*/);
        expect(report).toMatch(/generated_references=[1-9]\d*/);
        expect(report).toMatch(/clean=1(?:\s|$)/);
        assertOutput(fixture.expected);
      }

      const reanalyzedCases = [
        {
          name: 'nested binding default',
          source: 'function get({ value = 2 }) { return value; } console.log(get({}));',
          expected: '2\n',
        },
        {
          name: 'defaulted parameter pattern',
          source: 'function get({ value } = {}) { return value; } console.log(get());',
          expected: 'undefined\n',
        },
        {
          name: 'rest parameter beside destructuring',
          source:
            'function get({ value }, ...rest) { return value + rest.length; } console.log(get({ value: 3 }, 1));',
          expected: '4\n',
        },
      ];

      for (const fixture of reanalyzedCases) {
        const proc = run(fixture.source);
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        expect(mode(proc.stderr ?? ''), `${fixture.name}: ${proc.stderr}`).toContain(
          'semantic_graph=reanalyzed',
        );
        assertOutput(fixture.expected);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native default and rest parameters retain identities while ES5 reanalyzes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-parameter-defaults-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'var fallback = 5;',
        'function choose(value = fallback, ...rest: number[]) {',
        '  return value + rest.length;',
        '}',
        'console.log(choose(undefined, 1, 2));',
      ].join('\n'),
    );

    const run = (target: string) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    const mode = (stderr: string) =>
      stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );

    try {
      const native = run('--target=es2015');
      expect(native.status, native.stderr).toBe(0);
      expect(mode(native.stderr ?? ''), native.stderr).toContain('semantic_graph=retained');
      const nativeReport = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeReport, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeReport}`,
        ).toBe(0);
      }
      expect(nativeReport).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('7\n');

      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expect(mode(downlevel.stderr ?? ''), downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('7\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('object-rest and object-spread lowering retain exact semantic identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-object-rest-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Values = { first: number; second: number; third: number };',
        'const _a = "user-binding";',
        'const source: Values = { first: 1, second: 2, third: 3 };',
        'const { first, ...rest }: Values = source;',
        'let assignedFirst = 0;',
        'let assignedRest: Partial<Values> = {};',
        '({ first: assignedFirst, ...assignedRest } = source);',
        'function count({ first: parameterFirst, ...parameterRest }: Values) {',
        '  return parameterFirst + Object.keys(parameterRest).length;',
        '}',
        'console.log(first, rest.second, rest.third, assignedFirst, assignedRest.second, count(source), _a);',
      ].join('\n'),
    );

    const run = (target: string, debugCoverage = true) => {
      const env = { ...process.env };
      if (debugCoverage) env.ZNTC_DEBUG_SYMBOL_COVERAGE = '1';
      else delete env.ZNTC_DEBUG_SYMBOL_COVERAGE;
      return spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env,
          encoding: 'utf8',
        },
      );
    };

    const mode = (stderr: string) =>
      stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
    const expectShadowedObjectReport = (stderr: string, label: string) => {
      const report = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, label + ': ' + stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        const expected = counter === 'shadowed_external_reference' ? 1 : 0;
        expect(
          Number(report?.match(new RegExp(counter + '=(\\d+)'))?.[1] ?? -1),
          label + ' ' + counter + ': ' + report,
        ).toBe(expected);
      }
      expect(report).toMatch(/clean=0(?:\s|$)/);
      expect(report).toMatch(/shadowed_external_reference=1(?:\s|$)/);
    };
    const expectRetainedGraph = (stderr: string, label: string) => {
      expect(mode(stderr), `${label}: ${stderr}`).toContain('semantic_graph=retained');
      const report = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, `${label}: ${stderr}`).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${label} ${counter}: ${report}`,
        ).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
    };

    try {
      const native = run('--target=es2018');
      expect(native.status, native.stderr).toBe(0);
      expect(mode(native.stderr ?? ''), native.stderr).toContain('semantic_graph=retained');
      const nativeReport = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nativeReport, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nativeReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nativeReport}`,
        ).toBe(0);
      }
      expect(nativeReport).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('1 2 3 1 2 3 user-binding\n');

      const downlevel = run('--target=es2017');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expectRetainedGraph(downlevel.stderr ?? '', 'declaration, assignment, parameter');
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('1 2 3 1 2 3 user-binding\n');

      const es2015 = run('--target=es2015');
      expect(es2015.status, es2015.stderr).toBe(0);
      expectRetainedGraph(es2015.stderr ?? '', 'ES2015 object-rest lowering');
      const es2015Output = spawnSync('node', [output], { encoding: 'utf8' });
      expect(es2015Output.status, es2015Output.stderr).toBe(0);
      expect(es2015Output.stdout).toBe('1 2 3 1 2 3 user-binding\n');

      const spreadSource = [
        'var source = { first: 1, second: 2 };',
        'function copy() { var result = { ...source }; return result; }',
        'console.log(copy().first, copy().second);',
      ].join('\n');
      for (const target of [
        '--target=es5',
        '--target=es2015',
        '--target=es2016',
        '--target=es2017',
      ]) {
        writeFileSync(input, spreadSource);
        const spreadResult = run(target);
        expect(spreadResult.status, target + ': ' + spreadResult.stderr).toBe(0);
        expectRetainedGraph(spreadResult.stderr ?? '', 'object spread ' + target);
        const spreadReport = spreadResult.stderr
          ?.split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
          );
        expect(spreadReport, target + ': missing exact report').toMatch(
          /generated_references=1(?:\s|$)/,
        );
        expect(spreadReport, target + ': missing external-name registration').toMatch(
          /external=2(?:\s|$)/,
        );
        const spreadOutput = spawnSync('node', [output], { encoding: 'utf8' });
        expect(spreadOutput.status, target + ': ' + spreadOutput.stderr).toBe(0);
        expect(spreadOutput.stdout).toBe('1 2\n');
      }

      // A source Object binding conflicts with the generated external
      // Object.assign reference. Keep reanalysis and require that exact,
      // intentional conflict to be the only non-zero invariant.
      writeFileSync(
        input,
        [
          'const source = { first: 1, second: 2 };',
          'const { first, ...rest } = source;',
          'const copy = { ...source };',
          'console.log(first, rest.second, copy.second);',
        ].join('\n'),
      );
      const mixed = run('--target=es2017');
      expect(mixed.status, mixed.stderr).toBe(0);
      expectRetainedGraph(mixed.stderr ?? '', 'object rest and spread in one module');
      const mixedOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(mixedOutput.status, mixedOutput.stderr).toBe(0);
      expect(mixedOutput.stdout).toBe('1 2 2\n');

      writeFileSync(
        input,
        [
          'function copy(source: any) {',
          '  const Object = { assign() { throw new Error("shadowed Object was called"); } };',
          '  return { ...source };',
          '}',
          'console.log(copy({ value: 42 }).value);',
        ].join('\n'),
      );
      const shadowedObject = run('--target=es2017');
      expect(shadowedObject.status, shadowedObject.stderr).toBe(0);
      expect(mode(shadowedObject.stderr ?? ''), shadowedObject.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      expectShadowedObjectReport(shadowedObject.stderr ?? '', 'shadowed Object');
      const shadowedObjectOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(shadowedObjectOutput.status, shadowedObjectOutput.stderr).toBe(0);
      expect(shadowedObjectOutput.stdout).toBe('42\n');
      const shadowedObjectWithoutCoverage = run('--target=es2017', false);
      expect(shadowedObjectWithoutCoverage.status, shadowedObjectWithoutCoverage.stderr).toBe(0);
      const productionShadowedObjectOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(productionShadowedObjectOutput.status, productionShadowedObjectOutput.stderr).toBe(0);
      expect(productionShadowedObjectOutput.stdout).toBe('42\n');

      const loopFixtures = [
        {
          label: 'binding rest with per-iteration closures',
          source: [
            'const _b = "user-binding";',
            'const fns: any[] = [];',
            'for (const { a, ...r } of [{ a: 1, b: 2 }, { a: 3, c: 4 }] as any) fns.push(() => a + ":" + Object.keys(r).join(""));',
            'console.log(fns.map((f: any) => f()).join("|") + "|" + _b);',
          ],
          output: '1:b|3:c|user-binding\n',
        },
        {
          label: 'assignment-target rest in for-of',
          source: [
            'let a: any, r: any; const out: any[] = [];',
            'for ({ a, ...r } of [{ a: 1, b: 2 }, { a: 3, c: 4 }] as any) out.push(a + ":" + Object.keys(r).join(""));',
            'console.log(out.join("|"));',
          ],
          output: '1:b|3:c\n',
        },
        {
          label: 'nested array-target rest in for-of',
          source: [
            'let b: any, a: any, r: any; const out: any[] = [];',
            'for ([b, { a, ...r }] of [[1, { a: 2, c: 3 }], [4, { a: 5, d: 6 }]] as any) out.push(b + ":" + a + ":" + Object.keys(r).join(""));',
            'console.log(out.join("|"));',
          ],
          output: '1:2:c|4:5:d\n',
        },
      ];
      for (const fixture of loopFixtures) {
        writeFileSync(input, fixture.source.join('\n'));
        const loop = run('--target=es2017');
        expect(loop.status, `${fixture.label}: ${loop.stderr}`).toBe(0);
        expectRetainedGraph(loop.stderr ?? '', fixture.label);
        const loopOutput = spawnSync('node', [output], { encoding: 'utf8' });
        expect(loopOutput.status, `${fixture.label}: ${loopOutput.stderr}`).toBe(0);
        expect(loopOutput.stdout, fixture.label).toBe(fixture.output);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('native tagged templates keep TypeScript erasure on the edited semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-tagged-template-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'var previous: TemplateStringsArray | undefined;',
        'function tag(strings: TemplateStringsArray, value: number) {',
        '  var same = previous === strings;',
        '  previous = strings;',
        '  return `${strings[0]}${value}${strings[1]}:${same}`;',
        '}',
        'function emit(value: number) { return tag`n=${value}!`; }',
        'console.log(emit(41), emit(42));',
      ].join('\n'),
    );

    const run = (target: string) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          target,
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

    const graphMode = (stderr: string | null) =>
      stderr
        ?.split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );

    try {
      const native = run('--target=es2015');
      expect(native.status, native.stderr).toBe(0);
      expect(graphMode(native.stderr), native.stderr).toContain('semantic_graph=retained');
      const report = (native.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, native.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const nativeOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nativeOutput.status, nativeOutput.stderr).toBe(0);
      expect(nativeOutput.stdout).toBe('n=41!:false n=42!:true\n');

      // ES5 lowering creates an exact cache-function scope and data binding,
      // so bundling can keep the edited graph through the generated helpers.
      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expect(graphMode(downlevel.stderr), downlevel.stderr).toContain('semantic_graph=retained');
      const downlevelReport = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(downlevelReport, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(downlevelReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${downlevelReport}`,
        ).toBe(0);
      }
      expect(downlevelReport).toMatch(/clean=1(?:\s|$)/);
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('n=41!:false n=42!:true\n');

      // Direct eval can shadow generated cache names, so the conservative
      // resynchronization boundary remains in place for that module.
      writeFileSync(
        input,
        [
          'function tag(parts: TemplateStringsArray, value: number) { return `${parts[0]}${value}`; }',
          'function emit(value: number) { eval("var _templateObject = 1"); return tag`answer:${value}`; }',
          'console.log(emit(42));',
        ].join('\n'),
      );
      const directEval = run('--target=es5');
      expect(directEval.status, directEval.stderr).toBe(0);
      expect(graphMode(directEval.stderr), directEval.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      const directEvalOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(directEvalOutput.status, directEvalOutput.stderr).toBe(0);
      expect(directEvalOutput.stdout).toBe('answer:42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 untagged template lowering retains exact source symbol identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-template-literal-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var left: Numeric = 20;',
        'var right: Numeric = 22;',
        'var count = 0;',
        'var message = `${++count}:${left + right}:${++count}`;',
        'console.log(message, count, typeof message);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('1:42:2 2 string\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 object shorthand expansion retains the value reference symbol', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-object-shorthand-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var value: Numeric = 42;',
        'var object = { value };',
        "console.log(Object.keys(object).join(','), object.value, JSON.stringify(object));",
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('value 42 {"value":42}\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 computed object data keys retain exact generated temp identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-computed-object-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var events = [];',
        'var keyCalls = 0;',
        "var _a = 'outer';",
        'function getKey() { events.push("key"); keyCalls++; return "dynamic"; }',
        'function getInitial(): Numeric { events.push("initial"); return 1; }',
        'function getComputed(): Numeric { events.push("computed"); return 9; }',
        'function make(): { first: number; dynamic: number; dynamic2: number; last: string } {',
        "  var _a = 'inner';",
        '  function getAfter(): string { events.push("after"); return _a; }',
        '  return { first: getInitial(), [getKey()]: getComputed(), [getKey() + "2"]: getComputed(), last: getAfter() };',
        '}',
        'var object = make();',
        "console.log(Object.keys(object).join(','), object.first, object.dynamic, object.dynamic2, object.last, keyCalls, events.join(','), _a);",
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(
        'first,dynamic,dynamic2,last 1 9 9 inner 2 initial,key,computed,key,computed,after outer\n',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 simple object method lowering retains the original function scope', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-object-method-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var methods = { combine(addend: Numeric) { return this.base + addend; } };',
        'methods.base = 10;',
        'console.log(methods.combine(32), methods.combine.name);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 combine\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 computed object methods retain exact generated temp and function scopes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-computed-object-method-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var keyCalls = 0;',
        "var _a = 'outer';",
        'function getKey() { keyCalls++; return "combine"; }',
        'var methods = { [getKey()](addend: Numeric) { return this.base + addend; } };',
        'methods.base = 10;',
        "console.log(Object.keys(methods).join(','), methods.combine(32), keyCalls, _a);",
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('combine,base 42 1 outer\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 computed object methods with super retain exact home and key symbols', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-computed-object-super-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'var keyCalls = 0;',
        'var _obj = 1;',
        'var _obj2 = 2;',
        'function getKey() { keyCalls++; return "read"; }',
        'var base = { read() { return this.input; } };',
        'var alternate = { read() { return this.input * 2; } };',
        'var methods = { [getKey()]() { return super.read() + 1; } };',
        'Object.setPrototypeOf(methods, base);',
        'var method = methods.read;',
        'var first = method.call({ input: 41 });',
        'Object.setPrototypeOf(methods, alternate);',
        'var second = method.call({ input: 20 });',
        'console.log(first, second, keyCalls, _obj, _obj2);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 41 1 1 2\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 computed object accessors retain exact generated temp and accessor scopes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-computed-object-accessor-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var events = [];',
        'var keyCalls = 0;',
        "var _a = 'outer';",
        'var stored = 40;',
        'function getKey() { events.push("key"); keyCalls++; return "value"; }',
        'var object = { get [getKey()](): Numeric { events.push("get"); return stored; }, set [getKey()](input: Numeric) { events.push("set"); stored = input; } };',
        'object.value = 42;',
        "console.log(object.value, Object.keys(object).join(','), keyCalls, events.join(','), _a);",
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 value 2 key,key,set,get outer\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 computed object getter/setter super keeps the home-object reanalysis path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-computed-object-accessor-super-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'var keyCalls = 0;',
        'var _obj = 1;',
        'var _obj2 = 2;',
        'var _a = 3;',
        'function getKey() { keyCalls++; return "value"; }',
        'var base = { get value() { return this.input; }, set value(value) { this.input = value; } };',
        'var alternate = { get value() { return this.input * 2; }, set value(value) { this.input = value - 50; } };',
        'var object = { get [getKey()]() { return super.value + 1; }, set [getKey()](value) { super.value = value - 1; } };',
        'Object.setPrototypeOf(object, base);',
        'var receiver = { input: 41 };',
        'var descriptor = Object.getOwnPropertyDescriptor(object, "value");',
        'var first = descriptor.get.call(receiver);',
        'descriptor.set.call(receiver, 50);',
        'Object.setPrototypeOf(object, alternate);',
        'var second = descriptor.get.call(receiver);',
        'descriptor.set.call(receiver, 100);',
        'console.log(first, receiver.input, second, keyCalls, _obj, _obj2, _a);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 49 99 2 1 2 3\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 computed object accessors with shadowed Object keep reanalysis', () => {
    const dir = mkdtempSync(
      join(tmpdir(), 'zntc-bundle-computed-object-accessor-shadowed-object-'),
    );
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'var Object = globalThis.Object;',
        'var keyCalls = 0;',
        'function getKey() { keyCalls++; return "value"; }',
        'var object = { get [getKey()]() { return 42; } };',
        'console.log(object.value, keyCalls, Object === globalThis.Object);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        const expected = counter === 'shadowed_external_reference' ? 1 : 0;
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(
          expected,
        );
      }
      expect(report).toMatch(/clean=0(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 1 true\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 object methods with super retain generated home-object symbols', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-object-method-super-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var _obj = 1;',
        'var _obj2 = 2;',
        'var base = { read() { return this.input; } };',
        'var alternate = { read() { return this.input * 2; } };',
        'var methods = { read(): Numeric { return super.read() + 1; } };',
        'Object.setPrototypeOf(methods, base);',
        'var method = methods.read;',
        'var first = method.call({ input: 41 });',
        'Object.setPrototypeOf(methods, alternate);',
        'var second = method.call({ input: 20 });',
        'console.log(first, second, _obj, _obj2, method.name);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=retained');
      const report = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, downlevel.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 41 1 2 read\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 object methods with shadowed Object keep reanalysis for global references', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-object-method-shadowed-global-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Numeric = number;',
        'var poisonedPrototype = { read() { return 900; } };',
        'var Object = { marker: "shadow", getPrototypeOf() { return poisonedPrototype; }, setPrototypeOf(target, prototype) { target.__proto__ = prototype; } };',
        'var keyCalls = 0;',
        'function getKey() { keyCalls++; return "read"; }',
        'var base = { read() { return this.input; } };',
        'var methods = { [getKey()](): Numeric { return super.read() + 1; } };',
        'Object.setPrototypeOf(methods, base);',
        'console.log(methods.read.call({ input: 41 }), Object.marker, keyCalls);',
      ].join('\n'),
    );

    try {
      const downlevel = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(downlevel.status, downlevel.stderr).toBe(0);
      const mode = (downlevel.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 shadow 1\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtime TypeScript enums keep mixed ES5 arrow modules on semantic resync', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-enum-arrow-resync-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.ts'),
      [
        'enum Code { Ready = 42 }',
        'function read() { return () => Code.Ready; }',
        'console.log(read()());',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('classic JSX with a local factory preserves its semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-classic-jsx-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.tsx'),
      [
        'const Header = function () {};',
        'Header.Button = function () {};',
        'Header.Controls = { Button: function () {} };',
        'function render(h: (tag: unknown, props: unknown, child?: number) => number) {',
        '  return <Header><Header.Button /><Header.Controls.Button /></Header>;',
        '}',
        'console.log(render((tag, _props, child) => tag === Header ? 20 + (child ?? 0) : 22));',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.tsx',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=classic',
          '--jsx-factory=h',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.tsx'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      expect(Number(report?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.tsx'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 JSX lowering retains audited arrows and rejects untracked downlevel cases', () => {
    const cases = [
      {
        mode: 'classic',
        graph: 'retained',
        args: ['--jsx=classic', '--jsx-factory=h'],
        source: [
          'function render(h, value) {',
          '  var _jsx = 7;',
          '  var nested = (h, value) => <span>{value}</span>;',
          '  return [<div>{nested(innerFactory, value)}</div>, _jsx];',
          '}',
          'function outerFactory(tag, _props, child) { return ["outer", tag, child]; }',
          'function innerFactory(tag, _props, child) { return ["inner", tag, child]; }',
          'console.log(JSON.stringify(render(outerFactory, 42)));',
        ].join('\n'),
        expectedOutput: '[["outer","div",["inner","span",42]],7]\n',
      },
      {
        mode: 'automatic',
        graph: 'retained',
        args: ['--jsx=automatic', '--jsx-import-source=./runtime'],
        source: [
          'var _jsx = 7;',
          'function render(value) {',
          '  var nested = value => <span>{value}</span>;',
          '  return [<div>{nested(value)}</div>, _jsx];',
          '}',
          'console.log(JSON.stringify(render(42)));',
        ].join('\n'),
        expectedOutput: '[["div",["span",42]],7]\n',
        runtimeFile: 'jsx-runtime.js',
        runtimeSource: [
          'export function jsx(tag, props) { return [tag, props && props.children]; }',
          'export function jsxs(tag, props) { return [tag, props && props.children]; }',
          "export const Fragment = 'fragment';",
        ].join('\n'),
      },
      {
        mode: 'automatic-dev',
        graph: 'retained',
        args: ['--jsx=automatic-dev', '--jsx-import-source=./runtime'],
        source: [
          'var _jsxDEV = 7;',
          'function render(value) {',
          '  var nested = value => <span>{value}</span>;',
          '  return [<div>{nested(value)}</div>, _jsxDEV];',
          '}',
          'console.log(JSON.stringify(render(42)));',
        ].join('\n'),
        expectedOutput: '[["div",["span",42]],7]\n',
        runtimeFile: 'jsx-dev-runtime.js',
        runtimeSource: [
          'export function jsxDEV(tag, props) { return [tag, props && props.children]; }',
          "export const Fragment = 'fragment';",
        ].join('\n'),
      },
      {
        mode: 'classic-optional-chain-fallback',
        graph: 'reanalyzed',
        args: ['--jsx=classic', '--jsx-factory=h'],
        source: [
          'function h(tag, _props, child) { return [tag, child]; }',
          'var nested = value => <span>{value?.x}</span>;',
          'console.log(JSON.stringify(nested({ x: 42 })));',
        ].join('\n'),
        expectedOutput: '["span",42]\n',
      },
      {
        mode: 'classic-spread-attribute-retained',
        graph: 'retained',
        args: ['--jsx=classic', '--jsx-factory=h'],
        source: [
          'function h(tag, props) { return [tag, props]; }',
          'var props = { value: 42 };',
          'console.log(JSON.stringify(<div id="first" {...props} tail={7} />));',
        ].join('\n'),
        expectedOutput: '["div",{"id":"first","value":42,"tail":7}]\n',
      },
      {
        mode: 'classic-spread-attribute-object-shadow-fallback',
        graph: 'reanalyzed',
        args: ['--jsx=classic', '--jsx-factory=h'],
        source: [
          'function unrelated(Object) { return Object; }',
          'function h(tag, props) { return [tag, props]; }',
          'var props = { value: 42 };',
          'console.log(JSON.stringify(<div {...props} />));',
        ].join('\n'),
        expectedOutput: '["div",{"value":42}]\n',
      },
      {
        mode: 'classic-spread-child-fallback',
        graph: 'reanalyzed',
        args: ['--jsx=classic', '--jsx-factory=h'],
        source: [
          'function h(tag, _props, ...children) { return [tag, children]; }',
          'var children = [42];',
          'console.log(JSON.stringify(<div>{...children}</div>));',
        ].join('\n'),
        expectedOutput: '["div",[42]]\n',
      },
    ] as const;

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-jsx-arrow-retained-${fixture.mode}-`));
      const output = join(dir, 'out.cjs');

      mkdirSync(join(dir, 'runtime'), { recursive: true });
      if ('runtimeFile' in fixture) {
        writeFileSync(join(dir, 'runtime', fixture.runtimeFile), fixture.runtimeSource);
      }
      writeFileSync(join(dir, 'entry.tsx'), fixture.source);

      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.tsx',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            ...fixture.args,
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.mode}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.tsx'),
          );
        expect(report, `${fixture.mode}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.mode}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${fixture.mode}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.tsx'),
          );
        expect(graphMode, `${fixture.mode}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.mode}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.mode).toBe(fixture.expectedOutput);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('classic JSX keeps stable runtime imports only when verbatim syntax preserves them', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-classic-jsx-import-graph-'));
    writeFileSync(
      join(dir, 'dep.ts'),
      [
        'export interface Props { label?: string; }',
        'export const Header: () => void = () => {};',
        'export const unused: number = 1;',
      ].join('\n'),
    );
    try {
      for (const { name, importLine, flag, expectedMode } of [
        {
          name: 'verbatim',
          importLine: "import { Header, unused } from './dep';",
          flag: '--verbatim-module-syntax',
          expectedMode: 'retained',
        },
        {
          name: 'eliding',
          importLine: "import { Header, unused } from './dep';",
          flag: '--verbatim-module-syntax=false',
          expectedMode: 'reanalyzed',
        },
        {
          name: 'inline-type',
          importLine: "import { Header, type unused } from './dep';",
          flag: '--verbatim-module-syntax',
          expectedMode: 'reanalyzed',
        },
      ]) {
        writeFileSync(
          join(dir, 'entry.tsx'),
          [
            "import type { Props } from './dep';",
            importLine,
            'function render(h: (tag: unknown, props: Props) => number) {',
            '  return <Header />;',
            '}',
            'console.log(render((tag) => tag === Header ? 42 : 0));',
          ].join('\n'),
        );
        const output = join(dir, `out-${name}.cjs`);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.tsx',
            '--target=esnext',
            '--platform=node',
            '--format=cjs',
            '--jsx=classic',
            '--jsx-factory=h',
            '--minify-identifiers',
            flag,
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${name}: ${proc.stderr}`).toBe(0);

        const reports = (proc.stderr ?? '')
          .split(/\r?\n/)
          .filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
        expect(reports, `${name}: ${proc.stderr}`).toHaveLength(2);
        for (const report of reports) {
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(Number(report.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(
              0,
            );
          }
          expect(report).toMatch(/clean=1(?:\s|$)/);
        }

        const entryMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.tsx'),
          );
        expect(entryMode, `${name}: ${proc.stderr}`).toContain(`semantic_graph=${expectedMode}`);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('42\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('classic JSX preserves side-effect import graph entries in place', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-classic-jsx-side-effect-import-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'side.ts'),
      '(globalThis as { sideEffect?: boolean }).sideEffect = true;',
    );
    writeFileSync(
      join(dir, 'entry.tsx'),
      [
        "import './side';",
        'const Header = function () {};',
        'function render(h: (tag: unknown) => number) {',
        '  return <Header />;',
        '}',
        'console.log(render((tag) => tag === Header ? 42 : 0), (globalThis as { sideEffect?: boolean }).sideEffect);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.tsx',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=classic',
          '--jsx-factory=h',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const reports = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(reports, proc.stderr).toHaveLength(2);
      for (const report of reports) {
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(Number(report.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
        }
        expect(report).toMatch(/clean=1(?:\s|$)/);
      }

      const graphModes = (proc.stderr ?? '')
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(graphModes, proc.stderr).toHaveLength(2);
      expect(graphModes.find((line) => line.includes('side.ts'))).toContain(
        'semantic_graph=retained',
      );
      expect(graphModes.find((line) => line.includes('entry.tsx'))).toContain(
        'semantic_graph=retained',
      );

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 true\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('automatic JSX keeps its generated helper import in the semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-automatic-jsx-retained-'));
    const output = join(dir, 'out.cjs');
    mkdirSync(join(dir, 'runtime'), { recursive: true });
    writeFileSync(
      join(dir, 'runtime', 'jsx-runtime.js'),
      [
        "export const Fragment = 'fragment';",
        "export function jsx(tag, _props) { return tag === 'div' ? 42 : tag; }",
        "export function jsxs(tag, props) { return `${tag}:${props.children.join(',')}`; }",
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'view.tsx'),
      [
        'const _jsx = 7;',
        'const _jsx2 = 8;',
        'const _jsxs = 9;',
        'const _jsxs2 = 10;',
        'const _Fragment = 11;',
        'export function view() { return [<><span /><div /></>, _jsx, _jsx2, _jsxs, _jsxs2, _Fragment].join(" "); }',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'entry.ts'),
      ["import { view } from './view.tsx';", 'console.log(view());'].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=automatic',
          '--jsx-import-source=./runtime',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('view.tsx'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      expect(Number(report?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('view.tsx'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('fragment:span,42 7 8 9 10 11\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('automatic JSX helper references in dead functions do not keep imports live', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-automatic-jsx-dead-'));
    const output = join(dir, 'out.cjs');
    mkdirSync(join(dir, 'runtime'), { recursive: true });
    writeFileSync(
      join(dir, 'runtime', 'jsx-runtime.js'),
      "export function jsx() { throw new Error('dead JSX ran'); }",
    );
    writeFileSync(
      join(dir, 'dep.tsx'),
      ['function unused() { return <div />; }', "console.log('dep side effect');"].join('\n'),
    );
    writeFileSync(
      join(dir, 'entry.ts'),
      ["import './dep.tsx';", "console.log('entry');"].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=automatic',
          '--jsx-import-source=./runtime',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.tsx'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      expect(Number(report?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.tsx'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('dep side effect\nentry\n');
      expect(readFileSync(output, 'utf8')).not.toContain('dead JSX ran');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('automatic-dev JSX keeps runtime and key-spread fallback helpers in the semantic graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-automatic-dev-jsx-retained-'));
    const output = join(dir, 'out.cjs');
    mkdirSync(join(dir, 'runtime'), { recursive: true });
    writeFileSync(
      join(dir, 'runtime', 'jsx-dev-runtime.js'),
      [
        "export const Fragment = 'fragment';",
        "export function jsxDEV(tag, _props) { return tag === 'div' ? 42 : tag; }",
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'runtime', 'index.js'),
      "export function createElement(tag, props) { return 'fallback:' + tag + ':' + props.key; }",
    );
    writeFileSync(
      join(dir, 'view.tsx'),
      [
        'const _jsxDEV = 7;',
        'const _jsxDEV2 = 8;',
        'const _Fragment = 9;',
        'export function view() { return [<><span /><div /></>, <div {...{ value: true }} key="k" />, _jsxDEV, _jsxDEV2, _Fragment].join(" "); }',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'entry.ts'),
      ["import { view } from './view.tsx';", 'console.log(view());'].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=automatic-dev',
          '--jsx-import-source=./runtime',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('view.tsx'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      expect(Number(report?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('view.tsx'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('fragment fallback:div:k 7 8 9\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('automatic-dev JSX in a dead function does not keep its helper import live', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-automatic-dev-jsx-dead-'));
    const output = join(dir, 'out.cjs');
    mkdirSync(join(dir, 'runtime'), { recursive: true });
    writeFileSync(
      join(dir, 'runtime', 'jsx-dev-runtime.js'),
      "export function jsxDEV() { throw new Error('dead JSX ran'); }",
    );
    writeFileSync(
      join(dir, 'dep.tsx'),
      ['function unused() { return <div />; }', "console.log('dep side effect');"].join('\n'),
    );
    writeFileSync(
      join(dir, 'entry.ts'),
      ["import './dep.tsx';", "console.log('entry');"].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--jsx=automatic-dev',
          '--jsx-import-source=./runtime',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.tsx'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.tsx'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('dep side effect\nentry\n');
      expect(readFileSync(output, 'utf8')).not.toContain('dead JSX ran');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('JSX runtime helpers stay bound through ES5 semantic reanalysis', () => {
    const cases = [
      { mode: 'automatic', helper: '_jsx', runtimeFile: 'jsx-runtime.js', exportName: 'jsx' },
      {
        mode: 'automatic-dev',
        helper: '_jsxDEV',
        runtimeFile: 'jsx-dev-runtime.js',
        exportName: 'jsxDEV',
      },
    ] as const;

    for (const { mode, helper, runtimeFile, exportName } of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-${mode}-es5-resync-`));
      const output = join(dir, 'out.cjs');
      mkdirSync(join(dir, 'runtime'), { recursive: true });
      writeFileSync(
        join(dir, 'runtime', runtimeFile),
        `export function ${exportName}(tag, _props) { return tag === 'div' ? 42 : tag; }`,
      );
      writeFileSync(
        join(dir, 'view.tsx'),
        [
          `var ${helper} = 7;`,
          `export function view() { return [<div />, ${helper}].join(" "); }`,
        ].join('\n'),
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        ["import { view } from './view.tsx';", 'console.log(view());'].join('\n'),
      );
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.ts',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            `--jsx=${mode}`,
            '--jsx-import-source=./runtime',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${mode}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('view.tsx'),
          );
        expect(report, `${mode}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${mode}: ${report}`,
          ).toBe(0);
        }
        expect(report, `${mode}: ${report}`).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('view.tsx'),
          );
        expect(graphMode, `${mode}: ${proc.stderr}`).toContain('semantic_graph=reanalyzed');

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${mode}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('42 7\n');
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('downlevel runtime helpers stay bound through semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-helper-es5-resync-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.ts'),
      [
        "var __extends = 'shadow';",
        'function Base() {}',
        'export class Child extends Base {}',
        'console.log(new Child() instanceof Base, __extends);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.ts',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('true shadow\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('가상 namespace IIFE 매개변수도 정확한 SymbolId와 ScopeId를 가진다', () => {
    const file = join(FIXTURE_DIR, '4819-namespace-iife-params.ts');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-namespace-param-'));
    try {
      for (const target of TARGETS) {
        const { stderr, exitCode } = runCoverage(file, target, outDir);
        expect(exitCode, `${target.name}: ${stderr}`).toBe(0);
        const identity = stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(Number(identity?.match(/namespace_iife_params=(\d+)/)?.[1] ?? 0)).toBe(3);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('[109,102]\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('ES5 namespace class export와 decorator binding도 exact SymbolId를 유지한다', () => {
    const file = join(FIXTURE_DIR, '4819-namespace-class-export.ts');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-namespace-class-export-'));
    try {
      for (const target of TARGETS) {
        const { stderr, exitCode } = runCoverage(file, target, outDir);
        expect(exitCode, `${target.name}: ${stderr}`).toBe(0);
        const identity = stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(Number(identity?.match(/namespace_iife_params=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('[false,true,false,true]\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('namespace destructuring 임시 바인딩은 transform mangling 중 exact SymbolId를 유지한다', () => {
    const file = join(FIXTURE_DIR, '4819-namespace-destructuring-mangle.ts');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-namespace-destructuring-mangle-'));
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(ZNTC_BIN, [file, target.arg, '--minify-identifiers', '-o', output], {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        expect(proc.stderr).toMatch(/symbol-coverage .* missing=0 wrong=0/);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact identity report`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('[1,3,99,7,8]\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('TypeScript import-equals mangling reuses the edited semantic graph', () => {
    const file = join(FIXTURE_DIR, '4819-import-equals-transform-graph.ts');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-graph-'));
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(ZNTC_BIN, [file, target.arg, '--minify-identifiers', '-o', output], {
          env: {
            ...process.env,
            ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          },
          encoding: 'utf8',
        });
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact identity report`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('42|42|outer|outer2\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('local and static external TypeScript import-equals retain their graph', () => {
    const cases = [
      {
        name: 'local namespace aliases',
        source: [
          'namespace Source {',
          '  export let value = 40;',
          '  export namespace Inner { export let value = 42; }',
          '}',
          'namespace Container {',
          '  export namespace Nested { export let value = 43; }',
          '  import NestedAlias = Nested;',
          '  export function read() { return NestedAlias.value; }',
          '}',
          'import Alias = Source;',
          'import DeepAlias = Source.Inner;',
          'console.log(Alias.value, DeepAlias.value, Container.read());',
        ].join('\n'),
        graph: 'retained',
        output: '40 42 43\n',
      },
      {
        name: 'external require import-equals',
        source: [
          "import Assert = require('node:assert/strict');",
          'Assert.equal(42, 42);',
          "console.log('external-ok');",
        ].join('\n'),
        graph: 'retained',
        output: 'external-ok\n',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-bundle-graph-'));
      const input = join(dir, 'entry.ts');
      const output = join(dir, 'out.cjs');
      writeFileSync(input, fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            input,
            '--target=esnext',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        if (fixture.graph === 'retained') {
          const report = (proc.stderr ?? '')
            .split(/\r?\n/)
            .find(
              (line) =>
                line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
            );
          expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture.name}: ${counter}: ${report}`,
            ).toBe(0);
          }
          expect(report).toMatch(/clean=1(?:\s|$)/);
          expect(Number(report?.match(/generated_bindings=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
        }

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('external TypeScript import-equals retains the bundled loader record', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-loader-record-'));
    const entry = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    writeFileSync(join(dir, 'dep.ts'), 'const api = { answer: 42 };\nexport = api;');
    writeFileSync(entry, "import Api = require('./dep.ts');\nconsole.log(Api.answer);");

    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          entry,
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphModes = proc.stderr
        .split(/\r?\n/)
        .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      for (const path of ['entry.ts', 'dep.ts']) {
        const graphMode = graphModes.find((line) => line.includes(path));
        expect(graphMode, proc.stderr).toBeDefined();
        expect(graphMode, proc.stderr).toContain('semantic_graph=retained');
      }

      const entryIdentity = proc.stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(entryIdentity, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(entryIdentity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          entryIdentity,
        ).toBe(0);
      }
      expect(entryIdentity, proc.stderr).toMatch(/clean=1(?:\s|$)/);
      expect(Number(entryIdentity?.match(/generated_bindings=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

      expectCjsWrapperModuleParamMatchesBody(readFileSync(output, 'utf8'), 'dep.ts');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('non-static TypeScript import-equals stays on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-dynamic-require-'));
    const entry = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      [
        'declare function resolveModule(): string;',
        'import Dynamic = require(resolveModule());',
        'console.log(typeof Dynamic);',
      ].join('\n'),
    );

    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', entry, '--target=esnext', '--platform=node', '--format=cjs', '-o', output],
        {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const graphMode = proc.stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(graphMode, proc.stderr).toBeDefined();
      expect(graphMode, proc.stderr).toContain('semantic_graph=reanalyzed');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('plain TypeScript export-star retains its loader record', () => {
    const cases = [
      {
        name: 'plain export-star',
        source: "export * from './dep.ts';\ninterface Marker { value: number }",
        readExpression: 'api.value',
        graph: 'retained',
      },
      {
        name: 'namespace export-star control',
        source: "export * as ns from './dep.ts';\ninterface Marker { value: number }",
        readExpression: 'api.ns.value',
        graph: 'reanalyzed',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-export-star-graph-'));
      const entry = join(dir, 'entry.ts');
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'dep.ts'), 'export const value = 42;');
      writeFileSync(entry, fixture.source);

      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            '--target=esnext',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        const graphMode = proc.stderr
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        if (fixture.graph === 'retained') {
          const identity = proc.stderr
            .split(/\r?\n/)
            .find(
              (line) =>
                line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
            );
          expect(identity, proc.stderr).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              identity,
            ).toBe(0);
          }
          expect(identity, proc.stderr).toMatch(/clean=1(?:\s|$)/);
        }

        const actual = spawnSync(
          'node',
          [
            '-e',
            `const api = require(process.argv[1]); console.log(${fixture.readExpression});`,
            output,
          ],
          { encoding: 'utf8' },
        );
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe('42\n');
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('static TypeScript named re-exports retain only stable loader records', () => {
    const cases = [
      {
        name: 'plain named re-export',
        source:
          "export { value as publicValue } from './dep.ts';\ninterface Marker { value: number }",
        readExpression: 'api.publicValue',
        graph: 'retained',
        expected: '42\n',
      },
      {
        name: 'empty named re-export side effect',
        source: "export {} from './dep.ts';\ninterface Marker { value: number }",
        readExpression: 'globalThis.__zntcReExportLoaded ?? 0',
        graph: 'retained',
        expected: '42\n',
      },
      {
        name: 'inline type-only re-export retains source side effects',
        source: "export { type value } from './dep.ts';\ninterface Marker { value: number }",
        readExpression: 'globalThis.__zntcReExportLoaded ?? 0',
        graph: 'retained',
        expected: '42\n',
      },
      {
        name: 'string export-name control',
        source:
          "export { value as 'public-value' } from './dep.ts';\ninterface Marker { value: number }",
        readExpression: "api['public-value']",
        graph: 'reanalyzed',
        expected: '42\n',
        format: 'esm',
      },
      {
        name: 'import-attribute control',
        source:
          "export { value as publicValue } from './dep.ts' with { mode: 'custom' };\ninterface Marker { value: number }",
        readExpression: 'api.publicValue',
        graph: 'reanalyzed',
        expected: '42\n',
        execute: false,
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-named-re-export-graph-'));
      const entry = join(dir, 'entry.ts');
      const output = join(dir, fixture.format === 'esm' ? 'out.mjs' : 'out.cjs');
      writeFileSync(
        join(dir, 'dep.ts'),
        'globalThis.__zntcReExportLoaded = 42; export const value = 42;',
      );
      writeFileSync(entry, fixture.source);

      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            entry,
            '--target=esnext',
            '--platform=node',
            `--format=${fixture.format ?? 'cjs'}`,
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        const graphMode = proc.stderr
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        if (fixture.graph === 'retained') {
          const identity = proc.stderr
            .split(/\r?\n/)
            .find(
              (line) =>
                line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
            );
          expect(identity, proc.stderr).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              identity,
            ).toBe(0);
          }
          expect(identity, proc.stderr).toMatch(/clean=1(?:\s|$)/);
        }

        if (fixture.execute !== false) {
          const runExpression =
            fixture.format === 'esm'
              ? `import(require('node:url').pathToFileURL(process.argv[1])).then((api) => console.log(${fixture.readExpression}));`
              : `const api = require(process.argv[1]); console.log(${fixture.readExpression});`;
          const actual = spawnSync('node', ['-e', runExpression, output], { encoding: 'utf8' });
          expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, fixture.name).toBe(fixture.expected);
        }
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('TypeScript export-equals mangling reuses the edited semantic graph', () => {
    const file = join(FIXTURE_DIR, '4819-export-equals-transform-graph.ts');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-graph-'));
    const shadowFile = join(outDir, 'export-equals-shadow.ts');
    writeFileSync(
      shadowFile,
      `
        const module = 'local-module';
        const exports = 'local-exports';
        const value = {
          module,
          exports,
          add(delta: number) { return 40 + delta; },
        };
        export = value;
      `,
    );
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(ZNTC_BIN, [file, target.arg, '--minify-identifiers', '-o', output], {
          env: {
            ...process.env,
            ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          },
          encoding: 'utf8',
        });
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact identity report`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync(
          'node',
          ['-e', 'console.log(require(process.argv[1]).add(2));', output],
          { encoding: 'utf8' },
        );
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('42\n');

        const shadowOutput = join(outDir, `shadow-${target.name}.js`);
        const shadowProc = spawnSync(
          ZNTC_BIN,
          [shadowFile, target.arg, '--minify-identifiers', '-o', shadowOutput],
          { encoding: 'utf8' },
        );
        expect(shadowProc.status, `${target.name} shadow: ${shadowProc.stderr}`).toBe(0);
        const shadowActual = spawnSync(
          'node',
          [
            '-e',
            'const api = require(process.argv[1]); console.log(`${api.module}|${api.exports}|${api.add(2)}`);',
            shadowOutput,
          ],
          { encoding: 'utf8' },
        );
        expect(shadowActual.status, `${target.name} shadow: ${shadowActual.stderr}`).toBe(0);
        expect(shadowActual.stdout).toBe('local-module|local-exports|42\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('TypeScript export-equals bundling retains its semantic graph and CommonJS wrapper', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-export-equals-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'dep.ts'),
      'const api = { add(delta: number) { return 40 + delta; } };\nexport = api;',
    );
    writeFileSync(
      join(dir, 'entry.js'),
      "const api = require('./dep.ts');\nconsole.log(api.add(2));",
    );

    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.js',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = proc.stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.ts'),
        );
      expect(graphMode, proc.stderr).toBeDefined();
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const identity = proc.stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.ts'),
        );
      expect(identity, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), identity).toBe(
          0,
        );
      }
      expect(Number(identity?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      expect(identity, proc.stderr).toMatch(/clean=1(?:\s|$)/);

      const bundle = readFileSync(output, 'utf8');
      expect(bundle).toContain('__commonJS');
      expectCjsWrapperModuleParamMatchesBody(bundle, 'dep.ts');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('TypeScript export-equals bundling keeps generated module global distinct from local names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-export-equals-shadow-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'dep.ts'),
      [
        "const module = 'local-module';",
        "const exports = 'local-exports';",
        'const api = { module, exports, add(delta: number) { return 40 + delta; } };',
        'export = api;',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'entry.js'),
      [
        "const api = require('./dep.ts');",
        'console.log(`${api.module}|${api.exports}|${api.add(2)}`);',
      ].join('\n'),
    );

    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.js',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = proc.stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.ts'),
        );
      expect(graphMode, proc.stderr).toBeDefined();
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const identity = proc.stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.ts'),
        );
      expect(identity, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        const expected = counter === 'shadowed_external_reference' ? 1 : 0;
        expect(Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), identity).toBe(
          expected,
        );
      }
      expect(Number(identity?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      expect(identity, proc.stderr).toMatch(/clean=0(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('local-module|local-exports|42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('가상 enum IIFE 매개변수와 initializer 참조가 정확한 SymbolId와 ScopeId를 가진다', () => {
    const file = join(FIXTURE_DIR, '4819-enum-iife-params.ts');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-enum-param-'));
    try {
      for (const target of TARGETS) {
        const { stderr, exitCode } = runCoverage(file, target, outDir);
        expect(exitCode, `${target.name}: ${stderr}`).toBe(0);
        const identity = stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(Number(identity?.match(/enum_iife_params=(\d+)/)?.[1] ?? 0)).toBe(2);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('[3,1,3,23]\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('TS enum identifier minify reuses exact transform symbols without changing runtime behavior', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-enum-symbol-mangle-'));
    const input = join(dir, 'input.ts');
    const referencePath = join(dir, 'reference.cjs');
    const source = [
      'const Same = 100;',
      'const _Self1 = 19;',
      'const _Self = 91;',
      'const A = 100;',
      'enum Escaped { "\\u0041" = 1, B = A + 2 }',
      'enum Self { "\\u0053elf" = 1, Same = Self, Next = Same + _Self1, NextSelf = Self + 2, Qualified = (Self).Self + 3, Direct = Self.Self + 4, Computed = Self["Self"] + 5, Shadow = (() => { const Same = 9; return Same; })() }',
      'function read(Self: number) { return Self + 1; }',
      'console.log(Self.Self, Self.Same, Self.Next, Self.NextSelf, Self.Qualified, Self.Direct, Self.Computed, Self.Shadow, Same, _Self1, read(40), Escaped.B, A, _Self);',
    ].join('\n');
    writeFileSync(input, source);
    const referenceJs = ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2015, module: ts.ModuleKind.CommonJS },
    }).outputText;
    writeFileSync(referencePath, referenceJs);
    try {
      const reference = spawnSync('node', [referencePath], { encoding: 'utf8' });
      expect(reference.status, reference.stderr).toBe(0);
      expect(reference.stdout).toBe('1 1 20 3 NaN 5 NaN 9 100 19 41 3 100 91\n');
      for (const target of [TARGETS[0], TARGETS[4]]) {
        for (const minify of [['--minify-identifiers'], ['--minify']]) {
          const label = `${target.name} ${minify[0]}`;
          const output = join(dir, `${target.name}-${minify[0]}.js`);
          const proc = spawnSync(ZNTC_BIN, [input, target.arg, ...minify, '-o', output], {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          });
          expect(proc.status, `${label}: ${proc.stderr}`).toBe(0);
          const identity = proc.stderr
            .split('\n')
            .find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, `${label}: missing exact identity report`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${label}: ${counter}: ${identity}`,
            ).toBe(0);
          }
          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${label}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout).toBe(reference.stdout);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('인라인 runtime helper 호출은 preamble helper 심볼에 연결된다', () => {
    const file = join(FIXTURE_DIR, '4819-inline-runtime-helper-symbols.mjs');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-inline-helper-symbols-'));
    try {
      const { stderr, exitCode } = runCoverage(file, TARGETS[0], outDir);
      expect(exitCode, stderr).toBe(0);
      const identity = stderr.split('\n').find((line) => line.startsWith('zntc: symbol-identity '));
      const strict = stderr
        .split('\n')
        .find((line) => line.startsWith('zntc: synthetic-coverage '));
      expect(identity).toBeDefined();
      expect(strict).toBeDefined();
      expect(strict).toMatch(/(?:^| )consistent=1(?: |$)/);
      expect(strict).toMatch(/(?:^| )symbol_identity_complete=1(?: |$)/);
      expect(Number(identity?.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      expect(Number(identity?.match(/helper_symbol_mismatch=(\d+)/)?.[1] ?? -1)).toBe(0);
      const generatedReferences = Number(identity?.match(/generated_references=(\d+)/)?.[1] ?? 0);
      const boundReferences = Number(strict?.match(/bound=(\d+)/)?.[1] ?? -1);
      expect(boundReferences).toBeGreaterThanOrEqual(generatedReferences);
      expect(Number(strict?.match(/orphan_symbols=(\d+)/)?.[1] ?? -1)).toBe(0);
      expect(Number(strict?.match(/missing_binding=(\d+)/)?.[1] ?? -1)).toBe(0);
      const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
      expect(actual.status, `${actual.stderr}\n${actual.stdout}`).toBe(0);
      expect(actual.stdout).toBe('[7]\n');
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Flow enum bindings and references have exact identity across targets', () => {
    const file = join(FIXTURE_DIR, '4819-flow-enum.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-enum-'));
    try {
      for (const target of TARGETS) {
        const { stderr, exitCode } = runCoverage(file, target, outDir);
        expect(exitCode, `${target.name}: ${stderr}`).toBe(0);
        const identity = stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(identity, `${target.name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Flow enum bundling retains exact symbols and resolves its runtime once', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-flow-enum-retained-'));
    const output = join(dir, 'out.cjs');
    mkdirSync(join(dir, 'node_modules', 'flow-enums-runtime'), { recursive: true });
    writeFileSync(
      join(dir, 'entry.js'),
      [
        '// @flow',
        "import flowEnums from 'flow-enums-runtime';",
        "const require = () => 'user-require';",
        "const Symbol = () => 'user-Symbol';",
        'enum LongColor { Red, Blue }',
        'enum LongShape of string { Circle, Square }',
        'function read() { return [LongColor.Red, LongShape.Circle]; }',
        'console.log(typeof flowEnums, typeof read()[0], read()[0].description, read()[1], require(), Symbol(), globalThis.flowEnumRuntimeLoads);',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'node_modules', 'flow-enums-runtime', 'index.js'),
      [
        'globalThis.flowEnumRuntimeLoads = (globalThis.flowEnumRuntimeLoads || 0) + 1;',
        'function make(values) { return values; }',
        'make.Mirrored = (names) => make(Object.fromEntries(names.map((name) => [name, name])));',
        'module.exports = make;',
      ].join('\n'),
    );

    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          join(dir, 'entry.js'),
          '--flow',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--verbatim-module-syntax',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      expectCjsWrapperModuleParamMatchesBody(readFileSync(output, 'utf8'), 'index.js');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('function symbol Red Circle user-require user-Symbol 1\n');
      const emitted = readFileSync(output, 'utf8');
      expect(emitted.match(/flowEnumRuntimeLoads\s*=\s*\(/g)).toHaveLength(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('Flow component helper and component binding have exact identity across targets', () => {
    const file = join(FIXTURE_DIR, '4819-flow-component.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-component-'));
    try {
      for (const target of TARGETS) {
        const { stderr, exitCode } = runCoverage(file, target, outDir);
        expect(exitCode, `${target.name}: ${stderr}`).toBe(0);
        const identity = stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(identity, `${target.name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Flow component bundling retains generated forwardRef symbols and name collisions', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-flow-component-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.js'),
      [
        '// @flow',
        "const LongCard_withRef = 'user-binding';",
        "const LongCard_withRef2 = 'user-binding-2';",
        'const React = { forwardRef: (fn) => fn };',
        'component LongCard(ref?: mixed, ...props: { label?: string }) {',
        '  return props.label;',
        '}',
        'function renderLocal() {',
        "  const LocalCard_withRef = 'nested-binding';",
        "  const LocalCard_withRef2 = 'nested-binding-2';",
        '  component LocalCard(ref?: mixed, ...props: { label?: string }) {',
        '    return props.label;',
        '  }',
        "  return [LocalCard({ label: 'nested' }), LocalCard_withRef, LocalCard_withRef2].join(' ');",
        '}',
        "console.log(LongCard({ label: 'ok' }), LongCard_withRef, LongCard_withRef2, renderLocal());",
      ].join('\n'),
    );

    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          join(dir, 'entry.js'),
          '--flow',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(
        'ok user-binding user-binding-2 nested nested-binding nested-binding-2\n',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 regex literal lowering retains only helper-free arrow graphs', () => {
    const cases = [
      {
        name: 'dotAll rewrite stays a literal leaf',
        source: [
          'function matches(input) { return (() => /a.b/s.test(input))(); }',
          "console.log(matches('a\\nb'));",
        ].join('\n'),
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'named capture helper keeps semantic resync',
        source: [
          'function word(input) {',
          '  return (() => {',
          '    var match = /(?<word>[a-z]+)-\\d+/.exec(input);',
          '    return match && match.groups.word;',
          '  })();',
          '}',
          "console.log(word('abc-42'));",
        ].join('\n'),
        graph: 'reanalyzed',
        output: 'abc\n',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-regex-${fixture.graph}-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('ES5 arrow lowering retains copied BigInt literal leaves', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-bigint-retained-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function exact(BigInt) { return (() => 9007199254740993n)(); }',
        'console.log(typeof exact(void 0), exact(void 0).toString());',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');

      const emitted = readFileSync(output, 'utf8');
      expect(emitted).toContain('9007199254740993n');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('bigint 9007199254740993\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('array, call, and constructor spread lowering retain audited graphs', () => {
    const cases = [
      {
        name: 'native array call and constructor spread on node5',
        target: 'node5',
        graph: 'retained',
        source: [
          'function list(values) { return (() => [...values, 3])(); }',
          'function max(values) { return (() => Math.max(...values))(); }',
          'function Pair(left, right) { this.left = left; this.right = right; }',
          'function pair(values) { return (() => new Pair(...values))(); }',
          'var result = pair([4, 7]);',
          "console.log(list([1, 2]).join(','), max([4, 7]), result.left, result.right);",
        ].join('\n'),
        output: '1,2,3 7 4 7\n',
      },
      {
        name: 'array spread literal lowering on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'function list() { return (() => [...[1, 2], 3])(); }',
          "console.log(list().join(','));",
        ].join('\n'),
        output: '1,2,3\n',
      },
      {
        name: 'direct identifier call spread literal lowering on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'function add(left, right) { return left + right; }',
          'function total() { return (() => add(...[4, 7]))(); }',
          'console.log(total());',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'direct bound identifier call dynamic spread lowering on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'function add(left, right) { return left + right; }',
          'function total(values) { return (() => add(...values))(); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'unbound direct call dynamic spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.remoteAdd = function (left, right) { return left + right; };',
          'function total(values) { return remoteAdd(...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'bound simple member call dynamic spread retains graph on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations.add(...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'member spread preserves receiver and reads getter once on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'var getterReads = 0;',
          'var operations = { base: 4 };',
          'Object.defineProperty(operations, "add", {',
          '  get: function () {',
          '    getterReads++;',
          '    return function (left, right) { return this.base + left + right; };',
          '  },',
          '});',
          'function total(values) { return operations.add(...values); }',
          'console.log(total([4, 7]), getterReads);',
        ].join('\n'),
        output: '15 1\n',
      },
      {
        name: 'unbound member receiver spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations.add(...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'computed member call spread with a literal key retains graph on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations["add"](...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'computed member call spread with a bound key retains graph on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'var methodName = "add";',
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations[methodName](...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'computed member call spread with an unbound key stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.methodName = "add";',
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations[methodName](...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'computed member call spread with an effectful key stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var operations = { add: function (left, right) { return left + right; } };',
          'function getMethodName() { return "add"; }',
          'function total(values) { return operations[getMethodName()](...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'optional member receiver spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations?.add(...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'optional computed member spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var methodName = "add";',
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations?.[methodName](...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'optional member call spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var operations = { add: function (left, right) { return left + right; } };',
          'function total(values) { return operations.add?.(...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'effectful member receiver dynamic spread is evaluated once on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var receiverCalls = 0;',
          'var operations = { add: function (left, right) { return left + right; } };',
          'function getOperations() { receiverCalls++; return operations; }',
          'function total(values) { return getOperations().add(...values); }',
          'console.log(total([4, 7]), receiverCalls);',
        ].join('\n'),
        output: '11 1\n',
      },
      {
        name: 'optional direct call dynamic spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'function add(left, right) { return left + right; }',
          'function total(values) { return add?.(...values); }',
          'console.log(total([4, 7]));',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'optional direct call literal spread stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'function add(left, right) { return left + right; }',
          'function total() { return add?.(...[4, 7]); }',
          'console.log(total());',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'bound direct constructor dynamic spread retains graph on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'function Pair(left, right) { this.total = left + right; }',
          'function pair(values) { return new Pair(...values); }',
          'console.log(pair([4, 7]).total);',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'unbound direct constructor callee stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.RemotePair = function (left, right) { this.total = left + right; };',
          'function pair(values) { return new RemotePair(...values); }',
          'console.log(pair([4, 7]).total);',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'member constructor callee stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var constructors = { Pair: function (left, right) { this.total = left + right; } };',
          'function pair(values) { return new constructors.Pair(...values); }',
          'console.log(pair([4, 7]).total);',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'complex constructor callee stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'var constructorCalls = 0;',
          'function Pair(left, right) { this.total = left + right; }',
          'function getPair() { constructorCalls++; return Pair; }',
          'function pair(values) { return new (getPair())(...values); }',
          'var result = pair([4, 7]);',
          'console.log(result.total, constructorCalls);',
        ].join('\n'),
        output: '11 1\n',
      },
      {
        name: 'unbound constructor spread operand stays on reanalysis on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.remoteValues = [4, 7];',
          'function Pair(left, right) { this.total = left + right; }',
          'function pair() { return new Pair(...remoteValues); }',
          'console.log(pair().total);',
        ].join('\n'),
        output: '11\n',
      },
      {
        name: 'call spread literal lowering on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'function max() { return (() => Math.max(...[4, 7]))(); }',
          'console.log(max());',
        ].join('\n'),
        output: '7\n',
      },
      {
        name: 'constructor spread literal lowering retains graph on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'function Pair(left, right) { this.left = left; this.right = right; }',
          'function pair() { return (() => new Pair(...[4, 7]))(); }',
          'var result = pair();',
          'console.log(result.left, result.right);',
        ].join('\n'),
        output: '4 7\n',
      },
      {
        name: 'iterable array spread helper on node4',
        target: 'node4',
        graph: 'retained',
        source: [
          'var iteratorCalls = 0;',
          'var values = {};',
          'values[Symbol.iterator] = function () {',
          '  iteratorCalls++;',
          '  var item = 0;',
          '  return { next: function () { item++; return item <= 2 ? { value: item, done: false } : { done: true }; } };',
          '};',
          'function list(values) { return (() => [...values, 3])(); }',
          "console.log(list(values).join(','), iteratorCalls);",
        ].join('\n'),
        output: '1,2,3 1\n',
      },
      {
        name: 'unbound member array spread operand on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.values = [1, 2];',
          'function list() { return [...globalThis.values, 3]; }',
          "console.log(list().join(','));",
        ].join('\n'),
        output: '1,2,3\n',
      },
      {
        name: 'unbound identifier array spread operand on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'globalThis.remoteValues = [1, 2];',
          'function list() { return [...remoteValues, 3]; }',
          "console.log(list().join(','));",
        ].join('\n'),
        output: '1,2,3\n',
      },
      {
        name: 'direct eval beside helper array spread on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          'function list(values) { eval("var observed = 1"); return [...values, 3]; }',
          "console.log(list([1, 2]).join(','));",
        ].join('\n'),
        output: '1,2,3\n',
      },
      {
        name: 'array spread with a hole on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: ['function list() { return [...[, 2]]; }', 'console.log(list().length);'].join(
          '\n',
        ),
        output: '2\n',
      },
      {
        name: 'direct eval array spread on node4',
        target: 'node4',
        graph: 'reanalyzed',
        source: [
          "function run() { return (() => eval(...['1 + 2']))(); }",
          'console.log(run());',
        ].join('\n'),
        output: '3\n',
      },
      {
        name: 'object spread lowering on node5',
        target: 'node5',
        graph: 'retained',
        source: [
          'function merge(value) { return (() => ({ ...value, b: 2 }))(); }',
          'var result = merge({ a: 1 });',
          'console.log(result.a, result.b);',
        ].join('\n'),
        output: '1 2\n',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-spread-${fixture.target}-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            `--target=${fixture.target}`,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('ES5 member spread lowering registers a distinct exact receiver reference', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-member-spread-symbols-'));
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-member-spread-output-'));
    const file = join(dir, 'entry.mjs');
    writeFileSync(
      file,
      [
        'var operations = { add: function (left, right) { return left + right; } };',
        'function total(values) { return operations.add(...values); }',
        'console.log(total([4, 7]));',
      ].join('\n'),
    );
    try {
      const { stderr, exitCode } = runCoverage(file, TARGETS[0], outDir);
      expect(exitCode, stderr).toBe(0);
      expect(transformIdentityAuditProblems(stderr), stderr).toEqual([]);

      const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('11\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('ES5 member spread evaluates an effectful receiver only once', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-member-spread-evaluation-'));
    const file = join(dir, 'entry.mjs');
    const output = join(dir, 'out.js');
    writeFileSync(
      file,
      [
        'var receiverCalls = 0;',
        'var operations = { add: function (left, right) { return left + right; } };',
        'function getOperations() { receiverCalls++; return operations; }',
        'function total(values) { return getOperations().add(...values); }',
        'console.log(total([4, 7]), receiverCalls);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(ZNTC_BIN, [file, '--target=es5', '-o', output], {
        encoding: 'utf8',
      });
      expect(proc.status, proc.stderr).toBe(0);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('11 1\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 constructor spread preserves callee identity and evaluates complex callees once', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-constructor-spread-symbols-'));
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-constructor-spread-output-'));
    const file = join(dir, 'entry.mjs');
    writeFileSync(
      file,
      [
        'function Pair(left, right) { this.total = left + right; }',
        'function make(values) { return new Pair(...values); }',
        'var constructorCalls = 0;',
        'function getPair() { constructorCalls++; return Pair; }',
        'function makeIndirect(values) { return new (getPair())(...values); }',
        'console.log(make([4, 7]).total, makeIndirect([5, 6]).total, constructorCalls);',
      ].join('\n'),
    );
    try {
      const { stderr, exitCode } = runCoverage(file, TARGETS[0], outDir);
      expect(exitCode, stderr).toBe(0);
      expect(transformIdentityAuditProblems(stderr), stderr).toEqual([]);

      const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('11 11 1\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('ES5 arrow lowering retains computed object data key temp identities', () => {
    const cases = [
      {
        name: 'native computed object key on node5',
        target: 'node5',
        graph: 'retained',
        source: [
          'var events = [];',
          'function key() { events.push("key"); return "answer"; }',
          'function value() { events.push("value"); return 42; }',
          'function make(prefix) { return (() => ({ [key() + prefix]: value(), plain: prefix }))(); }',
          'var result = make("Key");',
          "console.log(events.join(','), result.answerKey, result.plain);",
        ].join('\n'),
        output: 'key,value 42 Key\n',
      },
      {
        name: 'computed object key downlevel on es5',
        target: 'es5',
        graph: 'retained',
        source: [
          'var events = [];',
          'function key() { events.push("key"); return "answer"; }',
          'function value() { events.push("value"); return 42; }',
          'function make(prefix) { return (() => ({ [key() + prefix]: value(), plain: prefix }))(); }',
          'var result = make("Key");',
          "console.log(events.join(','), result.answerKey, result.plain);",
        ].join('\n'),
        output: 'key,value 42 Key\n',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-computed-key-${fixture.target}-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            `--target=${fixture.target}`,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('arrow lowering retains object method scopes across ES5 method lowering', () => {
    const cases = [
      {
        name: 'native object method and getter on node5',
        target: 'node5',
        graph: 'retained',
        source: [
          'var methods = {',
          '  combine(_this) { return (() => this.prefix + _this)(); },',
          '  get captured() { return (() => this.prefix)(); },',
          '};',
          'methods.prefix = "answer";',
          'console.log(methods.combine("!"), methods.captured);',
        ].join('\n'),
        output: 'answer! answer\n',
      },
      {
        name: 'object method lowering on es5',
        target: 'es5',
        graph: 'retained',
        source: [
          'var methods = {',
          '  combine(_this) { return (() => this.prefix + _this)(); },',
          '  get captured() { return (() => this.prefix)(); },',
          '};',
          'methods.prefix = "answer";',
          'console.log(methods.combine("!"), methods.captured);',
        ].join('\n'),
        output: 'answer! answer\n',
      },
      {
        name: 'async object method without await lowers on node5',
        target: 'node5',
        graph: 'reanalyzed',
        source: [
          'var methods = { async value() { return (() => this.amount)(); } };',
          'methods.amount = 42;',
          'methods.value().then(function(result) { console.log(result); });',
        ].join('\n'),
        output: '42\n',
      },
      {
        name: 'generator object method without yield lowers on node5',
        target: 'node5',
        graph: 'reanalyzed',
        source: [
          'var methods = {',
          '  *values() { return 41; },',
          '  value() { return (() => this.amount)(); },',
          '};',
          'methods.amount = 42;',
          'console.log(methods.values().next().value, methods.value());',
        ].join('\n'),
        output: '41 42\n',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-bundle-arrow-object-method-${fixture.target}-`));
      const output = join(dir, 'out.cjs');
      writeFileSync(join(dir, 'entry.mjs'), fixture.source);
      try {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            `--target=${fixture.target}`,
            '--platform=node',
            '--format=cjs',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);

        const graphMode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
          );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

  test('legacy TypeScript decorators retain exact transform graph references', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-legacy-decorator-'));
    try {
      const file = join(outDir, 'input.ts');
      const source = `const __decorateClass = 7, __decorateParam = 8, __metadata = 9;
function classDec(target: any): any { return target; }
function propertyDec(target: any, key: string): void {}
function methodDec(target: any, key: string, descriptor: PropertyDescriptor): PropertyDescriptor { return descriptor; }
function parameterDec(target: any, key: string, index: number): void {}
@classDec
class Example {
  @propertyDec field: number = 2;
  @methodDec method(@parameterDec parameterDec: number, value: number): number { return this.field + eval('value'); }
  static self() { return Example; }
}
const parameterEvents: string[] = [];
class ParamExample {
  static decorator(target: any, key: string, index: number): void { parameterEvents.push(key + ':' + index + ':' + (target === ParamExample.prototype)); }
  method(@ParamExample.decorator value: number): number { return value; }
}
class CtorExample {
  static decorator(target: any, key: string | undefined, index: number): void { parameterEvents.push((key === undefined) + ':' + index + ':' + (target === CtorExample)); }
  constructor(@CtorExample.decorator value: number) {}
}
new CtorExample(4);
console.log(new Example().method(undefined, 3), __decorateClass, __decorateParam, __metadata, Example.self() === Example, parameterEvents.join(','), new ParamExample().method(6));
`;
      writeFileSync(file, source);
      const referenceFile = join(outDir, 'reference.js');
      const reference = ts.transpileModule(source, {
        compilerOptions: {
          experimentalDecorators: true,
          target: ts.ScriptTarget.ES5,
        },
      }).outputText;
      writeFileSync(referenceFile, reference);
      const oracle = spawnSync('node', [referenceFile], { encoding: 'utf8' });
      expect(oracle.status, oracle.stderr).toBe(0);
      expect(oracle.stdout).toBe('5 7 8 9 true method:0:true,true:0:true 6\n');
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--experimental-decorators', '--minify-identifiers', '-o', output],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(identity, `${target.name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, `${target.name}: differs from TypeScript 5 output`).toBe(
          oracle.stdout,
        );
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  // TypeScript drops legacy decorators on class expressions; lowering must still keep the expression value and scope.
  test('legacy decorator stripping keeps named class expressions valid', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-legacy-decorator-class-expression-'));
    try {
      const file = join(outDir, 'input.ts');
      const source = `const events: string[] = [];
function methodDec(target: any, key: string, descriptor: PropertyDescriptor): PropertyDescriptor { events.push(key); return descriptor; }
const Holder = class Inner {
  @methodDec method(value: number): number { return value + 1; }
  static value = (events.push('static'), 7);
  static selfValue = Inner;
  static self() { return Inner; }
};
const Anonymous = class {
  @methodDec value(): number { return 3; }
};
console.log(new Holder().method(3), Holder.self() === Holder, Holder.value, Holder.selfValue === Holder, new Anonymous().value(), events.join(','));
`;
      writeFileSync(file, source);
      const referenceFile = join(outDir, 'reference.js');
      const reference = ts.transpileModule(source, {
        compilerOptions: {
          experimentalDecorators: true,
          target: ts.ScriptTarget.ES5,
        },
      }).outputText;
      writeFileSync(referenceFile, reference);
      const oracle = spawnSync('node', [referenceFile], { encoding: 'utf8' });
      expect(oracle.status, oracle.stderr).toBe(0);
      expect(oracle.stdout).toBe('4 true 7 true 3 static\n');
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--experimental-decorators', '--minify-identifiers', '-o', output],
          {
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(identity, `${target.name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, `${target.name}: differs from TypeScript 5 output`).toBe(
          oracle.stdout,
        );
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Flow class lowering reuses exact symbols and keeps shadowed bindings separate', () => {
    const file = join(FIXTURE_DIR, '4819-flow-class.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-class-'));
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--flow', '--minify-identifiers', '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('42|22|900\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Flow private field lowering reuses exact symbols across shadowed names', () => {
    const file = join(FIXTURE_DIR, '4819-flow-private-class.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-private-class-'));
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--flow', '--minify-identifiers', '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('42:outer|5:outer\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('assign-semantics class methods retain their function-scope temp identities', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-class-method-temp-scopes-'));
    const fixtures = [
      '4789-assign-rest-private-super.mjs',
      '4819-static-private-async-generator-super.mjs',
      '4819-static-private-async-super.mjs',
      '4819-static-private-generator-super.mjs',
    ];
    try {
      for (const fixture of fixtures) {
        const file = join(FIXTURE_DIR, fixture);
        const reference = spawnSync('node', [file], { encoding: 'utf8' });
        expect(reference.status, `${fixture}: ${reference.stderr}`).toBe(0);

        for (const target of TARGETS) {
          const output = join(dir, `${fixture}-${target.name}.mjs`);
          const proc = spawnSync(
            ZNTC_BIN,
            [file, target.arg, '--minify-identifiers', '-o', output],
            {
              env: {
                ...process.env,
                ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
                ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
              },
              encoding: 'utf8',
            },
          );
          expect(proc.status, `${fixture} ${target.name}: ${proc.stderr}`).toBe(0);
          const lines = (proc.stderr ?? '').split(/\r?\n/);
          const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, `${fixture} ${target.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture} ${target.name} ${counter}: ${identity}`,
            ).toBe(0);
          }
          const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
          expect(strict, `${fixture} ${target.name}: ${proc.stderr}`).toMatch(
            /missing_binding=0 .*unclassified=0 .*orphan_symbols=0 .*symbol_identity_complete=1/,
          );
          if (target.name === 'es5' || target.name === 'esnext') {
            const postMinify = lines.find((line) =>
              line.startsWith('zntc: symbol-identity-post-minify '),
            );
            expect(postMinify, `${fixture} ${target.name}: ${proc.stderr}`).toMatch(
              /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
            );
          }
          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${fixture} ${target.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, `${fixture} ${target.name}`).toBe(reference.stdout);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('prehoisted class computed keys bind every generated temp read', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-prehoisted-class-keys-'));
    const fixtures = ['4801-static-field-this-boundaries.mjs', '4819-generator-state-computed.mjs'];
    try {
      for (const fixture of fixtures) {
        const file = join(FIXTURE_DIR, fixture);
        const reference = spawnSync('node', [file], { encoding: 'utf8' });
        expect(reference.status, `${fixture}: ${reference.stderr}`).toBe(0);

        for (const target of TARGETS) {
          const output = join(dir, `${fixture}-${target.name}.mjs`);
          const proc = spawnSync(
            ZNTC_BIN,
            [file, target.arg, '--minify-identifiers', '-o', output],
            {
              env: {
                ...process.env,
                ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
                ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
              },
              encoding: 'utf8',
            },
          );
          expect(proc.status, `${fixture} ${target.name}: ${proc.stderr}`).toBe(0);
          const lines = (proc.stderr ?? '').split(/\r?\n/);
          const identity = lines.find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, `${fixture} ${target.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture} ${target.name} ${counter}: ${identity}`,
            ).toBe(0);
          }
          const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
          expect(strict, `${fixture} ${target.name}: ${proc.stderr}`).toMatch(
            /missing_binding=0 .*unclassified=0 .*orphan_symbols=0 .*symbol_identity_complete=1/,
          );
          if (target.name === 'es5' || target.name === 'esnext') {
            const postMinify = lines.find((line) =>
              line.startsWith('zntc: symbol-identity-post-minify '),
            );
            expect(postMinify, `${fixture} ${target.name}: ${proc.stderr}`).toMatch(
              /invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
            );
          }
          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${fixture} ${target.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout, `${fixture} ${target.name}`).toBe(reference.stdout);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('Flow auto-accessor lowering reuses exact symbols without capturing same-named locals', () => {
    const file = join(FIXTURE_DIR, '4819-flow-accessor.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-accessor-'));
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--flow', '--minify-identifiers', '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        // The current non-ES5 emitter preserves `accessor` syntax, which Node
        // does not parse. Exercise runtime behavior on the ES5 downlevel path;
        // exact symbol identity above is still checked for every target.
        if (target.name === 'es5') {
          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
          expect(actual.stdout).toBe('42:outer:99\n');
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Flow Stage 3 decorators reuse exact symbols through scopes and name collisions', () => {
    const file = join(FIXTURE_DIR, '4819-flow-decorator.flow');
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-flow-decorator-'));
    try {
      for (const target of TARGETS) {
        const output = join(outDir, `${target.name}.js`);
        const proc = spawnSync(
          ZNTC_BIN,
          [file, target.arg, '--flow', '--minify-identifiers', '-o', output],
          {
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, `${target.name}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split('\n')
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${target.name}: missing exact report`).toBeDefined();
        expect(identity, `${target.name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        // TypeScript's Stage 3 transform oracle reports false here: the method
        // resolves Box to the decorated outer binding, not the captured input class.
        expect(actual.stdout).toBe('83 40 7 8 9 10 11 false 20 true\n');
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('Reanimated worklet preserves generated SymbolIds on the bundler prepass path', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-symbol-identity-'));
    const entry = join(dir, 'entry.js');
    const shadow = join(dir, 'shadow.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      shadow,
      'const global = { Error: class ShadowError {} }; console.log(global.Error.name); export {};\n',
    );
    writeFileSync(
      entry,
      [
        "import './shadow.js';",
        'let captured = 40;',
        'export function declared() { "worklet"; return captured + 1; }',
        'export const arrow = (value) => { "worklet"; return captured + value; };',
        'export const handlers = { method(value) { "worklet"; return captured + value; } };',
        'console.log(declared(), arrow(2), handlers.method(3), declared.__stackDetails[0] instanceof Error);',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const buildOptions = JSON.stringify({
      entryPoints: [entry],
      platform: 'node',
      format: 'cjs',
      target: 'esnext',
      workletTransform: true,
      minifyIdentifiers: true,
      write: false,
    });
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${buildOptions});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: {
          ...process.env,
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
          ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
        },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      expect(identity).toMatch(/clean=1(?:\s|$)/);
      expect(Number(identity!.match(/generated_bindings=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      expect(Number(identity!.match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=retained');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('ShadowError\n41 42 43 true\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated getter factory chooses its output name after preserving captured SymbolIds', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-late-factory-name-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      [
        'const captured = 41;',
        'const object = { get captured() { "worklet"; return captured + 1; } };',
        'console.log(object.captured());',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    try {
      for (const minifyIdentifiers of [false, true]) {
        const runner = [
          `import { build } from ${JSON.stringify(coreEntry)};`,
          `const result = await build(${JSON.stringify({
            entryPoints: [entry],
            platform: 'node',
            format: 'cjs',
            target: 'esnext',
            workletTransform: true,
            minifyIdentifiers,
            write: false,
          })});`,
          'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
          'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
        ].join('\n');
        const proc = spawnSync('bun', ['-e', runner], {
          cwd: join(import.meta.dir, '../../..'),
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, proc.stderr).toBe(0);
        const identity = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
          );
        expect(identity, proc.stderr).toBeDefined();
        expect(exactSchemaProblems(identity!), identity).toEqual([]);
        expect(identity).toMatch(/clean=1(?:\s|$)/);

        const outputs = JSON.parse(proc.stdout) as string[];
        expect(outputs).toHaveLength(1);
        writeFileSync(output, outputs[0]);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe('42\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated class factory closure key does not capture same-named source locals', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-class-factory-name-collision-'));
    const entry = join(dir, 'entry.js');
    writeFileSync(
      entry,
      [
        'class Clazz { __workletClass = true; value() { return 1; } }',
        'class Other { __workletClass = true; value() { return 2; } }',
        'const Clazz__classFactory = 73;',
        'const Other__classFactory = 74;',
        'const __zntcWorkletClosure0 = 88;',
        'export function capturedName() {',
        '  "worklet";',
        '  const other = new Other();',
        '  const instance = new Clazz();',
        '  return [other.value(), instance.value(), Clazz__classFactory, Other__classFactory, __zntcWorkletClosure0];',
        '}',
        'export function plainName() {',
        '  "worklet";',
        '  return Clazz__classFactory;',
        '}',
        'export function localName() {',
        '  "worklet";',
        '  const Clazz__classFactory = 19;',
        '  const instance = new Clazz();',
        '  return [instance.value(), Clazz__classFactory];',
        '}',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    try {
      for (const minifyIdentifiers of [false, true]) {
        const runner = [
          `import { build } from ${JSON.stringify(coreEntry)};`,
          `const result = await build(${JSON.stringify({
            entryPoints: [entry],
            platform: 'react-native',
            format: 'cjs',
            target: 'esnext',
            workletTransform: true,
            minifyIdentifiers,
            write: false,
          })});`,
          'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
          'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
        ].join('\n');
        const proc = spawnSync('bun', ['-e', runner], {
          cwd: join(import.meta.dir, '../../..'),
          encoding: 'utf8',
        });
        expect(proc.status, proc.stderr).toBe(0);
        const outputs = JSON.parse(proc.stdout) as string[];
        expect(outputs).toHaveLength(1);
        const output = outputs[0]!;
        expect(output).toMatch(/Clazz__classFactory:\s*[A-Za-z_$][\w$]*\.Clazz__classFactory/);
        expect(output).toMatch(/Other__classFactory:\s*[A-Za-z_$][\w$]*\.Other__classFactory/);
        const userClosureAlias = output.match(/(__zntcWorkletClosure1):\s*[A-Za-z_$][\w$]*/)?.[1];
        const otherClosureAlias = output.match(/(__zntcWorkletClosure2):\s*[A-Za-z_$][\w$]*/)?.[1];
        expect(userClosureAlias).toBeDefined();
        expect(otherClosureAlias).toBeDefined();

        const initDataCodes = Array.from(
          output.matchAll(/__initData\s*=\s*\{\s*code:\s*("(?:\\.|[^"\\])*")/g),
          (match) => JSON.parse(match[1]!) as string,
        );
        for (const name of ['capturedName', 'plainName', 'localName']) {
          const initDataCode = initDataCodes.find((code) => code.startsWith(`function ${name}(`));
          expect(initDataCode, `${name} init data was not emitted`).toBeDefined();
          expect(() => new Function(initDataCode!)).not.toThrow();
          if (initDataCode) {
            if (name === 'capturedName') {
              expect(initDataCode).toContain('__zntcWorkletClosure1:Clazz__classFactory');
              expect(initDataCode).toContain('__zntcWorkletClosure2:Other__classFactory');
            }
            const generated = new Function(`return (${initDataCode});`)() as (this: {
              __closure: Record<string, unknown>;
            }) => unknown;
            const closure: Record<string, unknown> = {
              Clazz: class {
                value() {
                  return 1;
                }
              },
              Other: class {
                value() {
                  return 2;
                }
              },
            };
            if (name === 'capturedName') {
              closure[userClosureAlias!] = 73;
              closure[otherClosureAlias!] = 74;
              closure.__zntcWorkletClosure0 = 88;
              closure.Clazz__classFactory = () => class {};
              closure.Other__classFactory = () => class {};
            } else {
              closure.Clazz__classFactory = name === 'plainName' ? 73 : () => class {};
            }
            const value = generated.call({ __closure: closure });
            const expectedValue =
              name === 'capturedName' ? [2, 1, 73, 74, 88] : name === 'plainName' ? 73 : [1, 19];
            expect(value, `${name}, minifyIdentifiers=${minifyIdentifiers}`).toEqual(expectedValue);
          }
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated worklet retains its graph when the body has an ordinary nested function', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-nested-helper-retained-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      [
        'export function work(value) {',
        '  "worklet";',
        '  function addOne(input) { return value + input; }',
        '  return addOne(1);',
        '}',
        'console.log(work(41));',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${JSON.stringify({
        entryPoints: [entry],
        platform: 'node',
        format: 'cjs',
        target: 'esnext',
        workletTransform: true,
        minifyIdentifiers: true,
        write: false,
      })});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      expect(identity).toMatch(/clean=1(?:\s|$)/);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=retained');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated worklet nested in another function stays on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-nested-reanalysis-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      [
        'function make(global) { return function nested() { "worklet"; return 44; }; }',
        'const nested = make({ Error: class NestedError {} });',
        'console.log(nested(), nested.__stackDetails[0].constructor.name);',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${JSON.stringify({
        entryPoints: [entry],
        platform: 'node',
        format: 'cjs',
        target: 'esnext',
        workletTransform: true,
        minifyIdentifiers: true,
        write: false,
      })});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=reanalyzed');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('44 NestedError\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated file-level Worklet directive retains the graph with a nested helper', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-file-directive-nested-retained-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      [
        '"worklet";',
        'export function make(value) {',
        '  function addOne(input) { return value + input; }',
        '  return addOne(1);',
        '}',
        'console.log(make(41));',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${JSON.stringify({
        entryPoints: [entry],
        platform: 'node',
        format: 'cjs',
        target: 'esnext',
        workletTransform: true,
        minifyIdentifiers: true,
        write: false,
      })});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      expect(identity).toMatch(/clean=1(?:\s|$)/);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=retained');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated worklet with downlevel syntax stays on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-downlevel-reanalysis-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      'export const compute = (value) => { "worklet"; return value + 1; };\nconsole.log(compute(41));\n',
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${JSON.stringify({
        entryPoints: [entry],
        platform: 'node',
        format: 'cjs',
        target: 'es5',
        workletTransform: true,
        minifyIdentifiers: true,
        write: false,
      })});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=reanalyzed');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated worklet binds generated global.Error to a same-file source symbol', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-global-shadow-reanalysis-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      [
        'const global = { Error: class ShadowError {} };',
        'export function work() { "worklet"; return 42; }',
        'console.log(work(), global.Error.name);',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${JSON.stringify({
        entryPoints: [entry],
        platform: 'node',
        format: 'cjs',
        target: 'esnext',
        workletTransform: true,
        minifyIdentifiers: true,
        write: false,
      })});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=retained');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42 ShadowError\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated worklet with direct eval stays on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-eval-reanalysis-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      'export function dynamic() { "worklet"; return eval("40 + 2"); }\nconsole.log(dynamic());\n',
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build(${JSON.stringify({
        entryPoints: [entry],
        platform: 'node',
        format: 'cjs',
        target: 'esnext',
        workletTransform: true,
        write: false,
      })});`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=reanalyzed');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated worklet with a user AST plugin stays on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-plugin-reanalysis-'));
    const entry = join(dir, 'entry.js');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      'export function work() { "worklet"; return 42; }\nconsole.log(work());\n',
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const baseOptions = JSON.stringify({
      entryPoints: [entry],
      platform: 'node',
      format: 'cjs',
      target: 'esnext',
      workletTransform: true,
      write: false,
    });
    const runner = [
      `import { build } from ${JSON.stringify(coreEntry)};`,
      `const result = await build({ ...${baseOptions}, plugins: [{ name: 'noop-ast', setup(build) { build.onAstFunction({ filter: /.*/ }, () => null); } }] });`,
      'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
    ].join('\n');
    try {
      const proc = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      const stderr = proc.stderr ?? '';
      expect(proc.status, stderr).toBe(0);
      const identity = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(identity, stderr).toBeDefined();
      expect(exactSchemaProblems(identity!), identity).toEqual([]);
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.js'),
        );
      expect(mode, stderr).toContain('semantic_graph=reanalyzed');

      const outputs = JSON.parse(proc.stdout) as string[];
      expect(outputs).toHaveLength(1);
      writeFileSync(output, outputs[0]);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Emotion css prop keeps its exact import identity through bundling and minification', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emotion-symbol-identity-'));
    const emotionDir = join(dir, 'node_modules', '@emotion', 'react');
    mkdirSync(emotionDir, { recursive: true });
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ compiler: { emotion: true } }));
    writeFileSync(
      join(emotionDir, 'package.json'),
      JSON.stringify({ name: '@emotion/react', version: '0.0.0-test', main: 'index.js' }),
    );
    writeFileSync(
      join(emotionDir, 'index.js'),
      "exports.css = function(value) { return 'EMOTION:' + value.color; };\n",
    );
    writeFileSync(
      join(dir, 'index.tsx'),
      [
        "import { css as cx } from '@emotion/react';",
        'function h(_tag, props) { return props.css; }',
        'function render(cx, _emotionCss, _emotionCss2, _emotionCss3) {',
        "  return <div css={{ color: 'red' }} />;",
        '}',
        "console.log(render(() => 'SHADOWED-CX', () => 'SHADOWED-1', () => 'SHADOWED-2', () => 'SHADOWED-3'));",
        '',
      ].join('\n'),
    );

    try {
      // React Native's automatic JSX runtime does not apply this web Emotion
      // css-prop transform. Exercise every ES target that runs this producer.
      const emotionTargets = TARGETS.filter((target) => target.name !== 'hermes');
      for (const target of emotionTargets) {
        const output = join(dir, `out-${target.name}.js`);
        const proc = spawnSync(
          'bun',
          [
            ZNTC_JS_CLI,
            '--bundle',
            'index.tsx',
            target.arg,
            ...(target.name === 'esnext' ? ['--verbatim-module-syntax'] : []),
            '--jsx=classic',
            '--jsx-factory=h',
            '--minify-identifiers',
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        const stderr = proc.stderr ?? '';
        expect(proc.status, `${target.name}: ${stderr}`).toBe(0);

        const identityReports = stderr
          .split(/\r?\n/)
          .filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('/index.tsx:'),
          );
        expect(identityReports, `${target.name}: ${stderr}`).toHaveLength(1);
        const identity = identityReports[0];
        expect(exactSchemaProblems(identity), `${target.name}: ${identity}`).toEqual([]);
        expect(identity, `${target.name}: ${identity}`).toMatch(/clean=1(?:\s|$)/);
        const mode = stderr
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes('/index.tsx:'),
          );
        if (target.name === 'esnext') {
          expect(mode, `${target.name}: ${stderr}`).toContain('semantic_graph=retained');
        } else if (target.name === 'es2022') {
          expect(mode, `${target.name}: ${stderr}`).toContain('semantic_graph=reanalyzed');
        }
        expect(
          Number(identity.match(/generated_bindings=(\d+)/)?.[1] ?? 0),
          `${target.name}: ${identity}`,
        ).toBeGreaterThan(0);
        expect(
          Number(identity.match(/generated_references=(\d+)/)?.[1] ?? 0),
          `${target.name}: ${identity}`,
        ).toBeGreaterThan(0);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target.name).toBe('EMOTION:red\n');
      }

      const noVerbatimOutput = join(dir, 'out-esnext-no-verbatim.js');
      const noVerbatimProc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'index.tsx',
          '--target=esnext',
          '--jsx=classic',
          '--jsx-factory=h',
          '--minify-identifiers',
          '-o',
          noVerbatimOutput,
        ],
        {
          cwd: dir,
          env: {
            ...process.env,
            ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          },
          encoding: 'utf8',
        },
      );
      const noVerbatimStderr = noVerbatimProc.stderr ?? '';
      expect(noVerbatimProc.status, noVerbatimStderr).toBe(0);
      const noVerbatimMode = noVerbatimStderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('/index.tsx:'),
        );
      expect(noVerbatimMode, noVerbatimStderr).toContain('semantic_graph=reanalyzed');
      const noVerbatimIdentity = noVerbatimStderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes('/index.tsx:'),
        );
      expect(noVerbatimIdentity, noVerbatimStderr).toMatch(/clean=1(?:\s|$)/);
      const noVerbatimActual = spawnSync('node', [noVerbatimOutput], { encoding: 'utf8' });
      expect(noVerbatimActual.status, noVerbatimActual.stderr).toBe(0);
      expect(noVerbatimActual.stdout).toBe('EMOTION:red\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('bundler Emotion keeps direct eval on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emotion-eval-reanalysis-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ compiler: { emotion: true } }));
    writeFileSync(join(dir, 'entry.tsx'), "void eval('40 + 2');\n");
    try {
      const proc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'entry.tsx',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const mode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('/entry.tsx:'),
        );
      expect(mode, proc.stderr).toContain('semantic_graph=reanalyzed');
      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes('/entry.tsx:'),
        );
      expect(report, proc.stderr).toMatch(/clean=1(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('오라클 전체에서 exact 구조 불변식과 심볼 부채가 모두 0', async () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-symcov-'));
    const problems: string[] = [];
    const exactCounts = new Map<string, number>();
    const exactExamples = new Map<string, string[]>();
    let generatedBindings = 0;
    let generatedReferences = 0;
    let declarationAnchorsChecked = 0;
    let strictExternalReferences = 0;
    let strictRawScopeMismatches = 0;
    let runs = 0;
    try {
      for (const file of fixtures) {
        const name = relative(FIXTURE_DIR, file);
        for (const target of TARGETS) {
          const { stderr, exitCode } = runCoverage(file, target, outDir);
          if (exitCode !== 0) {
            // A transform may fail after the exact identity report is emitted
            // but before the source-only summary is printed. Keep checking the
            // same owner counters from that authoritative report on this path.
            const identityLines = stderr
              .split('\n')
              .filter((line) => line.startsWith('zntc: symbol-identity '));
            if (identityLines.length !== 1) {
              problems.push(
                `${name} ${target.name}: expected one exact identity audit for failed transform, got ${identityLines.length}`,
              );
            } else {
              for (const scopeOwnerProblem of scopeOwnerAuditProblems(identityLines[0])) {
                problems.push(
                  `${name} ${target.name}: exact identity scope-owner audit ${scopeOwnerProblem}: ${identityLines[0]}`,
                );
              }
            }
            problems.push(`${name} ${target.name}: exit=${exitCode} ${stderr.trim()}`);
            continue;
          }
          const sourceScopeOwnerLines = stderr
            .split('\n')
            .filter((line) => line.startsWith('zntc: symbol-source-scope-owner '));
          if (sourceScopeOwnerLines.length !== 1) {
            problems.push(
              `${name} ${target.name}: expected one source scope-owner audit, got ${sourceScopeOwnerLines.length}`,
            );
          } else {
            const scopeOwnerDetails = stderr
              .split('\n')
              .filter(
                (line) =>
                  line.startsWith('zntc: symbol-identity-detail ') && line.includes('scope_owner'),
              );
            for (const scopeOwnerProblem of scopeOwnerAuditProblems(sourceScopeOwnerLines[0])) {
              problems.push(
                `${name} ${target.name}: source scope-owner audit ${scopeOwnerProblem}: ${sourceScopeOwnerLines[0]} ${scopeOwnerDetails.join(' ')}`,
              );
            }
          }
          const lines = stderr
            .split('\n')
            .filter((line) => line.startsWith('zntc: symbol-coverage '));
          if (lines.length !== 1) {
            problems.push(
              `${name} ${target.name}: expected one coverage report, got ${lines.length}`,
            );
            continue;
          }
          const identityLines = stderr
            .split('\n')
            .filter((l) => l.startsWith('zntc: symbol-identity '));
          if (identityLines.length !== 1) {
            problems.push(
              `${name} ${target.name}: expected one identity report, got ${identityLines.length}`,
            );
            continue;
          }
          const strictLines = stderr
            .split('\n')
            .filter((l) => l.startsWith('zntc: synthetic-coverage '));
          if (strictLines.length !== 1) {
            problems.push(
              `${name} ${target.name}: expected one strict coverage report, got ${strictLines.length}`,
            );
            continue;
          }
          if (!/(?:^| )consistent=1(?: |$)/.test(strictLines[0])) {
            problems.push(
              `${name} ${target.name}: strict report counters/details disagree: ${strictLines[0]}`,
            );
          }
          if (!/(?:^| )symbol_identity_complete=1(?: |$)/.test(strictLines[0])) {
            problems.push(
              `${name} ${target.name}: strict SymbolId identity coverage is incomplete: ${strictLines[0]}`,
            );
          }
          for (const schemaProblem of strictSchemaProblems(strictLines[0])) {
            problems.push(
              `${name} ${target.name}: strict report schema ${schemaProblem}: ${strictLines[0]}`,
            );
          }
          const line = lines[0];
          runs++;
          const m = line.match(/missing=(\d+) wrong=(\d+)/);
          if (!m || m[1] !== '0' || m[2] !== '0') {
            const detail = stderr
              .split('\n')
              .filter((l) => /^\s+(missing|wrong) /.test(l))
              .join('; ');
            problems.push(
              `${name} ${target.name}: ${m ? `missing=${m[1]} wrong=${m[2]}` : line} ${detail}`,
            );
          }
          const identity = identityLines[0];
          const clean = identity.match(/(?:^| )clean=(\d+)(?: |$)/)?.[1];
          if (clean !== '1') {
            problems.push(
              `${name} ${target.name}: exact aggregate clean=${clean ?? 'missing'}: ${identity}`,
            );
          }
          for (const schemaProblem of exactSchemaProblems(identity)) {
            problems.push(
              `${name} ${target.name}: exact report schema ${schemaProblem}: ${identity}`,
            );
          }
          const generatedBindingsMatch = identity.match(/generated_bindings=(\d+)/);
          const generatedReferencesMatch = identity.match(/generated_references=(\d+)/);
          const declarationAnchorsMatch = identity.match(/declaration_anchors_checked=(\d+)/);
          if (!generatedBindingsMatch || !generatedReferencesMatch || !declarationAnchorsMatch) {
            problems.push(`${name} ${target.name}: missing generated-node totals: ${identity}`);
          } else {
            generatedBindings += Number(generatedBindingsMatch[1]);
            generatedReferences += Number(generatedReferencesMatch[1]);
            declarationAnchorsChecked += Number(declarationAnchorsMatch[1]);
          }
          for (const counter of EXACT_ZERO_COUNTERS) {
            const value = identity.match(new RegExp(`${counter}=(\\d+)`))?.[1];
            if (value === undefined) {
              problems.push(
                `${name} ${target.name}: missing identity counter ${counter}: ${identity}`,
              );
              continue;
            }
            exactCounts.set(counter, (exactCounts.get(counter) ?? 0) + Number(value));
            if (value !== '0') {
              const examples = exactExamples.get(counter) ?? [];
              if (examples.length < 4) examples.push(`${name} ${target.name} ${counter}=${value}`);
              exactExamples.set(counter, examples);
            }
          }
          for (const counter of STRICT_ZERO_COUNTERS) {
            const value = strictLines[0].match(new RegExp(`${counter}=(\\d+)`))?.[1];
            if (value === undefined) {
              problems.push(
                `${name} ${target.name}: missing strict counter ${counter}: ${strictLines[0]}`,
              );
            } else if (value !== '0') {
              problems.push(
                `${name} ${target.name}: strict ${counter}=${value}: ${strictLines[0]}`,
              );
            }
          }
          const externalCount = strictLines[0].match(/external=(\d+)/)?.[1];
          if (externalCount === undefined) {
            problems.push(
              `${name} ${target.name}: missing strict external counter: ${strictLines[0]}`,
            );
          } else {
            strictExternalReferences += Number(externalCount);
          }
          const rawScopeMismatchCount = strictLines[0].match(/scope_mismatch=(\d+)/)?.[1];
          if (rawScopeMismatchCount === undefined) {
            problems.push(
              `${name} ${target.name}: missing delegated raw scope counter: ${strictLines[0]}`,
            );
          } else {
            strictRawScopeMismatches += Number(rawScopeMismatchCount);
          }
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
    const identityFailures = [...exactCounts.entries()].filter(([, count]) => count !== 0);
    if (identityFailures.length > 0) {
      problems.push(
        `exact identity totals: ${identityFailures.map(([counter, count]) => `${counter}=${count}`).join(' ')}; examples: ${identityFailures.map(([counter]) => `${counter}: ${(exactExamples.get(counter) ?? []).join(' || ')}`).join(' || ')}`,
      );
    }
    // 검사기가 실제로 돌았는지(출력 형식이 바뀌어 전부 건너뛰면 공허하게 통과한다).
    expect(fixtures.length).toBeGreaterThan(0);
    expect(problems).toEqual([]);
    expect(runs).toBe(298 * 6);
    expect(generatedBindings).toBeGreaterThan(0);
    expect(generatedReferences).toBeGreaterThan(0);
    expect(declarationAnchorsChecked).toBeGreaterThan(0);
    expect(strictExternalReferences).toBeGreaterThan(0);
    // Exercise the documented raw-trace exception while the separate exact
    // report still requires all transform-aware binding/reference scopes clean.
    expect(strictRawScopeMismatches).toBeGreaterThan(0);
  }, 600_000);

  test('중첩 함수의 direct eval 은 모듈 범위의 외부 참조를 오염시키지 않는다', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-eval-scope-'));
    try {
      const { stderr, exitCode } = runCoverage(
        join(FIXTURE_DIR, '4760-block-eval.mjs'),
        TARGETS[0],
        outDir,
      );
      expect(exitCode, stderr).toBe(0);
      const identity = stderr.split('\n').find((line) => line.startsWith('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      expect(Number(identity?.match(/external=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
      expect(Number(identity?.match(/unclassified_reference=(\d+)/)?.[1] ?? 1)).toBe(0);
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('opt-in 합성 진단은 private 저장소를 추적하면서 누락으로 오분류하지 않는다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-synthetic-coverage-'));
    try {
      const input = join(dir, 'input.mjs');
      writeFileSync(
        input,
        'class C { static #x = 1; static read() { return this.#x; } } console.log(C.read());',
      );
      const proc = spawnSync(ZNTC_BIN, [input, '--target=es5', '-o', join(dir, 'out.mjs')], {
        env: {
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
          ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          PATH: process.env.PATH ?? '/usr/bin:/bin',
        },
        encoding: 'utf8',
      });
      expect(proc.status, proc.stderr).toBe(0);
      expect(proc.stderr).toMatch(/symbol-coverage .* missing=0 wrong=0/);
      expect(proc.stderr).toMatch(/synthetic-coverage .* missing_binding=0/);
      // Private storage and generated runtime-helper references all carry
      // synthetic identity markers now.
      expect(proc.stderr).toMatch(/synthetic-coverage .* marked_synthetic=4/);
      expect(proc.stderr).toMatch(/synthetic-coverage .* consistent=1/);
      expect(proc.stderr).toMatch(/synthetic-coverage .* symbol_identity_complete=1/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('minify 뒤에도 살아 있는 심볼 참조가 최종 바인딩을 가리킨다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-post-minify-symbol-'));
    try {
      const input = join(dir, 'input.mjs');
      const output = join(dir, 'out.mjs');
      writeFileSync(
        input,
        [
          'function alias(parameterName) {',
          '  const firstAlias = parameterName;',
          '  const secondAlias = firstAlias;',
          '  return secondAlias;',
          '}',
          'function shadow(outerValue) {',
          '  const first = outerValue;',
          '  { const second = first; return second; }',
          '}',
          'export { alias, shadow };',
        ].join('\n'),
      );
      const proc = spawnSync(
        ZNTC_BIN,
        [input, '--minify-syntax', '--minify-identifiers', '-o', output],
        {
          env: {
            ...process.env,
            ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            PATH: process.env.PATH ?? '/usr/bin:/bin',
          },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);
      expect(proc.stderr).toMatch(
        /symbol-identity-post-minify .* invalid_binding_id=0 invalid_reference_id=0 missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 shadowed_external_reference=0 unproven_external_reference=0 clean=1/,
      );
      expect(readFileSync(output, 'utf8')).toContain('function');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 empty classes, safe static fields, plain methods and compatible accessors retain their graph; other forms resync', () => {
    let deeplyNestedComputedKey = 'makeKey()';
    for (let depth = 0; depth < 64; depth += 1) {
      deeplyNestedComputedKey = `wrap(holder[${deeplyNestedComputedKey}]())`;
    }
    const cases = [
      {
        name: 'empty named class',
        source: 'class Empty {}\nconsole.log(new Empty() instanceof Empty);\n',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'static primitive fields retain their exact class graph and generated Object global',
        source:
          'class StaticField { static enabled = true; static empty = null; static value = 9; static label = "ready"; } console.log(StaticField.enabled, StaticField.empty, StaticField.value, StaticField.label);',
        graph: 'retained',
        output: 'true null 9 ready\n',
      },
      {
        name: 'static name field keeps DefineOwnProperty semantics',
        source: 'class StaticName { static name = "field-name"; } console.log(StaticName.name);',
        graph: 'retained',
        output: 'field-name\n',
      },
      {
        name: 'static field reads a bound source identifier with its exact identity',
        source:
          'var seed = 41; class StaticReference { static value = seed; } console.log(StaticReference.value);',
        graph: 'retained',
        output: '41\n',
      },
      {
        name: 'static fields retain side-effect-free expressions with exact source references',
        source:
          'var seed = 41, delta = 2; class StaticExpressions { static sum = seed + delta; static selected = seed > 0 ? seed + 1 : 0; static logical = seed && delta; static negative = -delta; } console.log(StaticExpressions.sum, StaticExpressions.selected, StaticExpressions.logical, StaticExpressions.negative);',
        graph: 'retained',
        output: '43 42 2 -2\n',
      },
      {
        name: 'single bound optional static-member reads retain their graph and null short-circuit',
        source:
          'var reads = []; var holder = { get value() { reads.push("value"); return reads.length; } }; var missing = null; class OptionalStaticMemberRead { static present = holder?.value; static absent = missing?.value; } console.log(OptionalStaticMemberRead.present, OptionalStaticMemberRead.absent, reads.join(","));',
        graph: 'retained',
        output: '1 undefined value\n',
      },
      {
        name: 'bound deep static member reads retain getter order and receiver this',
        source:
          'var order = []; var holder = { get outer() { order.push("outer"); return { order, get value() { this.order.push("value"); return this.order.length; } }; } }; class StaticMemberReadField { static first = holder.outer.value; static second = holder.outer.value; } console.log(StaticMemberReadField.first, StaticMemberReadField.second, order.join(","));',
        graph: 'retained',
        output: '2 4 outer,value,outer,value\n',
      },
      {
        name: 'bound safe computed static member keys retain exact reads and getter order',
        source:
          'var order = []; var prefix = "va"; var suffix = "lue"; var holder = { get value() { order.push("value"); return order.length; } }; class ComputedStaticMemberReadField { static first = holder[prefix + suffix]; static second = holder["value"]; } console.log(ComputedStaticMemberReadField.first, ComputedStaticMemberReadField.second, order.join(","));',
        graph: 'retained',
        output: '1 2 value,value\n',
      },
      {
        name: 'whitespace-only minification keeps the exact graph for safe static fields',
        source:
          'var seed = 41; class WhitespaceOnly { static value = seed + 1; } console.log(WhitespaceOnly.value);',
        graph: 'retained',
        output: '42\n',
        minifyWhitespace: true,
      },
      {
        name: 'syntax minification still uses semantic reanalysis',
        source:
          'var seed = 41; class SyntaxMinified { static value = seed + 1; } console.log(SyntaxMinified.value);',
        graph: 'reanalyzed',
        output: '42\n',
        minifyWhitespace: true,
        minifySyntax: true,
      },
      {
        name: 'static field reads its exact class declaration binding',
        source:
          'class StaticSelf { static self = StaticSelf; } console.log(StaticSelf.self === StaticSelf);',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'static field reads its exact named class expression binding',
        source:
          'var StaticHolder = class StaticExpressionSelf { static self = StaticExpressionSelf; }; console.log(StaticHolder.self === StaticHolder);',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'static literal field and method preserve class self identity',
        source:
          'var Holder = class Inner { static value = 6; static self() { return Inner; } }; console.log(Holder.value, Holder.self() === Holder);',
        graph: 'retained',
        output: '6 true\n',
      },
      {
        name: 'instance fields stay on semantic reanalysis',
        source: 'class InstanceField { value = 9; } console.log(new InstanceField().value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'static __proto__ field stays on semantic reanalysis',
        source:
          'class ProtoStaticField { static __proto__ = 9; } console.log(Object.hasOwn(ProtoStaticField, "__proto__"), ProtoStaticField.__proto__);',
        graph: 'reanalyzed',
        output: 'true 9\n',
      },
      {
        name: 'unbound global initializer stays on semantic reanalysis',
        source:
          'globalThis.__zntcStaticFieldValue = 17; class GlobalStaticField { static value = __zntcStaticFieldValue; } console.log(GlobalStaticField.value);',
        graph: 'reanalyzed',
        output: '17\n',
      },
      {
        name: 'bound nested calls in computed static member keys retain exact graph and order',
        source:
          'var order = []; function makeKey() { order.push("make"); return "value"; } function fieldKey(key) { order.push("field"); return key; } var holder = { get value() { order.push("get"); return order.length; } }; class ComputedStaticMemberValueField { static first = holder[fieldKey(makeKey())]; static second = holder[fieldKey(makeKey())]; } console.log(ComputedStaticMemberValueField.first, ComputedStaticMemberValueField.second, order.join(","));',
        graph: 'retained',
        output: '3 6 make,field,get,make,field,get\n',
      },
      {
        name: 'bound computed static member calls retain exact graph, this and nested evaluation order',
        source:
          'var order = []; function makeInnerKey() { order.push("inner-key"); return "next"; } function fieldKey(key) { order.push("field-key"); return key; } function fieldArgument() { order.push("argument"); return 4; } var holder = { base: 3, next() { order.push("next"); return "value"; }, value(input) { order.push("value"); return this.base + input; } }; class ComputedStaticMemberCallField { static value = holder[fieldKey(holder[makeInnerKey()]())](fieldArgument()); } console.log(ComputedStaticMemberCallField.value, order.join(","));',
        graph: 'retained',
        output: '7 inner-key,next,field-key,argument,value\n',
      },
      {
        name: 'deeply nested computed static member calls use the iterative validator',
        source: `function makeKey() { return "method"; } function wrap(key) { return key; } var holder = { method() { return "method"; } }; class DeepComputedMemberCallField { static value = holder[${deeplyNestedComputedKey}](); } console.log(DeepComputedMemberCallField.value);`,
        graph: 'retained',
        output: 'method\n',
      },
      {
        name: 'bound computed member receiver chains retain getter order, method this and nested calls',
        source:
          'var order = []; function innerKey() { order.push("inner-key"); return "next"; } function outerKey(key) { order.push("outer-key"); return key; } function argument() { order.push("argument"); return 4; } var holder = { next() { order.push("next"); return "outer"; }, get outer() { order.push("outer-get"); return { base: 5, method(input) { order.push("method"); return this.base + input; } }; } }; class ComputedMemberReceiverChainField { static value = holder[outerKey(holder[innerKey()]())].method(argument()); } console.log(ComputedMemberReceiverChainField.value, order.join(","));',
        graph: 'retained',
        output: '9 inner-key,next,outer-key,outer-get,argument,method\n',
      },
      {
        name: 'unbound computed member receiver keys stay on semantic reanalysis',
        source:
          'globalThis.__zntcComputedReceiverKey = "outer"; var holder = { outer: { value: 9 } }; class UnboundComputedMemberReceiverField { static value = holder[__zntcComputedReceiverKey].value; } console.log(UnboundComputedMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound roots of computed member receiver chains stay on semantic reanalysis',
        source:
          'globalThis.__zntcComputedReceiverRoot = { outer: { value: 9 } }; var key = "outer"; class UnboundComputedMemberReceiverRootField { static value = __zntcComputedReceiverRoot[key].value; } console.log(UnboundComputedMemberReceiverRootField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound computed member receiver key calls stay on semantic reanalysis',
        source:
          'globalThis.__zntcComputedReceiverKeyFn = () => "outer"; var holder = { outer: { value: 9 } }; class UnboundComputedMemberReceiverCallField { static value = holder[__zntcComputedReceiverKeyFn()].value; } console.log(UnboundComputedMemberReceiverCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed member receiver with exact-bound key retains getter order',
        source:
          'var order = []; var key = "outer"; var holder = { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; class OptionalComputedMemberReceiverField { static value = holder?.[key].value; } console.log(OptionalComputedMemberReceiverField.value, order.join(","));',
        graph: 'retained',
        output: '9 outer,value\n',
      },
      {
        name: 'optional computed member receiver key calls stay on semantic reanalysis',
        source:
          'var key = () => "outer"; var holder = { outer: { value: 9 } }; class OptionalComputedMemberReceiverCallField { static value = holder[key?.()].value; } console.log(OptionalComputedMemberReceiverCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result computed member receiver stays on semantic reanalysis',
        source:
          'var key = "outer"; function makeHolder() { return { outer: { value: 9 } }; } class CallResultComputedMemberReceiverField { static value = makeHolder()[key].value; } console.log(CallResultComputedMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound computed static member call key stays on semantic reanalysis',
        source:
          'globalThis.__zntcComputedStaticCallKey = "value"; var holder = { value() { return 9; } }; class UnboundComputedStaticMemberCallField { static value = holder[__zntcComputedStaticCallKey](); } console.log(UnboundComputedStaticMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound computed static member call key function stays on semantic reanalysis',
        source:
          'globalThis.__zntcComputedStaticCallKeyFn = () => "value"; var holder = { value() { return 9; } }; class UnboundComputedStaticMemberCallKeyFunctionField { static value = holder[__zntcComputedStaticCallKeyFn()](); } console.log(UnboundComputedStaticMemberCallKeyFunctionField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static member call key function stays on semantic reanalysis',
        source:
          'var key = () => "value"; var holder = { value() { return 9; } }; class OptionalComputedStaticMemberCallKeyFunctionField { static value = holder[key?.()](); } console.log(OptionalComputedStaticMemberCallKeyFunctionField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static member call access stays on semantic reanalysis',
        source:
          'var key = "value"; var holder = { value() { return 9; } }; class OptionalComputedStaticMemberCallField { static value = holder?.[key](); } console.log(OptionalComputedStaticMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static member invocation stays on semantic reanalysis',
        source:
          'var key = "value"; var holder = { value() { return 9; } }; class OptionalComputedStaticMemberInvocationField { static value = holder[key]?.(); } console.log(OptionalComputedStaticMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result computed static member call receiver stays on semantic reanalysis',
        source:
          'var key = "value"; function makeHolder() { return { value() { return 9; } }; } class CallResultComputedStaticMemberCallField { static value = makeHolder()[key](); } console.log(CallResultComputedStaticMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound computed static member key call stays on semantic reanalysis',
        source:
          'globalThis.__zntcStaticMemberKeyFn = () => "value"; var holder = { value: 9 }; class UnboundComputedStaticMemberKeyCallField { static value = holder[__zntcStaticMemberKeyFn()]; } console.log(UnboundComputedStaticMemberKeyCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static member key call stays on semantic reanalysis',
        source:
          'var key = () => "value"; var holder = { value: 9 }; class OptionalComputedStaticMemberKeyCallField { static value = holder[key?.()]; } console.log(OptionalComputedStaticMemberKeyCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound computed static member key stays on semantic reanalysis',
        source:
          'globalThis.__zntcStaticMemberKey = "value"; var holder = { value: 9 }; class UnboundComputedStaticMemberValueField { static value = holder[__zntcStaticMemberKey]; } console.log(UnboundComputedStaticMemberValueField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static-member reads retain safe exact-bound key expressions',
        source:
          'var order = []; var key = { toString: function() { order.push("coerce"); return "value"; } }; var prefix = "va"; var suffix = "lue"; var holder = { get value() { order.push("get"); return 9; } }; var missing = null; class OptionalComputedStaticMemberValueField { static bound = holder?.[key]; static literal = holder?.["value"]; static expression = holder?.[prefix + suffix]; static absent = missing?.[key]; } console.log(OptionalComputedStaticMemberValueField.bound, OptionalComputedStaticMemberValueField.literal, OptionalComputedStaticMemberValueField.expression, OptionalComputedStaticMemberValueField.absent, order.join(","));',
        graph: 'retained',
        output: '9 9 9 undefined coerce,get,get,get\n',
      },
      {
        name: 'unbound optional computed static-member key stays on semantic reanalysis',
        source:
          'globalThis.__zntcOptionalComputedStaticKey = "value"; var holder = { value: 9 }; class UnboundOptionalComputedStaticMemberKey { static value = holder?.[__zntcOptionalComputedStaticKey]; } console.log(UnboundOptionalComputedStaticMemberKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static-member reads retain exact-bound call keys and skip them for null receivers',
        source:
          'var order = []; function makeOptionalStaticKey() { order.push("call"); return { toString: function() { order.push("coerce"); return "value"; } }; } var holder = { get value() { order.push("get"); return 9; } }; var missing = null; class OptionalComputedStaticMemberKeyCall { static present = holder?.[makeOptionalStaticKey()]; static absent = missing?.[makeOptionalStaticKey()]; } console.log(OptionalComputedStaticMemberKeyCall.present, OptionalComputedStaticMemberKeyCall.absent, order.join(","));',
        graph: 'retained',
        output: '9 undefined call,coerce,get\n',
      },
      {
        name: 'unbound optional computed static-member key call stays on semantic reanalysis',
        source:
          'globalThis.__zntcOptionalStaticMemberKeyFn = function() { return "value"; }; var holder = { value: 9 }; class UnboundOptionalComputedStaticMemberKeyCall { static value = holder?.[__zntcOptionalStaticMemberKeyFn()]; } console.log(UnboundOptionalComputedStaticMemberKeyCall.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional-call key stays on semantic reanalysis inside optional computed access',
        source:
          'var key = function() { return "value"; }; var holder = { value: 9 }; class OptionalCallComputedStaticMemberKey { static value = holder?.[key?.()]; } console.log(OptionalCallComputedStaticMemberKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result computed static member receiver stays on semantic reanalysis',
        source:
          'var key = "value"; function makeComputedStaticMemberHolder() { return { value: 9 }; } class CallResultComputedStaticMemberValueField { static value = makeComputedStaticMemberHolder()[key]; } console.log(CallResultComputedStaticMemberValueField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound optional static member value stays on semantic reanalysis',
        source:
          'globalThis.__zntcOptionalStaticReceiver = { value: 9 }; class UnboundOptionalStaticMemberValueField { static value = __zntcOptionalStaticReceiver?.value; } console.log(UnboundOptionalStaticMemberValueField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'nested bound optional static-member chains retain getter order and null short-circuit',
        source:
          'var order = []; var holder = { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; var missing = null; var empty = { get outer() { order.push("empty"); return null; } }; class NestedOptionalStaticMemberValueField { static first = holder?.outer?.value; static tail = holder?.outer.value; static missingRoot = missing?.outer?.value; static missingMiddle = empty?.outer?.value; } console.log(NestedOptionalStaticMemberValueField.first, NestedOptionalStaticMemberValueField.tail, NestedOptionalStaticMemberValueField.missingRoot, NestedOptionalStaticMemberValueField.missingMiddle, order.join(","));',
        graph: 'retained',
        output: '9 9 undefined undefined outer,value,outer,value,empty\n',
      },
      {
        name: 'unresolved static member receiver stays on semantic reanalysis',
        source:
          'globalThis.__zntcStaticMemberHolder = { value: 9 }; class UnresolvedStaticMemberValueField { static value = __zntcStaticMemberHolder.value; } console.log(UnresolvedStaticMemberValueField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result static member value stays on semantic reanalysis',
        source:
          'function makeStaticMemberHolder() { return { value: 9 }; } class CallResultStaticMemberValueField { static value = makeStaticMemberHolder().value; } console.log(CallResultStaticMemberValueField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'bound computed static field name identifiers retain their exact key temp graph',
        source:
          'var fieldName = "value"; class BoundComputedStaticFieldName { static [fieldName] = 7; } console.log(BoundComputedStaticFieldName.value);',
        graph: 'retained',
        output: '7\n',
      },
      {
        name: 'bound computed static field member-read keys retain getter receiver and order',
        source:
          'var order = []; var holder = { get first() { order.push(this === holder ? "first:true" : "first:false"); return "alpha"; }, get second() { order.push(this === holder ? "second:true" : "second:false"); return "beta"; } }; var fieldName = "second"; class ComputedStaticMemberReadKeys { static [holder.first] = 7; static [holder[fieldName]] = 8; } console.log(ComputedStaticMemberReadKeys.alpha, ComputedStaticMemberReadKeys.beta, order.join(","));',
        graph: 'retained',
        output: '7 8 first:true,second:true\n',
      },
      {
        name: 'bound computed static field names retain their exact key temp graph',
        source:
          'function fieldKey() { return "value"; } class ComputedStaticField { static [fieldKey()] = 9; } console.log(ComputedStaticField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'nested bound computed static field names retain key and initializer evaluation order',
        source:
          'var order = []; function baseKey() { order.push("base-key"); return "first"; } function fieldKey(key) { order.push("field-key"); return key; } function fieldValue(value) { order.push("field-value:" + value); return value; } class OrderedComputedStaticFields { static [fieldKey(baseKey())] = fieldValue(7); static [fieldKey("second")] = fieldValue(8); } console.log(OrderedComputedStaticFields.first, OrderedComputedStaticFields.second, order.join(","));',
        graph: 'retained',
        output: '7 8 base-key,field-key,field-key,field-value:7,field-value:8\n',
      },
      {
        name: 'unbound computed static field name reference stays on semantic reanalysis',
        source:
          'globalThis.__zntcComputedStaticFieldName = "value"; class UnboundComputedStaticFieldName { static [__zntcComputedStaticFieldName] = 9; } console.log(UnboundComputedStaticFieldName.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unbound computed static field name call stays on semantic reanalysis',
        source:
          'globalThis.__zntcComputedStaticFieldNameFn = () => "value"; class UnboundComputedStaticFieldNameCall { static [__zntcComputedStaticFieldNameFn()] = 9; } console.log(UnboundComputedStaticFieldNameCall.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static field name call stays on semantic reanalysis',
        source:
          'var fieldKey = () => "value"; class OptionalComputedStaticFieldNameCall { static [fieldKey?.()] = 9; } console.log(OptionalComputedStaticFieldNameCall.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'class-self references in computed static field keys stay on semantic reanalysis',
        source:
          'var SelfKey = class SelfKey { static [false && SelfKey] = 1; }; console.log(SelfKey.false);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'unbound receiver in computed static field member-read key stays on semantic reanalysis',
        source:
          'globalThis.__zntcComputedStaticFieldKeyHolder = { key: "value" }; class UnboundComputedStaticFieldMemberKey { static [__zntcComputedStaticFieldKeyHolder.key] = 9; } console.log(UnboundComputedStaticFieldMemberKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static field member-read key stays on semantic reanalysis',
        source:
          'var holder = { key: "value" }; class OptionalComputedStaticFieldMemberKey { static [holder?.key] = 9; } console.log(OptionalComputedStaticFieldMemberKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result receiver in computed static field member-read key stays on semantic reanalysis',
        source:
          'function makeHolder() { return { key: "value" }; } class CallResultComputedStaticFieldMemberKey { static [makeHolder().key] = 9; } console.log(CallResultComputedStaticFieldMemberKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'direct bound static initializer calls retain their graph and run once in order',
        source:
          'var calls = []; function fieldValue(input) { calls.push(input); return input + 1; } class DirectCallField { static first = fieldValue(8); static value = fieldValue(9); } console.log(DirectCallField.first, DirectCallField.value, calls.join(","));',
        graph: 'retained',
        output: '9 10 8,9\n',
      },
      {
        name: 'bound member-call static initializers retain receiver this and source order',
        source:
          'var receiver = { order: [], fieldValue(input) { this.order.push(input); return input + 1; } }; class MemberCallField { static first = receiver.fieldValue(8); static value = receiver.fieldValue(9); } console.log(MemberCallField.first, MemberCallField.value, receiver.order.join(","));',
        graph: 'retained',
        output: '9 10 8,9\n',
      },
      {
        name: 'bound computed member-call static field initializers retain their graph',
        source:
          'var receiver = { fieldValue(input) { return input + 1; } }; function fieldKey() { return "fieldValue"; } class ComputedMemberCallField { static value = receiver[fieldKey()](8); } console.log(ComputedMemberCallField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'optional member-call static field initializers stay on semantic reanalysis',
        source:
          'var receiver = { fieldValue(input) { return input + 1; } }; class OptionalMemberCallField { static value = receiver?.fieldValue(8); } console.log(OptionalMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional member-call invocation static field initializers stay on semantic reanalysis',
        source:
          'var receiver = { fieldValue(input) { return input + 1; } }; class OptionalCallMemberCallField { static value = receiver.fieldValue?.(8); } console.log(OptionalCallMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved member receiver static field initializers stay on semantic reanalysis',
        source:
          'globalThis.__zntcFieldReceiver = { fieldValue(input) { return input + 1; } }; class ExternalReceiverMemberCallField { static value = __zntcFieldReceiver.fieldValue(8); } console.log(ExternalReceiverMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'one level of bound nested member receiver retains getter order and method this',
        source:
          'var order = []; var holder = { get receiver() { order.push("receiver"); return { order, fieldValue(input) { this.order.push("method:" + input); return input + 1; } }; } }; class NestedMemberReceiverField { static first = holder.receiver.fieldValue(8); static value = holder.receiver.fieldValue(9); } console.log(NestedMemberReceiverField.first, NestedMemberReceiverField.value, order.join(","));',
        graph: 'retained',
        output: '9 10 receiver,method:8,receiver,method:9\n',
      },
      {
        name: 'deep bound static member receiver chains retain getter order and method this',
        source:
          'var order = []; var holder = { get outer() { order.push("outer"); return { get receiver() { order.push("receiver"); return { order, fieldValue(input) { this.order.push("method:" + input); return input + 1; } }; } }; } }; class DeepMemberReceiverField { static first = holder.outer.receiver.fieldValue(8); static value = holder.outer.receiver.fieldValue(9); } console.log(DeepMemberReceiverField.first, DeepMemberReceiverField.value, order.join(","));',
        graph: 'retained',
        output: '9 10 outer,receiver,method:8,outer,receiver,method:9\n',
      },
      {
        name: 'bound computed nested member receiver static fields retain their graph',
        source:
          'var holder = { receiver: { fieldValue(input) { return input + 1; } } }; function receiverKey() { return "receiver"; } class ComputedNestedMemberReceiverField { static value = holder[receiverKey()].fieldValue(8); } console.log(ComputedNestedMemberReceiverField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'optional nested member receiver static fields stay on semantic reanalysis',
        source:
          'var holder = { receiver: { fieldValue(input) { return input + 1; } } }; class OptionalNestedMemberReceiverField { static value = holder?.receiver.fieldValue(8); } console.log(OptionalNestedMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved nested member receiver static fields stay on semantic reanalysis',
        source:
          'globalThis.__zntcNestedFieldHolder = { receiver: { fieldValue(input) { return input + 1; } } }; class UnresolvedNestedMemberReceiverField { static value = __zntcNestedFieldHolder.receiver.fieldValue(8); } console.log(UnresolvedNestedMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result deep member receiver static fields stay on semantic reanalysis',
        source:
          'function getFieldHolder() { return { outer: { receiver: { fieldValue(input) { return input + 1; } } } }; } class CallResultDeepMemberReceiverField { static value = getFieldHolder().outer.receiver.fieldValue(8); } console.log(CallResultDeepMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'bound computed deep member receiver static fields retain their graph',
        source:
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } }; function receiverKey() { return "receiver"; } class ComputedDeepMemberReceiverField { static value = holder.outer[receiverKey()].fieldValue(8); } console.log(ComputedDeepMemberReceiverField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'optional deep member receiver static fields stay on semantic reanalysis',
        source:
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } }; class OptionalDeepMemberReceiverField { static value = holder.outer?.receiver.fieldValue(8); } console.log(OptionalDeepMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved deep member receiver static fields stay on semantic reanalysis',
        source:
          'globalThis.__zntcDeepFieldHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } }; class UnresolvedDeepMemberReceiverField { static value = __zntcDeepFieldHolder.outer.receiver.fieldValue(8); } console.log(UnresolvedDeepMemberReceiverField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result member receiver static field initializers stay on semantic reanalysis',
        source:
          'function getFieldReceiver() { return { fieldValue(input) { return input + 1; } }; } class NestedReceiverMemberCallField { static value = getFieldReceiver().fieldValue(8); } console.log(NestedReceiverMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved direct static initializer calls stay on semantic reanalysis',
        source:
          'globalThis.__zntcUnresolvedFieldCall = function (input) { return input + 1; }; class UnresolvedCallField { static value = __zntcUnresolvedFieldCall(8); } console.log(UnresolvedCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'one level of bound nested static-field calls retains graph and evaluation order',
        source:
          'var order = []; function fieldArgument(input) { order.push("arg:" + input); return input + 1; } function fieldValue(input) { order.push("field:" + input); return input + 1; } var receiver = { order, fieldValue(input) { this.order.push("member:" + input); return input + 1; } }; class NestedCallField { static first = fieldValue(fieldArgument(8)); static second = receiver.fieldValue(fieldArgument(10)); } console.log(NestedCallField.first, NestedCallField.second, order.join(","));',
        graph: 'retained',
        output: '10 12 arg:8,field:9,arg:10,member:11\n',
      },
      {
        name: 'unresolved nested static-field call arguments stay on semantic reanalysis',
        source:
          'globalThis.__zntcNestedFieldArgument = function (input) { return input + 1; }; function fieldValue(input) { return input + 1; } class UnresolvedNestedCallField { static value = fieldValue(__zntcNestedFieldArgument(8)); } console.log(UnresolvedNestedCallField.value);',
        graph: 'reanalyzed',
        output: '10\n',
      },
      {
        name: 'optional nested static-field call arguments stay on semantic reanalysis',
        source:
          'function fieldArgument(input) { return input + 1; } function fieldValue(input) { return input + 1; } class OptionalNestedCallField { static value = fieldValue(fieldArgument?.(8)); } console.log(OptionalNestedCallField.value);',
        graph: 'reanalyzed',
        output: '10\n',
      },
      {
        name: 'bound computed member calls in static-field arguments retain their graph',
        source:
          'var receiver = { fieldArgument(input) { return input + 1; } }; function fieldValue(input) { return input + 1; } class ComputedNestedCallField { static value = fieldValue(receiver["fieldArgument"](8)); } console.log(ComputedNestedCallField.value);',
        graph: 'retained',
        output: '10\n',
      },
      {
        name: 'deep bound nested static-field calls retain evaluation order and member this',
        source:
          'var order = []; function inner(input) { order.push("inner:" + input); return input + 1; } function middle(input) { order.push("middle:" + input); return input + 1; } function fieldValue(input) { order.push("field:" + input); return input + 1; } var receiver = { order, fieldValue(input) { this.order.push("member:" + input); return input + 1; } }; class DeepNestedCallField { static first = fieldValue(inner(middle(8))); static second = receiver.fieldValue(inner(middle(10))); } console.log(DeepNestedCallField.first, DeepNestedCallField.second, order.join(","));',
        graph: 'retained',
        output: '11 13 middle:8,inner:9,field:10,middle:10,inner:11,member:12\n',
      },
      {
        name: 'deep unresolved static-field call arguments stay on semantic reanalysis',
        source:
          'globalThis.__zntcDeepFieldArgument = function (input) { return input + 1; }; function inner(input) { return input + 1; } function fieldValue(input) { return input + 1; } class DeepUnresolvedCallField { static value = fieldValue(inner(__zntcDeepFieldArgument(8))); } console.log(DeepUnresolvedCallField.value);',
        graph: 'reanalyzed',
        output: '11\n',
      },
      {
        name: 'deep optional static-field call arguments stay on semantic reanalysis',
        source:
          'function inner(input) { return input + 1; } function fieldArgument(input) { return input + 1; } function fieldValue(input) { return input + 1; } class DeepOptionalCallField { static value = fieldValue(inner(fieldArgument?.(8))); } console.log(DeepOptionalCallField.value);',
        graph: 'reanalyzed',
        output: '11\n',
      },
      {
        name: 'deep bound computed member calls in static-field arguments retain their graph',
        source:
          'var receiver = { fieldArgument(input) { return input + 1; } }; function inner(input) { return input + 1; } function fieldValue(input) { return input + 1; } class DeepComputedCallField { static value = fieldValue(inner(receiver["fieldArgument"](8))); } console.log(DeepComputedCallField.value);',
        graph: 'retained',
        output: '11\n',
      },
      {
        name: 'optional direct static initializer calls stay on semantic reanalysis',
        source:
          'function fieldValue(input) { return input + 1; } class OptionalCallField { static value = fieldValue?.(8); } console.log(OptionalCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'escaped direct eval in a static initializer stays on semantic reanalysis',
        source:
          'class DirectEvalField { static value = e\\u0076al("1 + 2"); } console.log(DirectEvalField.value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'static field this initializers stay on semantic reanalysis',
        source:
          'class StaticThisField { static value = this; } console.log(StaticThisField.value === StaticThisField);',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'source Object bindings remain separate from generated class-field globals',
        source:
          'var Object = { defineProperty() { throw new Error("captured generated global"); } }; class ShadowedStaticField { static value = 9; } console.log(ShadowedStaticField.value);',
        graph: 'reanalyzed',
        output: '9\n',
        shadowedExternal: true,
      },
      {
        name: 'named class expression in a top-level var initializer retains exact inner identity',
        source:
          'var prefix = 2, Holder = class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }; var instance = new Holder(9); console.log(prefix, Holder.length, instance.value, Holder.self() === Holder);',
        graph: 'retained',
        output: '2 1 9 true\n',
      },
      {
        name: 'named class expression literal constructor defaults retain exact inner identity',
        source:
          'var ExpressionHolder = class ExpressionInner { constructor(value = "expr") { this.value = value; } self() { return ExpressionInner; } }; var expressionDefault = new ExpressionHolder(); var expressionProvided = new ExpressionHolder("passed"); console.log(expressionDefault.value, expressionProvided.value, expressionDefault.self() === ExpressionHolder);',
        graph: 'retained',
        output: 'expr passed true\n',
      },
      {
        name: 'one plain instance method',
        source:
          'class WithMethod { value(n) { return this.base + n; } }\nvar instance = new WithMethod(); instance.base = 2; console.log(instance.value(7));\n',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'method reads its class binding',
        source:
          'class Self { self() { return Self; } }\nconsole.log(new Self().self() === Self);\n',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'multiple instance methods',
        source:
          'class Pair { first(n) { return Pair.base + this.second(n); } second(n) { return n + 1; } }\nPair.base = 2; console.log(new Pair().first(2));\n',
        graph: 'retained',
        output: '5\n',
      },
      {
        name: 'single instance getter',
        source:
          'class Getter { get value() { return this.offset; } } var getter = new Getter(); getter.offset = 9; console.log(getter.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'single instance setter',
        source:
          'class Setter { set value(n) { this.offset = n; } } var setter = new Setter(); setter.value = 9; console.log(setter.offset);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'single static method',
        source:
          'class Static { static value(n) { return Static.base + this.offset + n; } }\nStatic.base = 2; console.log(Static.value.call({ offset: 3 }, 4));\n',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'static method after an ordinary method',
        source:
          'class Mixed { instance() { return 1; } static value(n) { return Mixed.base + this.offset + n; } } Mixed.base = 2; console.log(new Mixed().instance() + Mixed.value.call({ offset: 3 }, 4));',
        graph: 'retained',
        output: '10\n',
      },
      {
        name: 'single static getter',
        source:
          'class StaticGetter { static get value() { return StaticGetter.base + this.offset; } } StaticGetter.base = 2; StaticGetter.offset = 7; console.log(StaticGetter.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'single static setter',
        source:
          'class StaticSetter { static set value(n) { StaticSetter.stored = n; } } StaticSetter.value = 9; console.log(StaticSetter.stored);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'static method with a source Object binding',
        source:
          'var Object = globalThis.Object; class Shadowed { static value() { return 9; } } console.log(Shadowed.value());',
        graph: 'reanalyzed',
        output: '9\n',
        // The generated Object.defineProperty reference is explicitly global.
        shadowedExternal: true,
      },
      {
        name: 'trailing static accessor after an ordinary method',
        source:
          'class Accessor { instance() { return 1; } static get value() { return 9; } } console.log(Accessor.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'paired instance accessors',
        source:
          'class Pair { get value() { return Pair.stored; } set value(n) { Pair.stored = n; } } var pair = new Pair(); pair.value = 9; console.log(pair.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'paired static accessors in setter-first order',
        source:
          'class StaticPair { static set value(n) { StaticPair.stored = n; } static get value() { return StaticPair.stored; } } StaticPair.value = 9; console.log(StaticPair.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'ordinary methods followed by a compatible accessor pair',
        source:
          'class Combined { first(n) { return n + this.second(); } second() { return 1; } get value() { return Combined.stored; } set value(n) { Combined.stored = n; } } var combined = new Combined(); combined.value = 8; console.log(combined.first(2), combined.value);',
        graph: 'retained',
        output: '3 8\n',
      },
      {
        name: 'method after an accessor keeps source order on reanalysis',
        source:
          'class Reordered { get value() { return 7; } method() { return 9; } } var reordered = new Reordered(); console.log(reordered.value, reordered.method());',
        graph: 'reanalyzed',
        output: '7 9\n',
      },
      {
        name: 'method and accessor with the same key keep duplicate order on reanalysis',
        source:
          'class DuplicateKey { value() { return 7; } get value() { return 9; } } console.log(new DuplicateKey().value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'duplicate getter methods',
        source:
          'class Duplicate { get value() { return 7; } get value() { return 9; } } console.log(new Duplicate().value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'more than one accessor pair member of a kind keeps reanalysis',
        source:
          'class Triple { get value() { return 1; } set value(n) { this.stored = n; } set value(n) { this.stored = n + 1; } } var triple = new Triple(); triple.value = 4; console.log(triple.value, triple.stored);',
        graph: 'reanalyzed',
        output: '1 5\n',
      },
      {
        name: 'getter/setter keys differ',
        source:
          'class Different { get value() { return 7; } set other(n) {} } console.log(new Different().value);',
        graph: 'reanalyzed',
        output: '7\n',
      },
      {
        name: 'getter/setter staticness differs',
        source:
          'class MixedAccessor { get value() { return 7; } static set value(n) {} } console.log(new MixedAccessor().value);',
        graph: 'reanalyzed',
        output: '7\n',
      },
      {
        name: 'explicit constructor',
        source:
          'class Explicit { constructor() {} }\nvar explicit = new Explicit(); try { Explicit(); } catch (error) { console.log(explicit instanceof Explicit, explicit.constructor === Explicit, error instanceof TypeError); }\n',
        graph: 'retained',
        output: 'true true true\n',
      },
      {
        name: 'constructor primitive literal defaults retain their graph',
        source:
          'class LiteralDefaults { constructor(number = 3, enabled = true, empty = null, label = "ready") { this.number = number; this.enabled = enabled; this.empty = empty; this.label = label; } } var defaults = new LiteralDefaults(); var provided = new LiteralDefaults(8, false, null, "custom"); console.log(defaults.number, provided.number, defaults.enabled, provided.enabled, defaults.empty === null, defaults.label, provided.label);',
        graph: 'retained',
        output: '3 8 true false true ready custom\n',
      },
      {
        name: 'constructor defaults read earlier parameters with exact identity across a body var shadow',
        source:
          'class EarlierDefault { constructor(first = 2, second = first + 1) { var first = 100; this.defaulted = second; this.bodyVar = first; } } var omitted = new EarlierDefault(); var supplied = new EarlierDefault(5); console.log(omitted.defaulted, omitted.bodyVar, supplied.defaulted, supplied.bodyVar);',
        graph: 'retained',
        output: '3 100 6 100\n',
      },
      {
        name: 'constructor chained defaults read the preceding parameter values',
        source:
          'class ChainedDefaults { constructor(first = 2, second = first * 3, third = second + 1) { this.first = first; this.second = second; this.third = third; } } var defaults = new ChainedDefaults(); var supplied = new ChainedDefaults(4, undefined, 20); console.log(defaults.first, defaults.second, defaults.third, supplied.first, supplied.second, supplied.third);',
        graph: 'retained',
        output: '2 6 7 4 12 20\n',
      },
      {
        name: 'constructor parameter TDZ default stays on reanalysis',
        source:
          'class TdzDefaulted { constructor(first, value = later, later = 4) { this.value = value; } } try { new TdzDefaulted(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor self-referencing parameter default stays on reanalysis',
        source:
          'class SelfTdzDefaulted { constructor(first, value = value + 1) { this.value = value; } } try { new SelfTdzDefaulted(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor default bound outside the parameter list stays on reanalysis',
        source:
          'var outside = 4; class OutsideDefault { constructor(first, value = outside) { this.value = value; } } console.log(new OutsideDefault().value);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'constructor call default stays on reanalysis',
        source:
          'function getDefault() { return 4; } class CalledDefault { constructor(value = getDefault()) { this.value = value; } } console.log(new CalledDefault().value);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'constructor destructured literal default stays on reanalysis',
        source:
          'class DestructuredDefaulted { constructor({ value } = { value: 4 }) { this.value = value; } } console.log(new DestructuredDefaulted().value);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'constructor with a simple literal assignment retains its graph',
        source:
          'class WithConstructorBody { constructor() { this.value = 7; } } console.log(new WithConstructorBody().value);',
        graph: 'retained',
        output: '7\n',
      },
      {
        name: 'constructor debugger statement retains its graph',
        source:
          'class ConstructorDebugger { constructor() { debugger; this.value = 1; } } console.log(new ConstructorDebugger().value);',
        graph: 'retained',
        output: '1\n',
      },
      {
        name: 'constructor parameter and reference keep their exact identity',
        source:
          'class Parameterized { constructor(value) { this.value = value; } } console.log(Parameterized.length, new Parameterized(8).value);',
        graph: 'retained',
        output: '1 8\n',
      },
      {
        name: 'empty constructor preserves its simple parameter and function length',
        source:
          'class EmptyParameterized { constructor(value) {} } console.log(EmptyParameterized.length, new EmptyParameterized(1) instanceof EmptyParameterized);',
        graph: 'retained',
        output: '1 true\n',
      },
      {
        name: 'multiple simple constructor parameters retain their references',
        source:
          'class TwoParameters { constructor(first, second) { this.first = first; this.second = second; } } var twoParameters = new TwoParameters(3, 4); console.log(TwoParameters.length, twoParameters.first, twoParameters.second);',
        graph: 'retained',
        output: '2 3 4\n',
      },
      {
        name: 'constructor var locals retain exact bindings and references',
        source:
          'class LocalBindings { constructor(input) { var first = input, second = first; this.value = second; } } console.log(new LocalBindings(9).value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'constructor uninitialized var local retains its undefined binding',
        source:
          'class UninitializedLocal { constructor() { var value; this.value = value; } } console.log(new UninitializedLocal().value);',
        graph: 'retained',
        output: 'undefined\n',
      },
      {
        name: 'constructor var arithmetic locals retain exact bindings and references',
        source:
          'class ArithmeticLocals { constructor(input) { var twice = input * 2; var result = twice + 1; this.value = result; } } console.log(new ArithmeticLocals(4).value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'constructor var unary values retain exact bindings and references',
        source:
          'class UnaryValues { constructor(input, flag) { var negative = -input; var positive = +input; var inverted = !flag; var complemented = ~input; this.negative = negative; this.positive = positive; this.inverted = inverted; this.complemented = complemented; } } var unaryValues = new UnaryValues(4, false); console.log(unaryValues.negative, unaryValues.positive, unaryValues.inverted, unaryValues.complemented);',
        graph: 'retained',
        output: '-4 4 true -5\n',
      },
      {
        name: 'constructor conditional and short-circuit values retain exact references',
        source:
          'class BranchingValues { constructor(input, flag) { var selected = input > 0 ? input : 0; var shortValue = flag && selected; this.selected = selected; this.shortValue = shortValue; } } var positiveBranch = new BranchingValues(4, true); var negativeBranch = new BranchingValues(-4, false); console.log(positiveBranch.selected, positiveBranch.shortValue, negativeBranch.selected, negativeBranch.shortValue);',
        graph: 'retained',
        output: '4 4 0 false\n',
      },
      {
        name: 'constructor safe if and block branches retain exact local writes',
        source:
          'class ConstructorBranches { constructor(input, flag) { if (input > 0) { var result = input + 1; this.value = result; } else if (flag) this.value = -input; else { ; this.value = 10; } } } console.log(new ConstructorBranches(3, false).value, new ConstructorBranches(-3, true).value, new ConstructorBranches(0, false).value);',
        graph: 'retained',
        output: '4 3 10\n',
      },
      {
        name: 'constructor safe returns preserve base new return semantics',
        source:
          'class ConstructorReturnsValue { constructor(value, mode) { this.ownValue = 7; if (mode === 1) return value; if (mode === 2) return; return 4; } } var replacement = { name: "replacement" }; var returnedObject = new ConstructorReturnsValue(replacement, 1); var returnedBare = new ConstructorReturnsValue(replacement, 2); var returnedPrimitive = new ConstructorReturnsValue(replacement, 0); console.log(returnedObject === replacement, returnedObject.name, returnedBare instanceof ConstructorReturnsValue, returnedBare.ownValue, returnedPrimitive instanceof ConstructorReturnsValue, returnedPrimitive.ownValue);',
        graph: 'retained',
        output: 'true replacement true 7 true 7\n',
      },
      {
        name: 'constructor exact throw preserves the thrown value identity',
        source:
          'class ConstructorThrow { constructor(value, shouldThrow) { if (shouldThrow) throw value; this.value = 3; } } var marker = { kind: "marker" }; try { new ConstructorThrow(marker, true); } catch (error) { console.log(error === marker); } console.log(new ConstructorThrow(marker, false).value);',
        graph: 'retained',
        output: 'true\n3\n',
      },
      {
        name: 'constructor safe while loop retains exact local writes and condition references',
        source:
          'class ConstructorWhile { constructor(limit) { var index = 0; while (index < limit) { this.value = index; index++; } } } console.log(new ConstructorWhile(3).value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'constructor safe do-while runs the body before checking its condition',
        source:
          'class ConstructorDoWhile { constructor(limit) { var index = 0; do { this.value = index; index++; } while (index < limit); } } console.log(new ConstructorDoWhile(3).value, new ConstructorDoWhile(0).value);',
        graph: 'retained',
        output: '2 0\n',
      },
      {
        name: 'constructor safe for loop keeps its exact var head and references',
        source:
          'class ConstructorFor { constructor(limit) { for (var index = 0; index < limit; index++) this.value = index; } } console.log(new ConstructorFor(3).value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'constructor safe for loop accepts exact assignment clauses',
        source:
          'class ConstructorForAssignments { constructor(limit) { var index; for (index = 0; index < limit; index += 1) this.value = index; } } console.log(new ConstructorForAssignments(3).value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'constructor safe while loop preserves unlabeled break',
        source:
          'class ConstructorWhileBreak { constructor() { var index = 0; while (index < 5) { this.value = index; if (index === 2) break; index++; } } } console.log(new ConstructorWhileBreak().value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'constructor safe for loop preserves unlabeled continue',
        source:
          'class ConstructorForContinue { constructor() { for (var index = 0; index < 4; index++) { if (index === 2) continue; this.value = index; } } } console.log(new ConstructorForContinue().value);',
        graph: 'retained',
        output: '3\n',
      },
      {
        name: 'constructor safe labeled loop preserves labeled break',
        source:
          'class ConstructorLabeledBreak { constructor(target) { target: while (true) { this.value = target; break target; } } } console.log(new ConstructorLabeledBreak(4).value);',
        graph: 'retained',
        output: '4\n',
      },
      {
        name: 'constructor safe labeled loop preserves labeled continue',
        source:
          'class ConstructorLabeledContinue { constructor() { target: for (var index = 0; index < 4; index++) { if (index === 1) continue target; this.value = index; } } } console.log(new ConstructorLabeledContinue().value);',
        graph: 'retained',
        output: '3\n',
      },
      {
        name: 'constructor nested safe labels preserve an outer labeled break',
        source:
          'class ConstructorNestedLabels { constructor() { outer: inner: { this.value = 5; break outer; } } } console.log(new ConstructorNestedLabels().value);',
        graph: 'retained',
        output: '5\n',
      },
      {
        name: 'constructor safe switch preserves exact case references and fallthrough',
        source:
          'class ConstructorSwitch { constructor(input, selector) { switch (input) { case selector: this.value = 1; break; case 2: this.value = 2; case 3: this.extra = 3; break; default: this.value = 4; } } } var switchFirst = new ConstructorSwitch(1, 1); var switchFallthrough = new ConstructorSwitch(2, 9); var switchDefault = new ConstructorSwitch(8, 9); console.log(switchFirst.value, switchFallthrough.value, switchFallthrough.extra, switchDefault.value);',
        graph: 'retained',
        output: '1 2 3 4\n',
      },
      {
        name: 'constructor safe try catch finally keeps the exact catch binding',
        source:
          'class ConstructorTryCatchFinally { constructor(input) { try { if (input) throw input; this.value = 1; } catch (error) { this.value = error; } finally { this.finalized = true; } } } var caughtConstructor = new ConstructorTryCatchFinally(7); var normalConstructor = new ConstructorTryCatchFinally(0); console.log(caughtConstructor.value, caughtConstructor.finalized, normalConstructor.value, normalConstructor.finalized);',
        graph: 'retained',
        output: '7 true 1 true\n',
      },
      {
        name: 'constructor optional catch binding retains its exact graph',
        source:
          'class ConstructorOptionalCatch { constructor() { try { throw 2; } catch { this.caught = true; } } } console.log(new ConstructorOptionalCatch().caught);',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'constructor local plus assignment retains exact references',
        source:
          'class LocalPlusAssignment { constructor(input) { var value = input; value += 1; this.value = value; } } console.log(new LocalPlusAssignment(3).value);',
        graph: 'retained',
        output: '4\n',
      },
      {
        name: 'constructor ES5-native compound assignments retain exact references',
        source:
          'class LocalNativeCompounds { constructor(input) { var value = input; value *= 2; value /= 2; value %= 5; value <<= 1; value >>= 1; value >>>= 1; value |= 2; value &= 7; value ^= 1; this.value = value; } } console.log(new LocalNativeCompounds(3).value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'constructor native this-property compounds and updates preserve accessor effects',
        source:
          'class NativePropertyWrites { constructor(input) { this.reads = 0; this.writes = 0; this.backing = input; this.value += 1; this.value -= 1; this.value *= 2; this.value /= 2; this.value %= 4; this.value <<= 1; this.value >>= 1; this.value >>>= 1; this.value |= 2; this.value &= 7; this.value ^= 1; this.value++; ++this.value; } get value() { this.reads++; return this.backing; } set value(next) { this.writes++; this.backing = next; } } var nativePropertyWrites = new NativePropertyWrites(3); console.log(nativePropertyWrites.reads, nativePropertyWrites.writes, nativePropertyWrites.backing);',
        graph: 'retained',
        output: '13 13 4\n',
      },
      {
        name: 'constructor local postfix update retains its reference',
        source:
          'class LocalPostfixUpdate { constructor(input) { var value = input; value++; this.value = value; } } console.log(new LocalPostfixUpdate(3).value);',
        graph: 'retained',
        output: '4\n',
      },
      {
        name: 'constructor local prefix update retains its reference',
        source:
          'class LocalPrefixUpdate { constructor(input) { var value = input; --value; this.value = value; } } console.log(new LocalPrefixUpdate(3).value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'constructor let local stays on reanalysis',
        source:
          'class LexicalLocal { constructor() { let value = 6; this.value = value; } } console.log(new LexicalLocal().value);',
        graph: 'reanalyzed',
        output: '6\n',
      },
      {
        name: 'constructor const local stays on reanalysis',
        source:
          'class ConstantLocal { constructor() { const value = 6; this.value = value; } } console.log(new ConstantLocal().value);',
        graph: 'reanalyzed',
        output: '6\n',
      },
      {
        name: 'constructor destructuring var local stays on reanalysis',
        source:
          'var sourceValue = { value: 6 }; class DestructuredLocal { constructor() { var { value } = sourceValue; this.value = value; } } console.log(new DestructuredLocal().value);',
        graph: 'reanalyzed',
        output: '6\n',
      },
      {
        name: 'constructor var call initializer stays on reanalysis',
        source:
          'function readValue() { return 6; } class CalledLocal { constructor() { var value = readValue(); this.value = value; } } console.log(new CalledLocal().value);',
        graph: 'reanalyzed',
        output: '6\n',
      },
      {
        name: 'constructor var call inside binary initializer stays on reanalysis',
        source:
          'function readValue() { return 6; } class CalledBinaryLocal { constructor() { var value = readValue() + 1; this.value = value; } } console.log(new CalledBinaryLocal().value);',
        graph: 'reanalyzed',
        output: '7\n',
      },
      {
        name: 'constructor var exponentiation initializer stays on reanalysis',
        source:
          'class ExponentLocal { constructor(input) { var value = input ** 2; this.value = value; } } console.log(new ExponentLocal(3).value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved constructor binary reference stays on reanalysis',
        source:
          'class UnresolvedBinaryLocal { constructor() { var value = unboundBinaryValue + 1; this.value = value; } } console.log(typeof UnresolvedBinaryLocal);',
        graph: 'reanalyzed',
        output: 'function\n',
      },
      {
        name: 'unresolved constructor unary reference stays on reanalysis',
        source:
          'class UnresolvedUnaryLocal { constructor() { var value = -unboundUnaryValue; this.value = value; } } console.log(typeof UnresolvedUnaryLocal);',
        graph: 'reanalyzed',
        output: 'function\n',
      },
      {
        name: 'constructor typeof initializer stays on reanalysis',
        source:
          'class TypeofLocal { constructor(input) { var value = typeof input; this.value = value; } } console.log(new TypeofLocal(3).value);',
        graph: 'reanalyzed',
        output: 'number\n',
      },
      {
        name: 'constructor delete initializer stays on reanalysis',
        source:
          'class DeleteLocal { constructor() { var removed = delete this.value; this.removed = removed; } } console.log(new DeleteLocal().removed);',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor call inside conditional initializer stays on reanalysis',
        source:
          'function readCondition() { return 1; } class CalledConditionalLocal { constructor() { var value = readCondition() > 0 ? 1 : 0; this.value = value; } } console.log(new CalledConditionalLocal().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor unresolved if condition stays on reanalysis',
        source:
          'class UnresolvedIfCondition { constructor() { if (missingConstructorCondition) this.value = 1; } } try { new UnresolvedIfCondition(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor call in if condition stays on reanalysis',
        source:
          'function shouldWrite() { return true; } class CalledIfCondition { constructor() { if (shouldWrite()) this.value = 1; } } console.log(new CalledIfCondition().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor call in while condition stays on reanalysis',
        source:
          'function shouldContinue() { return false; } class CalledWhileCondition { constructor() { while (shouldContinue()) this.value = 1; } } console.log(typeof new CalledWhileCondition().value);',
        graph: 'reanalyzed',
        output: 'undefined\n',
      },
      {
        name: 'constructor unresolved do-while condition stays on reanalysis',
        source:
          'class UnresolvedDoWhileCondition { constructor() { do { this.value = 1; } while (missingDoWhileCondition); } } try { new UnresolvedDoWhileCondition(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor while loop with unlabeled break retains its graph',
        source:
          'class ConstructorBreak { constructor() { while (true) { this.value = 1; break; } } } console.log(new ConstructorBreak().value);',
        graph: 'retained',
        output: '1\n',
      },
      {
        name: 'constructor call in for condition stays on reanalysis',
        source:
          'function shouldContinueFor() { return false; } class CalledForCondition { constructor() { for (; shouldContinueFor();) this.value = 1; } } console.log(typeof new CalledForCondition().value);',
        graph: 'reanalyzed',
        output: 'undefined\n',
      },
      {
        name: 'constructor call in for initializer stays on reanalysis',
        source:
          'function startForIndex() { return 0; } class CalledForInitializer { constructor() { for (var index = startForIndex(); index < 1; index++) this.value = index; } } console.log(new CalledForInitializer().value);',
        graph: 'reanalyzed',
        output: '0\n',
      },
      {
        name: 'constructor call in for update stays on reanalysis',
        source:
          'var forUpdateCount = 0; function advanceForIndex() { forUpdateCount++; } class CalledForUpdate { constructor() { for (; forUpdateCount < 1; advanceForIndex()) this.value = forUpdateCount; } } console.log(new CalledForUpdate().value);',
        graph: 'reanalyzed',
        output: '0\n',
      },
      {
        name: 'constructor for loop with unlabeled break retains its graph',
        source:
          'class ConstructorForBreak { constructor() { for (var index = 0; index < 1; index++) { this.value = index; break; } } } console.log(new ConstructorForBreak().value);',
        graph: 'retained',
        output: '0\n',
      },
      {
        name: 'constructor safe for-in var head retains exact loop references',
        source:
          'class ConstructorForInVar { constructor(values) { for (var key in values) this.value = key; } } console.log(new ConstructorForInVar({ safe: 1 }).value);',
        graph: 'retained',
        output: 'safe\n',
      },
      {
        name: 'constructor safe for-in source assignment head retains its graph',
        source:
          'class ConstructorForInAssignment { constructor(values) { var key; for (key in values) this.value = key; } } console.log(new ConstructorForInAssignment({ safe: 1 }).value);',
        graph: 'retained',
        output: 'safe\n',
      },
      {
        name: 'constructor safe for-of var head retains helper and loop identities',
        source:
          'class ConstructorForOfVar { constructor(values) { for (var value of values) this.value = value; } } console.log(new ConstructorForOfVar([4, 7]).value);',
        graph: 'retained',
        output: '7\n',
      },
      {
        name: 'constructor safe labeled for-of continue updates a source parameter',
        source:
          'class ConstructorForOfAssignment { constructor(values, value) { outer: for (value of values) { if (value === 2) continue outer; this.value = value; } } } console.log(new ConstructorForOfAssignment([2, 4], 0).value);',
        graph: 'retained',
        output: '4\n',
      },
      {
        name: 'constructor simple lexical for head retains its graph',
        source:
          'class LexicalForHead { constructor() { for (let index = 0; index < 1; index++) this.value = index; } } console.log(new LexicalForHead().value);',
        graph: 'retained',
        output: '0\n',
      },
      {
        name: 'constructor lexical for-of head stays on reanalysis',
        source:
          'class LexicalConstructorForOf { constructor(values) { for (let value of values) this.value = value; } } console.log(new LexicalConstructorForOf([4, 7]).value);',
        graph: 'reanalyzed',
        output: '7\n',
      },
      {
        name: 'constructor lexical for-in head stays on reanalysis',
        source:
          'class LexicalConstructorForIn { constructor(values) { for (const key in values) this.value = key; } } console.log(new LexicalConstructorForIn({ safe: 1 }).value);',
        graph: 'reanalyzed',
        output: 'safe\n',
      },
      {
        name: 'constructor destructuring for-of head stays on reanalysis',
        source:
          'class DestructuredConstructorForOf { constructor(values) { for (var { value } of values) this.value = value; } } console.log(new DestructuredConstructorForOf([{ value: 8 }]).value);',
        graph: 'reanalyzed',
        output: '8\n',
      },
      {
        name: 'constructor call in for-of iterable stays on reanalysis',
        source:
          'function getConstructorValues() { return [8]; } class CalledConstructorForOfIterable { constructor() { for (var value of getConstructorValues()) this.value = value; } } console.log(new CalledConstructorForOfIterable().value);',
        graph: 'reanalyzed',
        output: '8\n',
      },
      {
        name: 'constructor call in for-of body stays on reanalysis',
        source:
          'function readConstructorLoopValue(value) { return value; } class CalledConstructorForOfBody { constructor(values) { for (var value of values) this.value = readConstructorLoopValue(value); } } console.log(new CalledConstructorForOfBody([8]).value);',
        graph: 'reanalyzed',
        output: '8\n',
      },
      {
        name: 'unresolved constructor for-of head stays on reanalysis',
        source:
          'class UnresolvedConstructorForOfHead { constructor(values) { for (missingConstructorLoopTarget of values) this.value = 1; } } try { new UnresolvedConstructorForOfHead([8]); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor unescaped labeled loop control retains its graph',
        source:
          'class ConstructorLabeledControl { constructor() { target: while (false) { break target; } this.value = 1; } } console.log(new ConstructorLabeledControl().value);',
        graph: 'retained',
        output: '1\n',
      },
      {
        name: 'constructor escaped label spelling stays on reanalysis',
        source:
          'class EscapedConstructorLabel { constructor() { \\u0074arget: while (true) { break target; } this.value = 1; } } console.log(new EscapedConstructorLabel().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor escaped label control spelling stays on reanalysis',
        source:
          'class EscapedConstructorLabelControl { constructor() { target: while (true) { break \\u0074arget; } this.value = 1; } } console.log(new EscapedConstructorLabelControl().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor call in labeled body stays on reanalysis',
        source:
          'function readLabeledBody() { return 1; } class CalledLabeledBody { constructor() { target: { this.value = readLabeledBody(); } } } console.log(new CalledLabeledBody().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor call in switch discriminant stays on reanalysis',
        source:
          'function readSwitchDiscriminant() { return 1; } class CalledSwitchDiscriminant { constructor() { switch (readSwitchDiscriminant()) { case 1: this.value = 1; break; default: this.value = 2; } } } console.log(new CalledSwitchDiscriminant().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor call in switch case test stays on reanalysis',
        source:
          'function readSwitchCase() { return 1; } class CalledSwitchCase { constructor(input) { switch (input) { case readSwitchCase(): this.value = 1; break; default: this.value = 2; } } } console.log(new CalledSwitchCase(1).value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor call in switch case body stays on reanalysis',
        source:
          'function readSwitchBody() { return 3; } class CalledSwitchBody { constructor() { switch (1) { case 1: this.value = readSwitchBody(); break; default: this.value = 0; } } } console.log(new CalledSwitchBody().value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'constructor lexical switch case stays on reanalysis',
        source:
          'class LexicalSwitchCase { constructor(input) { switch (input) { case 1: let value = 3; this.value = value; break; default: this.value = 0; } } } console.log(new LexicalSwitchCase(1).value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'constructor call in catch body stays on reanalysis',
        source:
          'function readCaughtValue(value) { return value + 1; } class CalledCatchBody { constructor(input) { try { throw input; } catch (error) { this.value = readCaughtValue(error); } } } console.log(new CalledCatchBody(7).value);',
        graph: 'reanalyzed',
        output: '8\n',
      },
      {
        name: 'constructor call in finally body stays on reanalysis',
        source:
          'function finishConstructor() { return 1; } class CalledFinallyBody { constructor() { try { this.value = 1; } finally { this.finalized = finishConstructor(); } } } console.log(new CalledFinallyBody().finalized);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor call in if branch stays on reanalysis',
        source:
          'function readIfValue() { return 1; } class CalledIfBranch { constructor(flag) { if (flag) this.value = readIfValue(); } } console.log(new CalledIfBranch(true).value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'constructor lexical local in if block stays on reanalysis',
        source:
          'class LexicalIfBranch { constructor(input, flag) { if (flag) { let value = input; this.value = value; } } } console.log(new LexicalIfBranch(3, true).value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'constructor unresolved return value stays on reanalysis',
        source:
          'class UnresolvedConstructorReturn { constructor() { return missingConstructorReturn; } } try { new UnresolvedConstructorReturn(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor call return value stays on reanalysis',
        source:
          'function makeConstructorReturn() { return {}; } class CalledConstructorReturn { constructor() { return makeConstructorReturn(); } } console.log(new CalledConstructorReturn() !== CalledConstructorReturn.prototype);',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor object literal return stays on reanalysis',
        source:
          'class LiteralConstructorReturn { constructor(input) { return { value: input }; } } console.log(new LiteralConstructorReturn(3).value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'constructor unresolved throw value stays on reanalysis',
        source:
          'class UnresolvedConstructorThrow { constructor() { throw missingConstructorThrow; } } try { new UnresolvedConstructorThrow(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor call throw value stays on reanalysis',
        source:
          'function makeConstructorThrow() { return {}; } class CalledConstructorThrow { constructor() { throw makeConstructorThrow(); } } try { new CalledConstructorThrow(); } catch (error) { console.log(typeof error); }',
        graph: 'reanalyzed',
        output: 'object\n',
      },
      {
        name: 'constructor nullish initializer stays on reanalysis',
        source:
          'class NullishLocal { constructor(input) { var value = input ?? 7; this.value = value; } } console.log(new NullishLocal(undefined).value);',
        graph: 'reanalyzed',
        output: '7\n',
      },
      {
        name: 'unresolved constructor local assignment stays on reanalysis',
        source:
          'class UnresolvedMutation { constructor() { unboundMutationTarget = 2; } } console.log(typeof UnresolvedMutation);',
        graph: 'reanalyzed',
        output: 'function\n',
      },
      {
        name: 'constructor exponentiation compound assignment stays on reanalysis',
        source:
          'class ExponentMutation { constructor(input) { var value = input; value **= 2; this.value = value; } } console.log(new ExponentMutation(3).value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'constructor logical compound assignment stays on reanalysis',
        source:
          'class LogicalMutation { constructor(input) { var value = input; value ||= 4; this.value = value; } } console.log(new LogicalMutation(0).value);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'constructor this-property exponentiation assignment stays on reanalysis',
        source:
          'class ExponentPropertyMutation { constructor(input) { this.value = input; this.value **= 2; } } console.log(new ExponentPropertyMutation(3).value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'constructor this-property logical assignment stays on reanalysis',
        source:
          'class LogicalPropertyMutation { constructor(input) { this.value = input; this.value ||= 4; } } console.log(new LogicalPropertyMutation(0).value);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'destructured constructor parameter stays on reanalysis',
        source:
          'class DestructuredParameter { constructor({ value }) { this.value = value; } } console.log(new DestructuredParameter({ value: 4 }).value);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'rest constructor parameter stays on reanalysis',
        source:
          'class RestParameter { constructor(...values) { this.value = values; } } console.log(new RestParameter(4).value[0]);',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'constructor primitive property initializers retain their graph',
        source:
          'class Initialized { constructor() { this.count = 3; this.label = "ready"; this.active = true; this.empty = null; } } var initialized = new Initialized(); console.log(initialized.count, initialized.label, initialized.active, initialized.empty);',
        graph: 'retained',
        output: '3 ready true null\n',
      },
      {
        name: 'constructor assignment still invokes a prototype setter',
        source:
          'class SetterTarget { constructor() { this.value = 7; } get value() { return this.stored; } set value(next) { this.stored = next; } } var setterTarget = new SetterTarget(); console.log(setterTarget.stored, setterTarget.value, Object.prototype.hasOwnProperty.call(setterTarget, "value"));',
        graph: 'retained',
        output: '7 7 false\n',
      },
      {
        name: 'constructor initializer keeps an exact source binding reference',
        source:
          'var sharedValue = 7; class BindingInitializer { constructor() { this.value = sharedValue; } } console.log(new BindingInitializer().value);',
        graph: 'retained',
        output: '7\n',
      },
      {
        name: 'constructor initializer reading its class binding keeps exact identity',
        source:
          'class ConstructorSelf { constructor() { this.value = ConstructorSelf; } } console.log(new ConstructorSelf().value === ConstructorSelf);',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'constructor initializer with unresolved global stays on reanalysis',
        source:
          'class UnresolvedInitializer { constructor() { this.value = missingInitialValue; } } try { new UnresolvedInitializer(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor arithmetic assignment retains its bound reference',
        source:
          'var initialValue = 7; class BinaryInitializer { constructor() { this.value = initialValue + 1; } } console.log(new BinaryInitializer().value);',
        graph: 'retained',
        output: '8\n',
      },
      {
        name: 'constructor native this-property compound preserves uninitialized read semantics',
        source:
          'class CompoundInitializer { constructor() { this.value += 2; } } console.log(new CompoundInitializer().value);',
        graph: 'retained',
        output: 'NaN\n',
      },
      {
        name: 'constructor computed compound property stays on reanalysis',
        source:
          'class ComputedCompound { constructor(key, input) { this[key] += input; } } console.log(Number.isNaN(new ComputedCompound("value", 2).value));',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor computed string compound property stays on reanalysis',
        source:
          'class ComputedStringCompound { constructor(input) { this["value"] += input; } } console.log(Number.isNaN(new ComputedStringCompound(2).value));',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor escaped static compound property stays on reanalysis',
        source:
          'class EscapedCompound { constructor() { this.v\\u0061lue = 3; this.v\\u0061lue += 2; } } console.log(new EscapedCompound().value);',
        graph: 'reanalyzed',
        output: '5\n',
      },
      {
        name: 'constructor non-this compound property stays on reanalysis',
        source:
          'var compoundReceiver = { value: 3 }; class ExternalCompound { constructor(input) { compoundReceiver.value += input; } } new ExternalCompound(2); console.log(compoundReceiver.value);',
        graph: 'reanalyzed',
        output: '5\n',
      },
      {
        name: 'constructor this-property compound with unresolved RHS stays on reanalysis',
        source:
          'class UnresolvedPropertyCompound { constructor() { this.value += missingCompoundValue; } } try { new UnresolvedPropertyCompound(); } catch (error) { console.log(error instanceof ReferenceError); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'constructor computed initializer stays on reanalysis',
        source:
          'var fieldName = "value"; class ComputedInitializer { constructor() { this[fieldName] = 2; } } console.log(new ComputedInitializer().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'constructor computed string key stays on reanalysis',
        source:
          'class ComputedStringInitializer { constructor() { this["value"] = 2; } } console.log(new ComputedStringInitializer().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'constructor initializer call stays on reanalysis',
        source:
          'function makeValue() { return 2; } class CalledInitializer { constructor() { this.value = makeValue(); } } console.log(new CalledInitializer().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'empty constructor may precede an ordinary method',
        source:
          'class ConstructorAndMethod { constructor() {} value() { return 7; } } console.log(new ConstructorAndMethod().value());',
        graph: 'retained',
        output: '7\n',
      },
      {
        name: 'empty constructor may follow instance and static methods',
        source:
          'class MethodThenConstructor { value() { return this instanceof MethodThenConstructor; } constructor() {} static self() { return MethodThenConstructor; } } console.log(new MethodThenConstructor().value(), MethodThenConstructor.self() === MethodThenConstructor);',
        graph: 'retained',
        output: 'true true\n',
      },
      {
        name: 'empty constructor may accompany a trailing accessor',
        source:
          'class ConstructorAndAccessor { constructor() {} get value() { return 8; } } console.log(new ConstructorAndAccessor().value);',
        graph: 'retained',
        output: '8\n',
      },
      {
        name: 'empty constructor may follow an accessor',
        source:
          'class AccessorBeforeConstructor { get value() { return 8; } constructor() {} } console.log(new AccessorBeforeConstructor().value);',
        graph: 'retained',
        output: '8\n',
      },
      {
        name: 'empty constructor and ordinary method may precede an accessor pair',
        source:
          'class ConstructorAndAccessorPair { constructor() {} value() { return this.stored; } get result() { return this.stored; } set result(n) { this.stored = n; } } var constructorPair = new ConstructorAndAccessorPair(); constructorPair.result = 5; console.log(constructorPair.value(), constructorPair.result);',
        graph: 'retained',
        output: '5 5\n',
      },
      {
        name: 'ordinary method after constructor accessor group stays on reanalysis',
        source:
          'class AccessorThenMethod { constructor() {} get value() { return 8; } method() { return 9; } } var accessorThenMethod = new AccessorThenMethod(); console.log(accessorThenMethod.value, accessorThenMethod.method());',
        graph: 'reanalyzed',
        output: '8 9\n',
      },
      {
        name: 'empty constructor mixed with a field stays on reanalysis',
        source:
          'class ConstructorAndField { constructor() {} value = 8; } console.log(new ConstructorAndField().value);',
        graph: 'reanalyzed',
        output: '8\n',
      },
      {
        name: 'static method named constructor stays on reanalysis',
        source:
          'class StaticConstructor { static constructor() {} } console.log(typeof StaticConstructor.constructor);',
        graph: 'reanalyzed',
        output: 'function\n',
      },
      {
        name: 'computed method key',
        source:
          "var key = 'value';\nclass Computed { [key]() { return 9; } }\nconsole.log(new Computed().value());\n",
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'method with super and no base class',
        source:
          'class WithSuper { value() { return super.toString(); } }\nconsole.log(new WithSuper().value());\n',
        graph: 'reanalyzed',
        output: '[object Object]\n',
      },
      {
        name: 'block scoped empty class',
        source:
          'if (false) { class Hidden {} }\ntry { console.log(Hidden); } catch (error) { console.log(error.name); }\n',
        graph: 'reanalyzed',
        output: 'ReferenceError\n',
      },
      {
        name: 'function local empty class retains its exact binding graph',
        source:
          'function make() { class Local {} return new Local() instanceof Local; }\nconsole.log(make());\n',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'function-body derived class retains its exact self and base identities',
        source:
          'function make(Base, Child) { function inner() { class Child extends Base { self() { return Child; } } var child = new Child(); return [child.self() === Child, child instanceof Base, Child.name]; } return [inner().join(" "), Child]; } console.log(make(function Base() {}, 9).join("|"));',
        graph: 'retained',
        output: 'true true Child|9\n',
      },
      {
        name: 'simple class declaration with a bound base retains its graph',
        source:
          'function Base() {}\nclass Derived extends Base {}\nconsole.log(new Derived() instanceof Base);\n',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'class expression with an effectful base stays on reanalysis and evaluates the base once',
        source:
          'var calls = 0; function getBase() { calls += 1; return function Base() {}; } var Child = class extends getBase() {}; new Child(); console.log(calls);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'class declaration extending its own TDZ binding stays on reanalysis',
        source:
          'function make(ReferenceError) { class Child extends Child {} return new Child(); } try { make(0); } catch (error) { console.log(error.name); }',
        graph: 'reanalyzed',
        output: 'ReferenceError\n',
      },
      {
        name: 'named class expression extending its own TDZ binding stays on reanalysis',
        source:
          'function make(ReferenceError) { var Holder = class Inner extends Inner {}; return Holder; } try { make(0); } catch (error) { console.log(error.name); }',
        graph: 'reanalyzed',
        output: 'ReferenceError\n',
      },
      {
        name: 'derived class with a super method stays on reanalysis',
        source:
          'function Base() {} Base.prototype.value = 4; class Child extends Base { read() { return super.value; } } console.log(new Child().read());',
        graph: 'reanalyzed',
        output: '4\n',
      },
      {
        name: 'named class expression with a bound base retains exact self and base identities',
        source:
          'function make(Base, Named) { var Derived = class Named extends Base { self() { return Named; } }; var child = new Derived(); return [child instanceof Base, child.self() === Derived, Derived.name, Named]; } console.log(make(function Base() {}, 9).join(" "));',
        graph: 'retained',
        output: 'true true Named 9\n',
      },
      {
        name: 'explicit derived constructor with only super retains exact helper and capture identities',
        source:
          'function Base() { this.base = 1; } var _this = 7, _newTarget = 8, __callSuper = 9, __assertThisInitialized = 10, __assertThisUninitialized = 11; class Child extends Base { constructor() { super(); } } var child = new Child(); console.log(child.base, child instanceof Base, child instanceof Child, _this, _newTarget, __callSuper, __assertThisInitialized, __assertThisUninitialized);',
        graph: 'retained',
        output: '1 true true 7 8 9 10 11\n',
      },
      {
        name: 'explicit super keeps primitive and bound identifier arguments exact',
        source:
          'var baseValue = 4; function Base(first, second) { this.sum = first + second; } class Child extends Base { constructor() { super(3, baseValue); } } var child = new Child(); console.log(child.sum, child instanceof Child);',
        graph: 'retained',
        output: '7 true\n',
      },
      {
        name: 'explicit super argument coercion with side effects happens once',
        source:
          'var coercions = 0; var operand = { valueOf() { coercions += 1; return 4; } }; function Base(value) { this.value = value; } class Child extends Base { constructor() { super(operand + 1); } } console.log(new Child().value, coercions);',
        graph: 'retained',
        output: '5 1\n',
      },
      {
        name: 'explicit super followed by one simple this-property assignment retains its graph',
        source:
          'var seed = 4; function Base() { this.base = 2; } class Child extends Base { constructor() { super(); this.value = seed + 1; } } var child = new Child(); console.log(child.base, child.value, child instanceof Child);',
        graph: 'retained',
        output: '2 5 true\n',
      },
      {
        name: 'post-super assignments use the base-returned object in source order',
        source:
          'var writes = []; function Base() { return new Proxy({}, { set(target, key, value) { writes.push(key + ":" + value); target[key] = value; return true; } }); } class Child extends Base { constructor() { super(); this.value = 3; this.other = 4; } } var child = new Child(); console.log(child.value, child.other, writes.join(","), child instanceof Child);',
        graph: 'retained',
        output: '3 4 value:3,other:4 false\n',
      },
      {
        name: 'post-super simple var declarations retain exact constructor-local symbols',
        source:
          'var _this = 9, _newTarget = 10, seed = 3; function Base() {} class Child extends Base { constructor() { super(); var _this = seed; var _newTarget = _this + 1; this.value = _newTarget; } } var child = new Child(); console.log(child.value, child instanceof Base, _this, _newTarget);',
        graph: 'retained',
        output: '4 true 9 10\n',
      },
      {
        name: 'post-super direct if-else preserves both initialized-this branches',
        source:
          'var selected = true; function Base() {} class Child extends Base { constructor() { super(); if (selected) this.value = 1; else this.value = 2; } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, first instanceof Child);',
        graph: 'retained',
        output: '1 2 true\n',
      },
      {
        name: 'post-super direct if without else preserves the unassigned base value',
        source:
          'var selected = false; function Base() { this.value = 0; } class Child extends Base { constructor() { super(); if (selected) this.value = 1; } } console.log(new Child().value);',
        graph: 'retained',
        output: '0\n',
      },
      {
        name: 'post-super branches write once to the object returned by the base constructor',
        source:
          'var selected = true; var writes = []; function Base() { return new Proxy({}, { set(target, key, value) { writes.push(key + ":" + value); target[key] = value; return true; } }); } class Child extends Base { constructor() { super(); if (selected) this.left = 1; else this.right = 2; } } var first = new Child(); selected = false; var second = new Child(); console.log(first.left, second.right, writes.join(","), first instanceof Child, second instanceof Child);',
        graph: 'retained',
        output: '1 2 left:1,right:2 false false\n',
      },
      {
        name: 'post-super branches preserve exact helper-colliding source bindings',
        source:
          'var _this = true, _newTarget = 7; function Base() {} class Child extends Base { constructor() { super(); if (_this) this.value = _newTarget; else this.value = 8; } } var child = new Child(); console.log(child.value, child instanceof Child, _this, _newTarget);',
        graph: 'retained',
        output: '7 true true 7\n',
      },
      {
        name: 'post-super block branches retain simple vars with helper-colliding source bindings',
        source:
          'var selected = true, _this = 70, _newTarget = 8; function Base() {} class Child extends Base { constructor() { super(); if (selected) { var _this = 1; this.value = _this; } else { var rightValue = 2; this.value = rightValue + _newTarget; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, first instanceof Child, _this, _newTarget);',
        graph: 'retained',
        output: '1 10 true 70 8\n',
      },
      {
        name: 'post-super block branches write in order to the base-returned object',
        source:
          'var selected = true, writes = []; function Base() { return new Proxy({}, { set(target, key, value) { writes.push(key + ":" + value); target[key] = value; return true; } }); } class Child extends Base { constructor() { super(); if (selected) { var leftMarker = 1; this.left = leftMarker; this.done = 2; } else { var rightMarker = 3; this.right = rightMarker; this.done = 4; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first.left, second.right, writes.join(","), first instanceof Child, second instanceof Child);',
        graph: 'retained',
        output: '1 3 left:1,done:2,right:3,done:4 false false\n',
      },
      {
        name: 'post-super this-property condition reads a Proxy getter once per construction',
        source:
          'var selected = true, reads = 0; function Base() { return new Proxy({ selected: selected }, { get(target, key, receiver) { if (key === "selected") reads += 1; return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (this.selected) { this.value = 1; } else { this.value = 2; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, reads, first instanceof Child, second instanceof Child);',
        graph: 'retained',
        output: '1 2 2 false false\n',
      },
      {
        name: 'post-super composed condition preserves getter and short-circuit coercion counts',
        source:
          'var selected = true, reads = 0, coercions = 0; var conditionValue = { valueOf() { coercions += 1; return 1; } }; function Base() { return new Proxy({ selected: selected }, { get(target, key, receiver) { if (key === "selected") reads += 1; return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (this.selected && +conditionValue) this.value = 1; else this.value = 2; } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, reads, coercions);',
        graph: 'retained',
        output: '1 2 2 1\n',
      },
      {
        name: 'post-super property comparison preserves coercive equality effects once',
        source:
          'var reads = 0, coercions = 0; var expected = { valueOf() { coercions += 1; return 1; } }; function Base() { return new Proxy({ selected: 1 }, { get(target, key, receiver) { if (key === "selected") reads += 1; return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (this.selected == expected) this.value = 1; else this.value = 2; } } var child = new Child(); console.log(child.value, reads, coercions);',
        graph: 'retained',
        output: '1 1 1\n',
      },
      {
        name: 'post-super ternary condition preserves branch reads and unary coercion once',
        source:
          'var selected = true, selectedReads = 0, amountReads = 0, coercions = 0; var amount = { valueOf() { coercions += 1; return 1; } }; function Base() { return new Proxy({ selected: selected, amount: amount }, { get(target, key, receiver) { if (key === "selected") selectedReads += 1; if (key === "amount") amountReads += 1; return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (this.selected ? +this.amount : false) this.value = 1; else this.value = 2; } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, selectedReads, amountReads, coercions);',
        graph: 'retained',
        output: '1 2 2 1 1\n',
      },
      {
        name: 'post-super branch return of a bound object keeps derived return semantics',
        source:
          'var selected = true, replacement = { value: 8 }; function Base() {} class Child extends Base { constructor() { super(); if (selected) return replacement; else this.value = 2; } } var first = new Child(); selected = false; var second = new Child(); console.log(first === replacement, first.value, second.value, second instanceof Child);',
        graph: 'retained',
        output: 'true 8 2 true\n',
      },
      {
        name: 'post-super block branch writes once before returning a replacement object',
        source:
          'var selected = true, writes = [], replacement = { value: 8 }; function Base() { return new Proxy({}, { set(target, key, value) { writes.push(key + ":" + value); target[key] = value; return true; } }); } class Child extends Base { constructor() { super(); if (selected) { this.marker = 1; return replacement; } else { this.marker = 2; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first === replacement, second.marker, writes.join(","), second instanceof Child);',
        graph: 'retained',
        output: 'true 2 marker:1,marker:2 false\n',
      },
      {
        name: 'post-super branch primitive return still throws TypeError',
        source:
          'var selected = true; function Base() {} class Child extends Base { constructor() { super(); if (selected) return 1; else this.value = 2; } } try { new Child(); } catch (error) { console.log(error.name); } selected = false; console.log(new Child().value);',
        graph: 'retained',
        output: 'TypeError\n2\n',
      },
      {
        name: 'post-super return of a bound object preserves derived constructor return semantics',
        source:
          'var replacement = { value: 8 }; function Base() {} class Child extends Base { constructor() { super(); return replacement; } } var child = new Child(); console.log(child === replacement, child.value, child instanceof Child);',
        graph: 'retained',
        output: 'true 8 false\n',
      },
      {
        name: 'post-super bare return preserves the initialized this value',
        source:
          'function Base() { this.value = 4; } class Child extends Base { constructor() { super(); return; } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'retained',
        output: '4 true\n',
      },
      {
        name: 'post-super primitive return still throws TypeError',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); return 1; } } try { new Child(); } catch (error) { console.log(error.name); }',
        graph: 'retained',
        output: 'TypeError\n',
      },
      {
        name: 'nested explicit super constructor retains exact outer base and inner class identities',
        source:
          'function make(Base, Child) { function inner() { class Child extends Base { constructor() { super(); } self() { return Child; } } var child = new Child(); return [child.self() === Child, child instanceof Base, Child.name]; } return [inner().join(" "), Child]; } console.log(make(function Base() {}, 9).join("|"));',
        graph: 'retained',
        output: 'true true Child|9\n',
      },
      {
        name: 'explicit super constructors preserve native base and multi-level new.target',
        source:
          'var NativeArray = Array; class Middle extends NativeArray { constructor() { super(); } } class Child extends Middle { constructor() { super(); } } var child = new Child(); child.push(3); console.log(Array.isArray(child), child[0], child instanceof Child, child instanceof Middle, child instanceof NativeArray);',
        graph: 'retained',
        output: 'true 3 true true true\n',
      },
      {
        name: 'explicit derived constructor super argument with side effect stays on reanalysis',
        source:
          'var evaluations = 0; function value() { evaluations += 1; return 2; } function Base(argument) { this.argument = argument; } class Child extends Base { constructor() { super(value()); } } console.log(new Child().argument, evaluations);',
        graph: 'reanalyzed',
        output: '2 1\n',
      },
      {
        name: 'explicit derived constructor super property getter stays on reanalysis',
        source:
          'var reads = 0; var argument = { get value() { reads += 1; return 2; } }; function Base(value) { this.value = value; } class Child extends Base { constructor() { super(argument.value); } } console.log(new Child().value, reads);',
        graph: 'reanalyzed',
        output: '2 1\n',
      },
      {
        name: 'explicit derived constructor super spread stays on reanalysis',
        source:
          'var values = [2]; function Base(value) { this.value = value; } class Child extends Base { constructor() { super(...values); } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'explicit derived constructor conditional super stays on reanalysis',
        source:
          'function Base(value) { this.value = value; } class Child extends Base { constructor(flag) { if (flag) super(1); else super(2); this.seen = this.value; } } console.log(new Child(true).seen, new Child(false).seen);',
        graph: 'reanalyzed',
        output: '1 2\n',
      },
      {
        name: 'post-super this assignment with a call initializer stays on reanalysis',
        source:
          'var calls = 0; function value() { calls += 1; return 3; } function Base() {} class Child extends Base { constructor() { super(); this.value = value(); } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '3 1\n',
      },
      {
        name: 'post-super return call stays on reanalysis',
        source:
          'var calls = 0; function replacement() { calls += 1; return { value: 8 }; } function Base() {} class Child extends Base { constructor() { super(); return replacement(); } } var child = new Child(); console.log(child.value, calls);',
        graph: 'reanalyzed',
        output: '8 1\n',
      },
      {
        name: 'post-super branch return call stays on reanalysis',
        source:
          'var calls = 0; function replacement() { calls += 1; return { value: 8 }; } function Base() {} class Child extends Base { constructor() { super(); if (true) return replacement(); else this.value = 2; } } var child = new Child(); console.log(child.value, calls);',
        graph: 'reanalyzed',
        output: '8 1\n',
      },
      {
        name: 'post-super branch block with non-final return stays on reanalysis',
        source:
          'var replacement = { value: 8 }; function Base() {} class Child extends Base { constructor() { super(); if (true) { return replacement; this.value = 5; } else { this.value = 2; } } } var child = new Child(); console.log(child === replacement, child.value);',
        graph: 'reanalyzed',
        output: 'true 8\n',
      },
      {
        name: 'post-super constructor with a local declaration stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); this.value = 3; let other = 4; } } var child = new Child(); console.log(child.value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'post-super var call initializer stays on reanalysis',
        source:
          'var calls = 0; function value() { calls += 1; return 3; } function Base() {} class Child extends Base { constructor() { super(); var local = value(); this.value = local; } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '3 1\n',
      },
      {
        name: 'post-super if with a call condition stays on reanalysis',
        source:
          'var calls = 0; function selected() { calls += 1; return true; } function Base() {} class Child extends Base { constructor() { super(); if (selected()) this.value = 1; else this.value = 2; } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '1 1\n',
      },
      {
        name: 'post-super method call through this in the condition stays on reanalysis',
        source:
          'var calls = 0; function Base() { this.selected = function() { calls += 1; return true; }; } class Child extends Base { constructor() { super(); if (this.selected()) this.value = 1; else this.value = 2; } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '1 1\n',
      },
      {
        name: 'post-super computed this-property condition stays on reanalysis',
        source:
          'var reads = 0, key = "selected"; function Base() { return new Proxy({ selected: true }, { get(target, property, receiver) { if (property === "selected") reads += 1; return Reflect.get(target, property, receiver); } }); } class Child extends Base { constructor() { super(); if (this[key]) this.value = 1; else this.value = 2; } } var child = new Child(); console.log(child.value, reads);',
        graph: 'reanalyzed',
        output: '1 1\n',
      },
      {
        name: 'post-super nested this-property condition stays on reanalysis',
        source:
          'var reads = 0; function Base() { return new Proxy({ nested: { selected: true } }, { get(target, key, receiver) { if (key === "nested") reads += 1; return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (this.nested.selected) this.value = 1; else this.value = 2; } } var child = new Child(); console.log(child.value, reads);',
        graph: 'reanalyzed',
        output: '1 1\n',
      },
      {
        name: 'post-super block branch with a lexical declaration stays on reanalysis',
        source:
          'var selected = true; function Base() {} class Child extends Base { constructor() { super(); if (selected) { let local = 1; this.value = local; } else { this.value = 2; } } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'post-super block branch with a call initializer stays on reanalysis',
        source:
          'var calls = 0; function value() { calls += 1; return 3; } function Base() {} class Child extends Base { constructor() { super(); if (true) { var local = value(); this.value = local; } else { this.value = 2; } } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '3 1\n',
      },
      {
        name: 'post-super block branch with a final bare return retains the graph',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { this.value = 3; return; } else { this.value = 2; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'retained',
        output: '3 true\n',
      },
      {
        name: 'post-super sibling blocks with same var binding retain the graph',
        source:
          'var selected = true; function Base() {} class Child extends Base { constructor() { super(); if (selected) { var local = 1; this.value = local; } else { var local = 2; this.value = local; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, first instanceof Child);',
        graph: 'retained',
        output: '1 2 true\n',
      },
      {
        name: 'post-super else-if branch stays on reanalysis',
        source:
          'var first = false, second = true; function Base() {} class Child extends Base { constructor() { super(); if (first) this.value = 1; else if (second) this.value = 2; else this.value = 3; } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'post-super computed property branch stays on reanalysis',
        source:
          'var key = "value"; function Base() {} class Child extends Base { constructor() { super(); if (true) this[key] = 1; else this[key] = 2; } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '1\n',
      },
      {
        name: 'post-super destructured var stays on reanalysis',
        source:
          'var source = { value: 3 }; function Base() {} class Child extends Base { constructor() { super(); var { value } = source; this.value = value; } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'explicit derived constructor this before super stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { this.value = 1; super(); } } try { new Child(); } catch (error) { console.log(error.name); }',
        graph: 'reanalyzed',
        output: 'ReferenceError\n',
      },
      {
        name: 'explicit derived constructor duplicate super stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); super(); } } try { new Child(); } catch (error) { console.log(error.name); }',
        graph: 'reanalyzed',
        output: 'ReferenceError\n',
      },
      {
        name: 'anonymous class expression in a top-level var initializer retains its generated constructor identity',
        source: 'var Holder = class {};\nconsole.log(new Holder() instanceof Holder);\n',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'anonymous class expression method keeps an exact outer binding reference',
        source:
          'var Holder = class { read() { return Holder; } }; console.log(new Holder().read() === Holder);',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'anonymous class expression assigned outside a var initializer stays on reanalysis',
        source: 'var Holder; Holder = class {}; console.log(new Holder() instanceof Holder);',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'anonymous class expression in a let initializer stays on reanalysis',
        source: 'let Holder = class {}; console.log(new Holder() instanceof Holder);',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'anonymous class expression in a nested const initializer stays on reanalysis',
        source:
          'function make() { const Holder = class {}; return new Holder() instanceof Holder; } console.log(make());',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'anonymous class expression with a bound base retains generated self and inferred name',
        source:
          'function make(Base) { var Holder = class extends Base { self() { return Holder; } }; var child = new Holder(); return [child instanceof Base, child.self() === Holder, Holder.name]; } console.log(make(function Base() {}).join(" "));',
        graph: 'retained',
        output: 'true true Holder\n',
      },
      {
        name: 'named class expression in a nested var initializer retains its exact inner identity',
        source:
          'function make(Inner) { var Holder = class Inner { self() { return Inner; } }; return [Holder.name, new Holder().self() === Holder, Inner]; } console.log(make(9).join(" "));',
        graph: 'retained',
        output: 'Inner true 9\n',
      },
      {
        name: 'anonymous class expression in a nested var initializer retains its exact outer binding',
        source:
          'function make() { var Holder = class { read() { return Holder; } }; return new Holder().read() === Holder; } console.log(make());',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'function-body class declaration retains its exact self binding beside an outer parameter',
        source:
          'function make(Local) { function inner() { class Local { self() { return Local; } } return new Local().self() === Local && Local.name === "Local"; } return inner() && Local === 9; } console.log(make(9));',
        graph: 'retained',
        output: 'true\n',
      },
      {
        name: 'class declaration inside a nested block stays on reanalysis',
        source:
          'function make(Local) { if (true) { class Local { self() { return Local; } } return new Local().self() === Local && Local.name === "Local"; } return Local === 9; } console.log(make(9));',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'named class expression assigned outside a variable initializer stays on reanalysis',
        source:
          'var Holder; Holder = class Inner {}; console.log(new Holder() instanceof Holder && Holder.name === "Inner");',
        graph: 'reanalyzed',
        output: 'true\n',
      },
    ];

    for (const fixture of cases) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-es5-class-${fixture.graph}-`));
      const entry = join(dir, 'entry.mjs');
      const output = join(dir, 'out.cjs');
      writeFileSync(entry, fixture.source);
      try {
        const args = [
          '--bundle',
          entry,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
        ];
        if ('minifyWhitespace' in fixture && fixture.minifyWhitespace) {
          args.push('--minify-whitespace');
        }
        if ('minifySyntax' in fixture && fixture.minifySyntax) {
          args.push('--minify-syntax');
        }
        args.push('-o', output);
        const proc = spawnSync(ZNTC_BIN, args, {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\0|\r?\n/);
        const report = lines.find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
        expect(report, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          const expected =
            fixture.shadowedExternal && counter === 'shadowed_external_reference' ? 1 : 0;
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.name}: ${counter}: ${report}`,
          ).toBe(expected);
        }
        expect(report, fixture.name).toMatch(
          fixture.shadowedExternal ? /clean=0(?:\s|$)/ : /clean=1(?:\s|$)/,
        );

        if (fixture.graph === 'retained') {
          const helperReport = (proc.stderr ?? '')
            .split(/\r?\n/)
            .find(
              (line) =>
                line.startsWith('zntc: symbol-identity-prepass ') &&
                line.includes('\0zntc:runtime/class-call-check'),
            );
          expect(helperReport, `${fixture.name}: ${proc.stderr}`).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(helperReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture.name} helper: ${counter}: ${helperReport}`,
            ).toBe(0);
          }
          expect(helperReport, `${fixture.name} helper`).toMatch(/clean=1(?:\s|$)/);
        }

        const graphMode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
        );
        expect(graphMode, `${fixture.name}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  }, 30_000);

  test('모든 target의 minify 출력에서 전체 oracle 심볼 연결이 정확하다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-post-minify-matrix-'));
    try {
      const problems: string[] = [];
      let runs = 0;
      let generatedBindings = 0;
      let generatedReferences = 0;
      let declarationAnchorsChecked = 0;
      let markedSynthetic = 0;
      for (const file of fixtures) {
        const isFlow = file.endsWith('.flow.mjs') || file.endsWith('.flow');
        for (const target of MINIFY_TARGETS) {
          for (const mode of MINIFY_MODES) {
            const output = join(dir, `${runs}.js`);
            const proc = spawnSync(
              ZNTC_BIN,
              [file, target.arg, ...(isFlow ? ['--flow'] : []), ...mode, '-o', output],
              {
                env: {
                  ...process.env,
                  ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
                  ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
                  PATH: process.env.PATH ?? '/usr/bin:/bin',
                },
                encoding: 'utf8',
              },
            );
            const stderr = proc.stderr ?? '';
            if (proc.status !== 0) {
              problems.push(
                `${relative(FIXTURE_DIR, file)} [${target.name}; ${mode.join('+')}]: ${stderr}`,
              );
            }
            for (const auditProblem of transformIdentityAuditProblems(stderr)) {
              problems.push(
                `${relative(FIXTURE_DIR, file)} [${target.name}; ${mode.join('+')}]: transform identity audit ${auditProblem}: ${stderr}`,
              );
            }
            const exact = stderr
              .split(/\r?\n/)
              .find((line) => line.startsWith('zntc: symbol-identity '));
            if (exact) {
              generatedBindings += Number(
                exact.match(/(?:^| )generated_bindings=(\d+)(?: |$)/)?.[1] ?? 0,
              );
              generatedReferences += Number(
                exact.match(/(?:^| )generated_references=(\d+)(?: |$)/)?.[1] ?? 0,
              );
              declarationAnchorsChecked += Number(
                exact.match(/(?:^| )declaration_anchors_checked=(\d+)(?: |$)/)?.[1] ?? 0,
              );
            }
            const strict = stderr
              .split(/\r?\n/)
              .find((line) => line.startsWith('zntc: synthetic-coverage '));
            if (strict)
              markedSynthetic += Number(
                strict.match(/(?:^| )marked_synthetic=(\d+)(?: |$)/)?.[1] ?? 0,
              );
            for (const auditProblem of postMinifyAuditProblems(stderr)) {
              problems.push(
                `${relative(FIXTURE_DIR, file)} [${target.name}; ${mode.join('+')}]: ${auditProblem}: ${stderr}`,
              );
            }
            runs += 1;
          }
        }
      }
      expect(fixtures.length).toBeGreaterThan(0);
      expect(runs).toBe(fixtures.length * MINIFY_TARGETS.length * MINIFY_MODES.length);
      expect(generatedBindings).toBeGreaterThan(0);
      expect(generatedReferences).toBeGreaterThan(0);
      expect(declarationAnchorsChecked).toBeGreaterThan(0);
      expect(markedSynthetic).toBeGreaterThan(0);
      expect(problems).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 600_000);
});
