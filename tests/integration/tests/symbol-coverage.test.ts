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
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
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
const LOOP_BINDING_MANIFEST = [
  {
    file: '4819-generator-loop-callers.mjs',
    target: { name: 'es5', arg: '--target=es5' },
    emittedBindings: ['_loop2', '_loop3'],
    stdout: '0:while,1:while,2:while|0:do,1:do,2:do\n',
  },
  {
    file: '4819-generator-shadowed-loop-header.mjs',
    target: { name: 'es5', arg: '--target=es5' },
    emittedBindings: ['_loop'],
    stdout: '0:10,2:32:99\n',
  },
] as const;
type ProducerReport = 'exact' | 'strict';
type ProducerObservationRequirement = {
  report: ProducerReport;
  field: string;
  minimum: number;
};
const REQUIRED_PRODUCER_OBSERVATIONS: ReadonlyArray<{
  file: string;
  target: (typeof TARGETS)[number];
  expectedStdout: string;
  observations: readonly ProducerObservationRequirement[];
}> = [
  {
    file: '4819-generator-state-observation.mjs',
    target: TARGETS[0],
    expectedStdout: '1,2\n',
    observations: [
      { report: 'exact', field: 'generated_bindings', minimum: 1 },
      { report: 'exact', field: 'generated_references', minimum: 1 },
      { report: 'strict', field: 'marked_synthetic', minimum: 1 },
    ],
  },
  {
    file: '4819-for-in-loop-capture.mjs',
    target: TARGETS[0],
    expectedStdout: 'first,second,inherited\n',
    observations: [
      { report: 'exact', field: 'generated_bindings', minimum: 1 },
      { report: 'exact', field: 'generated_references', minimum: 1 },
      { report: 'strict', field: 'marked_synthetic', minimum: 1 },
    ],
  },
  {
    file: '4819-private-generator.mjs',
    target: TARGETS[0],
    expectedStdout: '2,3\n',
    observations: [
      { report: 'exact', field: 'generated_bindings', minimum: 1 },
      { report: 'exact', field: 'generated_references', minimum: 1 },
      { report: 'strict', field: 'marked_synthetic', minimum: 1 },
    ],
  },
  {
    file: '4801-static-field-arrow-this-observation.mjs',
    target: TARGETS[0],
    expectedStdout: '7\n',
    observations: [
      { report: 'exact', field: 'generated_bindings', minimum: 1 },
      // The isolated fixture produces 8 generated references without the
      // captured class-this reference and 9 with it.
      { report: 'exact', field: 'generated_references', minimum: 9 },
      { report: 'strict', field: 'marked_synthetic', minimum: 1 },
    ],
  },
  {
    file: '4819-import-equals-producer-observation.ts',
    target: TARGETS[0],
    expectedStdout: 'function\n',
    observations: [{ report: 'exact', field: 'generated_bindings', minimum: 1 }],
  },
  {
    file: '4819-namespace-iife-params.ts',
    target: TARGETS[0],
    expectedStdout: '[109,102]\n',
    observations: [
      { report: 'exact', field: 'namespace_iife_params', minimum: 1 },
      { report: 'exact', field: 'generated_references', minimum: 1 },
    ],
  },
  {
    file: '4819-enum-iife-params.ts',
    target: TARGETS[0],
    expectedStdout: '[3,1,3,23]\n',
    observations: [{ report: 'exact', field: 'enum_iife_params', minimum: 1 }],
  },
];
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
const STRICT_STATUS_FIELDS = [
  'bound',
  'external',
  'missing_binding',
  'unclassified',
  'invalid_id',
  'name_mismatch',
  'missing_reference',
  'identity_mismatch',
  'invalid_scope',
  'scope_unknown',
  'scope_ambiguous',
  'scope_mismatch',
  'invisible_reference',
  'duplicate_reference',
] as const;
const STRICT_STATUS_COUNT = 14;
const STRICT_STATUS_SCHEMA_FINGERPRINT = '37fd7382c204a61b';
const STRICT_METRIC_FIELDS = ['bound', 'external', 'scope_mismatch', 'marked_synthetic'] as const;
const STRICT_BOOLEAN_FIELDS = ['consistent', 'symbol_identity_complete'] as const;
const STRICT_SCHEMA_FIELDS = ['strict_status_count', 'strict_status_fingerprint'] as const;
const STRICT_REPORT_FIELDS = [
  ...STRICT_METRIC_FIELDS,
  ...STRICT_ZERO_COUNTERS,
  ...STRICT_BOOLEAN_FIELDS,
  ...STRICT_SCHEMA_FIELDS,
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
const EXACT_NO_DEBT_FINGERPRINT = 'cbf29ce484222325';
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
  const debtFingerprint = identity
    .match(/(?:^| )legacy_debt_fingerprint=([0-9a-fA-F]+)(?: |$)/)?.[1]
    ?.toLowerCase();
  if (debtFingerprint !== EXACT_NO_DEBT_FINGERPRINT) {
    problems.push(
      `legacy_debt_fingerprint=${debtFingerprint ?? 'missing'}, expected ${EXACT_NO_DEBT_FINGERPRINT}`,
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

function exactIdentityObservationProblems(identity: string): string[] {
  const observationFields = [
    'generated_bindings',
    'generated_references',
    'external',
    'declaration_anchors_checked',
    'namespace_iife_params',
    'enum_iife_params',
  ] as const;
  let hasObservation = false;
  for (const field of observationFields) {
    const value = identity.match(new RegExp(`(?:^| )${field}=(\\d+)(?: |$)`))?.[1];
    if (value === undefined) return [`missing exact identity observation ${field}`];
    const count = Number(value);
    if (!Number.isSafeInteger(count))
      return [`malformed exact identity observation ${field}=${value}`];
    if (count > 0) hasObservation = true;
  }
  return hasObservation
    ? []
    : ['exact identity audit checked no binding or reference observations'];
}

function requiredProducerObservationProblems(
  reports: { exact: string; strict: string },
  requirements: readonly ProducerObservationRequirement[],
): string[] {
  const problems: string[] = [];
  for (const requirement of requirements) {
    const report = reports[requirement.report];
    const matches =
      report.match(new RegExp(`(?:^| )${requirement.field}=(\\d+)(?=\\s|$)`, 'g')) ?? [];
    if (matches.length !== 1) {
      problems.push(
        `${requirement.report}.${requirement.field} observations=${matches.length}, expected 1`,
      );
      continue;
    }
    const value = Number(matches[0].match(/=(\d+)/)?.[1]);
    if (!Number.isSafeInteger(value)) {
      problems.push(`${requirement.report}.${requirement.field} is not a safe integer`);
    } else if (value < requirement.minimum) {
      problems.push(
        `${requirement.report}.${requirement.field}=${value}, required >=${requirement.minimum}`,
      );
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
  const checkedBindings = Number(values.get('bindings'));
  const checkedReferences = Number(values.get('references'));
  if (
    Number.isFinite(checkedBindings) &&
    Number.isFinite(checkedReferences) &&
    checkedBindings + checkedReferences === 0
  ) {
    problems.push('post-minify audit checked no binding or reference nodes');
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
  let strictStatusFieldCount = 0;
  const payload = report.slice(payloadStart + 2);
  for (const token of payload.trim().split(/\s+/)) {
    const match = token.match(/^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/);
    if (!match) {
      problems.push(`malformed strict report field ${token}`);
      continue;
    }
    const [, field, value] = match;
    counts.set(field, (counts.get(field) ?? 0) + 1);
    values.set(field, value);
    if (STRICT_STATUS_FIELDS.includes(field as (typeof STRICT_STATUS_FIELDS)[number])) {
      strictStatusFieldCount++;
    }
    if (!expectedFields.has(field)) problems.push(`unexpected strict report field ${field}`);
    const valuePattern = field === 'strict_status_fingerprint' ? /^[0-9a-fA-F]{1,16}$/ : /^\d+$/;
    if (!valuePattern.test(value)) problems.push(`malformed strict report value ${field}=${value}`);
  }

  const declaredStatusCount = values.get('strict_status_count');
  if (declaredStatusCount !== undefined && strictStatusFieldCount !== Number(declaredStatusCount)) {
    problems.push(
      `strict status fields=${strictStatusFieldCount}, expected ${declaredStatusCount}`,
    );
  }

  for (const field of STRICT_REPORT_FIELDS) {
    const occurrences = counts.get(field) ?? 0;
    if (occurrences !== 1) {
      problems.push(`${field} occurrences=${occurrences}, expected 1`);
      continue;
    }
    const value = values.get(field);
    const expected =
      field === 'strict_status_count'
        ? String(STRICT_STATUS_COUNT)
        : field === 'strict_status_fingerprint'
          ? STRICT_STATUS_SCHEMA_FINGERPRINT
          : STRICT_ZERO_COUNTERS.includes(field as (typeof STRICT_ZERO_COUNTERS)[number])
            ? '0'
            : STRICT_BOOLEAN_FIELDS.includes(field as (typeof STRICT_BOOLEAN_FIELDS)[number])
              ? '1'
              : undefined;
    const mismatched =
      field === 'strict_status_fingerprint'
        ? value?.toLowerCase().padStart(16, '0') !== expected
        : value !== expected;
    if (expected !== undefined && mismatched) {
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

function runFixtureReference(file: string, outDir: string) {
  let referenceFile = file;
  if (file.endsWith('.ts')) {
    referenceFile = join(outDir, 'reference.js');
    writeFileSync(
      referenceFile,
      ts.transpileModule(readFileSync(file, 'utf8'), {
        compilerOptions: {
          module: ts.ModuleKind.CommonJS,
          target: ts.ScriptTarget.ES5,
        },
      }).outputText,
    );
  }
  return spawnSync('node', [referenceFile], { encoding: 'utf8' });
}

function runCoverage(
  file: string,
  target: (typeof TARGETS)[number],
  outDir: string,
  minifyIdentifiers = false,
): { stderr: string; exitCode: number } {
  const isFlow = file.endsWith('.flow.mjs') || file.endsWith('.flow');
  const stderrPath = join(outDir, 'stderr.log');
  // Capture CLI diagnostics through the shell because Bun's Node-compatible
  // child stdio is empty in this TypeScript-importing test module.
  const proc = spawnSync(
    '/bin/sh',
    [
      '-c',
      'export ZNTC_DEBUG_SYMBOL_COVERAGE=1 ZNTC_DEBUG_SYNTHETIC_COVERAGE=1; stderr_path=$1; shift; "$@" 2>"$stderr_path"',
      'zntc-symbol-coverage',
      stderrPath,
      ZNTC_BIN,
      file,
      target.arg,
      ...(isFlow ? ['--flow'] : []),
      ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
      '-o',
      join(outDir, 'out.js'),
    ],
    { encoding: 'utf8' },
  );
  return {
    stderr: readFileSync(stderrPath, 'utf8') + (proc.stderr ?? ''),
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

  test('ES5 computed instance-field key temp keeps exact identity and evaluates once', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-computed-field-key-symbol-'));
    const input = join(dir, 'entry.js');
    const output = join(dir, 'out.js');
    writeFileSync(
      input,
      [
        "var _a = 'outer-a';",
        "var _b = 'outer-b';",
        'var evaluations = 0;',
        "function computedKey() { evaluations++; return 'value'; }",
        'class Box { [computedKey()] = 5; }',
        'var first = new Box();',
        'var second = new Box();',
        "console.log([first.value, second.value, evaluations, _a, _b].join('|'));",
      ].join('\n'),
    );

    try {
      const baseline = spawnSync('node', [input], { encoding: 'utf8' });
      expect(baseline.status, baseline.stderr).toBe(0);

      const { stderr, exitCode } = runCoverage(input, TARGETS[0], dir);
      expect(exitCode, stderr).toBe(0);
      expect(transformIdentityAuditProblems(stderr), stderr).toEqual([]);

      const exact = stderr.split(/\r?\n/).find((line) => line.startsWith('zntc: symbol-identity '));
      expect(exact, stderr).toBeDefined();
      expect(
        Number(exact?.match(/(?:^| )generated_bindings=(\d+)(?: |$)/)?.[1] ?? 0),
      ).toBeGreaterThan(0);
      expect(
        Number(exact?.match(/(?:^| )generated_references=(\d+)(?: |$)/)?.[1] ?? 0),
      ).toBeGreaterThan(0);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(baseline.stdout);
      expect(actual.stdout).toBe('5|5|1|outer-a|outer-b\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 private-field postfix temp keeps exact identity and the old value', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-private-field-postfix-symbol-'));
    const input = join(dir, 'entry.js');
    const output = join(dir, 'out.js');
    writeFileSync(
      input,
      [
        "var _a = 'outer-a';",
        "var _b = 'outer-b';",
        'class Box { #value = 10; update() { return this.#value++; } *sequence() { yield this.#value++; yield this.#value++; } }',
        'var box = new Box();',
        'var iterator = box.sequence();',
        'console.log(box.update(), box.update(), [iterator.next().value, iterator.next().value].join(","), _a, _b);',
      ].join('\n'),
    );

    try {
      const native = spawnSync('node', [input], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const transformed = spawnSync(ZNTC_BIN, [input, '--target=es5', '-o', output], {
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
      expect(transformed.status, transformed.stderr).toBe(0);

      const report = (transformed.stderr ?? '')
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('entry.js'));
      expect(report, transformed.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
      expect(actual.stdout).toBe('10 11 12,13 outer-a outer-b\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // Pin the matrix surface; deriving the expected run count only from these
  // arrays would let a removed fixture or target silently shrink the gate.
  test('oracle fixture and target inventory cannot shrink silently', () => {
    const fixtureNames = fixtures.map((file) => relative(FIXTURE_DIR, file).replaceAll('\\', '/'));
    const fixtureInventory = createHash('sha256')
      .update(fixtureNames.join('\n') + '\n')
      .digest('hex');
    expect(fixtureNames).toHaveLength(302);
    expect(fixtureInventory).toBe(
      'fdadbf1a4ab11bab9c5ddd73cae07d5407134cd2a675538b8118ed4836a00b52',
    );
    expect(fixtureContentFingerprint(fixtures, FIXTURE_DIR)).toBe(
      '79faf3127e06801d57f70e87b2ffd86871add4ecea7b483082a0de80c0290384',
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

  test('required producer observation inventory cannot shrink or pass vacuously', () => {
    expect(
      REQUIRED_PRODUCER_OBSERVATIONS.map(
        (entry) =>
          `${entry.file}:${entry.target.name}:${entry.observations.map(({ report, field, minimum }) => `${report}.${field}>=${minimum}`).join(',')}`,
      ),
    ).toEqual([
      '4819-generator-state-observation.mjs:es5:exact.generated_bindings>=1,exact.generated_references>=1,strict.marked_synthetic>=1',
      '4819-for-in-loop-capture.mjs:es5:exact.generated_bindings>=1,exact.generated_references>=1,strict.marked_synthetic>=1',
      '4819-private-generator.mjs:es5:exact.generated_bindings>=1,exact.generated_references>=1,strict.marked_synthetic>=1',
      '4801-static-field-arrow-this-observation.mjs:es5:exact.generated_bindings>=1,exact.generated_references>=9,strict.marked_synthetic>=1',
      '4819-import-equals-producer-observation.ts:es5:exact.generated_bindings>=1',
      '4819-namespace-iife-params.ts:es5:exact.namespace_iife_params>=1,exact.generated_references>=1',
      '4819-enum-iife-params.ts:es5:exact.enum_iife_params>=1',
    ]);
    expect(
      new Set(REQUIRED_PRODUCER_OBSERVATIONS.map((entry) => `${entry.file}:${entry.target.name}`))
        .size,
    ).toBe(REQUIRED_PRODUCER_OBSERVATIONS.length);

    const outDir = mkdtempSync(join(tmpdir(), 'zntc-required-producer-observations-'));
    let runs = 0;
    try {
      for (const entry of REQUIRED_PRODUCER_OBSERVATIONS) {
        const file = join(FIXTURE_DIR, entry.file);
        expect(
          fixtures,
          `required producer fixture ${entry.file} must stay in the oracle`,
        ).toContain(file);
        const reference = runFixtureReference(file, outDir);
        expect(reference.status, entry.file + ' reference: ' + reference.stderr).toBe(0);
        expect(reference.stdout, entry.file + ' reference output').toBe(entry.expectedStdout);
        for (const minifyIdentifiers of [false, true]) {
          const label = `${entry.file} ${entry.target.name}${minifyIdentifiers ? ' identifier-minified' : ''}`;
          const { stderr, exitCode } = runCoverage(file, entry.target, outDir, minifyIdentifiers);
          expect(exitCode, `${label}: ${stderr}`).toBe(0);
          expect(transformIdentityAuditProblems(stderr), `${label}: ${stderr}`).toEqual([]);

          const lines = stderr.split(/\r?\n/);
          const exact = lines.find((line) => line.startsWith('zntc: symbol-identity '));
          const strict = lines.find((line) => line.startsWith('zntc: synthetic-coverage '));
          expect(exact, `${label}: exact identity report missing`).toBeDefined();
          expect(exact, `${label}: exact report must identify its fixture`).toContain(entry.file);
          expect(strict, `${label}: strict identity report missing`).toBeDefined();
          const reports = { exact: exact ?? '', strict: strict ?? '' };
          expect(
            requiredProducerObservationProblems(reports, entry.observations),
            `${label}: required producer observations missing`,
          ).toEqual([]);

          // Negative control: erase each required positive observation from an
          // otherwise valid real report. The same gate used by the matrix must
          // reject a transform that silently stops producing that identity.
          for (const requirement of entry.observations) {
            const report = reports[requirement.report];
            const value = report.match(
              new RegExp(`(?:^| )${requirement.field}=(\\d+)(?=\\s|$)`),
            )?.[1];
            expect(value, `${label}: ${requirement.report}.${requirement.field}`).toBeDefined();
            const corruptedReport = report.replace(
              `${requirement.field}=${value}`,
              `${requirement.field}=0`,
            );
            expect(corruptedReport, `${label}: ${requirement.field} negative control`).not.toBe(
              report,
            );
            const corruptedReports = { ...reports, [requirement.report]: corruptedReport };
            expect(
              requiredProducerObservationProblems(corruptedReports, [requirement]),
              `${label}: ${requirement.field} negative control`,
            ).toContain(
              `${requirement.report}.${requirement.field}=0, required >=${requirement.minimum}`,
            );

            const duplicateReport = report.replace(
              `${requirement.field}=${value}`,
              `${requirement.field}=${value} ${requirement.field}=${value}`,
            );
            expect(
              requiredProducerObservationProblems(
                { ...reports, [requirement.report]: duplicateReport },
                [requirement],
              ),
              `${label}: ${requirement.field} duplicate-field negative control`,
            ).toContain(`${requirement.report}.${requirement.field} observations=2, expected 1`);

            const unsafeReport = report.replace(
              `${requirement.field}=${value}`,
              `${requirement.field}=9007199254740992`,
            );
            expect(
              requiredProducerObservationProblems(
                { ...reports, [requirement.report]: unsafeReport },
                [requirement],
              ),
              `${label}: ${requirement.field} unsafe-integer negative control`,
            ).toContain(`${requirement.report}.${requirement.field} is not a safe integer`);
          }

          if (minifyIdentifiers) {
            expect(postMinifyAuditProblems(stderr), `${label}: post-minify audit`).toEqual([]);
          }
          const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
          expect(actual.status, label + ': ' + actual.stderr).toBe(0);
          expect(actual.stdout, label + ' runtime output').toBe(reference.stdout);
          runs += 1;
        }
        if (entry.file === '4801-static-field-arrow-this-observation.mjs') {
          // Removing only the captured class-this expression leaves a clean
          // generic report, but drops this fixture's reference count from 9 to 8.
          const source = readFileSync(file, 'utf8');
          const withoutCapture = source.replace('() => this.count', '() => 7');
          expect(withoutCapture).not.toBe(source);
          const mutantFile = join(outDir, 'static-field-arrow-without-capture.mjs');
          writeFileSync(mutantFile, withoutCapture);
          const mutant = runCoverage(mutantFile, entry.target, outDir);
          expect(mutant.exitCode, mutant.stderr).toBe(0);
          expect(transformIdentityAuditProblems(mutant.stderr), mutant.stderr).toEqual([]);
          const mutantLines = mutant.stderr.split(/\r?\n/);
          const mutantExact = mutantLines.find((line) => line.startsWith('zntc: symbol-identity '));
          const mutantStrict = mutantLines.find((line) =>
            line.startsWith('zntc: synthetic-coverage '),
          );
          expect(mutantExact, mutant.stderr).toBeDefined();
          expect(mutantStrict, mutant.stderr).toBeDefined();
          expect(
            requiredProducerObservationProblems(
              { exact: mutantExact ?? '', strict: mutantStrict ?? '' },
              entry.observations,
            ),
          ).toContain('exact.generated_references=8, required >=9');
        }
      }
      expect(runs).toBe(REQUIRED_PRODUCER_OBSERVATIONS.length * 2);
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('필수 `_loop` 바인딩 목록은 exact 심볼·스코프와 실행 결과를 유지한다', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-loop-identity-'));
    try {
      for (const entry of LOOP_BINDING_MANIFEST) {
        const file = join(FIXTURE_DIR, entry.file);
        expect(fixtures, `required loop fixture ${entry.file} must stay in the oracle`).toContain(
          file,
        );

        const { stderr, exitCode } = runCoverage(file, entry.target, outDir);
        expect(exitCode, `${entry.file} ${entry.target.name}: ${stderr}`).toBe(0);
        expect(transformIdentityAuditProblems(stderr), `${entry.file}: ${stderr}`).toEqual([]);

        const identity = stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, stderr).toMatch(/generated_bindings=[1-9]\d*/);
        expect(identity).toMatch(/binding_scope_mismatch=0(?:\s|$)/);
        expect(identity).toMatch(/reference_scope_mismatch=0(?:\s|$)/);

        const output = join(outDir, 'out.js');
        const code = readFileSync(output, 'utf8');
        const emittedBindings = Array.from(
          code.matchAll(/\b(_loop\d*)\s*=\s*function\b/g),
          (match) => match[1],
        );
        expect(emittedBindings, `${entry.file} emitted loop binding list`).toEqual([
          ...entry.emittedBindings,
        ]);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(entry.stdout);
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
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

  test('ES5 computed auto-accessor keys keep exact identity through minification', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-computed-auto-accessor-symbol-'));
    const file = join(dir, 'input.ts');
    const outDir = join(dir, 'out');
    mkdirSync(outDir);
    const source = [
      'const _acc_key_0 = "source";',
      'let keyEvaluations = 0;',
      'function makeInstanceKey() { keyEvaluations++; return "instanceValue"; }',
      'function makeStaticKey() { keyEvaluations++; return "staticValue"; }',
      'class ComputedAccessor {',
      '  accessor [makeInstanceKey()] = 5;',
      '  static accessor [makeStaticKey()] = 7;',
      '  write(value: number) { this["instanceValue"] = value; return this["instanceValue"]; }',
      '}',
      'console.log(new ComputedAccessor().write(11), ComputedAccessor["staticValue"], keyEvaluations, _acc_key_0);',
    ].join('\n');
    try {
      writeFileSync(file, source);
      const baselineCode = ts.transpileModule(source, {
        compilerOptions: { target: ts.ScriptTarget.ES2022 },
      }).outputText;
      const baselineFile = join(dir, 'baseline.js');
      writeFileSync(baselineFile, baselineCode);
      const baseline = spawnSync('node', [baselineFile], { encoding: 'utf8' });
      expect(baseline.status, baseline.stderr).toBe(0);

      const { stderr, exitCode } = runCoverage(file, TARGETS[0], outDir, true);
      expect(exitCode, stderr).toBe(0);
      const exact = stderr.split(/\r?\n/).find((line) => line.startsWith('zntc: symbol-identity '));
      expect(exact, stderr).toBeDefined();
      expect(exactSchemaProblems(exact ?? ''), stderr).toEqual([]);
      expect(exact, stderr).toMatch(/clean=1(?:\s|$)/);
      expect(postMinifyAuditProblems(stderr), stderr).toEqual([]);

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
      `legacy_debt_fingerprint=${EXACT_NO_DEBT_FINGERPRINT}`,
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
    expect(
      exactSchemaProblems(
        complete.replace(
          `legacy_debt_fingerprint=${EXACT_NO_DEBT_FINGERPRINT}`,
          'legacy_debt_fingerprint=0123456789abcdef',
        ),
      ),
    ).toContain('legacy_debt_fingerprint=0123456789abcdef, expected ' + EXACT_NO_DEBT_FINGERPRINT);
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
    const emptyIdentityObservations = complete
      .replace('generated_bindings=1', 'generated_bindings=0')
      .replace('generated_references=2', 'generated_references=0')
      .replace('external=3', 'external=0')
      .replace('declaration_anchors_checked=4', 'declaration_anchors_checked=0')
      .replace('namespace_iife_params=4', 'namespace_iife_params=0')
      .replace('enum_iife_params=5', 'enum_iife_params=0');
    expect(exactIdentityObservationProblems(complete)).toEqual([]);
    expect(exactIdentityObservationProblems(emptyIdentityObservations)).toContain(
      'exact identity audit checked no binding or reference observations',
    );
    const oversizedObservation = '9'.repeat(400);
    expect(
      exactIdentityObservationProblems(
        complete.replace('external=3', `external=${oversizedObservation}`),
      ),
    ).toContain(`malformed exact identity observation external=${oversizedObservation}`);
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
      `strict_status_count=${STRICT_STATUS_COUNT}`,
      `strict_status_fingerprint=${STRICT_STATUS_SCHEMA_FINGERPRINT}`,
    ].join(' ');
    const report = `zntc: synthetic-coverage fixture.mjs: ${complete}`;

    expect(strictSchemaProblems(report)).toEqual([]);
    expect(
      strictSchemaProblems(
        report.replace(
          STRICT_STATUS_SCHEMA_FINGERPRINT,
          STRICT_STATUS_SCHEMA_FINGERPRINT.toUpperCase(),
        ),
      ),
    ).toEqual([]);
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
    expect(strictSchemaProblems(report.replace(' strict_status_count=14', ''))).toContain(
      'strict_status_count occurrences=0, expected 1',
    );
    expect(
      strictSchemaProblems(report.replace(' strict_status_count=14', ' strict_status_count=15')),
    ).toContain('strict_status_count=15, expected ' + STRICT_STATUS_COUNT);
    expect(
      strictSchemaProblems(
        report.replace(
          ` strict_status_fingerprint=${STRICT_STATUS_SCHEMA_FINGERPRINT}`,
          ' strict_status_fingerprint=0000000000000001',
        ),
      ),
    ).toContain(
      'strict_status_fingerprint=0000000000000001, expected ' + STRICT_STATUS_SCHEMA_FINGERPRINT,
    );
    expect(
      strictSchemaProblems(
        report.replace(
          ` strict_status_fingerprint=${STRICT_STATUS_SCHEMA_FINGERPRINT}`,
          ' strict_status_fingerprint=not-a-hash',
        ),
      ),
    ).toContain('malformed strict report value strict_status_fingerprint=not-a-hash');
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
    const emptyObservationReport = report
      .replace('bindings=1', 'bindings=0')
      .replace('references=1', 'references=0');
    expect(postMinifySchemaProblems(emptyObservationReport)).toContain(
      'post-minify audit checked no binding or reference nodes',
    );
    expect(postMinifyAuditProblems(emptyObservationReport)).toContain(
      'post-minify audit checked no binding or reference nodes',
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

  test('dropping debugger retains the exact graph while console dropping reanalyzes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-drop-debugger-retained-graph-'));
    const input = join(dir, 'entry.ts');
    const retainedOutput = join(dir, 'retained.cjs');
    const reanalyzedOutput = join(dir, 'reanalyzed.cjs');
    writeFileSync(
      input,
      [
        'const base = 40;',
        'function addTwo(value: number) {',
        '  const result = value + 2;',
        '  return result;',
        '}',
        'debugger;',
        'console.log(addTwo(base));',
      ].join('\n'),
    );
    const bundle = (output: string, extraFlags: string[] = []) =>
      spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--platform=node', '--format=cjs', ...extraFlags, '-o', output],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    try {
      const retained = bundle(retainedOutput, ['--drop=debugger']);
      expect(retained.status, retained.stderr).toBe(0);
      const retainedLines = (retained.stderr ?? '').split(/\r?\n/);
      const retainedScopeAudits = retainedLines.filter((line) =>
        line.startsWith('zntc: symbol-source-scope-owner '),
      );
      expect(retainedScopeAudits, retained.stderr).toHaveLength(1);
      expect(scopeOwnerAuditProblems(retainedScopeAudits[0]), retained.stderr).toEqual([]);
      const retainedReports = retainedLines.filter((line) =>
        line.startsWith('zntc: symbol-identity-prepass '),
      );
      expect(retainedReports, retained.stderr).toHaveLength(1);
      expect(exactSchemaProblems(retainedReports[0]), retained.stderr).toEqual([]);
      const retainedMode = retainedLines.find((line) =>
        line.startsWith('zntc: symbol-identity-prepass-mode '),
      );
      expect(retainedMode, retained.stderr).toContain('semantic_graph=retained');
      const retainedCode = readFileSync(retainedOutput, 'utf8');
      expect(retainedCode).not.toContain('debugger;');
      const retainedRun = spawnSync('node', [retainedOutput], { encoding: 'utf8' });
      expect(retainedRun.status, retainedRun.stderr).toBe(0);
      expect(retainedRun.stdout).toBe('42\n');

      const reanalyzed = bundle(reanalyzedOutput, ['--drop=debugger', '--drop=console']);
      expect(reanalyzed.status, reanalyzed.stderr).toBe(0);
      const reanalyzedLines = (reanalyzed.stderr ?? '').split(/\r?\n/);
      const reanalyzedScopeAudits = reanalyzedLines.filter((line) =>
        line.startsWith('zntc: symbol-source-scope-owner '),
      );
      expect(reanalyzedScopeAudits, reanalyzed.stderr).toHaveLength(1);
      expect(scopeOwnerAuditProblems(reanalyzedScopeAudits[0]), reanalyzed.stderr).toEqual([]);
      const reanalyzedReports = reanalyzedLines.filter((line) =>
        line.startsWith('zntc: symbol-identity-prepass '),
      );
      expect(reanalyzedReports, reanalyzed.stderr).toHaveLength(1);
      expect(exactSchemaProblems(reanalyzedReports[0]), reanalyzed.stderr).toEqual([]);
      const reanalyzedMode = reanalyzedLines.find((line) =>
        line.startsWith('zntc: symbol-identity-prepass-mode '),
      );
      expect(reanalyzedMode, reanalyzed.stderr).toContain('semantic_graph=reanalyzed');
      const reanalyzedCode = readFileSync(reanalyzedOutput, 'utf8');
      expect(reanalyzedCode).not.toContain('debugger;');
      const reanalyzedRun = spawnSync('node', [reanalyzedOutput], { encoding: 'utf8' });
      expect(reanalyzedRun.status, reanalyzedRun.stderr).toBe(0);
      expect(reanalyzedRun.stdout).toBe('');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('unmatched dropped labels skip the pre-pass while matched labels reanalyze', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-unmatched-drop-label-retained-graph-'));
    const input = join(dir, 'entry.ts');
    const retainedOutput = join(dir, 'retained.cjs');
    const reanalyzedOutput = join(dir, 'reanalyzed.cjs');
    writeFileSync(
      input,
      [
        'const base = 40;',
        'function addTwo(value: number) {',
        '  const result = value + 2;',
        '  return result;',
        '}',
        'DEV: {',
        '  const discarded = base + 1;',
        '  console.log(discarded);',
        '}',
        'console.log(addTwo(base));',
      ].join('\n'),
    );
    const bundle = (output: string, label: string) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--platform=node',
          '--format=cjs',
          `--drop-labels=${label}`,
          '-o',
          output,
        ],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    const expectPrepass = (stderr: string, graph: 'skipped' | 'reanalyzed') => {
      const lines = stderr.split(/\r?\n/);
      const scopeAudits = lines.filter((line) =>
        line.startsWith('zntc: symbol-source-scope-owner '),
      );
      const reports = lines.filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      const mode = lines.find((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      if (graph === 'skipped') {
        expect(scopeAudits, stderr).toHaveLength(0);
        expect(reports, stderr).toHaveLength(0);
        expect(mode, stderr).toBeUndefined();
        return;
      }

      expect(scopeAudits, stderr).toHaveLength(1);
      expect(scopeOwnerAuditProblems(scopeAudits[0]), stderr).toEqual([]);
      expect(reports, stderr).toHaveLength(1);
      expect(exactSchemaProblems(reports[0]), stderr).toEqual([]);
      expect(mode, stderr).toContain(`semantic_graph=${graph}`);
    };
    try {
      const retained = bundle(retainedOutput, 'TEST');
      expect(retained.status, retained.stderr).toBe(0);
      expectPrepass(retained.stderr ?? '', 'skipped');
      const retainedRun = spawnSync('node', [retainedOutput], { encoding: 'utf8' });
      expect(retainedRun.status, retainedRun.stderr).toBe(0);
      expect(retainedRun.stdout).toBe('41\n42\n');

      const reanalyzed = bundle(reanalyzedOutput, 'DEV');
      expect(reanalyzed.status, reanalyzed.stderr).toBe(0);
      expectPrepass(reanalyzed.stderr ?? '', 'reanalyzed');
      const reanalyzedRun = spawnSync('node', [reanalyzedOutput], { encoding: 'utf8' });
      expect(reanalyzedRun.status, reanalyzedRun.stderr).toBe(0);
      expect(reanalyzedRun.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('drop-console skips the pre-pass without a console call and reanalyzes when one is removed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-no-console-drop-retained-graph-'));
    const input = join(dir, 'entry.ts');
    const retainedOutput = join(dir, 'retained.cjs');
    const reanalyzedOutput = join(dir, 'reanalyzed.cjs');
    const source = [
      'const base = 40;',
      'function addTwo(value: number) {',
      '  const result = value + 2;',
      '  return result;',
      '}',
    ];
    const bundle = (output: string) =>
      spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--platform=node', '--format=cjs', '--drop=console', '-o', output],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    const expectPrepass = (stderr: string, graph: 'retained' | 'reanalyzed') => {
      const lines = stderr.split(/\r?\n/);
      const scopeAudits = lines.filter((line) =>
        line.startsWith('zntc: symbol-source-scope-owner '),
      );
      expect(scopeAudits, stderr).toHaveLength(1);
      expect(scopeOwnerAuditProblems(scopeAudits[0]), stderr).toEqual([]);
      const reports = lines.filter((line) => line.startsWith('zntc: symbol-identity-prepass '));
      expect(reports, stderr).toHaveLength(1);
      expect(exactSchemaProblems(reports[0]), stderr).toEqual([]);
      const mode = lines.find((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
      expect(mode, stderr).toContain(`semantic_graph=${graph}`);
    };
    try {
      writeFileSync(
        input,
        [...source, 'process.stdout.write(String(addTwo(base)) + "\\n");'].join('\n'),
      );
      const retained = bundle(retainedOutput);
      expect(retained.status, retained.stderr).toBe(0);
      // Without a console call there is nothing to drop, so the graph
      // pre-pass is skipped entirely and reports nothing (#5795).
      const retainedLines = (retained.stderr ?? '').split(/\r?\n/);
      expect(
        retainedLines.filter(
          (line) =>
            line.startsWith('zntc: symbol-source-scope-owner ') ||
            line.startsWith('zntc: symbol-identity-prepass'),
        ),
        retained.stderr,
      ).toEqual([]);
      const retainedRun = spawnSync('node', [retainedOutput], { encoding: 'utf8' });
      expect(retainedRun.status, retainedRun.stderr).toBe(0);
      expect(retainedRun.stdout).toBe('42\n');

      writeFileSync(input, [...source, 'console.log(addTwo(base));'].join('\n'));
      const reanalyzed = bundle(reanalyzedOutput);
      expect(reanalyzed.status, reanalyzed.stderr).toBe(0);
      expectPrepass(reanalyzed.stderr ?? '', 'reanalyzed');
      const reanalyzedRun = spawnSync('node', [reanalyzedOutput], { encoding: 'utf8' });
      expect(reanalyzedRun.status, reanalyzedRun.stderr).toBe(0);
      expect(reanalyzedRun.stdout).toBe('');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  for (const minifyIdentifiers of [false, true]) {
    test(`Stage 3 decorator-only lowering retains its exact prepass graph${minifyIdentifiers ? ' with identifier minification' : ''}`, () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-stage3-retained-graph-'));
      const input = join(dir, 'entry.ts');
      const output = join(dir, 'out.cjs');
      writeFileSync(
        input,
        [
          'const _metadata = 17, _classThis = 19;',
          'function classTag(value, context) { value.tag = context.kind; return value; }',
          [
            'function tweak(value, context) {',
            "  if (context.kind === 'field') return initial => initial + 1;",
            "  if (context.kind === 'method') return function() { return value.call(this) + 1; };",
            "  if (context.kind === 'accessor') return { get() { return value.get.call(this) + 1; }, set(v) { value.set.call(this, v); }, init(v) { return v + 1; } };",
            '  return value;',
            '}',
          ].join('\n'),
          '@classTag class Example {',
          '  @tweak field = 40;',
          '  @tweak method() { return this.field; }',
          '  @tweak accessor count = 1;',
          '  @tweak static staticValue = 8;',
          '}',
          '@classTag class Other {}',
          'console.log(Example.tag, Other.tag, new Example().method(), new Example().count, Example.staticValue, _metadata, _classThis);',
        ].join('\n'),
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
            ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
            '-o',
            output,
          ],
          {
            cwd: dir,
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(proc.status, proc.stderr).toBe(0);

        const stderr = proc.stderr ?? '';
        const modes = stderr
          .split(/\r?\n/)
          .filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts:'),
          );
        expect(modes, stderr).toHaveLength(1);
        expect(modes[0]).toContain('semantic_graph=retained');

        const reports = stderr
          .split(/\r?\n/)
          .filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts:'),
          );
        expect(reports, stderr).toHaveLength(1);
        expect(exactSchemaProblems(reports[0])).toEqual([]);
        expect(Number(reports[0].match(/generated_bindings=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);
        expect(Number(reports[0].match(/generated_references=(\d+)/)?.[1] ?? 0)).toBeGreaterThan(0);

        const owners = stderr
          .split(/\r?\n/)
          .filter(
            (line) =>
              line.startsWith('zntc: symbol-source-scope-owner ') && line.includes('entry.ts:'),
          );
        expect(owners, stderr).toHaveLength(1);
        expect(scopeOwnerAuditProblems(owners[0])).toEqual([]);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe('class class 42 3 9 17 19\n');
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });
  }

  test('Stage 3 decorator graph retention keeps downlevel, direct-eval, and legacy cases on reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-stage3-retained-negative-'));
    const input = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    const stage3Source = [
      'function mark(value, context) { return value; }',
      '@mark class Example { @mark method() { return 42; } }',
      'console.log(new Example().method());',
    ].join('\n');
    const cases = [
      { name: 'ES5 class lowering', args: ['--target=es5'], source: stage3Source },
      {
        name: 'syntax minification',
        args: ['--target=esnext', '--minify-syntax'],
        source: stage3Source,
      },
      {
        name: 'direct eval',
        args: ['--target=esnext'],
        source: [
          'function observe() { return eval("typeof _classThis"); }',
          ...stage3Source.split('\n'),
          'console.log(observe());',
        ].join('\n'),
      },
      {
        name: 'legacy decorators',
        args: ['--target=esnext', '--experimental-decorators'],
        source: stage3Source,
      },
    ];

    try {
      for (const fixture of cases) {
        writeFileSync(input, fixture.source);
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.ts',
            ...fixture.args,
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
        expect(proc.status, `${fixture.name}: ${proc.stderr}`).toBe(0);
        const modes = (proc.stderr ?? '')
          .split(/\r?\n/)
          .filter((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
        const sourceMode = modes.find((line) => line.includes('entry.ts'));
        expect(sourceMode, `${fixture.name}: ${proc.stderr}`).toBeDefined();
        expect(sourceMode, fixture.name).toContain('semantic_graph=reanalyzed');
      }
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

  test('ES5 optional, nullish, and logical-assign lowering enter exact identity prepass', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-operator-symbol-prepass-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'var calls = 0;',
        'function makeNullish() { calls += 1; return null; }',
        'function readOptional() { return makeNullish()?.value; }',
        'var maybeCallable = null;',
        'function readOptionalCall() { return maybeCallable?.(); }',
        'function readNullish() { return makeNullish() ?? 42; }',
        'var box = { value: 0 };',
        'function getBox() { calls += 1; return box; }',
        'function getKey() { calls += 1; return "value"; }',
        'function writeLogical() { return getBox()[getKey()] ||= 7; }',
        'console.log(readOptional(), readOptionalCall(), readNullish(), writeLogical(), calls);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', 'entry.mjs', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
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
      expect(actual.stdout).toBe('undefined undefined 42 7 4\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES2018 optional catch binding lowering enters exact identity prepass', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-catch-symbol-prepass-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function run() {',
        '  try { throw "e"; } catch { return 42; }',
        '}',
        'console.log(run());',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es2018',
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
      expect(actual.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES2017 object spread identity keeps generated Object.assign global from source shadowing', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-object-spread-symbol-prepass-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'var Object = { assign: function () { throw new Error("source Object was observed"); } };',
        'var source = { value: 42 };',
        'var copy = { ...source };',
        'console.log(copy.value);',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          'entry.mjs',
          '--target=es2017',
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
      expect(proc.stderr).toContain('semantic_graph=reanalyzed');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');

      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
        );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS.filter(
        (name) => name !== 'shadowed_external_reference',
      )) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/shadowed_external_reference=1(?:\s|$)/);
      expect(report).toMatch(/clean=0(?:\s|$)/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('object spread retains the graph when Object is bound only in an unrelated function', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-object-spread-unrelated-object-symbol-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function readLocalObject() {',
        '  var Object = { value: "local" };',
        '  return Object.value;',
        '}',
        'var source = { value: 42 };',
        'var copy = { ...source };',
        'console.log(copy.value, readLocalObject());',
      ].join('\n'),
    );
    try {
      const cases = [
        { label: 'ES5', target: '--target=es5' },
        { label: 'ES2017', target: '--target=es2017' },
        { label: 'ES5 identifier minify', target: '--target=es5', minify: true },
      ];
      for (const { label, target, minify = false } of cases) {
        const proc = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'entry.mjs',
            target,
            ...(minify ? ['--minify-identifiers'] : []),
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
        expect(proc.status, `${label}: ${proc.stderr}`).toBe(0);
        expect(proc.stderr, label).toContain('semantic_graph=retained');

        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
          );
        expect(report, `${label}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${label}: ${report}`,
          ).toBe(0);
        }
        expect(report, label).toMatch(/clean=1(?:\s|$)/);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${label}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, label).toBe('42 local\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('non-minified ES5 arrow captures still receive exact bundler SymbolIds', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-capture-symbols-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function captured(_this) { return (() => this.value)(); }',
        'console.log(captured.call({ value: 42 }, 7));',
      ].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', 'entry.mjs', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
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

  test('ES5 named-function new.target alone triggers exact identity prepass', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-named-new-target-prepass-'));
    const input = join(dir, 'entry.mjs');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      input,
      ['function Plain() { return new.target; }', 'console.log(new Plain() === Plain);'].join('\n'),
    );
    try {
      const proc = spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--target=es5', '--platform=node', '--format=cjs', '-o', output],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const lines = (proc.stderr ?? '').split(/\r?\n/);
      const report = lines.find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
      );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/generated_references=1(?:\s|$)/);
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const graphMode = lines.find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
      );
      expect(graphMode, proc.stderr).toContain('semantic_graph=retained');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('true\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('es5 new.target lowering retains the exact graph only without dynamic eval', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-arrow-new-target-retained-'));
    const runAndCheck = (
      entry: string,
      source: string,
      expectedGraph: 'retained' | 'reanalyzed',
      expectedStdout: string,
    ) => {
      const output = join(dir, entry.replace(/\.mjs$/, '.cjs'));
      writeFileSync(join(dir, entry), source);
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
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const graphMode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(entry),
        );
      expect(graphMode, proc.stderr).toContain(`semantic_graph=${expectedGraph}`);
      const report = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes(entry));
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(expectedStdout);
    };
    try {
      runAndCheck(
        'entry.mjs',
        [
          'function Plain() { return new.target; }',
          'function Foo() { return () => new.target; }',
          'function Bar() { return () => new.target; }',
          'console.log(new Plain() === Plain, new Foo()() === Foo, new Bar()() === Bar);',
        ].join('\n'),
        'retained',
        'true true true\n',
      );
      runAndCheck(
        'dynamic.mjs',
        [
          "function Foo() { eval(''); return () => new.target; }",
          'console.log(new Foo()() === Foo);',
        ].join('\n'),
        'reanalyzed',
        'true\n',
      );
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
      expect(proc.stderr).not.toContain(
        'non-literal direct eval argument can observe generated capture bindings',
      );

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

  test('dynamic direct eval cannot observe generated new.target capture names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-rn-param-new-target-dynamic-eval-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(
      join(dir, 'entry.mjs'),
      [
        'function Foo(_newTarget = 11, value = () => () => [new.target, eval("typeof _newTarget" + "2")]) {',
        '  const captured = value()();',
        '  console.log(captured[0] === Foo, captured[1]);',
        '}',
        'function Escaped(_newTarget = 12, value = () => () => { function read() { return ev\\u0061l("typeof _newTarget" + "2"); } return [new.target, read()]; }) {',
        '  const captured = value()();',
        '  console.log(captured[0] === Escaped, captured[1]);',
        '}',
        'function Parenthesized(_newTarget = 13, value = () => () => [new.target, (eval)("typeof _newTarget" + "2")]) {',
        '  const captured = value()();',
        '  console.log(captured[0] === Parenthesized, captured[1]);',
        '}',
        'new Foo();',
        'new Escaped();',
        'new Parenthesized();',
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
        expect(Number(report?.match(new RegExp(counter + '=(\\d+)'))?.[1] ?? -1), report).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);

      const code = readFileSync(output, 'utf8');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('true undefined\ntrue undefined\ntrue undefined\n');
      expect(code).toContain('=>');
      expect(proc.stderr).toContain(
        'non-literal direct eval argument can observe generated capture bindings',
      );

      const transpileOutput = join(dir, 'transpiled.cjs');
      const transpile = spawnSync(
        ZNTC_BIN,
        [
          'entry.mjs',
          '--target=es5',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          transpileOutput,
        ],
        { cwd: dir, encoding: 'utf8' },
      );
      expect(transpile.status, transpile.stderr).toBe(0);
      expect(transpile.stderr).toContain(
        'non-literal direct eval argument can observe generated capture bindings',
      );
      const transpiled = spawnSync('node', [transpileOutput], { encoding: 'utf8' });
      expect(transpiled.status, transpiled.stderr).toBe(0);
      expect(transpiled.stdout).toBe('true undefined\ntrue undefined\ntrue undefined\n');
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
        name: 'optional member call on an unresolved global keeps one receiver read and exact this',
        graph: 'retained',
        source: [
          'var order = []; var receiver = { base: 37, method: function (value) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + value; } };',
          'Object.defineProperty(globalThis, "__zntcOptionalGlobalReceiver", { configurable: true, get() { order.push("root"); return receiver; } });',
          'Object.defineProperty(globalThis, "__zntcMissingOptionalGlobalReceiver", { configurable: true, get() { order.push("missing"); return null; } });',
          'function argument() { order.push("argument"); return 5; }',
          'function read() { return __zntcOptionalGlobalReceiver?.method(argument()); }',
          'function readMissing() { return __zntcMissingOptionalGlobalReceiver?.method(argument()); }',
          'console.log(read(), readMissing(), order.join(","));',
        ].join('\n'),
        output: '42 undefined root,argument,this,missing\n',
      },
      {
        name: 'optional invocation on an unresolved optional member stays on semantic reanalysis',
        graph: 'reanalyzed',
        source: [
          'var order = []; var receiver = { base: 2, method: function (value) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + value; } };',
          'Object.defineProperty(globalThis, "__zntcOptionalInvocationReceiver", { configurable: true, get() { order.push("root"); return receiver; } });',
          'function argument() { order.push("argument"); return 5; }',
          'function read() { return __zntcOptionalInvocationReceiver?.method?.(argument()); }',
          'console.log(read(), order.join(","));',
        ].join('\n'),
        output: '7 root,argument,this\n',
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
        name: 'unresolved direct optional call outside static initializers stays on semantic reanalysis',
        graph: 'reanalyzed',
        source: [
          'globalThis.__zntcUnresolvedOptionalCallOutside = function () { return 42; };',
          'function read() { return __zntcUnresolvedOptionalCallOutside?.(); }',
          'console.log(read());',
        ].join('\n'),
        output: '42\n',
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

  test('ES5 async class methods retain state-machine, home, and inherited static graphs', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-async-class-method-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    const compilerStdout = join(dir, 'compiler.stdout');
    const compilerStderr = join(dir, 'compiler.stderr');
    const runtimeStdout = join(dir, 'runtime.stdout');
    const runtimeStderr = join(dir, 'runtime.stderr');
    const run = (source: string) => {
      writeFileSync(input, source);
      const proc = spawnSync(
        '/bin/sh',
        [
          '-c',
          'export ZNTC_DEBUG_SYMBOL_COVERAGE=1; stderr_path=$1; stdout_path=$2; shift 2; "$@" >"$stdout_path" 2>"$stderr_path"',
          'zntc-class-super-coverage',
          compilerStderr,
          compilerStdout,
          ZNTC_BIN,
          '--bundle',
          input,
          '--target=es5',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '-o',
          output,
        ],
        { cwd: dir, encoding: 'utf8' },
      );
      return {
        status: proc.status,
        stderr: readFileSync(compilerStderr, 'utf8') + (proc.stderr ?? ''),
      };
    };
    const runOutput = () => {
      const proc = spawnSync(
        '/bin/sh',
        [
          '-c',
          'stdout_path=$1; stderr_path=$2; shift 2; "$@" >"$stdout_path" 2>"$stderr_path"',
          'zntc-class-super-runtime',
          runtimeStdout,
          runtimeStderr,
          'node',
          output,
        ],
        { cwd: dir, encoding: 'utf8' },
      );
      return {
        status: proc.status,
        stdout: readFileSync(runtimeStdout, 'utf8') + (proc.stdout ?? ''),
        stderr: readFileSync(runtimeStderr, 'utf8') + (proc.stderr ?? ''),
      };
    };
    const expectRetainedClean = (stderr: string) => {
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, stderr).toContain('semantic_graph=retained');
      const report = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(report, stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${report}`,
        ).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
    };
    const expectReanalyzedOutput = (
      result: { status: number | null; stderr: string },
      expected: string,
    ) => {
      expect(result.status, result.stderr).toBe(0);
      const mode = result.stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, result.stderr).toContain('semantic_graph=reanalyzed');
      const actual = runOutput();
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(expected);
    };

    try {
      const retained = run(
        [
          'var service;',
          'class Service {',
          '  async calculate(value) {',
          '    var _state = 1, _context = 1, _arguments = arguments[0];',
          '    await Promise.resolve(value);',
          '    return this === service ? value + _state + _context + _arguments : 0;',
          '  }',
          '}',
          'service = new Service();',
          'service.calculate(40).then(value => console.log(value));',
        ].join('\n'),
      );
      expect(retained.status, retained.stderr).toBe(0);
      const retainedMode = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(retainedMode, retained.stderr).toContain('semantic_graph=retained');
      const retainedReport = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(retainedReport, retained.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(retainedReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${retainedReport}`,
        ).toBe(0);
      }
      expect(retainedReport).toMatch(/clean=1(?:\s|$)/);
      const retainedOutput = runOutput();
      expect(retainedOutput.status, retainedOutput.stderr).toBe(0);
      expect(retainedOutput.stdout).toBe('82\n');

      // Direct eval can observe state-machine locals and stays on semantic resync.
      const directEval = run(
        [
          'class Service {',
          '  async calculate(value) {',
          '    await Promise.resolve();',
          "    return eval('value') + 1;",
          '  }',
          '}',
          'new Service().calculate(41).then(value => console.log(value));',
        ].join('\n'),
      );
      expect(directEval.status, directEval.stderr).toBe(0);
      const directEvalMode = (directEval.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(directEvalMode, directEval.stderr).toContain('semantic_graph=reanalyzed');
      const directEvalOutput = runOutput();
      expect(directEvalOutput.status, directEvalOutput.stderr).toBe(0);
      expect(directEvalOutput.stdout).toBe('42\n');

      // Direct async class-method super keeps the exact class home and helper graph.
      const classSuper = run(
        [
          'class Base {',
          '  get current() { return this.value; }',
          '  set current(value) { this.value = value; }',
          '}',
          'class Service extends Base {',
          '  async readWrite() {',
          '    await Promise.resolve();',
          '    var before = super.current;',
          '    var assigned = super.current = 50;',
          '    return [before, assigned, this.current].join(" ");',
          '  }',
          '}',
          'var service = new Service();',
          'service.value = 42;',
          'service.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(classSuper.status, classSuper.stderr).toBe(0);
      const classSuperMode = (classSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(classSuperMode, classSuper.stderr).toContain('semantic_graph=retained');
      const classSuperReport = (classSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(classSuperReport, classSuper.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(classSuperReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${classSuperReport}`,
        ).toBe(0);
      }
      expect(classSuperReport).toMatch(/clean=1(?:\s|$)/);
      const classSuperOutput = runOutput();
      expect(classSuperOutput.status, classSuperOutput.stderr).toBe(0);
      expect(classSuperOutput.stdout).toBe('42 50 50\n');

      // Static async state machines preserve an inherited call's receiver.
      const staticAsync = run(
        [
          'var receiver;',
          'class Service {',
          '  static async calculate(value) {',
          '    var _state = 1, _context = 1, _arguments = arguments[0];',
          '    await Promise.resolve(value);',
          '    return this === receiver ? value + _state + _context + _arguments : 0;',
          '  }',
          '}',
          'class Derived extends Service {}',
          'receiver = Derived;',
          'Derived.calculate(40).then(value => console.log(value));',
        ].join('\n'),
      );
      expect(staticAsync.status, staticAsync.stderr).toBe(0);
      const staticAsyncMode = (staticAsync.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(staticAsyncMode, staticAsync.stderr).toContain('semantic_graph=retained');
      const staticAsyncReport = (staticAsync.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(staticAsyncReport, staticAsync.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(staticAsyncReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${staticAsyncReport}`,
        ).toBe(0);
      }
      expect(staticAsyncReport).toMatch(/clean=1(?:\s|$)/);
      const staticAsyncOutput = runOutput();
      expect(staticAsyncOutput.status, staticAsyncOutput.stderr).toBe(0);
      expect(staticAsyncOutput.stdout).toBe('82\n');

      // A direct static async super access preserves the constructor home and receiver.
      const staticSuper = run(
        [
          'var receiver;',
          'class Base {',
          '  static get current() { return this.value; }',
          '  static set current(value) { receiver = this; this.value = value; }',
          '}',
          'class Service extends Base {',
          '  static async readWrite() {',
          '    await Promise.resolve();',
          '    var before = super.current;',
          '    var assigned = super.current = 50;',
          '    return [before, assigned, this === receiver, this.current].join(" ");',
          '  }',
          '}',
          'class Derived extends Service {}',
          'Derived.value = 42;',
          'Derived.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(staticSuper.status, staticSuper.stderr).toBe(0);
      const staticSuperMode = (staticSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(staticSuperMode, staticSuper.stderr).toContain('semantic_graph=retained');
      const staticSuperReport = (staticSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(staticSuperReport, staticSuper.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(staticSuperReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${staticSuperReport}`,
        ).toBe(0);
      }
      expect(staticSuperReport).toMatch(/clean=1(?:\s|$)/);
      const staticSuperOutput = runOutput();
      expect(staticSuperOutput.status, staticSuperOutput.stderr).toBe(0);
      expect(staticSuperOutput.stdout).toBe('42 50 true 50\n');

      // One synchronous arrow can keep static super on the exact constructor home graph.
      const staticNestedArrowSuper = run(
        [
          'var receiver;',
          'class Base {',
          '  static get current() { return this.value; }',
          '  static set current(value) { receiver = this; this.value = value; }',
          '}',
          'class Service extends Base {',
          '  static async readWrite() {',
          '    await Promise.resolve();',
          '    var readWrite = value => {',
          '      var before = super.current;',
          '      var assigned = super.current = value;',
          '      return [before, assigned, this === receiver, this.current].join(" ");',
          '    };',
          '    return readWrite(50);',
          '  }',
          '}',
          'class Derived extends Service {}',
          'Derived.value = 42;',
          'Derived.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(staticNestedArrowSuper.status, staticNestedArrowSuper.stderr).toBe(0);
      expectRetainedClean(staticNestedArrowSuper.stderr ?? '');
      const staticNestedArrowOutput = runOutput();
      expect(staticNestedArrowOutput.status, staticNestedArrowOutput.stderr).toBe(0);
      expect(staticNestedArrowOutput.stdout).toBe('42 50 true 50\n');

      // A synchronous static sibling with super keeps the whole class on reanalysis.
      const synchronousStaticSuper = run(
        [
          'class Base {',
          '  static get current() { return this.value; }',
          '}',
          'class Service extends Base {',
          '  static async readAsync() {',
          '    await Promise.resolve();',
          '    return 40;',
          '  }',
          '  static readSync() { return super.current; }',
          '}',
          'Service.value = 42;',
          'Service.readAsync().then(value => console.log(value, Service.readSync()));',
        ].join('\n'),
      );
      expect(synchronousStaticSuper.status, synchronousStaticSuper.stderr).toBe(0);
      const synchronousStaticMode = (synchronousStaticSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(synchronousStaticMode, synchronousStaticSuper.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      const synchronousStaticOutput = runOutput();
      expect(synchronousStaticOutput.status, synchronousStaticOutput.stderr).toBe(0);
      expect(synchronousStaticOutput.stdout).toBe('40 42\n');

      // A synchronous sibling with super keeps the whole class on reanalysis.
      const synchronousSuper = run(
        [
          'class Base {',
          '  get current() { return this.value; }',
          '}',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    return super.current;',
          '  }',
          '  readSync() { return super.current; }',
          '}',
          'var service = new Service();',
          'service.value = 42;',
          'service.readAsync().then(value => console.log(value, service.readSync()));',
        ].join('\n'),
      );
      expect(synchronousSuper.status, synchronousSuper.stderr).toBe(0);
      const synchronousSuperMode = (synchronousSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(synchronousSuperMode, synchronousSuper.stderr).toContain('semantic_graph=reanalyzed');
      const synchronousSuperOutput = runOutput();
      expect(synchronousSuperOutput.status, synchronousSuperOutput.stderr).toBe(0);
      expect(synchronousSuperOutput.stdout).toBe('42 42\n');

      // One synchronous arrow keeps instance super and its lexical receiver on the home graph.
      const nestedArrowSuper = run(
        [
          'var receiver;',
          'class Base {',
          '  get current() { return this.value; }',
          '  set current(value) { receiver = this; this.value = value; }',
          '}',
          'class Service extends Base {',
          '  async readWrite() {',
          '    await Promise.resolve();',
          '    var readWrite = value => {',
          '      var before = super.current;',
          '      var assigned = super.current = value;',
          '      return [before, assigned, this === receiver, this.current].join(" ");',
          '    };',
          '    return readWrite(50);',
          '  }',
          '}',
          'var service = new Service();',
          'service.value = 42;',
          'service.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(nestedArrowSuper.status, nestedArrowSuper.stderr).toBe(0);
      expectRetainedClean(nestedArrowSuper.stderr ?? '');
      const nestedArrowSuperOutput = runOutput();
      expect(nestedArrowSuperOutput.status, nestedArrowSuperOutput.stderr).toBe(0);
      expect(nestedArrowSuperOutput.stdout).toBe('42 50 true 50\n');

      // One async arrow keeps the class method's exact home graph after both
      // state-machine preflights pass.
      const asyncArrowSuper = run(
        [
          'var receiver;',
          'class Base {',
          '  get current() { return this.value; }',
          '  set current(value) { receiver = this; this.value = value; }',
          '}',
          'class Service extends Base {',
          '  async readWrite() {',
          '    await Promise.resolve();',
          '    var readWrite = async value => {',
          '      await Promise.resolve();',
          '      var before = super.current;',
          '      var assigned = super.current = value;',
          '      return [before, assigned, this === receiver, this.current].join(" ");',
          '    };',
          '    return await readWrite(50);',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(asyncArrowSuper.status, asyncArrowSuper.stderr).toBe(0);
      expectRetainedClean(asyncArrowSuper.stderr ?? '');
      const asyncArrowSuperOutput = runOutput();
      expect(asyncArrowSuperOutput.status, asyncArrowSuperOutput.stderr).toBe(0);
      expect(asyncArrowSuperOutput.stdout).toBe('42 50 true 50\n');

      // Static async-arrow super keeps the inherited constructor as receiver.
      const staticAsyncArrowSuper = run(
        [
          'var receiver;',
          'class Base {',
          '  static get current() { return this.value; }',
          '  static set current(value) { receiver = this; this.value = value; }',
          '}',
          'class Service extends Base {',
          '  static async readWrite() {',
          '    await Promise.resolve();',
          '    var readWrite = async value => {',
          '      await Promise.resolve();',
          '      var before = super.current;',
          '      var assigned = super.current = value;',
          '      return [before, assigned, this === receiver, this.current].join(" ");',
          '    };',
          '    return await readWrite(50);',
          '  }',
          '}',
          'class Derived extends Service {}',
          'Derived.value = 42;',
          'Derived.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(staticAsyncArrowSuper.status, staticAsyncArrowSuper.stderr).toBe(0);
      expectRetainedClean(staticAsyncArrowSuper.stderr ?? '');
      const staticAsyncArrowSuperOutput = runOutput();
      expect(staticAsyncArrowSuperOutput.status, staticAsyncArrowSuperOutput.stderr).toBe(0);
      expect(staticAsyncArrowSuperOutput.stdout).toBe('42 50 true 50\n');

      // Nested static async-arrow owners keep the inherited constructor home
      // for both property reads and writes.
      const nestedStaticAsyncArrowSuper = run(
        [
          'var receiver;',
          'class Base {',
          '  static get current() { return this.value; }',
          '  static set current(value) { receiver = this; this.value = value; }',
          '}',
          'class Service extends Base {',
          '  static async readWrite() {',
          '    await Promise.resolve();',
          '    var readWrite = async () => {',
          '      await Promise.resolve();',
          '      var read = async () => { await Promise.resolve(); return super.current; };',
          '      var write = async value => { await Promise.resolve(); return super.current = value; };',
          '      var before = await read();',
          '      var assigned = await write(50);',
          '      return [before, assigned, this === receiver, this.current].join(" ");',
          '    };',
          '    return await readWrite();',
          '  }',
          '}',
          'class Derived extends Service {}',
          'Derived.value = 42;',
          'Derived.readWrite().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(nestedStaticAsyncArrowSuper.status, nestedStaticAsyncArrowSuper.stderr).toBe(0);
      expectRetainedClean(nestedStaticAsyncArrowSuper.stderr ?? '');
      const nestedStaticAsyncArrowSuperOutput = runOutput();
      expect(
        nestedStaticAsyncArrowSuperOutput.status,
        nestedStaticAsyncArrowSuperOutput.stderr,
      ).toBe(0);
      expect(nestedStaticAsyncArrowSuperOutput.stdout).toBe('42 50 true 50\n');

      // Nested async-arrow calls keep the lexical instance and constructor
      // receivers for both instance and static class super methods.
      const nestedClassAsyncSuperCalls = run(
        [
          'var instanceReceiver;',
          'var constructorReceiver;',
          'class Base {',
          '  read() { return this === instanceReceiver ? this.value : 0; }',
          '  static read() { return this === constructorReceiver ? this.value : 0; }',
          '}',
          'class Service extends Base {',
          '  async readInstance() {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => { await Promise.resolve(); return super.read(); };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '  static async readStatic() {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => { await Promise.resolve(); return super.read(); };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class Derived extends Service {}',
          'var instance = new Service();',
          'instance.value = 42;',
          'instanceReceiver = instance;',
          'Derived.value = 84;',
          'constructorReceiver = Derived;',
          'Promise.all([instance.readInstance(), Derived.readStatic()]).then(values => console.log(values.join(" ")));',
        ].join('\n'),
      );
      expect(nestedClassAsyncSuperCalls.status, nestedClassAsyncSuperCalls.stderr).toBe(0);
      expectRetainedClean(nestedClassAsyncSuperCalls.stderr ?? '');
      const nestedClassAsyncSuperCallsOutput = runOutput();
      expect(nestedClassAsyncSuperCallsOutput.status, nestedClassAsyncSuperCallsOutput.stderr).toBe(
        0,
      );
      expect(nestedClassAsyncSuperCallsOutput.stdout).toBe('42 84\n');

      // Computed nested super calls evaluate the key once and keep the same
      // lexical instance or constructor receiver.
      const nestedComputedClassAsyncSuperCalls = run(
        [
          'var instanceReceiver;',
          'var constructorReceiver;',
          'var keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "read"; }',
          'class Base {',
          '  read() { return this === instanceReceiver ? this.value : 0; }',
          '  static read() { return this === constructorReceiver ? this.value : 0; }',
          '}',
          'class Service extends Base {',
          '  async readInstance() {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => { await Promise.resolve(); return super[getKey()](); };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '  static async readStatic() {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => { await Promise.resolve(); return super[getKey()](); };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class Derived extends Service {}',
          'var instance = new Service();',
          'instance.value = 42;',
          'instanceReceiver = instance;',
          'Derived.value = 84;',
          'constructorReceiver = Derived;',
          'Promise.all([instance.readInstance(), Derived.readStatic()]).then(values => console.log(values.join(" "), keyEvaluations));',
        ].join('\n'),
      );
      expect(
        nestedComputedClassAsyncSuperCalls.status,
        nestedComputedClassAsyncSuperCalls.stderr,
      ).toBe(0);
      expectRetainedClean(nestedComputedClassAsyncSuperCalls.stderr ?? '');
      const nestedComputedClassAsyncSuperCallsOutput = runOutput();
      expect(
        nestedComputedClassAsyncSuperCallsOutput.status,
        nestedComputedClassAsyncSuperCallsOutput.stderr,
      ).toBe(0);
      expect(nestedComputedClassAsyncSuperCallsOutput.stdout).toBe('42 84 2\n');

      // Computed getter and setter super accesses evaluate each key once and
      // preserve both instance and inherited constructor receivers.
      const nestedComputedClassAsyncSuperAccesses = run(
        [
          'var instanceReceiver;',
          'var constructorReceiver;',
          'var instanceWrites = 0;',
          'var constructorWrites = 0;',
          'var keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'class InstanceBase {',
          '  get value() { return this._value; }',
          '  set value(next) { instanceWrites += 1; instanceReceiver = this; this._value = next; }',
          '}',
          'class InstanceService extends InstanceBase {',
          '  async readWrite(next) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var before = super[getKey()];',
          '        var assigned = super[getKey()] = next;',
          '        return [before, assigned, this === instanceReceiver, this.value, instanceWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class StaticBase {',
          '  static get value() { return this._value; }',
          '  static set value(next) { constructorWrites += 1; constructorReceiver = this; this._value = next; }',
          '}',
          'class StaticService extends StaticBase {',
          '  static async readWrite(next) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var before = super[getKey()];',
          '        var assigned = super[getKey()] = next;',
          '        return [before, assigned, this === constructorReceiver, this.value, constructorWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class Derived extends StaticService {}',
          'var instance = new InstanceService();',
          'instance._value = 42;',
          'Derived._value = 84;',
          'Promise.all([instance.readWrite(50), Derived.readWrite(90)]).then(values => console.log(values.join("|"), keyEvaluations));',
        ].join('\n'),
      );
      expect(
        nestedComputedClassAsyncSuperAccesses.status,
        nestedComputedClassAsyncSuperAccesses.stderr,
      ).toBe(0);
      expectRetainedClean(nestedComputedClassAsyncSuperAccesses.stderr ?? '');
      const nestedComputedClassAsyncSuperAccessesOutput = runOutput();
      expect(
        nestedComputedClassAsyncSuperAccessesOutput.status,
        nestedComputedClassAsyncSuperAccessesOutput.stderr,
      ).toBe(0);
      expect(nestedComputedClassAsyncSuperAccessesOutput.stdout).toBe(
        '42 50 true 50 1|84 90 true 90 1 4\n',
      );

      // Computed super compound assignments and updates keep their single
      // key evaluation, accessor effects, and lexical receivers in nested arrows.
      const nestedComputedClassAsyncSuperUpdates = run(
        [
          'var instanceReceiver;',
          'var constructorReceiver;',
          'var instanceReads = 0;',
          'var constructorReads = 0;',
          'var instanceWrites = 0;',
          'var constructorWrites = 0;',
          'var keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'class InstanceBase {',
          '  get value() { instanceReads += 1; return this._value; }',
          '  set value(next) { instanceWrites += 1; instanceReceiver = this; this._value = next; }',
          '}',
          'class InstanceService extends InstanceBase {',
          '  async update(next) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var sum = super[getKey()] += next;',
          '        var previous = super[getKey()]++;',
          '        return [sum, previous, this === instanceReceiver, this._value, instanceReads, instanceWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class StaticBase {',
          '  static get value() { constructorReads += 1; return this._value; }',
          '  static set value(next) { constructorWrites += 1; constructorReceiver = this; this._value = next; }',
          '}',
          'class StaticService extends StaticBase {',
          '  static async update(next) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var sum = super[getKey()] += next;',
          '        var previous = super[getKey()]++;',
          '        return [sum, previous, this === constructorReceiver, this._value, constructorReads, constructorWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class Derived extends StaticService {}',
          'var instance = new InstanceService(); instance._value = 42;',
          'Derived._value = 84;',
          'Promise.all([instance.update(8), Derived.update(6)]).then(values => console.log(values.join("|"), keyEvaluations));',
        ].join('\n'),
      );
      expect(
        nestedComputedClassAsyncSuperUpdates.status,
        nestedComputedClassAsyncSuperUpdates.stderr,
      ).toBe(0);
      expectRetainedClean(nestedComputedClassAsyncSuperUpdates.stderr ?? '');
      const nestedComputedClassAsyncSuperUpdatesOutput = runOutput();
      expect(
        nestedComputedClassAsyncSuperUpdatesOutput.status,
        nestedComputedClassAsyncSuperUpdatesOutput.stderr,
      ).toBe(0);
      expect(nestedComputedClassAsyncSuperUpdatesOutput.stdout).toBe(
        '50 50 true 51 2 2|90 90 true 91 2 2 4\n',
      );

      // Logical computed super assignments preserve key, accessor, and
      // inherited-receiver behavior while their generated state stays exact.
      const nestedComputedClassAsyncSuperLogicalAssignments = run(
        [
          'var instanceReceiver;',
          'var constructorReceiver;',
          'var instanceReads = 0;',
          'var constructorReads = 0;',
          'var instanceWrites = 0;',
          'var constructorWrites = 0;',
          'var keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'class InstanceBase {',
          '  get value() { instanceReads += 1; return this._value; }',
          '  set value(next) { instanceWrites += 1; instanceReceiver = this; this._value = next; }',
          '}',
          'class InstanceService extends InstanceBase {',
          '  async update(first, second, third) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var nullish = super[getKey()] ??= first;',
          '        var either = super[getKey()] ||= second;',
          '        var both = super[getKey()] &&= third;',
          '        return [nullish, either, both, this === instanceReceiver, this._value, instanceReads, instanceWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class StaticBase {',
          '  static get value() { constructorReads += 1; return this._value; }',
          '  static set value(next) { constructorWrites += 1; constructorReceiver = this; this._value = next; }',
          '}',
          'class StaticService extends StaticBase {',
          '  static async update(first, second, third) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var nullish = super[getKey()] ??= first;',
          '        var either = super[getKey()] ||= second;',
          '        var both = super[getKey()] &&= third;',
          '        return [nullish, either, both, this === constructorReceiver, this._value, constructorReads, constructorWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class Derived extends StaticService {}',
          'var instance = new InstanceService(); instance._value = null;',
          'Derived._value = 0;',
          'Promise.all([instance.update(8, 9, 10), Derived.update(6, 7, 8)]).then(values => console.log(values.join("|"), keyEvaluations));',
        ].join('\n'),
      );
      expect(
        nestedComputedClassAsyncSuperLogicalAssignments.status,
        nestedComputedClassAsyncSuperLogicalAssignments.stderr,
      ).toBe(0);
      expectRetainedClean(nestedComputedClassAsyncSuperLogicalAssignments.stderr ?? '');
      const nestedComputedClassAsyncSuperLogicalAssignmentsOutput = runOutput();
      expect(
        nestedComputedClassAsyncSuperLogicalAssignmentsOutput.status,
        nestedComputedClassAsyncSuperLogicalAssignmentsOutput.stderr,
      ).toBe(0);
      expect(nestedComputedClassAsyncSuperLogicalAssignmentsOutput.stdout).toBe(
        '8 8 10 true 10 3 2|0 7 8 true 8 3 2 6\n',
      );

      // A synchronous super owner keeps the whole class on semantic reanalysis.
      const mixedAsyncAndSyncSuperLogicalAssignment = run(
        [
          'var keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'class Base {',
          '  get value() { return this._value; }',
          '  set value(next) { this._value = next; }',
          '}',
          'class Service extends Base {',
          '  async update(next) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => { await Promise.resolve(); return super[getKey()] ||= next; };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '  updateSync(next) { return super[getKey()] ||= next; }',
          '}',
          'var service = new Service(); service._value = 0;',
          'var other = { _value: 0 };',
          'service.update(8).then(asyncValue => {',
          '  var syncValue = service.updateSync.call(other, 9);',
          '  console.log(asyncValue, service._value, syncValue, other._value, keyEvaluations);',
          '});',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedAsyncAndSyncSuperLogicalAssignment, '8 8 9 9 2\n');

      // Static nested super uses at different arrow depths stay on reanalysis.
      const mixedNestedStaticAsyncArrowSuper = run(
        [
          'class Base { static get current() { return this.value; } }',
          'class Service extends Base {',
          '  static async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var nested = async () => { await Promise.resolve(); return super.current; };',
          '      return await nested() + super.current;',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'Service.value = 42;',
          'Service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedNestedStaticAsyncArrowSuper, '84\n');

      // A direct method-body super mixed with async-arrow super stays on reanalysis.
      const mixedMethodAndAsyncArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => { await Promise.resolve(); return super.current; };',
          '    return super.current + await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedMethodAndAsyncArrowSuper, '84\n');

      // Sibling async arrows can keep separate state machines on the same
      // method home graph.
      const multipleAsyncArrowSuperOwners = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var first = async () => { await Promise.resolve(); return super.current; };',
          '    var second = async () => { await Promise.resolve(); return super.current; };',
          '    return await first() + await second();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(multipleAsyncArrowSuperOwners.status, multipleAsyncArrowSuperOwners.stderr).toBe(0);
      expectRetainedClean(multipleAsyncArrowSuperOwners.stderr ?? '');
      const multipleAsyncArrowSuperOutput = runOutput();
      expect(multipleAsyncArrowSuperOutput.status, multipleAsyncArrowSuperOutput.stderr).toBe(0);
      expect(multipleAsyncArrowSuperOutput.stdout).toBe('84\n');

      // Mixing synchronous and async arrow owners remains on reanalysis.
      const mixedSyncAndAsyncArrowSuperOwners = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var first = async () => { await Promise.resolve(); return super.current; };',
          '    var second = () => super.current;',
          '    return await first() + second();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedSyncAndAsyncArrowSuperOwners, '84\n');

      // One nested async arrow can retain its own state machine and the
      // intermediate async-arrow scope on the same method home graph.
      const deepAsyncArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var nested = async () => { await Promise.resolve(); return super.current; };',
          '      return nested();',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(deepAsyncArrowSuper.status, deepAsyncArrowSuper.stderr).toBe(0);
      expectRetainedClean(deepAsyncArrowSuper.stderr ?? '');
      const deepAsyncArrowSuperOutput = runOutput();
      expect(deepAsyncArrowSuperOutput.status, deepAsyncArrowSuperOutput.stderr).toBe(0);
      expect(deepAsyncArrowSuperOutput.stdout).toBe('42\n');

      // Multiple nested async-arrow owners can retain their separate
      // state machines and the intermediate async-arrow scope.
      const multipleNestedAsyncArrowSuperOwners = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var first = async () => { await Promise.resolve(); return super.current; };',
          '      var second = async () => { await Promise.resolve(); return super.current; };',
          '      return await first() + await second();',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(
        multipleNestedAsyncArrowSuperOwners.status,
        multipleNestedAsyncArrowSuperOwners.stderr,
      ).toBe(0);
      expectRetainedClean(multipleNestedAsyncArrowSuperOwners.stderr ?? '');
      const multipleNestedAsyncArrowSuperOutput = runOutput();
      expect(
        multipleNestedAsyncArrowSuperOutput.status,
        multipleNestedAsyncArrowSuperOutput.stderr,
      ).toBe(0);
      expect(multipleNestedAsyncArrowSuperOutput.stdout).toBe('84\n');

      // A synchronous nested owner mixed with async nested owners stays on
      // semantic reanalysis.
      const mixedNestedAsyncArrowSuperOwners = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var first = async () => { await Promise.resolve(); return super.current; };',
          '      var second = () => super.current;',
          '      return await first() + second();',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedNestedAsyncArrowSuperOwners, '84\n');

      // A method-depth and nested-depth super mix stays on reanalysis.
      const mixedAsyncArrowDepthSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var nested = async () => { await Promise.resolve(); return super.current; };',
          '      return await nested() + super.current;',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedAsyncArrowDepthSuper, '84\n');

      // A synchronous intermediate arrow has no async state-machine proof.
      const nestedSyncArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var nested = () => super.current;',
          '      return nested();',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(nestedSyncArrowSuper, '42\n');

      // A synchronous outer arrow also stays out of the nested async proof.
      const nestedAsyncArrowInSyncOuter = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = () => {',
          '      var nested = async () => { await Promise.resolve(); return super.current; };',
          '      return nested();',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(nestedAsyncArrowInSyncOuter, '42\n');

      // Three async-arrow scopes at one uniform depth retain their state machines.
      const threeDeepAsyncArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var first = async () => {',
          '      await Promise.resolve();',
          '      var second = async () => {',
          '        await Promise.resolve();',
          '        var third = async () => { await Promise.resolve(); return super.current; };',
          '        return third();',
          '      };',
          '      return second();',
          '    };',
          '    return await first();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(threeDeepAsyncArrowSuper.status, threeDeepAsyncArrowSuper.stderr).toBe(0);
      expectRetainedClean(threeDeepAsyncArrowSuper.stderr ?? '');
      const threeDeepAsyncArrowSuperOutput = runOutput();
      expect(threeDeepAsyncArrowSuperOutput.status, threeDeepAsyncArrowSuperOutput.stderr).toBe(0);
      expect(threeDeepAsyncArrowSuperOutput.stdout).toBe('42\n');

      // Depth four follows the same uniform async-arrow proof.
      const fourDeepAsyncArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var first = async () => {',
          '      await Promise.resolve();',
          '      var second = async () => {',
          '        await Promise.resolve();',
          '        var third = async () => {',
          '          await Promise.resolve();',
          '          var fourth = async () => { await Promise.resolve(); return super.current; };',
          '          return fourth();',
          '        };',
          '        return third();',
          '      };',
          '      return second();',
          '    };',
          '    return await first();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(fourDeepAsyncArrowSuper.status, fourDeepAsyncArrowSuper.stderr).toBe(0);
      expectRetainedClean(fourDeepAsyncArrowSuper.stderr ?? '');
      const fourDeepAsyncArrowSuperOutput = runOutput();
      expect(fourDeepAsyncArrowSuperOutput.status, fourDeepAsyncArrowSuperOutput.stderr).toBe(0);
      expect(fourDeepAsyncArrowSuperOutput.stdout).toBe('42\n');

      // Mixed nested depths remain on reanalysis even when every arrow is async.
      const mixedNestedAsyncArrowDepthSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var second = async () => {',
          '        await Promise.resolve();',
          '        var third = async () => { await Promise.resolve(); return super.current; };',
          '        return await third() + super.current;',
          '      };',
          '      return await second();',
          '    };',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedNestedAsyncArrowDepthSuper, '84\n');

      // A super default in async-arrow parameters runs before its state machine.
      const asyncArrowParameterSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = async (value = super.current) => value;',
          '    return await read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(asyncArrowParameterSuper, '42\n');

      // A method-body super mixed with the arrow capture keeps the class on reanalysis.
      const mixedMethodAndArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = () => super.current;',
          '    return super.current + read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedMethodAndArrowSuper, '84\n');

      // Separate arrow owners are not covered by the one-scope home-object gate.
      const multipleArrowSuperOwners = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var first = () => super.current;',
          '    var second = () => super.current;',
          '    return first() + second();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(multipleArrowSuperOwners, '84\n');

      // Deeper arrow nesting introduces another lexical owner and stays gated.
      const deepArrowSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = () => { var nested = () => super.current; return nested(); };',
          '    return read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(deepArrowSuper, '42\n');

      // A super read in the arrow parameter initializer runs outside the body capture proof.
      const arrowParameterSuper = run(
        [
          'class Base { get current() { return this.value; } }',
          'class Service extends Base {',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    var read = (value = super.current) => value;',
          '    return read();',
          '  }',
          '}',
          'var service = new Service(); service.value = 42;',
          'service.readAsync().then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(arrowParameterSuper, '42\n');

      // Computed super exponentiation assignments keep the exact nested class
      // home graph while preserving the key, accessor, and receiver behavior.
      const nestedClassSuperExponentiationAssignment = run(
        [
          'var instanceReceiver;',
          'var constructorReceiver;',
          'var instanceReads = 0, constructorReads = 0;',
          'var instanceWrites = 0, constructorWrites = 0;',
          'var keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'class InstanceBase {',
          '  get value() { instanceReads += 1; return this._value; }',
          '  set value(next) { instanceWrites += 1; instanceReceiver = this; this._value = next; }',
          '}',
          'class InstanceService extends InstanceBase {',
          '  async update(power) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var result = super[getKey()] **= power;',
          '        return [result, this === instanceReceiver, this._value, instanceReads, instanceWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class StaticBase {',
          '  static get value() { constructorReads += 1; return this._value; }',
          '  static set value(next) { constructorWrites += 1; constructorReceiver = this; this._value = next; }',
          '}',
          'class StaticService extends StaticBase {',
          '  static async update(power) {',
          '    await Promise.resolve();',
          '    var outer = async () => {',
          '      await Promise.resolve();',
          '      var inner = async () => {',
          '        await Promise.resolve();',
          '        var result = super[getKey()] **= power;',
          '        return [result, this === constructorReceiver, this._value, constructorReads, constructorWrites].join(" ");',
          '      };',
          '      return await inner();',
          '    };',
          '    return await outer();',
          '  }',
          '}',
          'class Derived extends StaticService {}',
          'var instance = new InstanceService(); instance._value = 3; Derived._value = 4;',
          'Promise.all([instance.update(2), Derived.update(2)]).then(values => console.log(values.join("|"), keyEvaluations));',
        ].join('\n'),
      );
      expect(
        nestedClassSuperExponentiationAssignment.status,
        nestedClassSuperExponentiationAssignment.stderr,
      ).toBe(0);
      expectRetainedClean(nestedClassSuperExponentiationAssignment.stderr ?? '');
      const nestedClassSuperExponentiationAssignmentOutput = runOutput();
      expect(
        nestedClassSuperExponentiationAssignmentOutput.status,
        nestedClassSuperExponentiationAssignmentOutput.stderr,
      ).toBe(0);
      expect(nestedClassSuperExponentiationAssignmentOutput.stdout).toBe(
        '9 true 9 1 1|16 true 16 1 1 2\n',
      );

      // An audited optional computed-key access composes with super `**=`.
      // The optional null branch skips key evaluation while both operations
      // retain their generated references in the original graph.
      const optionalComputedSuperExponentiationKey = run(
        [
          'var events = []; var receiver;',
          'var keyEvaluations = 0, powerEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
          'function getPower() { powerEvaluations += 1; events.push("power"); return 2; }',
          'var keySource = { get key() { events.push("source-key"); return "value"; } };',
          'class Base {',
          '  get value() { events.push("get-value"); return this._value; }',
          '  set value(next) { events.push("set-value"); receiver = this; this._value = next; }',
          '}',
          'Object.defineProperty(Base.prototype, "undefined", {',
          '  get: function() { events.push("get-undefined"); return this._missing; },',
          '  set: function(next) { events.push("set-undefined"); receiver = this; this._missing = next; },',
          '});',
          'class Service extends Base {',
          '  async update(source) {',
          '    await Promise.resolve();',
          '    var nested = async () => {',
          '      await Promise.resolve();',
          '      var result = super[source?.[getKey()]] **= getPower();',
          '      return [result, this === receiver].join(" ");',
          '    };',
          '    return await nested();',
          '  }',
          '}',
          'var present = new Service(); present._value = 3;',
          'var absent = new Service(); absent._missing = 5;',
          'present.update(keySource).then(first => absent.update(null).then(second => console.log(first + "|" + second, events.join(","), keyEvaluations, powerEvaluations)));',
        ].join('\n'),
      );
      expect(
        optionalComputedSuperExponentiationKey.status,
        optionalComputedSuperExponentiationKey.stderr,
      ).toBe(0);
      expectRetainedClean(optionalComputedSuperExponentiationKey.stderr ?? '');
      const optionalComputedSuperExponentiationKeyOutput = runOutput();
      expect(
        optionalComputedSuperExponentiationKeyOutput.status,
        optionalComputedSuperExponentiationKeyOutput.stderr,
      ).toBe(0);
      expect(optionalComputedSuperExponentiationKeyOutput.stdout).toBe(
        '9 true|25 true key,source-key,get-value,power,set-value,get-undefined,power,set-undefined 1 2\n',
      );

      // A method-body super use beside the nested assignment still requires
      // semantic reanalysis for the mixed home-object owners.
      const mixedMethodAndArrowSuperExponentiationAssignment = run(
        [
          'var reads = 0, writes = 0, keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'class Base {',
          '  get value() { reads += 1; return this._value; }',
          '  set value(next) { writes += 1; this._value = next; }',
          '}',
          'class Service extends Base {',
          '  async update(power) {',
          '    await Promise.resolve();',
          '    var nested = async () => { await Promise.resolve(); return super[getKey()] **= power; };',
          '    var assigned = await nested();',
          '    var direct = super[getKey()];',
          '    return [assigned, direct, this._value, keyEvaluations, reads, writes].join(" ");',
          '  }',
          '}',
          'var instance = new Service(); instance._value = 3;',
          'instance.update(2).then(value => console.log(value));',
        ].join('\n'),
      );
      expectReanalyzedOutput(mixedMethodAndArrowSuperExponentiationAssignment, '9 9 9 2 2 1\n');

      // A computed key containing another super access remains outside the
      // direct-super target proof and continues through semantic reanalysis.
      const nestedSuperKeyExponentiationAssignment = run(
        [
          'var reads = 0, writes = 0;',
          'class Base {',
          '  get key() { return "value"; }',
          '  get value() { reads += 1; return this._value; }',
          '  set value(next) { writes += 1; this._value = next; }',
          '}',
          'class Service extends Base {',
          '  async update(power) {',
          '    await Promise.resolve();',
          '    var nested = async () => { await Promise.resolve(); return super[super.key] **= power; };',
          '    return await nested();',
          '  }',
          '}',
          'var instance = new Service(); instance._value = 3;',
          'instance.update(2).then(value => console.log(value, instance._value, reads, writes));',
        ].join('\n'),
      );
      expectReanalyzedOutput(nestedSuperKeyExponentiationAssignment, '9 9 1 1\n');

      // A computed optional key rooted in an untracked member chain remains
      // outside the audited optional-member proof even though the outer target
      // itself is a direct super property.
      const untrackedOptionalComputedSuperExponentiationKey = run(
        [
          'var reads = 0, writes = 0, keyEvaluations = 0;',
          'function getKey() { keyEvaluations += 1; return "key"; }',
          'function getPower() { return 2; }',
          'globalThis.__zntcUntrackedSuperKey = { key: "value" };',
          'class Base {',
          '  get value() { reads += 1; return this._value; }',
          '  set value(next) { writes += 1; this._value = next; }',
          '}',
          'class Service extends Base {',
          '  async update() {',
          '    await Promise.resolve();',
          '    var nested = async () => { await Promise.resolve(); return super[globalThis.__zntcUntrackedSuperKey?.[getKey()]] **= getPower(); };',
          '    return await nested();',
          '  }',
          '}',
          'var instance = new Service(); instance._value = 3;',
          'instance.update().then(result => console.log(result, instance._value, keyEvaluations, reads, writes));',
        ].join('\n'),
      );
      expectReanalyzedOutput(untrackedOptionalComputedSuperExponentiationKey, '9 9 1 1 1\n');

      // Optional keys stay retainable for logical super assignments only with
      // coverage for all short-circuit forms and their evaluation order.
      const optionalComputedSuperLogicalAssignmentKey = run(
        [
          'var events = []; var receiver;',
          'var keyEvaluations = 0, nullishEvaluations = 0, logicalOrEvaluations = 0, logicalAndEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
          'function getNullish() { nullishEvaluations += 1; events.push("rhs-nullish"); return 8; }',
          'function getLogicalOr() { logicalOrEvaluations += 1; events.push("rhs-or"); return 9; }',
          'function getLogicalAnd() { logicalAndEvaluations += 1; events.push("rhs-and"); return 10; }',
          'var keySource = { get key() { events.push("source-key"); return "value"; } };',
          'class Base {',
          '  get value() { reads += 1; events.push("get-value"); return this._value; }',
          '  set value(next) { writes += 1; events.push("set-value"); receiver = this; this._value = next; }',
          '}',
          'Object.defineProperty(Base.prototype, "undefined", {',
          '  get: function() { reads += 1; events.push("get-undefined"); return this._missing; },',
          '  set: function(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
          '});',
          'class Service extends Base {',
          '  async update(source) {',
          '    await Promise.resolve();',
          '    var nested = async () => {',
          '      await Promise.resolve();',
          '      var nullish = super[source?.[getKey()]] ??= getNullish();',
          '      var either = super[source?.[getKey()]] ||= getLogicalOr();',
          '      var both = super[source?.[getKey()]] &&= getLogicalAnd();',
          '      var value = source === null ? this._missing : this._value;',
          '      return [nullish, either, both, this === receiver, value, reads, writes].join(" ");',
          '    };',
          '    return await nested();',
          '  }',
          '}',
          'var present = new Service(); present._value = null;',
          'var absent = new Service(); absent._missing = 5;',
          'present.update(keySource).then(first => absent.update(null).then(second => console.log(first + "|" + second, events.join(","), keyEvaluations, nullishEvaluations, logicalOrEvaluations, logicalAndEvaluations, reads, writes)));',
        ].join('\n'),
      );
      expect(
        optionalComputedSuperLogicalAssignmentKey.status,
        optionalComputedSuperLogicalAssignmentKey.stderr,
      ).toBe(0);
      expectRetainedClean(optionalComputedSuperLogicalAssignmentKey.stderr ?? '');
      const optionalComputedSuperLogicalAssignmentKeyOutput = runOutput();
      expect(
        optionalComputedSuperLogicalAssignmentKeyOutput.status,
        optionalComputedSuperLogicalAssignmentKeyOutput.stderr,
      ).toBe(0);
      expect(optionalComputedSuperLogicalAssignmentKeyOutput.stdout).toBe(
        '8 8 10 true 10 3 2|5 5 10 true 10 6 3 key,source-key,get-value,rhs-nullish,set-value,key,source-key,get-value,key,source-key,get-value,rhs-and,set-value,get-undefined,get-undefined,get-undefined,rhs-and,set-undefined 3 1 0 2 6 3\n',
      );

      // An optional chain rooted in an untracked global member chain must
      // continue through semantic reanalysis for logical super assignment.
      const untrackedOptionalComputedSuperLogicalAssignmentKey = run(
        [
          'var keyEvaluations = 0, rhsEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; return "key"; }',
          'function getNext() { rhsEvaluations += 1; return 8; }',
          'globalThis.__zntcUntrackedLogicalSuperKey = { key: "value" };',
          'class Base {',
          '  get value() { reads += 1; return this._value; }',
          '  set value(next) { writes += 1; this._value = next; }',
          '}',
          'class Service extends Base {',
          '  async update() {',
          '    await Promise.resolve();',
          '    var nested = async () => { await Promise.resolve(); return super[globalThis.__zntcUntrackedLogicalSuperKey?.[getKey()]] ??= getNext(); };',
          '    return await nested();',
          '  }',
          '}',
          'var instance = new Service(); instance._value = null;',
          'instance.update().then(result => console.log(result, instance._value, keyEvaluations, rhsEvaluations, reads, writes));',
        ].join('\n'),
      );
      expectReanalyzedOutput(untrackedOptionalComputedSuperLogicalAssignmentKey, '8 8 1 1 1 1\n');

      // A nested super access inside the optional key remains outside the
      // direct-super target proof even when optional keys are admitted.
      const nestedSuperOptionalComputedLogicalAssignmentKey = run(
        [
          'var reads = 0, writes = 0;',
          'function getNext() { return 8; }',
          'class Base {',
          '  get key() { return "value"; }',
          '  get value() { reads += 1; return this._value; }',
          '  set value(next) { writes += 1; this._value = next; }',
          '}',
          'class Service extends Base {',
          '  async update(source) {',
          '    await Promise.resolve();',
          '    var nested = async () => { await Promise.resolve(); return super[source?.[super.key]] ??= getNext(); };',
          '    return await nested();',
          '  }',
          '}',
          'var instance = new Service(); instance._value = null;',
          'instance.update({ value: "value" }).then(result => console.log(result, instance._value, reads, writes));',
        ].join('\n'),
      );
      expectReanalyzedOutput(nestedSuperOptionalComputedLogicalAssignmentKey, '8 8 1 1\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 async object methods retain the exact state-machine graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-async-object-method-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
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

    try {
      const retained = run(
        [
          'var service = {',
          '  value: 40,',
          '  async calculate(value: number) {',
          '    var _state = 1, _context = 1, _arguments = arguments[0];',
          '    await Promise.resolve(value);',
          '    return this.value + value + _state + _context + _arguments;',
          '  },',
          '};',
          'service.calculate(0).then(value => console.log(value));',
        ].join('\n'),
      );
      expect(retained.status, retained.stderr).toBe(0);
      const retainedMode = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(retainedMode, retained.stderr).toContain('semantic_graph=retained');
      const retainedReport = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(retainedReport, retained.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(retainedReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${retainedReport}`,
        ).toBe(0);
      }
      expect(retainedReport).toMatch(/clean=1(?:\s|$)/);
      const retainedOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(retainedOutput.status, retainedOutput.stderr).toBe(0);
      expect(retainedOutput.stdout).toBe('42\n');

      // Direct eval can observe the state-machine locals and keeps its method
      // on the conservative semantic reanalysis path.
      const directEval = run(
        [
          'var service = {',
          '  async calculate(value: number) {',
          '    await Promise.resolve();',
          "    return eval('value') + 1;",
          '  },',
          '};',
          'service.calculate(41).then(value => console.log(value));',
        ].join('\n'),
      );
      expect(directEval.status, directEval.stderr).toBe(0);
      const directEvalMode = (directEval.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(directEvalMode, directEval.stderr).toContain('semantic_graph=reanalyzed');
      const directEvalOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(directEvalOutput.status, directEvalOutput.stderr).toBe(0);
      expect(directEvalOutput.stdout).toBe('42\n');

      // Computed keys are evaluated outside the method scope and remain gated.
      const computedKey = run(
        [
          "var key = 'calculate';",
          'var service = {',
          '  async [key](value: number) {',
          '    await Promise.resolve();',
          '    return value + 1;',
          '  },',
          '};',
          'service.calculate(41).then(value => console.log(value));',
        ].join('\n'),
      );
      expect(computedKey.status, computedKey.stderr).toBe(0);
      const computedKeyMode = (computedKey.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(computedKeyMode, computedKey.stderr).toContain('semantic_graph=reanalyzed');
      const computedKeyOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(computedKeyOutput.status, computedKeyOutput.stderr).toBe(0);
      expect(computedKeyOutput.stdout).toBe('42\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 async object methods retain direct super with their exact home graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-async-object-super-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
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

    try {
      const retained = run(
        [
          'var prototype = { read() { return this.value; } };',
          'var service = {',
          '  value: 42,',
          '  async read() {',
          '    await Promise.resolve();',
          '    return super.read();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.read().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(retained.status, retained.stderr).toBe(0);
      const retainedMode = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(retainedMode, retained.stderr).toContain('semantic_graph=retained');
      const retainedReport = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(retainedReport, retained.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(retainedReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${retainedReport}`,
        ).toBe(0);
      }
      expect(retainedReport).toMatch(/clean=1(?:\s|$)/);
      const retainedOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(retainedOutput.status, retainedOutput.stderr).toBe(0);
      expect(retainedOutput.stdout).toBe('42\n');

      // One synchronous arrow scope can keep its lexical super on the method's
      // exact home-object graph.
      const nestedArrow = run(
        [
          'var prototype = { read() { return this.value; } };',
          'var service = {',
          '  value: 42,',
          '  async read() {',
          '    await Promise.resolve();',
          '    var read = () => super.read();',
          '    return read();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.read().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(nestedArrow.status, nestedArrow.stderr).toBe(0);
      const nestedArrowMode = (nestedArrow.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(nestedArrowMode, nestedArrow.stderr).toContain('semantic_graph=retained');
      const nestedArrowReport = (nestedArrow.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(nestedArrowReport, nestedArrow.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(nestedArrowReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${nestedArrowReport}`,
        ).toBe(0);
      }
      expect(nestedArrowReport).toMatch(/clean=1(?:\s|$)/);
      const nestedArrowOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(nestedArrowOutput.status, nestedArrowOutput.stderr).toBe(0);
      expect(nestedArrowOutput.stdout).toBe('42\n');

      // A single async arrow keeps lexical super on the method's exact
      // home-object graph after its own state-machine preflight succeeds.
      const asyncArrow = run(
        [
          'var prototype = { read() { return this.value; } };',
          'var service = {',
          '  value: 42,',
          '  async read() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      return super.read();',
          '    };',
          '    return await read();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.read().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(asyncArrow.status, asyncArrow.stderr).toBe(0);
      const asyncArrowMode = (asyncArrow.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(asyncArrowMode, asyncArrow.stderr).toContain('semantic_graph=retained');
      const asyncArrowReport = (asyncArrow.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(asyncArrowReport, asyncArrow.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(asyncArrowReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${asyncArrowReport}`,
        ).toBe(0);
      }
      expect(asyncArrowReport).toMatch(/clean=1(?:\s|$)/);
      const asyncArrowOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(asyncArrowOutput.status, asyncArrowOutput.stderr).toBe(0);
      expect(asyncArrowOutput.stdout).toBe('42\n');

      // Direct method super mixed with a two-level async-arrow super chain
      // introduces more owners than this allowlist currently audits.
      const deepArrow = run(
        [
          'var prototype = { read() { return this.value; } };',
          'var service = {',
          '  value: 42,',
          '  async read() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      var nestedRead = async () => { await Promise.resolve(); return super.read(); };',
          '      return await nestedRead();',
          '    };',
          '    return super.read() + await read();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.read().then(value => console.log(value));',
        ].join('\n'),
      );
      expect(deepArrow.status, deepArrow.stderr).toBe(0);
      const deepArrowMode = (deepArrow.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(deepArrowMode, deepArrow.stderr).toContain('semantic_graph=reanalyzed');
      const deepArrowOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(deepArrowOutput.status, deepArrowOutput.stderr).toBe(0);
      expect(deepArrowOutput.stdout).toBe('84\n');

      // Direct method-body super and one async-arrow super owner share the
      // exact method home-object graph and retain both helper references.
      const mixedSuper = run(
        [
          'var events = []; var receiver;',
          'var keyEvaluations = 0, rhsEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
          'function getNext() { rhsEvaluations += 1; events.push("rhs"); return 84; }',
          'var keySource = { get key() { events.push("source-key"); return "undefined"; } };',
          'var prototype = {',
          '  read() { events.push("direct-read"); return this.value; },',
          '  get undefined() { reads += 1; events.push("get-undefined"); return this._missing; },',
          '  set undefined(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
          '};',
          'var service = {',
          '  value: 42, _missing: null,',
          '  async update(source) {',
          '    await Promise.resolve();',
          '    var update = async () => {',
          '      await Promise.resolve();',
          '      return super[source?.[getKey()]] ??= getNext();',
          '    };',
          '    var direct = super.read();',
          '    var assigned = await update();',
          '    return [direct, assigned].join(" ");',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.update(keySource).then(first => { var firstEvents = events.join(","); events.length = 0; return service.update(null).then(second => console.log(first, second, service._missing, service === receiver, firstEvents, events.join(","), reads, writes, keyEvaluations, rhsEvaluations)); });',
        ].join('\n'),
      );
      expect(mixedSuper.status, mixedSuper.stderr).toBe(0);
      const mixedSuperMode = (mixedSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mixedSuperMode, mixedSuper.stderr).toContain('semantic_graph=retained');
      const mixedSuperReport = (mixedSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(mixedSuperReport, mixedSuper.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(mixedSuperReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${mixedSuperReport}`,
        ).toBe(0);
      }
      expect(mixedSuperReport).toMatch(/clean=1(?:\s|$)/);
      const mixedSuperOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(mixedSuperOutput.status, mixedSuperOutput.stderr).toBe(0);
      expect(mixedSuperOutput.stdout).toBe(
        '42 84 42 84 84 true direct-read,key,source-key,get-undefined,rhs,set-undefined direct-read,get-undefined 2 1 1 1\n',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 async object methods retain mixed direct-super assignment operators', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-mixed-object-super-operators-'));
    const input = join(dir, 'entry.ts');
    const nativeInput = join(dir, 'oracle.mjs');
    const output = join(dir, 'out.cjs');
    const cases = [
      {
        operator: '??=',
        initialKey: 'null',
        initialMissing: '84',
        rhsValue: '84',
        assignmentValue: '84',
        writes: 1,
        rhsCalls: 1,
        secondEvents: 'direct-read,get-undefined',
      },
      {
        operator: '||=',
        initialKey: '0',
        initialMissing: '84',
        rhsValue: '84',
        assignmentValue: '84',
        writes: 1,
        rhsCalls: 1,
        secondEvents: 'direct-read,get-undefined',
      },
      {
        operator: '&&=',
        initialKey: '1',
        initialMissing: '1',
        rhsValue: '84',
        assignmentValue: '84',
        writes: 2,
        rhsCalls: 2,
        secondEvents: 'direct-read,get-undefined,rhs,set-undefined',
      },
      {
        operator: '**=',
        initialKey: '2',
        initialMissing: '2',
        rhsValue: '3',
        assignmentValue: '8',
        writes: 2,
        rhsCalls: 2,
        secondEvents: 'direct-read,get-undefined,rhs,set-undefined',
      },
    ] as const;

    const sourceFor = (testCase: (typeof cases)[number]) =>
      [
        'var events = []; var receiver;',
        'var keyEvaluations = 0, rhsEvaluations = 0, reads = 0, writes = 0;',
        'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
        `function getNext() { rhsEvaluations += 1; events.push("rhs"); return ${testCase.rhsValue}; }`,
        'var keySource = { get key() { events.push("source-key"); return "key"; } };',
        'var prototype = {',
        '  read() { events.push("direct-read"); return this.value; },',
        '  get key() { reads += 1; events.push("get-key"); return this._key; },',
        '  set key(next) { writes += 1; events.push("set-key"); receiver = this; this._key = next; },',
        '  get undefined() { reads += 1; events.push("get-undefined"); return this._missing; },',
        '  set undefined(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
        '};',
        'var service = {',
        `  value: 42, _key: ${testCase.initialKey}, _missing: ${testCase.initialMissing},`,
        '  async update(source) {',
        '    await Promise.resolve();',
        '    var update = async () => {',
        '      await Promise.resolve();',
        `      return super[source?.[getKey()]] ${testCase.operator} getNext();`,
        '    };',
        '    var direct = super.read();',
        '    var assigned = await update();',
        '    return [direct, assigned].join(" ");',
        '  },',
        '};',
        'Object.setPrototypeOf(service, prototype);',
        'service.update(keySource).then(first => { var firstEvents = events.join(","); events.length = 0; return service.update(null).then(second => console.log(first, second, service._key, service._missing, service === receiver, firstEvents, events.join(","), reads, writes, keyEvaluations, rhsEvaluations)); });',
      ].join('\n');

    try {
      // The async arrow owns the optional super key while method-body super stays direct.
      for (const testCase of cases) {
        const source = sourceFor(testCase);
        writeFileSync(nativeInput, source);
        const native = spawnSync('node', [nativeInput], { encoding: 'utf8' });
        expect(native.status, `${testCase.operator}: ${native.stderr}`).toBe(0);
        const expected = `42 ${testCase.assignmentValue} 42 ${testCase.assignmentValue} ${testCase.assignmentValue} ${testCase.assignmentValue} true direct-read,key,source-key,get-key,rhs,set-key ${testCase.secondEvents} 2 ${testCase.writes} 1 ${testCase.rhsCalls}\n`;
        expect(native.stdout, testCase.operator).toBe(expected);

        writeFileSync(input, source);
        const bundled = spawnSync(
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
        expect(bundled.status, `${testCase.operator}: ${bundled.stderr}`).toBe(0);
        const mode = (bundled.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(mode, `${testCase.operator}: ${bundled.stderr}`).toContain(
          'semantic_graph=retained',
        );
        const report = (bundled.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
          );
        expect(report, `${testCase.operator}: ${bundled.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${testCase.operator} ${counter}: ${report}`,
          ).toBe(0);
        }
        expect(report).toMatch(/clean=1(?:\s|$)/);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${testCase.operator}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, testCase.operator).toBe(native.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 async object super keeps static computed method keys on the retained graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-literal-object-super-key-'));
    const input = join(dir, 'entry.ts');
    const nativeInput = join(dir, 'oracle.mjs');
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
    const sourceFor = (methodKey: string, methodCall: string) => {
      return [
        'var events = []; var receiver;',
        'var keyEvaluations = 0, rhsEvaluations = 0, reads = 0, writes = 0, methodKeyCalls = 0;',
        'function getMethodName() { methodKeyCalls += 1; return "update"; }',
        'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
        'function getNext() { rhsEvaluations += 1; events.push("rhs"); return 84; }',
        'var keySource = { get key() { events.push("source-key"); return "undefined"; } };',
        'var prototype = {',
        '  read() { events.push("direct-read"); return this.value; },',
        '  get undefined() { reads += 1; events.push("get-undefined"); return this._missing; },',
        '  set undefined(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
        '};',
        'var service = {',
        '  value: 42, _missing: null,',
        `  async ${methodKey}(source) {`,
        '    await Promise.resolve();',
        '    var update = async () => {',
        '      await Promise.resolve();',
        '      return super[source?.[getKey()]] ??= getNext();',
        '    };',
        '    var direct = super.read();',
        '    var assigned = await update();',
        '    return [direct, assigned].join(" ");',
        '  },',
        '};',
        'Object.setPrototypeOf(service, prototype);',
        `${methodCall}(keySource).then(first => { var firstEvents = events.join(","); events.length = 0; return ${methodCall}(null).then(second => console.log(first, second, service._missing, service === receiver, methodKeyCalls, firstEvents, events.join(","), reads, writes, keyEvaluations, rhsEvaluations)); });`,
      ].join('\n');
    };

    try {
      const methodCases = [
        { key: "['update']", call: 'service.update', retainsGraph: true, keyCalls: 0 },
        { key: '[0]', call: 'service[0]', retainsGraph: true, keyCalls: 0 },
        { key: '[+0]', call: 'service[0]', retainsGraph: true, keyCalls: 0 },
        { key: '[-1]', call: "service['-1']", retainsGraph: true, keyCalls: 0 },
        { key: '[!0]', call: "service['true']", retainsGraph: true, keyCalls: 0 },
        { key: '[~0]', call: "service['-1']", retainsGraph: true, keyCalls: 0 },
        { key: '[typeof 0]', call: 'service.number', retainsGraph: true, keyCalls: 0 },
        { key: '[void 0]', call: 'service.undefined', retainsGraph: true, keyCalls: 0 },
        { key: '[delete 0]', call: "service['true']", retainsGraph: true, keyCalls: 0 },
        { key: '[true]', call: "service['true']", retainsGraph: true, keyCalls: 0 },
        { key: '[false]', call: "service['false']", retainsGraph: true, keyCalls: 0 },
        { key: '[null]', call: "service['null']", retainsGraph: true, keyCalls: 0 },
        { key: '[1n]', call: "service['1']", retainsGraph: true, keyCalls: 0 },
        { key: '[0x10n]', call: "service['16']", retainsGraph: true, keyCalls: 0 },
        { key: '[-1n]', call: "service['-1']", retainsGraph: true, keyCalls: 0 },
        { key: '[!1n]', call: 'service.false', retainsGraph: true, keyCalls: 0 },
        { key: '[~1n]', call: "service['-2']", retainsGraph: true, keyCalls: 0 },
        { key: '[typeof 1n]', call: 'service.bigint', retainsGraph: true, keyCalls: 0 },
        { key: '[void 1n]', call: 'service.undefined', retainsGraph: true, keyCalls: 0 },
        { key: '[delete 1n]', call: "service['true']", retainsGraph: true, keyCalls: 0 },
        { key: '[!!1n]', call: 'service.true', retainsGraph: true, keyCalls: 0 },
        { key: '[!~1n]', call: 'service.false', retainsGraph: true, keyCalls: 0 },
        { key: '[~!1n]', call: "service['-1']", retainsGraph: true, keyCalls: 0 },
        { key: '[+!0]', call: 'service[1]', retainsGraph: true, keyCalls: 0 },
        { key: '[~~1]', call: 'service[1]', retainsGraph: true, keyCalls: 0 },
        { key: '[+!0n]', call: 'service[1]', retainsGraph: true, keyCalls: 0 },
        { key: '[typeof !1n]', call: 'service.boolean', retainsGraph: true, keyCalls: 0 },
        { key: '[~~1n]', call: 'service[1]', retainsGraph: true, keyCalls: 0 },
        { key: '[void !1n]', call: 'service.undefined', retainsGraph: true, keyCalls: 0 },
        { key: '[`update`]', call: 'service.update', retainsGraph: true, keyCalls: 0 },
        { key: '[`up${"date"}`]', call: 'service.update', retainsGraph: false, keyCalls: 0 },
        { key: '[getMethodName()]', call: 'service.update', retainsGraph: false, keyCalls: 1 },
      ];
      for (const { key: methodKey, call: methodCall, retainsGraph, keyCalls } of methodCases) {
        const source = sourceFor(methodKey, methodCall);
        writeFileSync(nativeInput, source);
        const native = spawnSync('node', [nativeInput], { encoding: 'utf8' });
        expect(native.status, `${methodKey}: ${native.stderr}`).toBe(0);

        const bundled = run(source);
        expect(bundled.status, `${methodKey}: ${bundled.stderr}`).toBe(0);
        const mode = (bundled.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(mode, `${methodKey}: ${bundled.stderr}`).toContain(
          retainsGraph ? 'semantic_graph=retained' : 'semantic_graph=reanalyzed',
        );
        if (retainsGraph) {
          const report = (bundled.stderr ?? '')
            .split(/\r?\n/)
            .find(
              (line) =>
                line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
            );
          expect(report, bundled.stderr).toBeDefined();
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(
              Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${counter}: ${report}`,
            ).toBe(0);
          }
          expect(report).toMatch(/clean=1(?:\s|$)/);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${methodKey}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, methodKey).toBe(native.stdout);
        expect(native.stdout, methodKey).toBe(
          `42 84 42 84 84 true ${keyCalls} direct-read,key,source-key,get-undefined,rhs,set-undefined direct-read,get-undefined 2 1 1 1\n`,
        );
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 async object super keeps unary plus BigInt chains on reanalysis and preserves TypeError', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-bigint-plus-super-key-'));
    const input = join(dir, 'entry.ts');
    const nativeInput = join(dir, 'oracle.mjs');
    const output = join(dir, 'out.cjs');
    try {
      for (const key of ['+1n', '~+1n']) {
        const source = [
          'var result;',
          'try {',
          `  var service = { async [${key}]() { return super.value; } };`,
          '  result = "created";',
          '} catch (error) {',
          '  result = error instanceof TypeError ? "TypeError" : "unexpected";',
          '}',
          'console.log(result);',
        ].join('\n');
        writeFileSync(input, source);
        writeFileSync(nativeInput, source);

        const native = spawnSync('node', [nativeInput], { encoding: 'utf8' });
        expect(native.status, `${key}: ${native.stderr}`).toBe(0);
        expect(native.stdout, key).toBe('TypeError\n');

        const bundled = spawnSync(
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
        expect(bundled.status, `${key}: ${bundled.stderr}`).toBe(0);
        const mode = (bundled.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(mode, `${key}: ${bundled.stderr}`).toContain('semantic_graph=reanalyzed');

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${key}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, key).toBe(native.stdout);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 async object methods retain audited super property reads and writes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es5-async-object-super-get-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
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

    try {
      const retained = run(
        [
          'var prototype = { get read() { return this.value; } };',
          "var key = 'read';",
          'var service = {',
          '  value: 42,',
          '  async readDirect() {',
          '    await Promise.resolve();',
          '    return super.read;',
          '  },',
          '  async readArrow() {',
          '    await Promise.resolve();',
          '    var read = async () => {',
          '      await Promise.resolve();',
          '      return super[key];',
          '    };',
          '    return await read();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'Promise.all([service.readDirect(), service.readArrow()]).then(values => console.log(values.join(":")));',
        ].join('\n'),
      );
      expect(retained.status, retained.stderr).toBe(0);
      const retainedMode = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(retainedMode, retained.stderr).toContain('semantic_graph=retained');
      const retainedReport = (retained.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(retainedReport, retained.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(retainedReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${retainedReport}`,
        ).toBe(0);
      }
      expect(retainedReport).toMatch(/clean=1(?:\s|$)/);
      const retainedOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(retainedOutput.status, retainedOutput.stderr).toBe(0);
      expect(retainedOutput.stdout).toBe('42:42\n');

      // A super read in a synchronous sibling method must not authorize the
      // helper import for the async-method retained graph.
      const synchronousSuper = run(
        [
          'var prototype = { get read() { return this.value; } };',
          'var service = {',
          '  value: 42,',
          '  async readAsync() {',
          '    await Promise.resolve();',
          '    return super.read;',
          '  },',
          '  readSync() { return super.read; },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.readAsync().then(value => console.log(value, service.readSync.call({ value: 7 })));',
        ].join('\n'),
      );
      expect(synchronousSuper.status, synchronousSuper.stderr).toBe(0);
      const synchronousSuperMode = (synchronousSuper.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(synchronousSuperMode, synchronousSuper.stderr).toContain('semantic_graph=reanalyzed');
      const synchronousSuperOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(synchronousSuperOutput.status, synchronousSuperOutput.stderr).toBe(0);
      expect(synchronousSuperOutput.stdout).toBe('42 7\n');

      const superWrite = run(
        [
          'var prototype = { set read(value) { this.value = value; } };',
          'var service = {',
          '  value: 42,',
          '  async writeSuper() {',
          '    await Promise.resolve();',
          '    return super.read = 50;',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.writeSuper().then(value => console.log(value, service.value));',
        ].join('\n'),
      );
      expect(superWrite.status, superWrite.stderr).toBe(0);
      const superWriteMode = (superWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(superWriteMode, superWrite.stderr).toContain('semantic_graph=retained');
      const superWriteReport = (superWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(superWriteReport, superWrite.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(superWriteReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${superWriteReport}`,
        ).toBe(0);
      }
      expect(superWriteReport).toMatch(/clean=1(?:\s|$)/);
      const superWriteOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(superWriteOutput.status, superWriteOutput.stderr).toBe(0);
      expect(superWriteOutput.stdout).toBe('50 50\n');

      const superLogicalWrite = run(
        [
          'var reads = 0; var writes = 0; var keyEvaluations = 0; var receiver;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'var prototype = {',
          '  get value() { reads += 1; return this._value; },',
          '  set value(next) { writes += 1; receiver = this; this._value = next; },',
          '};',
          'var service = {',
          '  _value: null,',
          '  async writeLogical(next) {',
          '    await Promise.resolve();',
          '    var write = async () => { await Promise.resolve(); return super[getKey()] ??= next; };',
          '    return await write();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.writeLogical(42).then(value => console.log(value, service._value, service === receiver, reads, writes, keyEvaluations));',
        ].join('\n'),
      );
      expect(superLogicalWrite.status, superLogicalWrite.stderr).toBe(0);
      const superLogicalWriteMode = (superLogicalWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(superLogicalWriteMode, superLogicalWrite.stderr).toContain('semantic_graph=retained');
      const superLogicalWriteReport = (superLogicalWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(superLogicalWriteReport, superLogicalWrite.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(superLogicalWriteReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${superLogicalWriteReport}`,
        ).toBe(0);
      }
      expect(superLogicalWriteReport).toMatch(/clean=1(?:\s|$)/);
      const superLogicalWriteOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(superLogicalWriteOutput.status, superLogicalWriteOutput.stderr).toBe(0);
      expect(superLogicalWriteOutput.stdout).toBe('42 42 true 1 1 1\n');

      const optionalSuperLogicalWrite = run(
        [
          'var events = []; var receiver;',
          'var keyEvaluations = 0, rhsEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
          'function getNext() { rhsEvaluations += 1; events.push("rhs"); return 42; }',
          'var keySource = { get key() { events.push("source-key"); return "value"; } };',
          'var prototype = {',
          '  get value() { reads += 1; events.push("get-value"); return this._value; },',
          '  set value(next) { writes += 1; events.push("set-value"); receiver = this; this._value = next; },',
          '  get undefined() { reads += 1; events.push("get-undefined"); return this._missing; },',
          '  set undefined(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
          '};',
          'var service = {',
          '  _value: null,',
          '  _missing: 5,',
          '  async writeOptional(source) {',
          '    await Promise.resolve();',
          '    var write = async () => {',
          '      await Promise.resolve();',
          '      return super[source?.[getKey()]] ??= getNext();',
          '    };',
          '    return await write();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.writeOptional(keySource).then(first => service.writeOptional(null).then(second => console.log(first, service._value, second, service._missing, service === receiver, events.join(","), reads, writes, keyEvaluations, rhsEvaluations)));',
        ].join('\n'),
      );
      expect(optionalSuperLogicalWrite.status, optionalSuperLogicalWrite.stderr).toBe(0);
      const optionalSuperLogicalWriteMode = (optionalSuperLogicalWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(optionalSuperLogicalWriteMode, optionalSuperLogicalWrite.stderr).toContain(
        'semantic_graph=retained',
      );
      const optionalSuperLogicalWriteReport = (optionalSuperLogicalWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(optionalSuperLogicalWriteReport, optionalSuperLogicalWrite.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(
            optionalSuperLogicalWriteReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1,
          ),
          `${counter}: ${optionalSuperLogicalWriteReport}`,
        ).toBe(0);
      }
      expect(optionalSuperLogicalWriteReport).toMatch(/clean=1(?:\s|$)/);
      const optionalSuperLogicalWriteOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(optionalSuperLogicalWriteOutput.status, optionalSuperLogicalWriteOutput.stderr).toBe(
        0,
      );
      expect(optionalSuperLogicalWriteOutput.stdout).toBe(
        '42 42 5 5 true key,source-key,get-value,rhs,set-value,get-undefined 2 1 1 1\n',
      );

      const optionalSuperAssignmentMatrix = run(
        [
          'var events = []; var receiver;',
          'var keyEvaluations = 0, nullishEvaluations = 0, logicalOrEvaluations = 0, logicalAndEvaluations = 0, powerEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
          'function getNullish() { nullishEvaluations += 1; events.push("rhs-nullish"); return 8; }',
          'function getLogicalOr() { logicalOrEvaluations += 1; events.push("rhs-or"); return 11; }',
          'function getLogicalAnd() { logicalAndEvaluations += 1; events.push("rhs-and"); return 12; }',
          'function getPower() { powerEvaluations += 1; events.push("rhs-power"); return 2; }',
          'var keySource = { get key() { events.push("source-key"); return "value"; } };',
          'var prototype = {',
          '  get value() { reads += 1; events.push("get-value"); return this._value; },',
          '  set value(next) { writes += 1; events.push("set-value"); receiver = this; this._value = next; },',
          '  get undefined() { reads += 1; events.push("get-undefined"); return this._missing; },',
          '  set undefined(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
          '};',
          'var service = {',
          '  _value: null,',
          '  _missing: 5,',
          '  async updateOptional(source) {',
          '    await Promise.resolve();',
          '    var update = async () => {',
          '      await Promise.resolve();',
          '      var nullish = super[source?.[getKey()]] ??= getNullish();',
          '      var either = super[source?.[getKey()]] ||= getLogicalOr();',
          '      var both = super[source?.[getKey()]] &&= getLogicalAnd();',
          '      var powered = super[source?.[getKey()]] **= getPower();',
          '      return [nullish, either, both, powered].join(" ");',
          '    };',
          '    return await update();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.updateOptional(keySource).then(first => service.updateOptional(null).then(second => console.log(first, service._value, second, service._missing, service === receiver, events.join(","), reads, writes, keyEvaluations, nullishEvaluations, logicalOrEvaluations, logicalAndEvaluations, powerEvaluations)));',
        ].join('\n'),
      );
      expect(optionalSuperAssignmentMatrix.status, optionalSuperAssignmentMatrix.stderr).toBe(0);
      const optionalSuperAssignmentMatrixMode = (optionalSuperAssignmentMatrix.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(optionalSuperAssignmentMatrixMode, optionalSuperAssignmentMatrix.stderr).toContain(
        'semantic_graph=retained',
      );
      const optionalSuperAssignmentMatrixReport = (optionalSuperAssignmentMatrix.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(
        optionalSuperAssignmentMatrixReport,
        optionalSuperAssignmentMatrix.stderr,
      ).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(
            optionalSuperAssignmentMatrixReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1,
          ),
          `${counter}: ${optionalSuperAssignmentMatrixReport}`,
        ).toBe(0);
      }
      expect(optionalSuperAssignmentMatrixReport).toMatch(/clean=1(?:\s|$)/);
      const optionalSuperAssignmentMatrixOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(
        optionalSuperAssignmentMatrixOutput.status,
        optionalSuperAssignmentMatrixOutput.stderr,
      ).toBe(0);
      expect(optionalSuperAssignmentMatrixOutput.stdout).toBe(
        '8 8 12 144 144 5 5 12 144 144 true key,source-key,get-value,rhs-nullish,set-value,key,source-key,get-value,key,source-key,get-value,rhs-and,set-value,key,source-key,get-value,rhs-power,set-value,get-undefined,get-undefined,get-undefined,rhs-and,set-undefined,get-undefined,rhs-power,set-undefined 8 5 4 1 0 2 2\n',
      );

      const untrackedOptionalObjectSuperExponentiationKey = run(
        [
          'var keyEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; return "key"; }',
          'globalThis.__zntcUntrackedObjectSuperKey = { key: "value" };',
          'var prototype = {',
          '  get value() { reads += 1; return this._value; },',
          '  set value(next) { writes += 1; this._value = next; },',
          '};',
          'var service = {',
          '  _value: 3,',
          '  async update() {',
          '    await Promise.resolve();',
          '    var update = async () => {',
          '      await Promise.resolve();',
          '      return super[globalThis.__zntcUntrackedObjectSuperKey?.[getKey()]] **= 2;',
          '    };',
          '    return await update();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.update().then(value => console.log(value, service._value, keyEvaluations, reads, writes));',
        ].join('\n'),
      );
      expect(
        untrackedOptionalObjectSuperExponentiationKey.status,
        untrackedOptionalObjectSuperExponentiationKey.stderr,
      ).toBe(0);
      const untrackedOptionalObjectSuperExponentiationKeyMode = (
        untrackedOptionalObjectSuperExponentiationKey.stderr ?? ''
      )
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(untrackedOptionalObjectSuperExponentiationKeyMode).toContain(
        'semantic_graph=reanalyzed',
      );
      const untrackedOptionalObjectSuperExponentiationKeyOutput = spawnSync('node', [output], {
        encoding: 'utf8',
      });
      expect(
        untrackedOptionalObjectSuperExponentiationKeyOutput.status,
        untrackedOptionalObjectSuperExponentiationKeyOutput.stderr,
      ).toBe(0);
      expect(untrackedOptionalObjectSuperExponentiationKeyOutput.stdout).toBe('9 9 1 1 1\n');

      const methodDepthOptionalSuperAssignment = run(
        [
          'var events = []; var receiver;',
          'var keyEvaluations = 0, nullishEvaluations = 0, powerEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; events.push("key"); return "key"; }',
          'function getNullish() { nullishEvaluations += 1; events.push("rhs-nullish"); return 8; }',
          'function getPower() { powerEvaluations += 1; events.push("rhs-power"); return 2; }',
          'var keySource = { get key() { events.push("source-key"); return "value"; } };',
          'var prototype = {',
          '  get value() { reads += 1; events.push("get-value"); return this._value; },',
          '  set value(next) { writes += 1; events.push("set-value"); receiver = this; this._value = next; },',
          '  get undefined() { reads += 1; events.push("get-undefined"); return this._missing; },',
          '  set undefined(next) { writes += 1; events.push("set-undefined"); receiver = this; this._missing = next; },',
          '};',
          'var service = {',
          '  _value: null,',
          '  _missing: 5,',
          '  async updateOptional(source) {',
          '    await Promise.resolve();',
          '    var nullish = super[source?.[getKey()]] ??= getNullish();',
          '    var powered = super[source?.[getKey()]] **= getPower();',
          '    return [nullish, powered].join(" ");',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.updateOptional(keySource).then(first => service.updateOptional(null).then(second => console.log(first, service._value, second, service._missing, service === receiver, events.join(","), reads, writes, keyEvaluations, nullishEvaluations, powerEvaluations)));',
        ].join('\n'),
      );
      expect(
        methodDepthOptionalSuperAssignment.status,
        methodDepthOptionalSuperAssignment.stderr,
      ).toBe(0);
      const methodDepthOptionalSuperAssignmentMode = (
        methodDepthOptionalSuperAssignment.stderr ?? ''
      )
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(methodDepthOptionalSuperAssignmentMode).toContain('semantic_graph=retained');
      const methodDepthOptionalSuperAssignmentReport = (
        methodDepthOptionalSuperAssignment.stderr ?? ''
      )
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(methodDepthOptionalSuperAssignmentReport).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(
            methodDepthOptionalSuperAssignmentReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ??
              -1,
          ),
          `${counter}: ${methodDepthOptionalSuperAssignmentReport}`,
        ).toBe(0);
      }
      expect(methodDepthOptionalSuperAssignmentReport).toMatch(/clean=1(?:\s|$)/);
      const methodDepthOptionalSuperAssignmentOutput = spawnSync('node', [output], {
        encoding: 'utf8',
      });
      expect(
        methodDepthOptionalSuperAssignmentOutput.status,
        methodDepthOptionalSuperAssignmentOutput.stderr,
      ).toBe(0);
      expect(methodDepthOptionalSuperAssignmentOutput.stdout).toBe(
        '8 64 64 5 25 25 true key,source-key,get-value,rhs-nullish,set-value,key,source-key,get-value,rhs-power,set-value,get-undefined,get-undefined,rhs-power,set-undefined 4 3 2 1 2\n',
      );

      const untrackedMethodDepthOptionalObjectSuperKey = run(
        [
          'var keyEvaluations = 0, reads = 0, writes = 0;',
          'function getKey() { keyEvaluations += 1; return "key"; }',
          'globalThis.__zntcUntrackedDirectObjectSuperKey = { key: "value" };',
          'var prototype = {',
          '  get value() { reads += 1; return this._value; },',
          '  set value(next) { writes += 1; this._value = next; },',
          '};',
          'var service = {',
          '  _value: null,',
          '  async update() {',
          '    await Promise.resolve();',
          '    return super[globalThis.__zntcUntrackedDirectObjectSuperKey?.[getKey()]] ??= 8;',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.update().then(value => console.log(value, service._value, keyEvaluations, reads, writes));',
        ].join('\n'),
      );
      expect(
        untrackedMethodDepthOptionalObjectSuperKey.status,
        untrackedMethodDepthOptionalObjectSuperKey.stderr,
      ).toBe(0);
      const untrackedMethodDepthOptionalObjectSuperKeyMode = (
        untrackedMethodDepthOptionalObjectSuperKey.stderr ?? ''
      )
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(untrackedMethodDepthOptionalObjectSuperKeyMode).toContain('semantic_graph=reanalyzed');
      const untrackedMethodDepthOptionalObjectSuperKeyOutput = spawnSync('node', [output], {
        encoding: 'utf8',
      });
      expect(
        untrackedMethodDepthOptionalObjectSuperKeyOutput.status,
        untrackedMethodDepthOptionalObjectSuperKeyOutput.stderr,
      ).toBe(0);
      expect(untrackedMethodDepthOptionalObjectSuperKeyOutput.stdout).toBe('8 8 1 1 1\n');

      const superExponentiationWrite = run(
        [
          'var reads = 0; var writes = 0; var keyEvaluations = 0; var receiver;',
          'function getKey() { keyEvaluations += 1; return "value"; }',
          'var prototype = {',
          '  get value() { reads += 1; return this._value; },',
          '  set value(next) { writes += 1; receiver = this; this._value = next; },',
          '};',
          'var service = {',
          '  _value: 3,',
          '  async writeExponentiation(power) {',
          '    await Promise.resolve();',
          '    var write = async () => { await Promise.resolve(); return super[getKey()] **= power; };',
          '    return await write();',
          '  },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.writeExponentiation(2).then(value => console.log(value, service._value, service === receiver, reads, writes, keyEvaluations));',
        ].join('\n'),
      );
      expect(superExponentiationWrite.status, superExponentiationWrite.stderr).toBe(0);
      const superExponentiationWriteMode = (superExponentiationWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(superExponentiationWriteMode, superExponentiationWrite.stderr).toContain(
        'semantic_graph=retained',
      );
      const superExponentiationWriteReport = (superExponentiationWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(superExponentiationWriteReport, superExponentiationWrite.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(superExponentiationWriteReport?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${superExponentiationWriteReport}`,
        ).toBe(0);
      }
      expect(superExponentiationWriteReport).toMatch(/clean=1(?:\s|$)/);
      const superExponentiationWriteOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(superExponentiationWriteOutput.status, superExponentiationWriteOutput.stderr).toBe(0);
      expect(superExponentiationWriteOutput.stdout).toBe('9 9 true 1 1 1\n');

      // A synchronous sibling's super write must not authorize __superSet
      // for the async-method retained graph.
      const synchronousSuperWrite = run(
        [
          'var prototype = { set read(value) { this.value = value; } };',
          'var service = {',
          '  value: 42,',
          '  async writeAsync() {',
          '    await Promise.resolve();',
          '    return super.read = 50;',
          '  },',
          '  writeSync(value) { return super.read = value; },',
          '};',
          'Object.setPrototypeOf(service, prototype);',
          'service.writeAsync().then(value => {',
          '  var other = { value: 7 };',
          '  var syncValue = service.writeSync.call(other, 60);',
          '  console.log(value, service.value, syncValue, other.value);',
          '});',
        ].join('\n'),
      );
      expect(synchronousSuperWrite.status, synchronousSuperWrite.stderr).toBe(0);
      const synchronousSuperWriteMode = (synchronousSuperWrite.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(synchronousSuperWriteMode, synchronousSuperWrite.stderr).toContain(
        'semantic_graph=reanalyzed',
      );
      const synchronousSuperWriteOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(synchronousSuperWriteOutput.status, synchronousSuperWriteOutput.stderr).toBe(0);
      expect(synchronousSuperWriteOutput.stdout).toBe('50 50 60 60\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('async function state machines and top-level await use audited graph paths', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-native-await-retained-'));
    const output = join(dir, 'out.cjs');
    const esmOutput = join(dir, 'tla-out.mjs');
    const iifeOutput = join(dir, 'iife-out.js');
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

      // The IIFE async-factory option is a no-op for modules without TLA.
      // Keep their edited graph instead of forcing an unnecessary rescan.
      const nonTlaIife = run('--target=es2022', 'iife', iifeOutput);
      expect(nonTlaIife.status, nonTlaIife.stderr).toBe(0);
      const nonTlaIifeMode = (nonTlaIife.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(nonTlaIifeMode, nonTlaIife.stderr).toContain('semantic_graph=retained');
      const nonTlaIifeOutput = spawnSync('node', [iifeOutput], { encoding: 'utf8' });
      expect(nonTlaIifeOutput.status, nonTlaIifeOutput.stderr).toBe(0);
      expect(nonTlaIifeOutput.stdout).toBe('42\n');

      // Ordinary async function lowering now keeps its edited generator scope
      // and helper identity without replacing the source semantic graph.
      const downlevel = run('--target=es2015');
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
      expect(downlevelOutput.stdout).toBe('42\n');

      // ES5 lowers both async and generator syntax into an explicit state
      // machine. Its generated wrapper/callback identities are already
      // recorded by the semantic editor, so the parser graph remains exact.
      writeFileSync(
        input,
        [
          'var offset = 10;',
          'async function calculate(value) {',
          '  var _state = 4, _context = 4, _arguments = arguments[0];',
          '  await Promise.resolve(value);',
          '  return value + offset + _state + _context + _arguments;',
          '}',
          'calculate(12).then(function(result) { console.log(result); });',
        ].join('\n'),
      );
      const es5 = run('--target=es5');
      expect(es5.status, es5.stderr).toBe(0);
      const es5Mode = (es5.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(es5Mode, es5.stderr).toContain('semantic_graph=retained');
      const es5Report = (es5.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
      expect(es5Report, es5.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(es5Report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${es5Report}`,
        ).toBe(0);
      }
      expect(es5Report).toMatch(/clean=1(?:\s|$)/);
      const es5Output = spawnSync('node', [output], { encoding: 'utf8' });
      expect(es5Output.status, es5Output.stderr).toBe(0);
      expect(es5Output.stdout).toBe('42\n');

      // Direct eval can observe generated state-machine names. Keep that
      // shape on the existing full semantic resync path.
      writeFileSync(
        input,
        [
          'async function calculate(value) {',
          '  await Promise.resolve();',
          "  return eval('value') + 1;",
          '}',
          'calculate(41).then(value => console.log(value));',
        ].join('\n'),
      );
      const directEval = run('--target=es5');
      expect(directEval.status, directEval.stderr).toBe(0);
      const directEvalMode = (directEval.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(directEvalMode, directEval.stderr).toContain('semantic_graph=reanalyzed');
      const directEvalOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(directEvalOutput.status, directEvalOutput.stderr).toBe(0);
      expect(directEvalOutput.stdout).toBe('42\n');

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

  test('ES2015 async functions and capture-free arrows retain their exact graph', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es2015-async-retained-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');
    writeFileSync(
      input,
      [
        'type Count = number;',
        'async function calculate(value: Count) {',
        '  const _this = 5, _arguments = 6;',
        '  const captured = () => this.base + arguments[0] + _this + _arguments;',
        '  await Promise.resolve(value);',
        '  return captured() + value;',
        '}',
        'const expression = async function (value: Count) { await Promise.resolve(value); return value + 2; };',
        'const arrow = async (value: Count) => { const before = value + 1; await Promise.resolve(before); return before + value; };',
        'Promise.all([calculate.call({ base: 1 }, 40), expression(40), arrow(20)]).then(([captured, result, arrowResult]) => console.log(captured + ":" + result + ":" + arrowResult));',
      ].join('\n'),
    );

    const run = (minifyIdentifiers: boolean) =>
      spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          input,
          '--target=es2015',
          '--platform=node',
          '--format=cjs',
          ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
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
      for (const minifyIdentifiers of [false, true]) {
        const proc = run(minifyIdentifiers);
        expect(proc.status, proc.stderr).toBe(0);
        const mode = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
          );
        expect(mode, proc.stderr).toContain('semantic_graph=retained');
        const report = (proc.stderr ?? '')
          .split(/\r?\n/)
          .find(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
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
        expect(execution.stdout).toBe('92:42:41\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES2015 async-arrow and ES5 async-function graphs retain while unsupported cases reanalyze', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bundle-es2015-async-fallback-'));
    const output = join(dir, 'out.cjs');
    const input = join(dir, 'entry.ts');

    const run = (target = '--target=es2015') =>
      spawnSync(
        ZNTC_BIN,
        ['--bundle', input, target, '--platform=node', '--format=cjs', '-o', output],
        {
          cwd: dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
    const expectReanalyzedAndRuns = (proc: ReturnType<typeof run>, expectedOutput: string) => {
      expect(proc.status, proc.stderr).toBe(0);
      const mode = (proc.stderr ?? '')
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
      expect(mode, proc.stderr).toContain('semantic_graph=reanalyzed');
      const execution = spawnSync('node', [output], { encoding: 'utf8' });
      expect(execution.status, execution.stderr).toBe(0);
      expect(execution.stdout).toBe(expectedOutput);
    };
    const expectRetainedAndRuns = (proc: ReturnType<typeof run>, expectedOutput: string) => {
      expect(proc.status, proc.stderr).toBe(0);
      const lines = (proc.stderr ?? '').split(/\r?\n/);
      const mode = lines.find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
      );
      expect(mode, proc.stderr).toContain('semantic_graph=retained');
      const report = lines.find(
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
      const execution = spawnSync('node', [output], { encoding: 'utf8' });
      expect(execution.status, execution.stderr).toBe(0);
      expect(execution.stdout).toBe(expectedOutput);
    };

    try {
      writeFileSync(
        input,
        [
          'function readThis() {',
          '  return (async () => { await Promise.resolve(); return this.base; })();',
          '}',
          'readThis.call({ base: 40 }).then(result => console.log(result + 2));',
        ].join('\n'),
      );
      expectRetainedAndRuns(run(), '42\n');

      writeFileSync(
        input,
        [
          'const task = { async run(value: number) { await Promise.resolve(value); return value + 1; } };',
          'task.run(41).then(result => console.log(result));',
        ].join('\n'),
      );
      expectReanalyzedAndRuns(run(), '42\n');

      writeFileSync(
        input,
        [
          'async function read(value: number) { await Promise.resolve(value); return value + 1; }',
          'read(41).then(result => console.log(result));',
        ].join('\n'),
      );
      expectRetainedAndRuns(run('--target=es5'), '42\n');

      writeFileSync(
        input,
        [
          'async function drain(values: number[]) {',
          '  for await (const value of values) console.log(value);',
          '}',
          'drain([42]);',
        ].join('\n'),
      );
      expectReanalyzedAndRuns(run(), '42\n');

      writeFileSync(
        input,
        [
          'async function read(value: number) {',
          "  eval('console.log(value + 1)');",
          '  await Promise.resolve(value);',
          '}',
          'read(41);',
        ].join('\n'),
      );
      expectReanalyzedAndRuns(run(), '42\n');
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

  test('ES5 class-method Object shadow checks follow the class lexical scope', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-class-method-object-shadow-scope-'));
    const input = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    const cases = [
      {
        label: 'Object in an unrelated function',
        graph: 'retained',
        shadowedExternal: 0,
        source: [
          'function unrelated(Object) { return Object; }',
          'class Handler { read() { return 42; } }',
          'console.log(new Handler().read());',
        ].join('\n'),
      },
      {
        label: 'Object in the class declaration scope',
        graph: 'reanalyzed',
        shadowedExternal: 1,
        source: [
          'function run(Object) {',
          '  class Handler { read() { return 42; } }',
          '  return new Handler().read();',
          '}',
          'console.log(run({ defineProperty: function () { throw new Error("source Object was called"); } }));',
        ].join('\n'),
      },
    ];

    try {
      for (const fixture of cases) {
        writeFileSync(input, fixture.source);
        const proc = spawnSync(
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
        expect(proc.status, `${fixture.label}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const report = lines.find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
        expect(report, `${fixture.label}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          const expected = counter === 'shadowed_external_reference' ? fixture.shadowedExternal : 0;
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.label}: ${counter}: ${report}`,
          ).toBe(expected);
        }
        expect(report, fixture.label).toMatch(
          fixture.shadowedExternal === 0 ? /clean=1(?:\s|$)/ : /clean=0(?:\s|$)/,
        );

        const graphMode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
        expect(graphMode, `${fixture.label}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.label}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.label).toBe('42\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 static-field lowering avoids module-wide Object veto and preserves class shadow fallback', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-static-field-object-shadow-scope-'));
    const input = join(dir, 'entry.ts');
    const output = join(dir, 'out.cjs');
    const cases = [
      {
        label: 'Object in an unrelated function',
        graph: 'retained',
        shadowedExternal: 0,
        source: [
          'function unrelated(Object) { return Object; }',
          'console.log(unrelated(7));',
          'class Handler { static value = 42; }',
          'console.log(Handler.value);',
        ].join('\n'),
        output: '7\n42\n',
      },
      {
        label: 'Object in the static-field declaration scope',
        graph: 'reanalyzed',
        shadowedExternal: 1,
        source: [
          'function read(Object) {',
          '  class Handler { static value = 42; }',
          '  return Handler.value;',
          '}',
          'console.log(read({ defineProperty: function () { throw new Error("source Object was called"); } }));',
        ].join('\n'),
        output: '42\n',
      },
    ];

    try {
      for (const fixture of cases) {
        writeFileSync(input, fixture.source);
        const proc = spawnSync(
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
        expect(proc.status, `${fixture.label}: ${proc.stderr}`).toBe(0);

        const lines = (proc.stderr ?? '').split(/\r?\n/);
        const report = lines.find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.ts'),
        );
        expect(report, `${fixture.label}: ${proc.stderr}`).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          const expected = counter === 'shadowed_external_reference' ? fixture.shadowedExternal : 0;
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.label}: ${counter}: ${report}`,
          ).toBe(expected);
        }
        expect(report, fixture.label).toMatch(
          fixture.shadowedExternal === 0 ? /clean=1(?:\s|$)/ : /clean=0(?:\s|$)/,
        );

        const graphMode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.ts'),
        );
        expect(graphMode, `${fixture.label}: ${proc.stderr}`).toContain(
          `semantic_graph=${fixture.graph}`,
        );
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.label}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.label).toBe(fixture.output);
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
        mode: 'classic-spread-attribute-unrelated-object-retained',
        graph: 'retained',
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
        mode: 'classic-spread-attribute-same-scope-object-shadow-fallback',
        graph: 'reanalyzed',
        args: ['--jsx=classic', '--jsx-factory=h'],
        source: [
          'function h(tag, props) { return [tag, props]; }',
          'var props = { value: 42 };',
          'function render(Object) { return <div {...props} />; }',
          'console.log(JSON.stringify(render({ assign() { throw new Error("shadowed Object was called"); } })));',
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
        const hasExpectedShadowedExternal =
          fixture.mode === 'classic-spread-attribute-same-scope-object-shadow-fallback';
        for (const counter of EXACT_ZERO_COUNTERS) {
          const expected =
            hasExpectedShadowedExternal && counter === 'shadowed_external_reference' ? 1 : 0;
          expect(
            Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${fixture.mode}: ${report}`,
          ).toBe(expected);
        }
        expect(report, `${fixture.mode}: ${report}`).toMatch(
          hasExpectedShadowedExternal ? /clean=0(?:\s|$)/ : /clean=1(?:\s|$)/,
        );

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
        'var topLevel = new (getPair())(...[6, 7]);',
        'console.log(make([4, 7]).total, makeIndirect([5, 6]).total, topLevel.total, constructorCalls);',
      ].join('\n'),
    );
    try {
      const { stderr, exitCode } = runCoverage(file, TARGETS[0], outDir);
      expect(exitCode, stderr).toBe(0);
      expect(transformIdentityAuditProblems(stderr), stderr).toEqual([]);

      const actual = spawnSync('node', [join(outDir, 'out.js')], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('11 11 13 2\n');
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
        graph: 'retained',
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
        expect(postMinifyAuditProblems(proc.stderr), `${target.name}: ${proc.stderr}`).toEqual([]);
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

  test('legacy computed decorator keys evaluate once and keep exact temp references', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-legacy-computed-decorator-key-'));
    try {
      const file = join(outDir, 'input.ts');
      const source = `const _a = 'user-temp-name';
const events: string[] = [];
function base() { events.push('base'); return class {}; }
function methodKey() { events.push('method-key'); return 'run'; }
function staticKey() { events.push('static-key'); return 'build'; }
function getterKey() { events.push('getter-key'); return 'label'; }
function methodDec(target: any, key: string, descriptor: PropertyDescriptor): PropertyDescriptor { events.push('method:' + key); return descriptor; }
function makeMethodExample() {
  const _a = 'nested-user-temp-name';
  class MethodExample extends base() {
    @methodDec [methodKey()]() { return 7; }
    userName() { return _a; }
  }
  return MethodExample;
}
const MethodExample = makeMethodExample();
class StaticExample {
  @methodDec static [staticKey()]() { return 9; }
}
class GetterExample {
  @methodDec get [getterKey()]() { return 'getter'; }
}
console.log(_a, events.join(','), new MethodExample().run(), new MethodExample().userName(), StaticExample.build(), new GetterExample().label);
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
      expect(oracle.stdout).toBe(
        'user-temp-name base,method-key,method:run,static-key,method:build,getter-key,method:label 7 nested-user-temp-name 9 getter\n',
      );

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
        expect(postMinifyAuditProblems(proc.stderr), `${target.name}: ${proc.stderr}`).toEqual([]);
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

  test('legacy computed parameter decorators keep an exact key reference', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-legacy-computed-parameter-decorator-'));
    try {
      const file = join(outDir, 'input.ts');
      const source = `const _a = 'user-temp-name';
const events: string[] = [];
function key() { events.push('key'); return 'act'; }
function parameterDec(target: any, key: string, index: number): void { events.push('parameter:' + key + ':' + index); }
class Example {
  [key()](@parameterDec value: number) { return value + 2; }
}
console.log(_a, events.join(','), new Example().act(5));
`;
      writeFileSync(file, source);

      // TypeScript 6 emits an unbound temp for this parameter-only computed key, so assert its runtime contract directly.
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
        expect(postMinifyAuditProblems(proc.stderr), `${target.name}: ${proc.stderr}`).toEqual([]);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(
            Number(identity?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
            `${target.name}: ${counter}: ${identity}`,
          ).toBe(0);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, `${target.name}: computed parameter decorator output`).toBe(
          'user-temp-name key,parameter:act:0 7\n',
        );
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });

  test('legacy computed field decorators use a fresh exact key reference', () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-legacy-computed-field-decorator-'));
    try {
      const file = join(outDir, 'input.ts');
      const source = `const _a = 'user-temp-name';
let count = 0;
const events: string[] = [];
function key() { events.push('instance-key'); count++; return 'value'; }
function staticKey() { events.push('static-key'); count++; return 'staticValue'; }
function methodKey() { events.push('method-key'); count++; return 'run'; }
function fieldDec(target: any, key: string): void {}
function methodDec(target: any, key: string, descriptor: PropertyDescriptor): PropertyDescriptor { return descriptor; }
class Example {
  @fieldDec [key()] = 1;
  @fieldDec static [staticKey()] = 2;
  @methodDec [methodKey()]() { return 3; }
}
console.log(_a, new Example().value, Example.staticValue, new Example().run(), count, events.join(','));
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
      expect(oracle.stdout).toBe('user-temp-name 1 2 3 3 instance-key,static-key,method-key\n');

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
        expect(postMinifyAuditProblems(proc.stderr), `${target.name}: ${proc.stderr}`).toEqual([]);
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
function computedKey() { events.push('computed'); return 'value'; }
const Holder = class Inner {
  @methodDec method(value: number): number { return value + 1; }
  static value = (events.push('static'), 7);
  static selfValue = Inner;
  static self() { return Inner; }
};
const Anonymous = class {
  @methodDec [computedKey()](): number { return 3; }
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
      expect(oracle.stdout).toBe('4 true 7 true 3 static,computed\n');
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

  test('Stage 3 anonymous class wrapper gets its final name from its exact SymbolId', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-stage3-anonymous-class-name-'));
    const input = join(dir, 'entry.flow');
    const output = join(dir, 'out.js');
    writeFileSync(
      input,
      [
        '// @flow',
        'const _Class = 17;',
        'function identity(value, context) { return value; }',
        'const Decorated = @identity class { static read() { return _Class; } };',
        'console.log(Decorated.read(), Decorated.name);',
      ].join('\n'),
    );

    try {
      for (const minify of [false, true]) {
        const args = [input, '--flow', '--target=es5'];
        if (minify) args.push('--minify-identifiers');
        args.push('-o', output);
        const proc = spawnSync(ZNTC_BIN, args, {
          env: {
            ...process.env,
            ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
            ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          },
          encoding: 'utf8',
        });
        expect(proc.status, `${minify ? 'minified' : 'plain'}: ${proc.stderr}`).toBe(0);
        const identity = proc.stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity '));
        expect(identity, `${minify ? 'minified' : 'plain'}: missing exact report`).toBeDefined();
        expect(exactSchemaProblems(identity!), identity).toEqual([]);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${minify ? 'minified' : 'plain'}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe('17 Decorated\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
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

  test('Reanimated class factory closure key does not capture same-named source locals', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-class-factory-name-collision-'));
    const entry = join(dir, 'entry.js');
    const outputPath = join(dir, 'out.cjs');
    const resultPath = join(dir, 'result.json');
    writeFileSync(
      entry,
      [
        'const __zntcWorkletClass\\u0046actory = 75;',
        'const Clazz__classFactory = 73;',
        'const Other__classFactory = 74;',
        'class Clazz { __workletClass = true; static capturedFactoryName() { return Clazz__classFactory; } static capturedStagingName() { return __zntcWorkletClass\\u0046actory; } value() { return 1; } }',
        'class Other { __workletClass = true; value() { return 2; } }',
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
        'globalThis.__zntcWorkletClassFactoryResult = () => ({ closureMatchesSource: Clazz.Clazz__classFactory.__closure.Clazz__classFactory === 73, stagingCaptureValue: Clazz.Clazz__classFactory().capturedStagingName(), name: Clazz.Clazz__classFactory.name });',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const { build } = await import(coreEntry);
    try {
      for (const minifyIdentifiers of [false, true]) {
        const result = await build({
          entryPoints: [entry],
          platform: 'react-native',
          format: 'cjs',
          target: 'esnext',
          workletTransform: true,
          minifyIdentifiers,
          write: false,
        });
        expect(result.errors).toEqual([]);
        expect(result.outputFiles).toHaveLength(1);
        const output = result.outputFiles[0]!.text;
        expect(output).toMatch(/Clazz__classFactory:\s*[A-Za-z_$][\w$]*\.Clazz__classFactory/);
        expect(output).toMatch(/Other__classFactory:\s*[A-Za-z_$][\w$]*\.Other__classFactory/);
        writeFileSync(outputPath, output);
        const actual = spawnSync(
          'node',
          [
            '-e',
            `require(${JSON.stringify(outputPath)}); require('node:fs').writeFileSync(${JSON.stringify(resultPath)}, JSON.stringify(globalThis.__zntcWorkletClassFactoryResult()));`,
          ],
          { encoding: 'utf8' },
        );
        expect(actual.status, actual.stderr).toBe(0);
        const classFactoryResult = JSON.parse(readFileSync(resultPath, 'utf8')) as {
          closureMatchesSource: boolean;
          stagingCaptureValue: number;
          name: string;
        };
        expect(classFactoryResult.closureMatchesSource).toBe(true);
        expect(classFactoryResult.stagingCaptureValue).toBe(75);
        if (!minifyIdentifiers) expect(classFactoryResult.name).toBe('Clazz__classFactory$1');
        expect(classFactoryResult.name).not.toContain('__zntcWorkletClassFactory');
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

        const classFactoryInitCode = initDataCodes.find((code) =>
          code.startsWith('function Clazz__classFactory('),
        );
        expect(classFactoryInitCode).toBeDefined();
        if (classFactoryInitCode) {
          expect(classFactoryInitCode).toMatch(
            /const \{[^}]*\bClazz__classFactory\b[^}]*\}=this\.__closure;/,
          );
          const generated = new Function(`return (${classFactoryInitCode});`)() as (this: {
            __closure: Record<string, unknown>;
          }) => { capturedFactoryName: () => unknown };
          const reconstructed = generated.call({ __closure: { Clazz__classFactory: 73 } });
          expect(reconstructed.capturedFactoryName()).toBe(73);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test('Reanimated class factory supports long legal class names', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-worklet-long-class-factory-'));
    const entry = join(dir, 'entry.js');
    const outputPath = join(dir, 'out.cjs');
    const className = `Long${'A'.repeat(116)}`;
    writeFileSync(
      entry,
      [
        `class ${className} { __workletClass = true; value() { return 42; } }`,
        `const Recreated = ${className}.${className}__classFactory();`,
        'globalThis.__zntcLongWorkletClassFactory = new Recreated().value();',
      ].join('\n'),
    );

    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const { build } = await import(coreEntry);
    try {
      for (const minifyIdentifiers of [false, true]) {
        const result = await build({
          entryPoints: [entry],
          platform: 'react-native',
          format: 'cjs',
          target: 'esnext',
          workletTransform: true,
          minifyIdentifiers,
          write: false,
        });
        expect(result.errors).toEqual([]);
        expect(result.outputFiles).toHaveLength(1);
        writeFileSync(outputPath, result.outputFiles[0]!.text);

        const actual = spawnSync(
          'node',
          [
            '-e',
            `require(${JSON.stringify(outputPath)}); if (globalThis.__zntcLongWorkletClassFactory !== 42) process.exitCode = 1;`,
          ],
          { encoding: 'utf8' },
        );
        expect(actual.status, actual.stderr).toBe(0);
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

  test('Emotion css prop avoids escaped lexical shadows of its import', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emotion-escaped-shadow-'));
    const emotionDir = join(dir, 'node_modules', '@emotion', 'react');
    mkdirSync(emotionDir, { recursive: true });
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ compiler: { emotion: true } }));
    writeFileSync(
      join(emotionDir, 'package.json'),
      JSON.stringify({ name: '@emotion/react', version: '0.0.0-test', main: 'index.js' }),
    );
    writeFileSync(
      join(emotionDir, 'index.js'),
      "exports.css = function(value) { return 'EMOTION:' + value.color; };",
    );

    try {
      const source = [
        "import { css } from '@emotion/react';",
        'function h(_tag, props) { return props.css; }',
        'function render(c\\u0073s) {',
        "  return <div css={{ color: 'red' }} />;",
        '}',
        "console.log(render(() => 'SHADOWED'));",
        '',
      ].join('\n');
      writeFileSync(join(dir, 'index.tsx'), source);
      const output = join(dir, 'out.js');
      const proc = spawnSync(
        'bun',
        [
          ZNTC_JS_CLI,
          '--bundle',
          'index.tsx',
          '--target=esnext',
          '--jsx=classic',
          '--jsx-factory=h',
          '-o',
          output,
        ],
        { cwd: dir, encoding: 'utf8' },
      );
      expect(proc.status, proc.stderr).toBe(0);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('EMOTION:red\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('bundler Emotion keeps direct eval on semantic reanalysis', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emotion-eval-reanalysis-'));
    const output = join(dir, 'out.cjs');
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ compiler: { emotion: true } }));
    // The Emotion pre-pass only runs for a module importing Emotion (#5795).
    const emotionDir = join(dir, 'node_modules', '@emotion', 'react');
    mkdirSync(emotionDir, { recursive: true });
    writeFileSync(
      join(emotionDir, 'package.json'),
      JSON.stringify({ name: '@emotion/react', version: '0.0.0-test', main: 'index.js' }),
    );
    writeFileSync(join(emotionDir, 'index.js'), 'exports.css = function() { return 1; };');
    writeFileSync(
      join(dir, 'entry.tsx'),
      "import { css } from '@emotion/react';\nvoid css;\nvoid eval('40 + 2');\n",
    );
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
          for (const observationProblem of exactIdentityObservationProblems(identity)) {
            problems.push(
              `${name} ${target.name}: exact report ${observationProblem}: ${identity}`,
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
    expect(runs).toBe(fixtures.length * TARGETS.length);
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
      // synthetic identity markers now. The fifth is the generated self-name
      // of the lowered `read` method (`value: function read() {}`).
      expect(proc.stderr).toMatch(/synthetic-coverage .* marked_synthetic=5/);
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
        name: 'unresolved global initializer retains its external reference on the edited graph',
        source:
          'globalThis.__zntcStaticFieldValue = 17; class GlobalStaticField { static value = __zntcStaticFieldValue; } console.log(GlobalStaticField.value);',
        graph: 'retained',
        output: '17\n',
      },
      {
        name: 'unresolved temp-like global remains visible beside a computed static field key',
        source:
          'globalThis._a = 17; function fieldKey() { return "value"; } class GlobalTempLikeStaticField { static [fieldKey()] = _a; } console.log(GlobalTempLikeStaticField.value);',
        graph: 'retained',
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
        name: 'unresolved computed member receiver keys retain their external reference',
        source:
          'globalThis.__zntcComputedReceiverKey = "outer"; var order = []; var holder = { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; class UnboundComputedMemberReceiverField { static value = holder[__zntcComputedReceiverKey].value; } console.log(UnboundComputedMemberReceiverField.value, order.join(","));',
        graph: 'retained',
        output: '9 outer,value\n',
      },
      {
        name: 'unresolved roots of computed member receiver chains retain their external reference',
        source:
          'var order = []; globalThis.__zntcComputedReceiverRoot = { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; var key = "outer"; class UnboundComputedMemberReceiverRootField { static value = __zntcComputedReceiverRoot[key].value; } console.log(UnboundComputedMemberReceiverRootField.value, order.join(","));',
        graph: 'retained',
        output: '9 outer,value\n',
      },
      {
        name: 'unresolved optional computed static initializer roots retain order and skip null keys',
        source:
          'var order = []; function key() { order.push("key"); return "outer"; } Object.defineProperty(globalThis, "__zntcOptionalReceiverRoot", { configurable: true, get() { order.push("root"); return { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; } }); Object.defineProperty(globalThis, "__zntcMissingOptionalReceiverRoot", { configurable: true, get() { order.push("missing"); return null; } }); class OptionalUnresolvedReceiverRootField { static value = __zntcOptionalReceiverRoot?.[key()].value; static absent = __zntcMissingOptionalReceiverRoot?.[key()].value; } console.log(OptionalUnresolvedReceiverRootField.value, OptionalUnresolvedReceiverRootField.absent, order.join(","));',
        graph: 'retained',
        output: '9 undefined root,key,outer,value,missing\n',
      },
      {
        name: 'unresolved computed member receiver key calls retain order and external identity',
        source:
          'var order = []; globalThis.__zntcComputedReceiverKeyFn = () => { order.push("key"); return "outer"; }; var holder = { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; class UnboundComputedMemberReceiverCallField { static value = holder[__zntcComputedReceiverKeyFn()].value; } console.log(UnboundComputedMemberReceiverCallField.value, order.join(","));',
        graph: 'retained',
        output: '9 key,outer,value\n',
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
        name: 'bound call-result computed member reads retain key, getter receiver, and order',
        source: [
          'var order = [];',
          'var inner = { get value() { order.push(this === inner ? "value:true" : "value:false"); return 9; } };',
          'var holder = { get outer() { order.push(this === holder ? "outer:true" : "outer:false"); return inner; } };',
          'function makeHolder() { order.push("receiver"); return holder; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "outer"; } }; }',
          'class BoundCallResultComputedMemberReadField { static value = makeHolder()[memberKey()].value; }',
          'console.log(BoundCallResultComputedMemberReadField.value, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 receiver,key,coerce,outer:true,value:true\n',
      },
      {
        name: 'unresolved computed static member call key retains its external reference',
        source:
          'globalThis.__zntcComputedStaticCallKey = "value"; var holder = { value() { return 9; } }; class UnboundComputedStaticMemberCallField { static value = holder[__zntcComputedStaticCallKey](); } console.log(UnboundComputedStaticMemberCallField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'unresolved computed static member call key function retains order and its external reference',
        source:
          'var order = []; globalThis.__zntcComputedStaticCallKeyFn = () => { order.push("key"); return "value"; }; var holder = { value() { order.push(this === holder ? "this" : "wrong-this"); return 9; } }; class UnboundComputedStaticMemberCallKeyFunctionField { static value = holder[__zntcComputedStaticCallKeyFn()](); } console.log(UnboundComputedStaticMemberCallKeyFunctionField.value, order.join(","));',
        graph: 'retained',
        output: '9 key,this\n',
      },
      {
        name: 'optional computed static member call key function stays on semantic reanalysis',
        source:
          'var key = () => "value"; var holder = { value() { return 9; } }; class OptionalComputedStaticMemberCallKeyFunctionField { static value = holder[key?.()](); } console.log(OptionalComputedStaticMemberCallKeyFunctionField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static member call access retains receiver and null short-circuit',
        source:
          'var order = []; function key() { order.push("key"); return "value"; } var holder = { get value() { order.push("method"); return function () { order.push(this === holder ? "this" : "wrong-this"); return 9; }; } }; var missing = null; class OptionalComputedStaticMemberCallField { static value = holder?.[key()](); static absent = missing?.[key()](); } console.log(OptionalComputedStaticMemberCallField.value, OptionalComputedStaticMemberCallField.absent, order.join(","));',
        graph: 'retained',
        output: '9 undefined key,method,this\n',
      },
      {
        name: 'bound computed optional static member invocations retain key, receiver, argument, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var missingMethod = { get fieldValue() { order.push("missing-method"); return null; } };',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'function wrap(value) { order.push("wrap:" + String(value)); return value; }',
          'class ComputedOptionalCallMemberField { static direct = receiver[memberKey()]?.(argument()); static absent = missingMethod[memberKey()]?.(argument()); static nested = wrap(receiver[memberKey()]?.(argument())); }',
          'console.log(ComputedOptionalCallMemberField.direct, ComputedOptionalCallMemberField.absent, ComputedOptionalCallMemberField.nested, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined 9 key,coerce,method,argument,this,key,coerce,missing-method,key,coerce,method,argument,this,wrap:9\n',
      },
      {
        name: 'optional computed static member invocation with optional key call stays on semantic reanalysis',
        source:
          'var key = () => "value"; var holder = { value() { return 9; } }; class OptionalComputedStaticMemberInvocationField { static value = holder[key?.()]?.(); } console.log(OptionalComputedStaticMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed static member invocation with effectful assignment key stays on semantic reanalysis',
        source:
          'var key = "other"; var holder = { value() { return 9; } }; class EffectfulComputedOptionalMemberInvocationField { static value = holder[(key = "value")]?.(); } console.log(EffectfulComputedOptionalMemberInvocationField.value, key);',
        graph: 'reanalyzed',
        output: '9 value\n',
      },
      {
        name: 'bound call-result receiver with bound computed member key retains its graph',
        source:
          'var key = "value"; function makeHolder() { return { value() { return 9; } }; } class CallResultComputedOptionalMemberInvocationField { static value = makeHolder()[key]?.(); } console.log(CallResultComputedOptionalMemberInvocationField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound optional receiver member invocations retain key, receiver, argument, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var missingReceiver = null;',
          'var missingMethod = { get fieldValue() { order.push("missing-method"); return null; } };',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class BoundOptionalReceiverMemberInvocationField { static dotted = receiver?.fieldValue?.(argument()); static computed = receiver?.[memberKey()]?.(argument()); static absentReceiver = missingReceiver?.[memberKey()]?.(argument()); static absentMethod = missingMethod?.[memberKey()]?.(argument()); }',
          'console.log(BoundOptionalReceiverMemberInvocationField.dotted, BoundOptionalReceiverMemberInvocationField.computed, BoundOptionalReceiverMemberInvocationField.absentReceiver, BoundOptionalReceiverMemberInvocationField.absentMethod, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined undefined method,argument,this,key,coerce,method,argument,this,key,coerce,missing-method\n',
      },
      {
        name: 'computed optional member invocation with unresolved member-expression receiver stays on semantic reanalysis',
        source:
          'var key = "value"; globalThis.__zntcUnresolvedOptionalInvocationReceiver = { value() { return 9; } }; class UnresolvedComputedOptionalMemberInvocationField { static value = globalThis.__zntcUnresolvedOptionalInvocationReceiver[key]?.(); } console.log(UnresolvedComputedOptionalMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'bound computed static member invocation with direct key retains its graph',
        source:
          'var key = "value"; var holder = { value() { return 9; } }; class BoundComputedStaticMemberInvocationField { static value = holder[key]?.(); } console.log(BoundComputedStaticMemberInvocationField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound computed call-result member calls retain receiver, key order, and method this',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get value() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'function makeHolder() { order.push("receiver"); return receiver; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "value"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class BoundCallResultComputedMemberCallField { static value = makeHolder()[memberKey()](argument()); }',
          'console.log(BoundCallResultComputedMemberCallField.value, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 receiver,key,coerce,method,argument,this\n',
      },
      {
        name: 'call-result member-call failures retain computed-key and argument evaluation order',
        source: [
          'var order = [];',
          'var missingMethod = { get fieldValue() { order.push("method"); return null; } };',
          'function makeMissingMethodReceiver() { order.push("method-receiver"); return missingMethod; }',
          'function makeNullReceiver() { order.push("null-receiver"); return null; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'try { var MissingMethodCallResultField = class { static value = makeMissingMethodReceiver()[memberKey()](argument()); }; } catch (error) { order.push(error.name); }',
          'try { var NullCallResultField = class { static value = makeNullReceiver()[memberKey()](argument()); }; } catch (error) { order.push(error.name); }',
          'console.log(order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          'method-receiver,key,coerce,method,argument,TypeError,null-receiver,key,TypeError\n',
      },
      {
        name: 'unresolved computed static member key calls retain order and their external reference',
        source:
          'var order = []; globalThis.__zntcStaticMemberKeyFn = () => { order.push("key"); return "value"; }; var holder = { get value() { order.push("get"); return 9; } }; class UnboundComputedStaticMemberKeyCallField { static value = holder[__zntcStaticMemberKeyFn()]; } console.log(UnboundComputedStaticMemberKeyCallField.value, order.join(","));',
        graph: 'retained',
        output: '9 key,get\n',
      },
      {
        name: 'optional computed static member key call stays on semantic reanalysis',
        source:
          'var key = () => "value"; var holder = { value: 9 }; class OptionalComputedStaticMemberKeyCallField { static value = holder[key?.()]; } console.log(OptionalComputedStaticMemberKeyCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved computed static member read keys retain their external reference',
        source:
          'globalThis.__zntcStaticMemberKey = "value"; var holder = { value: 9 }; class UnboundComputedStaticMemberValueField { static value = holder[__zntcStaticMemberKey]; } console.log(UnboundComputedStaticMemberValueField.value);',
        graph: 'retained',
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
        name: 'unresolved optional computed static-member key calls retain null short-circuit and order',
        source:
          'var order = []; globalThis.__zntcOptionalStaticMemberKeyFn = function() { order.push("key"); return "value"; }; var holder = { get value() { order.push("get"); return 9; } }; var missing = null; class UnboundOptionalComputedStaticMemberKeyCall { static value = holder?.[__zntcOptionalStaticMemberKeyFn()]; static absent = missing?.[__zntcOptionalStaticMemberKeyFn()]; } console.log(UnboundOptionalComputedStaticMemberKeyCall.value, UnboundOptionalComputedStaticMemberKeyCall.absent, order.join(","));',
        graph: 'retained',
        output: '9 undefined key,get\n',
      },
      {
        name: 'optional-call key stays on semantic reanalysis inside optional computed access',
        source:
          'var key = function() { return "value"; }; var holder = { value: 9 }; class OptionalCallComputedStaticMemberKey { static value = holder?.[key?.()]; } console.log(OptionalCallComputedStaticMemberKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'bound call-result computed static member reads retain key conversion and getter order',
        source: [
          'var order = [];',
          'var holder = { get value() { order.push(this === holder ? "value:true" : "value:false"); return 9; } };',
          'function makeHolder() { order.push("receiver"); return holder; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "value"; } }; }',
          'class BoundCallResultComputedStaticMemberReadField { static value = makeHolder()[memberKey()]; }',
          'console.log(BoundCallResultComputedStaticMemberReadField.value, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 receiver,key,coerce,value:true\n',
      },
      {
        name: 'unbound optional static member value retains one root read and null short-circuit',
        source:
          'var order = []; Object.defineProperty(globalThis, "__zntcOptionalStaticReceiver", { configurable: true, get() { order.push("root"); return { get value() { order.push("value"); return 9; } }; } }); Object.defineProperty(globalThis, "__zntcMissingOptionalStaticReceiver", { configurable: true, get() { order.push("missing"); return null; } }); class UnboundOptionalStaticMemberValueField { static value = __zntcOptionalStaticReceiver?.value; static absent = __zntcMissingOptionalStaticReceiver?.value; } console.log(UnboundOptionalStaticMemberValueField.value, UnboundOptionalStaticMemberValueField.absent, order.join(","));',
        graph: 'retained',
        output: '9 undefined root,value,missing\n',
      },
      {
        name: 'nested bound optional static-member chains retain getter order and null short-circuit',
        source:
          'var order = []; var holder = { get outer() { order.push("outer"); return { get value() { order.push("value"); return 9; } }; } }; var missing = null; var empty = { get outer() { order.push("empty"); return null; } }; class NestedOptionalStaticMemberValueField { static first = holder?.outer?.value; static tail = holder?.outer.value; static missingRoot = missing?.outer?.value; static missingMiddle = empty?.outer?.value; } console.log(NestedOptionalStaticMemberValueField.first, NestedOptionalStaticMemberValueField.tail, NestedOptionalStaticMemberValueField.missingRoot, NestedOptionalStaticMemberValueField.missingMiddle, order.join(","));',
        graph: 'retained',
        output: '9 9 undefined undefined outer,value,outer,value,empty\n',
      },
      {
        name: 'function-local static initializer temps bind to the enclosing function hoist',
        source:
          'function make() { var holder = { outer: { value: 8 } }; class NestedStaticTemp { static value = holder?.outer?.value; } return NestedStaticTemp.value; } console.log(make());',
        graph: 'retained',
        output: '8\n',
      },
      {
        name: 'unresolved static member receiver retains its external reference',
        source:
          'globalThis.__zntcStaticMemberHolder = { value: 9 }; class UnresolvedStaticMemberValueField { static value = __zntcStaticMemberHolder.value; } console.log(UnresolvedStaticMemberValueField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'unresolved static member receiver stays visible beside a generated computed-field temp',
        source:
          "globalThis._a = { outer: { value: 9 } }; var key = 'outer'; function fieldKey() { return 'result'; } class ExternalRootCollision { static [fieldKey()] = _a[key].value; } console.log(ExternalRootCollision.result);",
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound call-result static member reads retain getter receiver and order',
        source:
          'var order = []; var holder = { get value() { order.push(this === holder ? "value:true" : "value:false"); return 9; } }; function makeHolder() { order.push("receiver"); return holder; } class BoundCallResultStaticMemberReadField { static value = makeHolder().value; } console.log(BoundCallResultStaticMemberReadField.value, order.join(","));',
        graph: 'retained',
        output: '9 receiver,value:true\n',
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
        name: 'unresolved _a computed field key stays external beside generated temp',
        source:
          'var reads = 0; Object.defineProperty(globalThis, "_a", { configurable: true, get() { reads += 1; return "value"; } }); class UnresolvedComputedStaticFieldNameCollision { static [_a] = 9; } console.log(UnresolvedComputedStaticFieldNameCollision.value, reads);',
        graph: 'retained',
        output: '9 1\n',
      },
      {
        name: 'unresolved computed static field name calls retain key evaluation exactly once',
        source:
          'var order = []; globalThis.__zntcComputedStaticFieldNameFn = () => { order.push("key"); return "value"; }; class UnboundComputedStaticFieldNameCall { static [__zntcComputedStaticFieldNameFn()] = 9; } console.log(UnboundComputedStaticFieldNameCall.value, order.join(","));',
        graph: 'retained',
        output: '9 key\n',
      },
      {
        name: 'optional computed static field name call stays on semantic reanalysis',
        source:
          'var fieldKey = () => "value"; class OptionalComputedStaticFieldNameCall { static [fieldKey?.()] = 9; } console.log(OptionalComputedStaticFieldNameCall.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional computed member call in static field name preserves receiver and key order',
        source:
          'var order = []; var receiver = { base: 5, get fieldKey() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } }; Object.defineProperty(globalThis, "__zntcOptionalStaticFieldKeyReceiver", { configurable: true, get() { order.push("root"); return receiver; } }); Object.defineProperty(globalThis, "__zntcMissingOptionalStaticFieldKeyReceiver", { configurable: true, get() { order.push("missing"); return null; } }); function memberKey() { order.push("key"); return "fieldKey"; } function argument() { order.push("argument"); return 4; } function initializer(value) { order.push("init:" + value); return value; } class OptionalMemberCallStaticFieldName { static [__zntcOptionalStaticFieldKeyReceiver?.[memberKey()](argument())] = initializer("present"); static [__zntcMissingOptionalStaticFieldKeyReceiver?.[memberKey()](argument())] = initializer("absent"); } console.log(OptionalMemberCallStaticFieldName["9"], OptionalMemberCallStaticFieldName.undefined, order.join(","));',
        graph: 'retained',
        output: 'present absent root,key,method,argument,this,missing,init:present,init:absent\n',
      },
      {
        name: 'nested optional member calls in computed static field names retain undefined key conversion',
        source:
          'var order = []; Object.defineProperty(globalThis, "__zntcNestedOptionalStaticFieldKeyReceiver", { configurable: true, get() { order.push("missing"); return null; } }); function memberKey() { order.push("key"); return "fieldKey"; } function argument() { order.push("argument"); return 4; } function wrapKey(value) { order.push("wrap:" + value); return value; } function initializer(value) { order.push("init:" + value); return value; } class NestedOptionalMemberCallStaticFieldName { static [wrapKey(__zntcNestedOptionalStaticFieldKeyReceiver?.[memberKey()](argument()))] = initializer("absent"); } console.log(NestedOptionalMemberCallStaticFieldName.undefined, order.join(","));',
        graph: 'retained',
        output: 'absent missing,wrap:undefined,init:absent\n',
      },
      {
        name: 'explicit optional invocation in computed static field name stays on semantic reanalysis',
        source:
          'globalThis.__zntcOptionalInvocationStaticFieldKeyReceiver = { fieldKey() { return "value"; } }; class OptionalInvocationStaticFieldName { static [__zntcOptionalInvocationStaticFieldKeyReceiver?.fieldKey?.()] = 9; } console.log(OptionalInvocationStaticFieldName.value);',
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
        name: 'unresolved member read in computed static field key retains external identity',
        source:
          'globalThis.__zntcComputedStaticFieldKeyHolder = { key: "value" }; class UnboundComputedStaticFieldMemberKey { static [__zntcComputedStaticFieldKeyHolder.key] = 9; } console.log(UnboundComputedStaticFieldMemberKey.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'unresolved member call in computed static field key retains receiver this and order',
        source:
          'var order = []; globalThis.__zntcComputedStaticMemberCallKey = { fieldKey() { order.push(this === globalThis.__zntcComputedStaticMemberCallKey ? "this" : "wrong-this"); return "value"; } }; class UnresolvedComputedStaticMemberCallKey { static [__zntcComputedStaticMemberCallKey.fieldKey()] = 9; } console.log(UnresolvedComputedStaticMemberCallKey.value, order.join(","));',
        graph: 'retained',
        output: '9 this\n',
      },
      {
        name: 'bound optional computed static field keys retain getter order and null short-circuit',
        source:
          'var order = []; var holder = { get key() { order.push("key"); return "value"; } }; var missing = null; class OptionalComputedStaticFieldMemberKey { static [holder?.key] = 9; static [missing?.key] = 10; } console.log(OptionalComputedStaticFieldMemberKey.value, OptionalComputedStaticFieldMemberKey.undefined, order.join(","));',
        graph: 'retained',
        output: '9 10 key\n',
      },
      {
        name: 'unresolved external optional computed field roots retain order and short-circuit',
        source:
          'var order = []; function computedKey() { order.push("computed"); return "key"; } Object.defineProperty(globalThis, "_a", { configurable: true, get() { order.push("root"); return { get key() { order.push("key"); return "value"; } }; } }); globalThis._b = null; class UnresolvedOptionalComputedStaticFieldMemberKey { static [_a?.[computedKey()]] = 9; static [_b?.[computedKey()]] = 10; } console.log(UnresolvedOptionalComputedStaticFieldMemberKey.value, UnresolvedOptionalComputedStaticFieldMemberKey.undefined, order.join(","));',
        graph: 'retained',
        output: '9 10 root,computed,key\n',
      },
      {
        name: 'unresolved optional member call roots keep identity on reanalysis',
        source:
          'var order = []; var receiver = { key: "called", get method() { order.push("method"); return function () { order.push(this === receiver ? "this" : "wrong-this"); return this.key; }; } }; Object.defineProperty(globalThis, "_callRoot", { configurable: true, get() { order.push("root"); return receiver; } }); globalThis._nullRoot = null; function argument() { order.push("argument"); return 1; } class UnresolvedOptionalMemberCallStaticFieldKey { static [_callRoot?.method?.(argument())] = 11; static [_nullRoot?.method?.(argument())] = 12; } console.log(UnresolvedOptionalMemberCallStaticFieldKey.called, UnresolvedOptionalMemberCallStaticFieldKey.undefined, order.join(","));',
        graph: 'reanalyzed',
        output: '11 12 root,method,argument,this\n',
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
        name: 'bound optional member-call static field initializers retain their graph',
        source:
          'var receiver = { fieldValue(input) { return input + 1; } }; class OptionalMemberCallField { static value = receiver?.fieldValue(8); } console.log(OptionalMemberCallField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound call-result optional receiver member calls retain key, this, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'function makeReceiver(value) { order.push(value === null ? "null-receiver" : "receiver"); return value; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class BoundCallResultOptionalReceiverMemberCallField { static dotted = makeReceiver(receiver)?.fieldValue(argument()); static computed = makeReceiver(receiver)?.[memberKey()](argument()); static absent = makeReceiver(null)?.[memberKey()](argument()); }',
          'console.log(BoundCallResultOptionalReceiverMemberCallField.dotted, BoundCallResultOptionalReceiverMemberCallField.computed, BoundCallResultOptionalReceiverMemberCallField.absent, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined receiver,method,argument,this,receiver,key,coerce,method,argument,this,null-receiver\n',
      },
      {
        name: 'unresolved optional member-call static initializers retain root, receiver this and argument order',
        source:
          'var order = []; var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } }; Object.defineProperty(globalThis, "__zntcOptionalStaticCallRoot", { configurable: true, get() { order.push("root"); return receiver; } }); Object.defineProperty(globalThis, "__zntcMissingOptionalStaticCallRoot", { configurable: true, get() { order.push("missing"); return null; } }); function memberKey() { order.push("key"); return "fieldValue"; } function argument() { order.push("argument"); return 4; } class UnresolvedOptionalMemberCallField { static value = __zntcOptionalStaticCallRoot?.[memberKey()](argument()); static absent = __zntcMissingOptionalStaticCallRoot?.[memberKey()](argument()); } console.log(UnresolvedOptionalMemberCallField.value, UnresolvedOptionalMemberCallField.absent, order.join(","));',
        graph: 'retained',
        output: '9 undefined root,key,method,argument,this,missing\n',
      },
      {
        name: 'bound optional member-call invocation static initializers retain receiver and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var missingMethod = { get fieldValue() { order.push("missing-method"); return null; } };',
          'function argument() { order.push("argument"); return 4; }',
          'function wrap(value) { order.push("wrap:" + String(value)); return value; }',
          'class OptionalCallMemberCallField { static direct = receiver.fieldValue?.(argument()); static absent = missingMethod.fieldValue?.(argument()); static nested = wrap(receiver.fieldValue?.(argument())); }',
          'console.log(OptionalCallMemberCallField.direct, OptionalCallMemberCallField.absent, OptionalCallMemberCallField.nested, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 undefined 9 method,argument,this,missing-method,method,argument,this,wrap:9\n',
      },
      {
        name: 'unresolved optional member invocations retain root getter, method this, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var missingMethod = { get fieldValue() { order.push("missing-method"); return null; } };',
          'Object.defineProperty(globalThis, "__zntcUnresolvedOptionalMemberInvocation", { configurable: true, get() { order.push("root"); return receiver; } });',
          'Object.defineProperty(globalThis, "__zntcUnresolvedOptionalMemberInvocationMissing", { configurable: true, get() { order.push("missing-root"); return missingMethod; } });',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class UnresolvedOptionalMemberInvocationField { static direct = __zntcUnresolvedOptionalMemberInvocation.fieldValue?.(argument()); static computed = __zntcUnresolvedOptionalMemberInvocation[memberKey()]?.(argument()); static absent = __zntcUnresolvedOptionalMemberInvocationMissing.fieldValue?.(argument()); }',
          'console.log(UnresolvedOptionalMemberInvocationField.direct, UnresolvedOptionalMemberInvocationField.computed, UnresolvedOptionalMemberInvocationField.absent, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined root,method,argument,this,root,key,coerce,method,argument,this,missing-root,missing-method\n',
      },
      {
        name: 'unresolved require member invocation stays on semantic reanalysis',
        source:
          'class UnresolvedRequireMemberInvocationField { static value = require.resolve?.("node:path"); } console.log(typeof UnresolvedRequireMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: 'string\n',
      },
      {
        name: 'bound call-result optional member invocations retain receiver, key, argument, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var missingMethod = { get fieldValue() { order.push("missing-method"); return null; } };',
          'function makeReceiver() { order.push("receiver"); return receiver; }',
          'function makeMissingReceiver() { order.push("null-receiver"); return null; }',
          'function makeMissingMethodReceiver() { order.push("missing-receiver"); return missingMethod; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class BoundCallResultOptionalMemberInvocationField { static direct = makeReceiver().fieldValue?.(argument()); static computed = makeReceiver()[memberKey()]?.(argument()); static absentReceiver = makeMissingReceiver()?.[memberKey()]?.(argument()); static absentMethod = makeMissingMethodReceiver()?.[memberKey()]?.(argument()); }',
          'console.log(BoundCallResultOptionalMemberInvocationField.direct, BoundCallResultOptionalMemberInvocationField.computed, BoundCallResultOptionalMemberInvocationField.absentReceiver, BoundCallResultOptionalMemberInvocationField.absentMethod, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined undefined receiver,method,argument,this,receiver,key,coerce,method,argument,this,null-receiver,missing-receiver,key,coerce,missing-method\n',
      },
      {
        name: 'unresolved optional receiver member invocations retain root getter and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var missingMethod = { get fieldValue() { order.push("missing-method"); return null; } };',
          'Object.defineProperty(globalThis, "__zntcUnresolvedOptionalReceiverMemberInvocation", { configurable: true, get() { order.push("root"); return receiver; } });',
          'Object.defineProperty(globalThis, "__zntcUnresolvedComputedOptionalReceiverMemberInvocation", { configurable: true, get() { order.push("computed-root"); return receiver; } });',
          'Object.defineProperty(globalThis, "__zntcUnresolvedNullOptionalReceiverMemberInvocation", { configurable: true, get() { order.push("null-root"); return null; } });',
          'Object.defineProperty(globalThis, "__zntcUnresolvedMissingOptionalReceiverMemberInvocation", { configurable: true, get() { order.push("missing-root"); return missingMethod; } });',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class UnresolvedOptionalReceiverMemberInvocationField { static dotted = __zntcUnresolvedOptionalReceiverMemberInvocation?.fieldValue?.(argument()); static computed = __zntcUnresolvedComputedOptionalReceiverMemberInvocation?.[memberKey()]?.(argument()); static absentReceiver = __zntcUnresolvedNullOptionalReceiverMemberInvocation?.[memberKey()]?.(argument()); static absentMethod = __zntcUnresolvedMissingOptionalReceiverMemberInvocation?.[memberKey()]?.(argument()); }',
          'console.log(UnresolvedOptionalReceiverMemberInvocationField.dotted, UnresolvedOptionalReceiverMemberInvocationField.computed, UnresolvedOptionalReceiverMemberInvocationField.absentReceiver, UnresolvedOptionalReceiverMemberInvocationField.absentMethod, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined undefined root,method,argument,this,computed-root,key,coerce,method,argument,this,null-root,missing-root,key,coerce,missing-method\n',
      },
      {
        name: 'unresolved call-result optional member invocation stays on semantic reanalysis',
        source:
          'globalThis.__zntcUnresolvedOptionalReceiverFactory = function () { return { fieldValue(input) { return input + 1; } }; }; class UnresolvedCallResultOptionalMemberInvocationField { static value = __zntcUnresolvedOptionalReceiverFactory().fieldValue?.(8); } console.log(UnresolvedCallResultOptionalMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved call-result optional receiver member call stays on semantic reanalysis',
        source:
          'globalThis.__zntcUnresolvedOptionalReceiverCallFactory = function () { return { fieldValue(input) { return input + 1; } }; }; class UnresolvedCallResultOptionalReceiverMemberCallField { static value = __zntcUnresolvedOptionalReceiverCallFactory()?.fieldValue(8); } console.log(UnresolvedCallResultOptionalReceiverMemberCallField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved call-result ordinary member invocation stays on semantic reanalysis',
        source:
          'globalThis.__zntcUnresolvedMemberReceiverFactory = function () { return { fieldValue(input) { return input + 1; } }; }; class UnresolvedCallResultMemberInvocationField { static value = __zntcUnresolvedMemberReceiverFactory().fieldValue(8); } console.log(UnresolvedCallResultMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'bound nested call-result member receivers retain receiver, key, argument, and this order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'function makeReceiverFactory() { order.push("factory"); return function (input) { order.push("receiver:" + input); return receiver; }; }',
          'function receiverArgument() { order.push("receiver-argument"); return 2; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "fieldValue"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class NestedCallResultMemberInvocationField { static value = makeReceiverFactory()(receiverArgument())[memberKey()](argument()); }',
          'console.log(NestedCallResultMemberInvocationField.value, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 factory,receiver-argument,receiver:2,key,coerce,method,argument,this\n',
      },
      {
        name: 'optional nested call-result member receivers stay on semantic reanalysis',
        source:
          'var receiver = { fieldValue(input) { return input + 1; } }; function makeReceiverFactory() { return function () { return receiver; }; } class OptionalNestedCallResultMemberInvocationField { static value = makeReceiverFactory()?.().fieldValue(8); } console.log(OptionalNestedCallResultMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'unresolved nested call-result member receivers stay on semantic reanalysis',
        source:
          'var receiver = { fieldValue(input) { return input + 1; } }; globalThis.__zntcUnresolvedNestedReceiverFactory = function () { return function () { return receiver; }; }; class UnresolvedNestedCallResultMemberInvocationField { static value = __zntcUnresolvedNestedReceiverFactory()().fieldValue(8); } console.log(UnresolvedNestedCallResultMemberInvocationField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'nested call-result member receiver with effectful call argument stays on semantic reanalysis',
        source:
          'var order = []; var receiver = { fieldValue(input) { return input + 1; } }; function makeReceiverFactory(input) { return function () { return receiver; }; } class EffectfulNestedCallResultMemberInvocationField { static value = makeReceiverFactory((order.push("argument-effect"), 1))().fieldValue(8); } console.log(EffectfulNestedCallResultMemberInvocationField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 argument-effect\n',
      },
      {
        name: 'nested call-result member access in computed class key stays on semantic reanalysis',
        source:
          'function makeReceiverFactory() { return function () { return { fieldKey: "value" }; }; } class NestedCallResultComputedKey { static [makeReceiverFactory()().fieldKey] = 9; } console.log(NestedCallResultComputedKey.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'call-result optional member invocation with effectful receiver argument stays on semantic reanalysis',
        source:
          'var order = []; function makeReceiver(input) { return { fieldValue(value) { return input + value; } }; } class EffectfulCallResultOptionalMemberInvocationField { static value = makeReceiver((order.push("receiver-argument"), 1)).fieldValue?.(8); } console.log(EffectfulCallResultOptionalMemberInvocationField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 receiver-argument\n',
      },
      {
        name: 'call-result optional receiver member call with effectful receiver argument stays on semantic reanalysis',
        source:
          'var order = []; function makeReceiver(input) { return { fieldValue(value) { return input + value; } }; } class EffectfulCallResultOptionalReceiverMemberCallField { static value = makeReceiver((order.push("receiver-argument"), 1))?.fieldValue(8); } console.log(EffectfulCallResultOptionalReceiverMemberCallField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 receiver-argument\n',
      },
      {
        name: 'call-result ordinary member invocation with effectful receiver argument stays on semantic reanalysis',
        source:
          'var order = []; function makeReceiver(input) { return { fieldValue(value) { return input + value; } }; } class EffectfulCallResultMemberInvocationField { static value = makeReceiver((order.push("receiver-argument"), 1)).fieldValue(8); } console.log(EffectfulCallResultMemberInvocationField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 receiver-argument\n',
      },
      {
        name: 'unresolved member-call receiver chains retain computed-key order and method this',
        source:
          'var order = []; var inner = { base: 5, fieldValue(input) { order.push(this === inner ? "this" : "wrong-this"); return this.base + input; } }; globalThis.__zntcFieldReceiver = { get outer() { order.push("outer"); return inner; } }; globalThis.__zntcFieldReceiverKey = () => { order.push("key"); return "outer"; }; class ExternalReceiverMemberCallField { static value = __zntcFieldReceiver[__zntcFieldReceiverKey()].fieldValue(4); } console.log(ExternalReceiverMemberCallField.value, order.join(","));',
        graph: 'retained',
        output: '9 key,outer,this\n',
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
        name: 'optional nested member receiver static fields retain their graph',
        source:
          'var holder = { receiver: { fieldValue(input) { return input + 1; } } }; class OptionalNestedMemberReceiverField { static value = holder?.receiver.fieldValue(8); } console.log(OptionalNestedMemberReceiverField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'unresolved nested member-call receiver chains retain their exact graph',
        source:
          'globalThis.__zntcNestedFieldHolder = { receiver: { fieldValue(input) { return input + 1; } } }; class UnresolvedNestedMemberReceiverField { static value = __zntcNestedFieldHolder.receiver.fieldValue(8); } console.log(UnresolvedNestedMemberReceiverField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound deep call-result member calls retain computed-key order and method this',
        source: [
          'var order = [];',
          'var receiver = { base: 5, fieldValue(input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; } };',
          'var holder = { get outer() { order.push("outer"); return { get receiver() { order.push("receiver"); return receiver; } }; } };',
          'function getFieldHolder() { order.push("root"); return holder; }',
          'function receiverKey() { order.push("key"); return "receiver"; }',
          'function argument() { order.push("argument"); return 4; }',
          'class BoundDeepCallResultMemberCallField { static value = getFieldHolder().outer[receiverKey()].fieldValue(argument()); }',
          'console.log(BoundDeepCallResultMemberCallField.value, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 root,outer,key,receiver,argument,this\n',
      },
      {
        name: 'bound computed deep member receiver static fields retain their graph',
        source:
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } }; function receiverKey() { return "receiver"; } class ComputedDeepMemberReceiverField { static value = holder.outer[receiverKey()].fieldValue(8); } console.log(ComputedDeepMemberReceiverField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound deep optional member receiver calls retain key, getter, argument, this, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var holder = { get outer() { order.push("outer"); return { get receiver() { order.push("receiver"); return receiver; } }; } };',
          'var missingHolder = { get outer() { order.push("missing-outer"); return null; } };',
          'var nullFinalHolder = { get outer() { order.push("null-outer"); return { get receiver() { order.push("null-receiver"); return null; } }; } };',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "receiver"; } }; }',
          'function argument() { order.push("argument"); return 4; }',
          'class DeepOptionalMemberReceiverField { static value = holder.outer?.[memberKey()].fieldValue(argument()); static absent = missingHolder.outer?.[memberKey()].fieldValue(argument()); }',
          'function failAtFinalReceiver() { class NullFinalOptionalReceiverField { static value = nullFinalHolder.outer?.[memberKey()].fieldValue(argument()); } } try { failAtFinalReceiver(); } catch (error) { order.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(DeepOptionalMemberReceiverField.value, DeepOptionalMemberReceiverField.absent, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,key,coerce,receiver,method,argument,this,missing-outer,null-outer,key,coerce,null-receiver,type-error\n',
      },
      {
        name: 'unresolved deep optional member receiver calls retain exact identity and short-circuit order',
        source: [
          'var events = [];',
          'var calls = 0;',
          'globalThis.__zntcUnresolvedDeepOptionalFieldHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcUnresolvedNullDeepOptionalFieldHolder = { get outer() { events.push("missing"); return null; } };',
          'function argument() { calls++; events.push("argument"); return 8; }',
          'class UnresolvedDeepOptionalMemberReceiverField { static value = __zntcUnresolvedDeepOptionalFieldHolder.outer?.receiver.fieldValue(argument()); static missing = __zntcUnresolvedNullDeepOptionalFieldHolder.outer?.receiver.fieldValue(argument()); }',
          'console.log(UnresolvedDeepOptionalMemberReceiverField.value, UnresolvedDeepOptionalMemberReceiverField.missing, calls, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 undefined 1 outer,receiver,method,argument,this,missing\n',
      },
      {
        name: 'unresolved deep optional member calls retain a safe computed key call and ToPropertyKey order',
        source: [
          'var events = [];',
          'globalThis.__zntcUnresolvedComputedOptionalKeyHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcUnresolvedNullComputedOptionalKeyHolder = { get outer() { events.push("missing"); return null; } };',
          'function memberKey() { events.push("key"); return { [Symbol.toPrimitive]() { events.push("coerce"); return "receiver"; } }; }',
          'function argument() { events.push("argument"); return 8; }',
          'class UnresolvedComputedOptionalMemberKeyField { static value = __zntcUnresolvedComputedOptionalKeyHolder.outer?.[memberKey()].fieldValue(argument()); static missing = __zntcUnresolvedNullComputedOptionalKeyHolder.outer?.[memberKey()].fieldValue(argument()); }',
          'console.log(UnresolvedComputedOptionalMemberKeyField.value, UnresolvedComputedOptionalMemberKeyField.missing, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 undefined outer,key,coerce,receiver,method,argument,this,missing\n',
      },
      {
        name: 'unresolved deep optional member calls retain an external computed key and short-circuit order',
        source: [
          'var events = [];',
          'globalThis.__zntcUnresolvedComputedKeyHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcUnresolvedNullComputedKeyHolder = { get outer() { events.push("missing"); return null; } };',
          'Object.defineProperty(globalThis, "__zntcUnresolvedComputedKey", { configurable: true, get() { events.push("key"); return { [Symbol.toPrimitive]() { events.push("coerce"); return "receiver"; } }; } });',
          'function argument() { events.push("argument"); return 8; }',
          'class UnresolvedComputedKeyDeepOptionalMemberField { static value = __zntcUnresolvedComputedKeyHolder.outer?.[__zntcUnresolvedComputedKey].fieldValue(argument()); static missing = __zntcUnresolvedNullComputedKeyHolder.outer?.[__zntcUnresolvedComputedKey].fieldValue(argument()); }',
          'console.log(UnresolvedComputedKeyDeepOptionalMemberField.value, UnresolvedComputedKeyDeepOptionalMemberField.missing, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 undefined outer,key,coerce,receiver,method,argument,this,missing\n',
      },
      {
        name: 'unresolved deep optional member calls retain exact bound-call sequence keys and order',
        source: [
          'var events = [];',
          'var keyValue = { [Symbol.toPrimitive]() { events.push("coerce"); return "receiver"; } };',
          'var missingKeyValue = { [Symbol.toPrimitive]() { events.push("coerce"); return "missing"; } };',
          'globalThis.__zntcUnresolvedEffectfulDeepOptionalFieldHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcUnresolvedNullEffectfulDeepOptionalFieldHolder = { get outer() { events.push("missing"); return null; } };',
          'globalThis.__zntcUnresolvedMissingEffectfulDeepOptionalFieldHolder = { get outer() { events.push("type-outer"); return {}; } };',
          'function argument() { events.push("argument"); return 8; }',
          'class UnresolvedEffectfulDeepOptionalMemberReceiverField { static value = __zntcUnresolvedEffectfulDeepOptionalFieldHolder.outer?.[events.push("before-key"), events.push("key"), keyValue].fieldValue(argument()); static absent = __zntcUnresolvedNullEffectfulDeepOptionalFieldHolder.outer?.[events.push("before-key"), events.push("key"), keyValue].fieldValue(argument()); }',
          'function failAtMissingEffectfulReceiver() { class UnresolvedMissingEffectfulDeepOptionalMemberReceiverField { static value = __zntcUnresolvedMissingEffectfulDeepOptionalFieldHolder.outer?.[events.push("before-key"), events.push("key"), missingKeyValue].fieldValue(argument()); } }',
          'try { failAtMissingEffectfulReceiver(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(UnresolvedEffectfulDeepOptionalMemberReceiverField.value, UnresolvedEffectfulDeepOptionalMemberReceiverField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,before-key,key,coerce,receiver,method,argument,this,missing,type-outer,before-key,key,coerce,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls with an effectful update key stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var keyIndex = 0;',
          'globalThis.__zntcUnresolvedEffectfulUpdateKeyHolder = { outer: { 0: { fieldValue(input) { return input + 1; } } } };',
          'class UnresolvedEffectfulUpdateKeyField { static value = __zntcUnresolvedEffectfulUpdateKeyHolder.outer?.[events.push("key"), keyIndex++].fieldValue(8); }',
          'console.log(UnresolvedEffectfulUpdateKeyField.value, keyIndex, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 1 key\n',
      },
      {
        name: 'bound-root deep optional member calls retain effectful sequence-key order and short-circuiting',
        source: [
          'var events = [];',
          'var keyValue = "receiver";',
          'var receiver = { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } };',
          'var holder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return receiver; } }; } };',
          'var missingHolder = { get outer() { events.push("missing"); return null; } };',
          'var missingMethodHolder = { get outer() { events.push("missing-method"); return { get receiver() { events.push("missing-receiver"); return {}; } }; } };',
          'function argument() { events.push("argument"); return 8; }',
          'class BoundEffectfulDeepOptionalMemberReceiverField { static value = holder.outer?.[events.push("before-key"), events.push("key"), keyValue].fieldValue(argument()); static absent = missingHolder.outer?.[events.push("before-key"), events.push("key"), keyValue].fieldValue(argument()); }',
          'function failAtMissingEffectfulMember() { class MissingEffectfulDeepOptionalMemberField { static value = missingMethodHolder.outer?.[events.push("before-key"), events.push("key"), keyValue].fieldValue(argument()); } } try { failAtMissingEffectfulMember(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(BoundEffectfulDeepOptionalMemberReceiverField.value, BoundEffectfulDeepOptionalMemberReceiverField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,before-key,key,receiver,method,argument,this,missing,missing-method,before-key,key,missing-receiver,argument,type-error\n',
      },
      {
        name: 'bound-root deep optional member calls keep an unbound sequence-key call on reanalysis',
        source: [
          'var events = [];',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'globalThis.__zntcBoundRootUnboundSequenceKey = function () { events.push("key"); return "receiver"; };',
          'class BoundRootUnboundSequenceKeyField { static value = holder.outer?.[__zntcBoundRootUnboundSequenceKey(), "receiver"].fieldValue(8); }',
          'console.log(BoundRootUnboundSequenceKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 key\n',
      },
      {
        name: 'bound-root deep optional member calls keep optional effectful sequence-key calls on reanalysis',
        source: [
          'var events = [];',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'function optionalKeyCall() { events.push("key"); return "receiver"; }',
          'class OptionalEffectfulSequenceKeyField { static value = holder.outer?.[optionalKeyCall?.(), "receiver"].fieldValue(8); }',
          'console.log(OptionalEffectfulSequenceKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 key\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound effectful sequence key stay on semantic reanalysis',
        source: [
          'var events = [];',
          'globalThis.__zntcExternalEffectfulSequenceKey = function () { events.push("key"); return "receiver"; };',
          'globalThis.__zntcUnboundEffectfulSequenceKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundEffectfulDeepOptionalMemberReceiverField { static value = __zntcUnboundEffectfulSequenceKeyHolder.outer?.[__zntcExternalEffectfulSequenceKey(), "receiver"].fieldValue(8); }',
          'console.log(UnboundEffectfulDeepOptionalMemberReceiverField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 key\n',
      },
      {
        name: 'unresolved deep optional member calls retain exact-bound effectful argument sequences and order',
        source: [
          'var events = [];',
          'globalThis.__zntcUnresolvedEffectfulDeepOptionalArgumentHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcUnresolvedNullEffectfulDeepOptionalArgumentHolder = { get outer() { events.push("missing"); return null; } };',
          'globalThis.__zntcUnresolvedMissingEffectfulDeepOptionalArgumentHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class UnresolvedEffectfulDeepOptionalArgumentField { static value = __zntcUnresolvedEffectfulDeepOptionalArgumentHolder.outer?.receiver.fieldValue((events.push("before-argument"), events.push("argument"), 8)); static absent = __zntcUnresolvedNullEffectfulDeepOptionalArgumentHolder.outer?.receiver.fieldValue((events.push("before-argument"), events.push("argument"), 8)); }',
          'function failAtMissingEffectfulArgumentMethod() { class UnresolvedMissingEffectfulDeepOptionalArgumentField { static value = __zntcUnresolvedMissingEffectfulDeepOptionalArgumentHolder.outer?.receiver.fieldValue((events.push("before-argument"), events.push("argument"), 8)); } }',
          'try { failAtMissingEffectfulArgumentMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(UnresolvedEffectfulDeepOptionalArgumentField.value, UnresolvedEffectfulDeepOptionalArgumentField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,receiver,method,before-argument,argument,this,missing,type-outer,type-receiver,before-argument,argument,type-error\n',
      },
      {
        name: 'bound-root deep optional member calls retain exact-bound effectful argument sequences',
        source: [
          'var events = [];',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundEffectfulDeepOptionalArgumentField { static value = holder.outer?.receiver.fieldValue((events.push("before-argument"), events.push("argument"), 8)); }',
          'console.log(BoundEffectfulDeepOptionalArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before-argument,argument\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound effectful argument sequence stay on semantic reanalysis',
        source: [
          'var events = [];',
          'globalThis.__zntcUnboundArgumentSequenceEffect = function () { events.push("argument"); return 8; };',
          'globalThis.__zntcUnboundEffectfulArgumentSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundEffectfulArgumentSequenceField { static value = __zntcUnboundEffectfulArgumentSequenceHolder.outer?.receiver.fieldValue((__zntcUnboundArgumentSequenceEffect(), 8)); }',
          'console.log(UnboundEffectfulArgumentSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 argument\n',
      },
      {
        name: 'unresolved deep optional member calls with an update argument sequence stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentValue = 8;',
          'globalThis.__zntcUpdateEffectfulArgumentSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UpdateEffectfulArgumentSequenceField { static value = __zntcUpdateEffectfulArgumentSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentValue++)); }',
          'console.log(UpdateEffectfulArgumentSequenceField.value, argumentValue, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 9 before-argument\n',
      },
      {
        name: 'unresolved deep optional member calls retain a sequence ending in a bound member read',
        source: [
          'var events = [];',
          'var argumentSource = { get receiver() { events.push(this === argumentSource ? "argument-receiver:this" : "argument-receiver:wrong-this"); return { base: 8, get value() { events.push(this.base === 8 ? "value:this" : "value:wrong-this"); return this.base; } }; } };',
          'var argumentKey = { [Symbol.toPrimitive]() { events.push("key"); return "value"; } };',
          'globalThis.__zntcBoundMemberSequenceHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcNullBoundMemberSequenceHolder = { get outer() { events.push("missing"); return null; } };',
          'globalThis.__zntcMissingBoundMemberSequenceHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class BoundMemberSequenceField { static value = __zntcBoundMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource.receiver.value)); static computed = __zntcBoundMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-computed"), argumentSource.receiver[argumentKey])); static absent = __zntcNullBoundMemberSequenceHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.receiver[argumentKey])); }',
          'function failAtMissingBoundMemberSequenceMethod() { class MissingBoundMemberSequenceField { static value = __zntcMissingBoundMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.receiver[argumentKey])); } }',
          'try { failAtMissingBoundMemberSequenceMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(BoundMemberSequenceField.value, BoundMemberSequenceField.computed, BoundMemberSequenceField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined outer,receiver,method,before-argument,argument-receiver:this,value:this,this,outer,receiver,method,before-computed,argument-receiver:this,key,value:this,this,missing,type-outer,type-receiver,before-missing,argument-receiver:this,key,value:this,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls retain a sequence ending in an exact-bound call',
        source: [
          'var events = [];',
          'var argumentSource = { get receiver() { events.push(this === argumentSource ? "argument-receiver:this" : "argument-receiver:wrong-this"); return { base: 7, get valueCall() { events.push("value-call-getter"); return function (input) { events.push(this.base === 7 ? "value-call:this" : "value-call:wrong-this"); return this.base + input; }; } }; } };',
          'globalThis.__zntcBoundCallSequenceHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcNullBoundCallSequenceHolder = { get outer() { events.push("missing"); return null; } };',
          'globalThis.__zntcMissingBoundCallSequenceHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class BoundCallSequenceField { static value = __zntcBoundCallSequenceHolder.outer?.receiver.fieldValue((events.push("before-call"), argumentSource.receiver.valueCall(1))); static absent = __zntcNullBoundCallSequenceHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.receiver.valueCall(1))); }',
          'function failAtMissingBoundCallSequenceMethod() { class MissingBoundCallSequenceField { static value = __zntcMissingBoundCallSequenceHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.receiver.valueCall(1))); } }',
          'try { failAtMissingBoundCallSequenceMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(BoundCallSequenceField.value, BoundCallSequenceField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,receiver,method,before-call,argument-receiver:this,value-call-getter,value-call:this,this,missing,type-outer,type-receiver,before-missing,argument-receiver:this,value-call-getter,value-call:this,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls retain a sequence ending in an exact-bound safe computed call',
        source: [
          'var events = [];',
          'var argumentKey = { [Symbol.toPrimitive]() { events.push("key"); return "valueCall"; } };',
          'var argumentSource = { get receiver() { events.push(this === argumentSource ? "argument-receiver:this" : "argument-receiver:wrong-this"); return { base: 7, get valueCall() { events.push("value-call-getter"); return function (input) { events.push(this.base === 7 ? "value-call:this" : "value-call:wrong-this"); return this.base + input; }; } }; } };',
          'globalThis.__zntcComputedBoundCallSequenceHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcNullComputedBoundCallSequenceHolder = { get outer() { events.push("missing"); return null; } };',
          'globalThis.__zntcMissingComputedBoundCallSequenceHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class ComputedBoundCallSequenceField { static value = __zntcComputedBoundCallSequenceHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey](1))); static absent = __zntcNullComputedBoundCallSequenceHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.receiver[argumentKey](1))); }',
          'function failAtMissingComputedBoundCallSequenceMethod() { class MissingComputedBoundCallSequenceField { static value = __zntcMissingComputedBoundCallSequenceHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.receiver[argumentKey](1))); } }',
          'try { failAtMissingComputedBoundCallSequenceMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(ComputedBoundCallSequenceField.value, ComputedBoundCallSequenceField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,receiver,method,before,argument-receiver:this,key,value-call-getter,value-call:this,this,missing,type-outer,type-receiver,before-missing,argument-receiver:this,key,value-call-getter,value-call:this,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls retain a sequence ending in a computed call with an exact-bound call key',
        source: [
          'var events = [];',
          'var argumentKeyObject = { [Symbol.toPrimitive]() { events.push("key-coerce"); return "valueCall"; } };',
          'function argumentKey() { events.push("key-call"); return argumentKeyObject; }',
          'var argumentSource = { get receiver() { events.push(this === argumentSource ? "argument-receiver:this" : "argument-receiver:wrong-this"); return { base: 7, get valueCall() { events.push("value-call-getter"); return function (input) { events.push(this.base === 7 ? "value-call:this" : "value-call:wrong-this"); return this.base + input; }; } }; } };',
          'globalThis.__zntcCallKeySequenceHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcNullCallKeySequenceHolder = { get outer() { events.push("missing"); return null; } };',
          'globalThis.__zntcMissingCallKeySequenceHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class CallKeySequenceField { static value = __zntcCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey()](1))); static absent = __zntcNullCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.receiver[argumentKey()](1))); }',
          'function failAtMissingCallKeySequenceMethod() { class MissingCallKeySequenceField { static value = __zntcMissingCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.receiver[argumentKey()](1))); } }',
          'try { failAtMissingCallKeySequenceMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(CallKeySequenceField.value, CallKeySequenceField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,receiver,method,before,argument-receiver:this,key-call,key-coerce,value-call-getter,value-call:this,this,missing,type-outer,type-receiver,before-missing,argument-receiver:this,key-call,key-coerce,value-call-getter,value-call:this,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound computed final-call key call stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'globalThis.__zntcUnboundComputedFinalCallKeyFactory = function () { events.push("key"); return "valueCall"; };',
          'globalThis.__zntcUnboundComputedFinalCallKeyCallHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundComputedFinalCallKeyCallField { static value = __zntcUnboundComputedFinalCallKeyCallHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[__zntcUnboundComputedFinalCallKeyFactory()](1))); }',
          'console.log(UnboundComputedFinalCallKeyCallField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,key\n',
      },
      {
        name: 'unresolved deep optional member calls retain a sequence with an exact-bound optional call key',
        source: [
          'var events = [];',
          'var argumentKeyObject = { [Symbol.toPrimitive]() { events.push("key-coerce"); return "valueCall"; } };',
          'function argumentKey(key) { events.push("key"); return key; }',
          'var absentArgumentKey = null;',
          'var argumentSource = { effectfulKeyArgument() { events.push(this === argumentSource ? "key-argument:this" : "key-argument:wrong-this"); return argumentKeyObject; }, get receiver() { events.push(this === argumentSource ? "argument-receiver:this" : "argument-receiver:wrong-this"); return { base: 7, get valueCall() { events.push("value-call-getter"); return function (input) { events.push(this.base === 7 ? "value-call:this" : "value-call:wrong-this"); return this.base + input; }; }, get undefined() { events.push("undefined-key-getter"); return function (input) { events.push(this.base === 7 ? "undefined-key:this" : "undefined-key:wrong-this"); return this.base + input; }; } }; } };',
          'globalThis.__zntcOptionalCallKeySequenceHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcNullOptionalCallKeySequenceHolder = { get outer() { events.push("null-outer"); return null; } };',
          'globalThis.__zntcMissingOptionalCallKeySequenceHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class OptionalCallKeySequenceField { static value = __zntcOptionalCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey?.(argumentSource.effectfulKeyArgument())](1))); static absent = __zntcOptionalCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("before-undefined-key"), argumentSource.receiver[absentArgumentKey?.(argumentSource.effectfulKeyArgument())](1))); static skipped = __zntcNullOptionalCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.receiver[argumentKey?.(argumentSource.effectfulKeyArgument())](1))); }',
          'function failAtMissingOptionalCallKeySequenceMethod() { class MissingOptionalCallKeySequenceField { static value = __zntcMissingOptionalCallKeySequenceHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.receiver[argumentKey?.(argumentSource.effectfulKeyArgument())](1))); } }',
          'try { failAtMissingOptionalCallKeySequenceMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(OptionalCallKeySequenceField.value, OptionalCallKeySequenceField.absent, OptionalCallKeySequenceField.skipped, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 9 undefined outer,receiver,method,before,argument-receiver:this,key-argument:this,key,key-coerce,value-call-getter,value-call:this,this,outer,receiver,method,before-undefined-key,argument-receiver:this,undefined-key-getter,undefined-key:this,this,null-outer,type-outer,type-receiver,before-missing,argument-receiver:this,key-argument:this,key,key-coerce,value-call-getter,value-call:this,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound optional computed final-call key call stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'globalThis.__zntcUnboundOptionalComputedFinalCallKeyFactory = function () { events.push("key"); return "valueCall"; };',
          'globalThis.__zntcUnboundOptionalComputedFinalCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOptionalComputedFinalCallKeyField { static value = __zntcUnboundOptionalComputedFinalCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[__zntcUnboundOptionalComputedFinalCallKeyFactory?.()](1))); }',
          'console.log(UnboundOptionalComputedFinalCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,key\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound argument call in the optional computed final-call key stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'function argumentKey(value) { events.push("key:" + value); return "valueCall"; }',
          'globalThis.__zntcUnboundOptionalComputedFinalCallKeyArgument = function () { events.push("unbound-key-argument"); return "value"; };',
          'globalThis.__zntcUnboundOptionalComputedFinalCallKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOptionalComputedFinalCallKeyArgumentField { static value = __zntcUnboundOptionalComputedFinalCallKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey?.(__zntcUnboundOptionalComputedFinalCallKeyArgument())](1))); }',
          'console.log(UnboundOptionalComputedFinalCallKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-key-argument,key:value\n',
      },
      {
        name: 'unresolved deep optional member calls retain a computed final-call key with one exact-bound argument call',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'function effectfulKeyArgument() { events.push("key-argument"); return "value"; }',
          'globalThis.__zntcEffectfulArgumentComputedFinalCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class EffectfulArgumentComputedFinalCallKeyField { static value = __zntcEffectfulArgumentComputedFinalCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(effectfulKeyArgument())](1))); }',
          'console.log(EffectfulArgumentComputedFinalCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before,key-argument,key:value\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound computed-member call argument in a final-call key',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { base: 7, get nestedKey() { events.push(this.base === 7 ? "nested-getter:this" : "nested-getter:wrong"); return function () { events.push(this.base === 7 ? "nested-call:this" : "nested-call:wrong"); return "value"; }; }, valueCall(input) { events.push(this.base === 7 ? "value-call:this" : "value-call:wrong"); return input + 7; } } };',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcComputedMemberArgumentKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class ComputedMemberArgumentKeyField { static value = __zntcComputedMemberArgumentKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver["nestedKey"]())](1))); }',
          'console.log(ComputedMemberArgumentKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before,nested-getter:this,nested-call:this,key:value,value-call:this\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound computed-member call argument in a final-call key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { nestedKey() { events.push("nested-call"); return "value"; }, valueCall(input) { events.push("value-call"); return input + 7; } } };',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcUnboundComputedMemberArgumentMethodKey = "nestedKey";',
          'globalThis.__zntcUnboundComputedMemberArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundComputedMemberArgumentKeyField { static value = __zntcUnboundComputedMemberArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver[__zntcUnboundComputedMemberArgumentMethodKey]())](1))); }',
          'console.log(UnboundComputedMemberArgumentKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,nested-call,key:value,value-call\n',
      },
      {
        name: 'unresolved deep optional member calls retain an exact-bound computed-member call key in a final-call key',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { base: 7, get nestedKey() { events.push(this.base === 7 ? "nested-getter:this" : "nested-getter:wrong"); return function () { events.push(this.base === 7 ? "nested-call:this" : "nested-call:wrong"); return "value"; }; }, valueCall(input) { events.push(this.base === 7 ? "value-call:this" : "value-call:wrong"); return input + 7; } } };',
          'function nestedMethodKey(prefix) { events.push("nested-key:" + prefix); return { toString() { events.push("key-coerce"); return "nestedKey"; } }; }',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcEffectfulComputedMemberArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class EffectfulComputedMemberArgumentKeyField { static value = __zntcEffectfulComputedMemberArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver[nestedMethodKey("prefix")]())](1))); }',
          'console.log(EffectfulComputedMemberArgumentKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 before,nested-key:prefix,key-coerce,nested-getter:this,nested-call:this,key:value,value-call:this\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound computed-member call key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { nestedKey() { events.push("nested-call"); return "value"; }, valueCall(input) { events.push("value-call"); return input + 7; } } };',
          'globalThis.__zntcUnboundNestedMethodKey = function () { events.push("unbound-nested-key"); return "nestedKey"; };',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcUnboundComputedMemberCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundComputedMemberCallKeyField { static value = __zntcUnboundComputedMemberCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver[__zntcUnboundNestedMethodKey()]())](1))); }',
          'console.log(UnboundComputedMemberCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-nested-key,nested-call,key:value,value-call\n',
      },
      {
        name: 'unresolved deep optional member calls keep an optional computed-member call key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { nestedKey() { events.push("nested-call"); return "value"; }, valueCall(input) { events.push("value-call"); return input + 7; } } };',
          'function nestedMethodKey() { events.push("nested-key"); return "nestedKey"; }',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcOptionalComputedMemberCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalComputedMemberCallKeyField { static value = __zntcOptionalComputedMemberCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver[nestedMethodKey?.()]())](1))); }',
          'console.log(OptionalComputedMemberCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,nested-key,nested-call,key:value,value-call\n',
      },
      {
        name: 'unresolved deep optional member calls keep a nested computed-member key call on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { nestedKey() { events.push("nested-call"); return "value"; }, valueCall(input) { events.push("value-call"); return input + 7; } } };',
          'function deepMethodKey() { events.push("deep-key"); return "nestedKey"; }',
          'function nestedMethodKey(key) { events.push("nested-key:" + key); return key; }',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcNestedComputedMemberCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class NestedComputedMemberCallKeyField { static value = __zntcNestedComputedMemberCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver[nestedMethodKey(deepMethodKey())]())](1))); }',
          'console.log(NestedComputedMemberCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,deep-key,nested-key:nestedKey,nested-call,key:value,value-call\n',
      },
      {
        name: 'unresolved deep optional member calls keep an optional computed-member call argument in a final-call key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { nestedKey() { events.push("nested-call"); return "value"; }, valueCall(input) { events.push("value-call"); return input + 7; } } };',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcOptionalComputedMemberArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalComputedMemberArgumentKeyField { static value = __zntcOptionalComputedMemberArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(argumentSource.receiver?.["nestedKey"]())](1))); }',
          'console.log(OptionalComputedMemberArgumentKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,nested-call,key:value,value-call\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound nested computed final-call key argument stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'function argumentKey(key) { events.push("key:" + key); return "valueCall"; }',
          'globalThis.__zntcUnboundComputedFinalCallKeyArgument = function () { events.push("unbound-key-argument"); return "value"; };',
          'globalThis.__zntcUnboundComputedFinalCallKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundNestedComputedFinalCallKeyArgumentField { static value = __zntcUnboundComputedFinalCallKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(__zntcUnboundComputedFinalCallKeyArgument())](1))); }',
          'console.log(UnboundNestedComputedFinalCallKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-key-argument,key:value\n',
      },
      {
        name: 'unresolved deep optional member calls with a two-level computed final-call key argument stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'function argumentKey(value) { events.push("key:" + value); return "valueCall"; }',
          'function nestedKeyArgument(value) { events.push("nested:" + value); return value; }',
          'function deepKeyArgument() { events.push("deep"); return "value"; }',
          'globalThis.__zntcDeepComputedFinalCallKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class DeepComputedFinalCallKeyArgumentField { static value = __zntcDeepComputedFinalCallKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey(nestedKeyArgument(deepKeyArgument()))](1))); }',
          'console.log(DeepComputedFinalCallKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,deep,nested:value,key:value\n',
      },
      {
        name: 'bound-root deep optional member calls retain safe computed final-call sequences',
        source: [
          'var events = [];',
          'var argumentKey = "valueCall";',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootComputedCallSequenceField { static value = holder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey](1))); }',
          'console.log(BoundRootComputedCallSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound computed final-call key stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'globalThis.__zntcUnboundComputedFinalCallKey = "valueCall";',
          'globalThis.__zntcUnboundComputedFinalCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundComputedFinalCallKeyField { static value = __zntcUnboundComputedFinalCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[__zntcUnboundComputedFinalCallKey](1))); }',
          'console.log(UnboundComputedFinalCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before\n',
      },
      {
        name: 'unresolved deep optional member calls retain an exact-bound computed final-call key call',
        source: [
          'var events = [];',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'function argumentKey() { events.push("key"); return "valueCall"; }',
          'globalThis.__zntcEffectfulComputedFinalCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class EffectfulComputedFinalCallKeyField { static value = __zntcEffectfulComputedFinalCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver[argumentKey()](1))); }',
          'console.log(EffectfulComputedFinalCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before,key\n',
      },
      {
        name: 'unresolved deep optional member calls with an optional computed final-call callee stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentKey = "valueCall";',
          'var argumentSource = { receiver: { valueCall(input) { return input + 7; } } };',
          'globalThis.__zntcOptionalComputedFinalCallKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalComputedFinalCallKeyField { static value = __zntcOptionalComputedFinalCallKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.receiver?.[argumentKey](1))); }',
          'console.log(OptionalComputedFinalCallKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before\n',
      },
      {
        name: 'bound-root deep optional member calls retain exact-bound call argument sequences and evaluation order',
        source: [
          'var events = [];',
          'var argumentSource = { base: 7, get valueCall() { events.push("argument-getter"); return function (input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return this.base + input; }; } };',
          'var holder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'var absentHolder = { get outer() { events.push("absent"); return null; } };',
          'var missingMethodHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class BoundRootCallSequenceField { static value = holder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(1))); static absent = absentHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.valueCall(1))); }',
          'function failAtMissingBoundRootSequenceMethod() { class MissingBoundRootSequenceMethodField { static value = missingMethodHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.valueCall(1))); } }',
          'try { failAtMissingBoundRootSequenceMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(BoundRootCallSequenceField.value, BoundRootCallSequenceField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,receiver,method,before,argument-getter,argument-this,this,absent,type-outer,type-receiver,before-missing,argument-getter,argument-this,type-error\n',
      },
      {
        name: 'bound-root deep optional member calls keep an unbound final sequence call on reanalysis',
        source: [
          'var events = [];',
          'globalThis.__zntcBoundRootUnboundSequenceCall = function () { events.push("unbound"); return 8; };',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootUnboundSequenceCallField { static value = holder.outer?.receiver.fieldValue((events.push("before"), __zntcBoundRootUnboundSequenceCall())); }',
          'console.log(BoundRootUnboundSequenceCallField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound\n',
      },
      {
        name: 'bound-root deep optional member calls keep an unbound prefix call in an argument sequence on reanalysis',
        source: [
          'var events = [];',
          'globalThis.__zntcBoundRootUnboundSequencePrefix = function () { events.push("unbound-prefix"); return 0; };',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootUnboundSequencePrefixField { static value = holder.outer?.receiver.fieldValue((events.push("before"), __zntcBoundRootUnboundSequencePrefix(), 8)); }',
          'console.log(BoundRootUnboundSequencePrefixField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-prefix\n',
      },
      {
        name: 'bound-root deep optional member calls keep an optional prefix call in an argument sequence on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { optionalCall() { events.push("optional-prefix"); return 0; } };',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootOptionalSequencePrefixField { static value = holder.outer?.receiver.fieldValue((events.push("before"), argumentSource.optionalCall?.(), 8)); }',
          'console.log(BoundRootOptionalSequencePrefixField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,optional-prefix\n',
      },
      {
        name: 'bound-root deep optional member calls keep an update in an argument sequence on reanalysis',
        source: [
          'var events = [];',
          'var argumentValue = 7;',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootUpdateSequenceField { static value = holder.outer?.receiver.fieldValue((events.push("before"), argumentValue++, 8)); }',
          'console.log(BoundRootUpdateSequenceField.value, argumentValue, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 8 before\n',
      },
      {
        name: 'bound-root deep optional member calls keep an optional call in an argument sequence on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { valueCall() { events.push("optional"); return 8; } };',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootOptionalSequenceCallField { static value = holder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall?.())); }',
          'console.log(BoundRootOptionalSequenceCallField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,optional\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound final sequence call stay on semantic reanalysis',
        source: [
          'var events = [];',
          'globalThis.__zntcUnboundFinalSequenceCall = function () { events.push("argument"); return 1; };',
          'globalThis.__zntcUnboundFinalSequenceCallHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundFinalSequenceCallField { static value = __zntcUnboundFinalSequenceCallHolder.outer?.receiver.fieldValue((events.push("before"), __zntcUnboundFinalSequenceCall())); }',
          'console.log(UnboundFinalSequenceCallField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '2 before,argument\n',
      },
      {
        name: 'unresolved deep optional member calls with an optional final sequence call stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { valueCall() { events.push("argument"); return 1; } };',
          'globalThis.__zntcOptionalFinalSequenceCallHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalFinalSequenceCallField { static value = __zntcOptionalFinalSequenceCallHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall?.())); }',
          'console.log(OptionalFinalSequenceCallField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '2 before,argument\n',
      },
      {
        name: 'unresolved deep optional member calls retain a safe computed final sequence call',
        source: [
          'var events = [];',
          'var argumentSource = { valueCall(input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return input + 7; } };',
          'globalThis.__zntcComputedFinalSequenceCallHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class ComputedFinalSequenceCallField { static value = __zntcComputedFinalSequenceCallHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource["valueCall"](1))); }',
          'console.log(ComputedFinalSequenceCallField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before,argument-this\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound nested sequence-call argument and order',
        source: [
          'var events = [];',
          'var argumentSource = { base: 7, get valueCall() { events.push("argument-getter"); return function (input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return this.base + input; }; } };',
          'function effectfulValue() { events.push("nested-call"); return 1; }',
          'globalThis.__zntcEffectfulArgumentFinalSequenceCallHolder = { get outer() { events.push("outer"); return { get receiver() { events.push("receiver"); return { base: 1, get fieldValue() { events.push("method"); return function (input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; }; } }; } }; } };',
          'globalThis.__zntcNullEffectfulArgumentFinalSequenceCallHolder = { get outer() { events.push("null-outer"); return null; } };',
          'globalThis.__zntcMissingEffectfulArgumentFinalSequenceCallHolder = { get outer() { events.push("type-outer"); return { get receiver() { events.push("type-receiver"); return {}; } }; } };',
          'class EffectfulArgumentFinalSequenceCallField { static value = __zntcEffectfulArgumentFinalSequenceCallHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(effectfulValue()))); static absent = __zntcNullEffectfulArgumentFinalSequenceCallHolder.outer?.receiver.fieldValue((events.push("null-before"), argumentSource.valueCall(effectfulValue()))); }',
          'function failAtMissingEffectfulFinalSequenceCallMethod() { class MissingEffectfulFinalSequenceCallMethodField { static value = __zntcMissingEffectfulArgumentFinalSequenceCallHolder.outer?.receiver.fieldValue((events.push("before-missing"), argumentSource.valueCall(effectfulValue()))); } }',
          'try { failAtMissingEffectfulFinalSequenceCallMethod(); } catch (error) { events.push(error instanceof TypeError ? "type-error" : "wrong-error"); }',
          'console.log(EffectfulArgumentFinalSequenceCallField.value, EffectfulArgumentFinalSequenceCallField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 undefined outer,receiver,method,before,argument-getter,nested-call,argument-this,this,null-outer,type-outer,type-receiver,before-missing,argument-getter,nested-call,argument-this,type-error\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound nested final-call argument on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { valueCall(input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return input + 7; } };',
          'globalThis.__zntcUnboundNestedSequenceArgument = function () { events.push("unbound-argument"); return 1; };',
          'globalThis.__zntcUnboundNestedSequenceArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundNestedSequenceArgumentField { static value = __zntcUnboundNestedSequenceArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(__zntcUnboundNestedSequenceArgument()))); }',
          'console.log(UnboundNestedSequenceArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-argument,argument-this\n',
      },
      {
        name: 'unresolved deep optional member calls retain one optional nested final-call argument',
        source: [
          'var events = [];',
          'var argumentSource = { optionalValue(input) { events.push(this === argumentSource ? "optional-this" : "optional-wrong-this"); return input; }, missingValue: null, valueCall(input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return input === undefined ? 7 : input + 7; } };',
          'globalThis.__zntcOptionalNestedSequenceArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalNestedSequenceArgumentField { static value = __zntcOptionalNestedSequenceArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(argumentSource.optionalValue?.(1)))); static absent = __zntcOptionalNestedSequenceArgumentHolder.outer?.receiver.fieldValue((events.push("absent-before"), argumentSource.valueCall(argumentSource.missingValue?.(1)))); }',
          'console.log(OptionalNestedSequenceArgumentField.value, OptionalNestedSequenceArgumentField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 8 before,optional-this,argument-this,absent-before,argument-this\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound optional nested final-call argument on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { valueCall(input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return input + 7; } };',
          'globalThis.__zntcUnboundOptionalNestedSequenceArgument = function () { events.push("unbound-optional"); return 1; };',
          'globalThis.__zntcUnboundOptionalNestedSequenceArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOptionalNestedSequenceArgumentField { static value = __zntcUnboundOptionalNestedSequenceArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(__zntcUnboundOptionalNestedSequenceArgument?.()))); }',
          'console.log(UnboundOptionalNestedSequenceArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-optional,argument-this\n',
      },
      {
        name: 'unresolved deep optional member calls keep effectful arguments in an optional nested call on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { optionalValue(input) { events.push("optional-this"); return input; }, valueCall(input) { return input + 7; } };',
          'function effectfulNestedArgument() { events.push("nested-argument"); return 1; }',
          'globalThis.__zntcEffectfulOptionalNestedSequenceArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class EffectfulOptionalNestedSequenceArgumentField { static value = __zntcEffectfulOptionalNestedSequenceArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(argumentSource.optionalValue?.(effectfulNestedArgument())))); }',
          'console.log(EffectfulOptionalNestedSequenceArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,nested-argument,optional-this\n',
      },
      {
        name: 'unresolved deep optional member calls keep deeper nested final-call arguments on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { inner() { events.push("inner"); return 1; }, outer(input) { events.push("outer"); return input + 1; }, valueCall(input) { events.push(this === argumentSource ? "argument-this" : "argument-wrong-this"); return input + 7; } };',
          'globalThis.__zntcDeepNestedSequenceArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class DeepNestedSequenceArgumentField { static value = __zntcDeepNestedSequenceArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource.valueCall(argumentSource.outer(argumentSource.inner())))); }',
          'console.log(DeepNestedSequenceArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '10 before,inner,outer,argument-this\n',
      },
      {
        name: 'bound-root deep optional member calls retain member-read argument sequences',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'var holder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class BoundRootMemberSequenceField { static value = holder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource.value)); }',
          'console.log(BoundRootMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before-argument,value\n',
      },
      {
        name: 'unresolved deep optional member calls with an unbound member-read sequence value stay on semantic reanalysis',
        source: [
          'var events = [];',
          'globalThis.__zntcUnboundMemberSequenceSource = { get value() { events.push("value"); return 8; } };',
          'globalThis.__zntcUnboundMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundMemberSequenceField { static value = __zntcUnboundMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), __zntcUnboundMemberSequenceSource.value)); }',
          'console.log(UnboundMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before-argument,value\n',
      },
      {
        name: 'unresolved deep optional member calls with an optional member-read sequence value stay on semantic reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'globalThis.__zntcOptionalMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalMemberSequenceField { static value = __zntcOptionalMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource?.value)); }',
          'console.log(OptionalMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before-argument,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain an effectful computed member-read sequence value',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function argumentKey() { events.push("key"); return "value"; }',
          'globalThis.__zntcComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class ComputedMemberSequenceField { static value = __zntcComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey()])); }',
          'console.log(ComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before-argument,key,value\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound computed member-read sequence key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'globalThis.__zntcUnboundComputedMemberSequenceKey = function () { events.push("key"); return "value"; };',
          'globalThis.__zntcUnboundComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundComputedMemberSequenceField { static value = __zntcUnboundComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[__zntcUnboundComputedMemberSequenceKey()])); }',
          'console.log(UnboundComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before-argument,key,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain an exact-bound optional computed member-read sequence key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push(this === argumentSource ? "value:this" : "value:wrong-this"); return 8; }, get undefined() { events.push(this === argumentSource ? "undefined:this" : "undefined:wrong-this"); return 10; }, key() { events.push(this === argumentSource ? "key:this" : "key:wrong-this"); return "value"; }, absentKey: null };',
          'function argumentKey() { events.push("key"); return "value"; }',
          'var absentArgumentKey = null;',
          'globalThis.__zntcOptionalComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalComputedMemberSequenceField { static value = __zntcOptionalComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey?.()])); static absent = __zntcOptionalComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-undefined"), argumentSource[absentArgumentKey?.()])); static member = __zntcOptionalComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-member"), argumentSource[argumentSource.key?.()])); static absentMember = __zntcOptionalComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-absent-member"), argumentSource[argumentSource.absentKey?.()])); }',
          'console.log(OptionalComputedMemberSequenceField.value, OptionalComputedMemberSequenceField.absent, OptionalComputedMemberSequenceField.member, OptionalComputedMemberSequenceField.absentMember, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 11 9 11 before-argument,key,value:this,before-undefined,undefined:this,before-member,key:this,value:this,before-absent-member,undefined:this\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound optional computed member-read key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'globalThis.__zntcUnboundOptionalMemberReadKey = function () { events.push("unbound-key"); return "value"; };',
          'globalThis.__zntcUnboundOptionalMemberReadSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOptionalMemberReadKeyField { static value = __zntcUnboundOptionalMemberReadSequenceHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[__zntcUnboundOptionalMemberReadKey?.()])); }',
          'console.log(UnboundOptionalMemberReadKeyField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-key,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound call argument in an optional computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; }, get undefined() { events.push("undefined"); return 10; } };',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'function effectfulKeyArgument() { events.push("key-argument"); return 1; }',
          'var absentArgumentKey = null;',
          'globalThis.__zntcEffectfulOptionalMemberReadKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class EffectfulOptionalMemberReadKeyField { static value = __zntcEffectfulOptionalMemberReadKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(effectfulKeyArgument())])); static absent = __zntcEffectfulOptionalMemberReadKeyHolder.outer?.receiver.fieldValue((events.push("before-undefined"), argumentSource[absentArgumentKey?.(effectfulKeyArgument())])); }',
          'console.log(EffectfulOptionalMemberReadKeyField.value, EffectfulOptionalMemberReadKeyField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 11 before,key-argument,key:1,value,before-undefined,undefined\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound nested argument in an optional computed member-read key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcUnboundOptionalMemberReadKeyArgument = function () { events.push("unbound-argument"); return 1; };',
          'globalThis.__zntcUnboundOptionalMemberReadKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOptionalMemberReadKeyArgumentField { static value = __zntcUnboundOptionalMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(__zntcUnboundOptionalMemberReadKeyArgument())])); }',
          'console.log(UnboundOptionalMemberReadKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-argument,key:1,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain two exact-bound call-argument levels in an optional computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'function outerKeyArgument(input) { events.push("outer-argument"); return input; }',
          'function innerKeyArgument() { events.push("inner-argument"); return 1; }',
          'globalThis.__zntcDeepOptionalMemberReadKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class DeepOptionalMemberReadKeyArgumentField { static value = __zntcDeepOptionalMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(outerKeyArgument(innerKeyArgument()))])); }',
          'console.log(DeepOptionalMemberReadKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before,inner-argument,outer-argument,key:1,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound optional nested call argument in an optional computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; }, get undefined() { events.push("undefined"); return 10; } };',
          'function argumentKey(input) { events.push("key:" + input); return input === "value" ? "value" : "undefined"; }',
          'function optionalKeyArgument() { events.push("optional-key-argument"); return "value"; }',
          'var absentOptionalKeyArgument = null;',
          'var absentArgumentKey = null;',
          'globalThis.__zntcOptionalNestedMemberReadKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalNestedMemberReadKeyArgumentField { static value = __zntcOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(optionalKeyArgument?.())])); static absentNested = __zntcOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before-null-inner"), argumentSource[argumentKey?.(absentOptionalKeyArgument?.())])); static absentOuter = __zntcOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before-null-outer"), argumentSource[absentArgumentKey?.(optionalKeyArgument?.())])); }',
          'console.log(OptionalNestedMemberReadKeyArgumentField.value, OptionalNestedMemberReadKeyArgumentField.absentNested, OptionalNestedMemberReadKeyArgumentField.absentOuter, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 11 11 before,optional-key-argument,key:value,value,before-null-inner,key:undefined,undefined,before-null-outer,undefined\n',
      },
      {
        name: 'unresolved deep optional member calls retain an exact-bound optional member-call argument in an optional computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; }, get undefined() { events.push("undefined"); return 10; }, keyArgument() { events.push(this === argumentSource ? "member-key:this" : "member-key:wrong-this"); return "value"; } };',
          'function argumentKey(input) { events.push("key:" + input); return input === "value" ? "value" : "undefined"; }',
          'globalThis.__zntcOptionalMemberNestedReadKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalMemberNestedReadKeyArgumentField { static value = __zntcOptionalMemberNestedReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(argumentSource.keyArgument?.())])); }',
          'console.log(OptionalMemberNestedReadKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before,member-key:this,key:value,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound optional member call inside an ordinary computed member-read key',
        source: [
          'var events = [];',
          'var fieldReceiver = { fieldValue(input) { events.push(this === fieldReceiver ? "field:this" : "field:wrong-this"); return input + 1; } };',
          'var argumentSource = { get value() { events.push("value"); return 8; }, get undefined() { events.push("undefined"); return 10; }, keyArgument() { events.push(this === argumentSource ? "member-key:this" : "member-key:wrong-this"); return "value"; }, absentKeyArgument: null };',
          'function argumentKey(input) { events.push("key:" + input); return input === "value" ? "value" : "undefined"; }',
          'globalThis.__zntcOrdinaryNestedOptionalMemberReadKeyHolder = { get outer() { events.push("outer"); return { receiver: fieldReceiver }; } };',
          'globalThis.__zntcMissingOrdinaryNestedOptionalMemberReadKeyHolder = { get outer() { events.push("missing"); return null; } };',
          'class OrdinaryNestedOptionalMemberReadKeyField { static value = __zntcOrdinaryNestedOptionalMemberReadKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey(argumentSource.keyArgument?.())])); static absent = __zntcOrdinaryNestedOptionalMemberReadKeyHolder.outer?.receiver.fieldValue((events.push("before-undefined"), argumentSource[argumentKey(argumentSource.absentKeyArgument?.())])); static skipped = __zntcMissingOrdinaryNestedOptionalMemberReadKeyHolder.outer?.receiver.fieldValue((events.push("before-skipped"), argumentSource[argumentKey(argumentSource.keyArgument?.())])); }',
          'console.log(OrdinaryNestedOptionalMemberReadKeyField.value, OrdinaryNestedOptionalMemberReadKeyField.absent, OrdinaryNestedOptionalMemberReadKeyField.skipped, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 11 undefined outer,before,member-key:this,key:value,value,field:this,outer,before-undefined,key:undefined,undefined,field:this,missing\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound optional nested call in an ordinary computed member-read key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcUnboundOrdinaryOptionalKeyArgument = function () { events.push("unbound"); return "value"; };',
          'globalThis.__zntcUnboundOrdinaryOptionalKeyHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOrdinaryOptionalKeyArgumentField { static value = __zntcUnboundOrdinaryOptionalKeyHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey(__zntcUnboundOrdinaryOptionalKeyArgument?.())])); }',
          'console.log(UnboundOrdinaryOptionalKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound,key:value,value\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound optional nested call argument in an optional computed member-read key on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcUnboundOptionalNestedMemberReadKeyArgument = function () { events.push("unbound-nested"); return "value"; };',
          'globalThis.__zntcUnboundOptionalNestedMemberReadKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundOptionalNestedMemberReadKeyArgumentField { static value = __zntcUnboundOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(__zntcUnboundOptionalNestedMemberReadKeyArgument?.())])); }',
          'console.log(UnboundOptionalNestedMemberReadKeyArgumentField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,unbound-nested,key:value,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain two exact-bound nested call-argument levels in an optional computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; }, get undefined() { events.push("undefined"); return 10; } };',
          'function argumentKey(input) { events.push("key:" + input); return input === 1 ? "value" : "undefined"; }',
          'function outerKeyArgument(input) { events.push("outer-key:" + input); return input; }',
          'function innerKeyArgument() { events.push("inner-key"); return 1; }',
          'var absentOuterKeyArgument = null;',
          'var absentKeyArgument = null;',
          'globalThis.__zntcDeeperOptionalNestedMemberReadKeyArgumentHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class DeeperOptionalNestedMemberReadKeyArgumentField { static value = __zntcDeeperOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(outerKeyArgument?.(innerKeyArgument?.()))])); static absentNested = __zntcDeeperOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before-absent-nested"), argumentSource[argumentKey?.(absentOuterKeyArgument?.(innerKeyArgument?.()))])); static absentKey = __zntcDeeperOptionalNestedMemberReadKeyArgumentHolder.outer?.receiver.fieldValue((events.push("before-absent-key"), argumentSource[absentKeyArgument?.(outerKeyArgument?.(innerKeyArgument?.()))])); }',
          'console.log(DeeperOptionalNestedMemberReadKeyArgumentField.value, DeeperOptionalNestedMemberReadKeyArgumentField.absentNested, DeeperOptionalNestedMemberReadKeyArgumentField.absentKey, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 11 11 before,inner-key,outer-key:1,key:1,value,before-absent-nested,key:undefined,undefined,before-absent-key,undefined\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound nested computed-member key argument',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function keyArgument() { events.push("key-argument"); return "inner"; }',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcNestedComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class NestedComputedMemberSequenceField { static value = __zntcNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey(keyArgument())])); }',
          'console.log(NestedComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before-argument,key-argument,key:inner,value\n',
      },
      {
        name: 'unresolved deep optional member calls keep an unbound nested computed-member key argument on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'globalThis.__zntcUnboundNestedComputedMemberKeyArgument = function () { events.push("key-argument"); return "inner"; };',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcUnboundNestedComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class UnboundNestedComputedMemberSequenceField { static value = __zntcUnboundNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey(__zntcUnboundNestedComputedMemberKeyArgument())])); }',
          'console.log(UnboundNestedComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before-argument,key-argument,key:inner,value\n',
      },
      {
        name: 'unresolved deep optional member calls retain one exact-bound optional direct call inside an ordinary computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; }, get undefined() { events.push("undefined"); return 10; } };',
          'function keyArgument() { events.push("key-argument"); return "inner"; }',
          'function argumentKey(input) { events.push("key:" + input); return input === "inner" ? "value" : "undefined"; }',
          'var absentKeyArgument = null;',
          'globalThis.__zntcOptionalNestedComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class OptionalNestedComputedMemberSequenceField { static value = __zntcOptionalNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey(keyArgument?.())])); static absent = __zntcOptionalNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-absent"), argumentSource[argumentKey(absentKeyArgument?.())])); }',
          'console.log(OptionalNestedComputedMemberSequenceField.value, OptionalNestedComputedMemberSequenceField.absent, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '9 11 before-argument,key-argument,key:inner,value,before-absent,key:undefined,undefined\n',
      },
      {
        name: 'unresolved deep optional member calls retain two exact-bound nested call-argument levels in an ordinary computed member-read key',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; }, keyArgument(input) { events.push(this === argumentSource ? "key-argument:" + input : "key-argument:wrong-this"); return "inner"; } };',
          'function deeperKeyArgument() { events.push("deeper-key-argument"); return "deep"; }',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcDeeperNestedComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class DeeperNestedComputedMemberSequenceField { static value = __zntcDeeperNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey(argumentSource.keyArgument?.(deeperKeyArgument?.()))])); }',
          'console.log(DeeperNestedComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 before-argument,deeper-key-argument,key-argument:deep,key:inner,value\n',
      },
      {
        name: 'unresolved deep optional member calls keep a third exact-bound nested call-argument level on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function innerKeyArgument() { events.push("inner-key"); return "deep"; }',
          'function middleKeyArgument(input) { events.push("middle-key:" + input); return input; }',
          'function outerKeyArgument(input) { events.push("outer-key:" + input); return input; }',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcThirdNestedComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class ThirdNestedComputedMemberSequenceField { static value = __zntcThirdNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before-argument"), argumentSource[argumentKey(outerKeyArgument?.(middleKeyArgument?.(innerKeyArgument?.())))])); }',
          'console.log(ThirdNestedComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before-argument,inner-key,middle-key:deep,outer-key:deep,key:deep,value\n',
      },
      {
        name: 'unresolved deep optional member calls keep a third nested optional call-argument level on reanalysis',
        source: [
          'var events = [];',
          'var argumentSource = { get value() { events.push("value"); return 8; } };',
          'function innerKeyArgument() { events.push("inner-key"); return 1; }',
          'function middleKeyArgument(input) { events.push("middle-key:" + input); return input; }',
          'function outerKeyArgument(input) { events.push("outer-key:" + input); return input; }',
          'function argumentKey(input) { events.push("key:" + input); return "value"; }',
          'globalThis.__zntcThirdOptionalNestedComputedMemberSequenceHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } };',
          'class ThirdOptionalNestedComputedMemberSequenceField { static value = __zntcThirdOptionalNestedComputedMemberSequenceHolder.outer?.receiver.fieldValue((events.push("before"), argumentSource[argumentKey?.(outerKeyArgument?.(middleKeyArgument?.(innerKeyArgument?.())))])); }',
          'console.log(ThirdOptionalNestedComputedMemberSequenceField.value, events.join(","));',
        ].join('\n'),
        graph: 'reanalyzed',
        output: '9 before,inner-key,middle-key:1,outer-key:1,key:1,value\n',
      },
      {
        name: 'optional invocation after a deep optional member receiver keeps short-circuit and exact identity',
        source: [
          'var events = [];',
          'var calls = 0;',
          'var holder = { get outer() { events.push("outer"); return { receiver: { base: 1, fieldValue(input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; } } }; } };',
          'var missingHolder = { get outer() { events.push("missing"); return null; } };',
          'function argument() { calls++; events.push("argument"); return 8; }',
          'class ExplicitOptionalDeepMemberReceiverField { static value = holder.outer?.receiver.fieldValue?.(argument()); static missing = missingHolder.outer?.receiver.fieldValue?.(argument()); }',
          'console.log(ExplicitOptionalDeepMemberReceiverField.value, ExplicitOptionalDeepMemberReceiverField.missing, calls, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 undefined 1 outer,argument,this,missing\n',
      },
      {
        name: 'unresolved optional invocation after a deep optional member receiver retains exact external identity',
        source: [
          'var events = [];',
          'var calls = 0;',
          'globalThis.__zntcUnresolvedDeepOptionalInvocationHolder = { get outer() { events.push("outer"); return { receiver: { base: 1, fieldValue(input) { events.push(this.base === 1 ? "this" : "wrong-this"); return this.base + input; } } }; } };',
          'globalThis.__zntcUnresolvedNullDeepOptionalInvocationHolder = { get outer() { events.push("missing"); return null; } };',
          'function argument() { calls++; events.push("argument"); return 8; }',
          'class UnresolvedOptionalDeepMemberReceiverField { static value = __zntcUnresolvedDeepOptionalInvocationHolder.outer?.receiver.fieldValue?.(argument()); static missing = __zntcUnresolvedNullDeepOptionalInvocationHolder.outer?.receiver.fieldValue?.(argument()); }',
          'console.log(UnresolvedOptionalDeepMemberReceiverField.value, UnresolvedOptionalDeepMemberReceiverField.missing, calls, events.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 undefined 1 outer,argument,this,missing\n',
      },
      {
        name: 'unresolved deep member-call receiver chains retain their exact graph',
        source:
          'globalThis.__zntcDeepFieldHolder = { outer: { receiver: { fieldValue(input) { return input + 1; } } } }; class UnresolvedDeepMemberReceiverField { static value = __zntcDeepFieldHolder.outer.receiver.fieldValue(8); } console.log(UnresolvedDeepMemberReceiverField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'bound call-result member receiver static field initializers retain their graph',
        source:
          'function getFieldReceiver() { return { fieldValue(input) { return input + 1; } }; } class NestedReceiverMemberCallField { static value = getFieldReceiver().fieldValue(8); } console.log(NestedReceiverMemberCallField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'unresolved call-result static member reads stay on semantic reanalysis',
        source:
          'globalThis.__zntcUnresolvedMemberReadFactory = function () { return { value: 9 }; }; class UnresolvedCallResultStaticMemberReadField { static value = __zntcUnresolvedMemberReadFactory().value; } console.log(UnresolvedCallResultStaticMemberReadField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'bound call-result optional member reads retain receiver, key, getter, and short-circuit order',
        source: [
          'var order = [];',
          'var receiver = { get value() { order.push(this === receiver ? "value:true" : "value:false"); return 9; } };',
          'function makeHolder(value) { order.push(value === null ? "null-receiver" : "receiver"); return value; }',
          'function memberKey() { order.push("key"); return { [Symbol.toPrimitive]() { order.push("coerce"); return "value"; } }; }',
          'class BoundCallResultOptionalMemberReadField { static dotted = makeHolder(receiver)?.value; static computed = makeHolder(receiver)?.[memberKey()]; static absent = makeHolder(null)?.[memberKey()]; }',
          'console.log(BoundCallResultOptionalMemberReadField.dotted, BoundCallResultOptionalMemberReadField.computed, BoundCallResultOptionalMemberReadField.absent, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output: '9 9 undefined receiver,value:true,receiver,key,coerce,value:true,null-receiver\n',
      },
      {
        name: 'unresolved call-result optional member reads stay on semantic reanalysis',
        source:
          'globalThis.__zntcUnresolvedOptionalMemberReadFactory = function () { return { value: 9 }; }; class UnresolvedCallResultOptionalMemberReadField { static value = __zntcUnresolvedOptionalMemberReadFactory()?.value; } console.log(UnresolvedCallResultOptionalMemberReadField.value);',
        graph: 'reanalyzed',
        output: '9\n',
      },
      {
        name: 'optional call-result member read with effectful receiver argument stays on semantic reanalysis',
        source:
          'var order = []; var holder = { value: 9 }; function makeHolder(input) { return holder; } class EffectfulOptionalCallResultMemberReadField { static value = makeHolder((order.push("receiver-argument"), 1))?.value; } console.log(EffectfulOptionalCallResultMemberReadField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 receiver-argument\n',
      },
      {
        name: 'call-result static member read with effectful receiver argument stays on semantic reanalysis',
        source:
          'var order = []; var holder = { value: 9 }; function makeHolder(input) { return holder; } class EffectfulCallResultStaticMemberReadField { static value = makeHolder((order.push("receiver-argument"), 1)).value; } console.log(EffectfulCallResultStaticMemberReadField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 receiver-argument\n',
      },
      {
        name: 'unresolved direct static initializer calls retain exact external identity and order',
        source:
          'var order = []; globalThis.__zntcUnresolvedFieldCall = function (input) { order.push("call:" + input); return input + 1; }; class UnresolvedCallField { static value = __zntcUnresolvedFieldCall(8); } console.log(UnresolvedCallField.value, order.join(","));',
        graph: 'retained',
        output: '9 call:8\n',
      },
      {
        name: 'unresolved direct call name collision with generated static-field temps stays exact',
        source:
          'var order = []; globalThis._a = function (input) { order.push("call"); return input + 1; }; function fieldKey() { order.push("key"); return "value"; } class ExternalStaticCallCollision { static [fieldKey()] = _a(8); } console.log(ExternalStaticCallCollision.value, order.join(","));',
        graph: 'retained',
        output: '9 key,call\n',
      },
      {
        name: 'unresolved optional direct static initializer calls retain root, temp collision, and short-circuit order',
        source: [
          'var order = [];',
          'Object.defineProperty(globalThis, "_a", { configurable: true, get() { order.push("root"); return function (input) { "use strict"; order.push(this === undefined ? "this:undefined" : "this:bound"); order.push("call:" + input); return input + 1; }; } });',
          'Object.defineProperty(globalThis, "_missingOptionalCall", { configurable: true, get() { order.push("missing"); return null; } });',
          'function argument() { order.push("argument"); return 4; }',
          'function wrap(value) { order.push("wrap:" + String(value)); return value; }',
          'class UnresolvedOptionalCallField { static direct = _a?.(argument()); static absent = _missingOptionalCall?.(argument()); static nested = wrap(_a?.(argument())); static nestedAbsent = wrap(_missingOptionalCall?.(argument())); }',
          'console.log(UnresolvedOptionalCallField.direct, UnresolvedOptionalCallField.absent, UnresolvedOptionalCallField.nested, UnresolvedOptionalCallField.nestedAbsent, order.join(","));',
        ].join('\n'),
        graph: 'retained',
        output:
          '5 undefined 5 undefined root,argument,this:undefined,call:4,missing,root,argument,this:undefined,call:4,wrap:5,missing,wrap:undefined\n',
      },
      {
        name: 'unresolved require calls keep import scanning on semantic reanalysis',
        source:
          'class UnresolvedRequireCallField { static value = require("node:path"); } console.log(typeof UnresolvedRequireCallField.value.join);',
        graph: 'reanalyzed',
        output: 'function\n',
      },
      {
        name: 'unresolved optional require calls keep import scanning on semantic reanalysis',
        source:
          'class OptionalUnresolvedRequireCallField { static value = require?.("node:path"); } console.log(typeof OptionalUnresolvedRequireCallField.value.join);',
        graph: 'reanalyzed',
        output: 'function\n',
      },
      {
        name: 'one level of bound nested static-field calls retains graph and evaluation order',
        source:
          'var order = []; function fieldArgument(input) { order.push("arg:" + input); return input + 1; } function fieldValue(input) { order.push("field:" + input); return input + 1; } var receiver = { order, fieldValue(input) { this.order.push("member:" + input); return input + 1; } }; class NestedCallField { static first = fieldValue(fieldArgument(8)); static second = receiver.fieldValue(fieldArgument(10)); } console.log(NestedCallField.first, NestedCallField.second, order.join(","));',
        graph: 'retained',
        output: '10 12 arg:8,field:9,arg:10,member:11\n',
      },
      {
        name: 'unresolved nested static-field call arguments retain their order and external identity',
        source:
          'var order = []; globalThis.__zntcNestedFieldArgument = function (input) { order.push("argument:" + input); return input + 1; }; function fieldValue(input) { order.push("field:" + input); return input + 1; } class UnresolvedNestedCallField { static value = fieldValue(__zntcNestedFieldArgument(8)); } console.log(UnresolvedNestedCallField.value, order.join(","));',
        graph: 'retained',
        output: '10 argument:8,field:9\n',
      },
      {
        name: 'bound optional nested static-field call arguments retain their graph',
        source:
          'function fieldArgument(input) { return input + 1; } function fieldValue(input) { return input + 1; } class OptionalNestedCallField { static value = fieldValue(fieldArgument?.(8)); } console.log(OptionalNestedCallField.value);',
        graph: 'retained',
        output: '10\n',
      },
      {
        name: 'optional member calls nested in static initializer arguments retain evaluation order',
        source:
          'var order = []; var receiver = { base: 5, get fieldValue() { order.push("method"); return function (input) { order.push(this === receiver ? "this" : "wrong-this"); return this.base + input; }; } }; Object.defineProperty(globalThis, "__zntcNestedOptionalCallRoot", { configurable: true, get() { order.push("root"); return receiver; } }); Object.defineProperty(globalThis, "__zntcMissingNestedOptionalCallRoot", { configurable: true, get() { order.push("missing"); return null; } }); function memberKey() { order.push("key"); return "fieldValue"; } function argument() { order.push("argument"); return 4; } function inner(value) { order.push("inner:" + value); return value; } function outer(value) { order.push("outer:" + value); return value; } class NestedOptionalMemberCallArgumentField { static value = outer(inner(__zntcNestedOptionalCallRoot?.[memberKey()](argument()))); static absent = outer(inner(__zntcMissingNestedOptionalCallRoot?.[memberKey()](argument()))); } console.log(NestedOptionalMemberCallArgumentField.value, NestedOptionalMemberCallArgumentField.absent, order.join(","));',
        graph: 'retained',
        output:
          '9 undefined root,key,method,argument,this,inner:9,outer:9,missing,inner:undefined,outer:undefined\n',
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
        name: 'deep unresolved static-field call arguments retain exact identity and evaluation order',
        source:
          'var order = []; globalThis.__zntcDeepFieldArgument = function (input) { order.push("external:" + input); return input + 1; }; function inner(input) { order.push("inner:" + input); return input + 1; } function fieldValue(input) { order.push("field:" + input); return input + 1; } class DeepUnresolvedCallField { static value = fieldValue(inner(__zntcDeepFieldArgument(8))); } console.log(DeepUnresolvedCallField.value, order.join(","));',
        graph: 'retained',
        output: '11 external:8,inner:9,field:10\n',
      },
      {
        name: 'deep bound optional static-field call arguments retain their graph',
        source:
          'function inner(input) { return input + 1; } function fieldArgument(input) { return input + 1; } function fieldValue(input) { return input + 1; } class DeepOptionalCallField { static value = fieldValue(inner(fieldArgument?.(8))); } console.log(DeepOptionalCallField.value);',
        graph: 'retained',
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
        name: 'bound direct optional static initializer calls retain graph and short-circuit order',
        source:
          'var order = []; function argument() { order.push("argument"); return 4; } function fieldValue(input) { "use strict"; order.push(this === undefined ? "this:undefined" : "this:bound"); order.push("call:" + input); return input + 1; } var missing = null; function wrap(value) { order.push("wrap:" + String(value)); return value; } class OptionalCallField { static direct = fieldValue?.(argument()); static absent = missing?.(argument()); static nested = wrap(fieldValue?.(argument())); static nestedAbsent = wrap(missing?.(argument())); } console.log(OptionalCallField.direct, OptionalCallField.absent, OptionalCallField.nested, OptionalCallField.nestedAbsent, order.join(","));',
        graph: 'retained',
        output:
          '5 undefined 5 undefined argument,this:undefined,call:4,argument,this:undefined,call:4,wrap:5,wrap:undefined\n',
      },
      {
        name: 'optional unresolved member receiver calls retain the external root',
        source:
          'globalThis.__zntcOptionalExternalReceiver = { fieldValue(input) { return input + 1; } }; class OptionalExternalReceiverCallField { static value = __zntcOptionalExternalReceiver?.fieldValue(8); } console.log(OptionalExternalReceiverCallField.value);',
        graph: 'retained',
        output: '9\n',
      },
      {
        name: 'effectful non-call static initializer arguments stay on semantic reanalysis',
        source:
          'var order = []; function fieldValue(input) { return input + 1; } class EffectfulArgumentField { static value = fieldValue((order.push("argument"), 8)); } console.log(EffectfulArgumentField.value, order.join(","));',
        graph: 'reanalyzed',
        output: '9 argument\n',
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
        name: 'constructor lexical for-of head retains its graph',
        source:
          'class LexicalConstructorForOf { constructor(values) { for (let value of values) this.value = value; } } console.log(new LexicalConstructorForOf([4, 7]).value);',
        graph: 'retained',
        output: '7\n',
      },
      {
        name: 'constructor const for-in head retains its graph',
        source:
          'class LexicalConstructorForIn { constructor(values) { for (const key in values) this.value = key; } } console.log(new LexicalConstructorForIn({ safe: 1 }).value);',
        graph: 'retained',
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
        name: 'post-super local updates retain their exact helper-colliding binding',
        source:
          'var _this = 50, _newTarget = 60; function Base() {} class Child extends Base { constructor() { super(); var _this = 1; _this++; _this += 2; this.value = _this; } } var child = new Child(); console.log(child.value, child instanceof Child, _this, _newTarget);',
        graph: 'retained',
        output: '4 true 50 60\n',
      },
      {
        name: 'post-super direct function call executes once on the retained graph',
        source:
          'var calls = 0, seen = 0; function record(value) { calls += 1; seen = value; } function Base() {} class Child extends Base { constructor() { super(); record(7); this.value = seen; } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'retained',
        output: '7 1 true\n',
      },
      {
        name: 'post-super receiver call preserves Proxy receiver and getter count',
        source:
          'var reads = 0, calls = 0, receiverOk = false; function Base() { return new Proxy({}, { get(target, key, receiver) { if (key === "setValue") { reads += 1; return function(value) { calls += 1; receiverOk = this === receiver; this.value = value; }; } return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); this.setValue(4); } } var child = new Child(); console.log(child.value, reads, calls, receiverOk, child instanceof Child);',
        graph: 'retained',
        output: '4 1 1 true false\n',
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
        name: 'post-super branch throw preserves the exact thrown object',
        source:
          'var selected = true, sentinel = { value: 9 }; function Base() {} class Child extends Base { constructor() { super(); if (selected) throw sentinel; else this.value = 2; } } try { new Child(); } catch (error) { console.log(error === sentinel, error.value); } selected = false; var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'retained',
        output: 'true 9\n2 true\n',
      },
      {
        name: 'post-super block branch writes once before throwing the exact object',
        source:
          'var selected = true, writes = [], sentinel = {}; function Base() { return new Proxy({}, { set(target, key, value) { writes.push(key + ":" + value); target[key] = value; return true; } }); } class Child extends Base { constructor() { super(); if (selected) { this.flag = 1; throw sentinel; } else { this.flag = 2; } } } try { new Child(); } catch (error) { console.log(error === sentinel, writes.join(",")); } selected = false; var child = new Child(); console.log(child.flag, writes.join(","), child instanceof Child);',
        graph: 'retained',
        output: 'true flag:1\n2 flag:1,flag:2 false\n',
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
        name: 'post-super final throw preserves exact thrown identity after one base call',
        source:
          'var baseCalls = 0, sentinel = { value: 9 }; function Base() { baseCalls += 1; } class Child extends Base { constructor() { super(); throw sentinel; } } var same = false; try { new Child(); } catch (error) { same = error === sentinel; } console.log(same, baseCalls);',
        graph: 'retained',
        output: 'true 1\n',
      },
      {
        name: 'post-super final throw with a call value stays on reanalysis',
        source:
          'var calls = 0, sentinel = {}; function makeError() { calls += 1; return sentinel; } function Base() {} class Child extends Base { constructor() { super(); throw makeError(); } } var same = false; try { new Child(); } catch (error) { same = error === sentinel; } console.log(same, calls);',
        graph: 'reanalyzed',
        output: 'true 1\n',
      },
      {
        name: 'post-super throw with following unreachable statement stays on reanalysis',
        source:
          'var sentinel = {}; function Base() {} class Child extends Base { constructor() { super(); throw sentinel; this.value = 1; } } var same = false; try { new Child(); } catch (error) { same = error === sentinel; } console.log(same);',
        graph: 'reanalyzed',
        output: 'true\n',
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
        name: 'post-super branch throw call stays on reanalysis',
        source:
          'var calls = 0, sentinel = {}; function failure() { calls += 1; return sentinel; } function Base() {} class Child extends Base { constructor() { super(); if (true) throw failure(); else this.value = 2; } } try { new Child(); } catch (error) { console.log(error === sentinel, calls); }',
        graph: 'reanalyzed',
        output: 'true 1\n',
      },
      {
        name: 'post-super branch block with non-final throw stays on reanalysis',
        source:
          'var sentinel = {}; function Base() {} class Child extends Base { constructor() { super(); if (true) { throw sentinel; this.value = 5; } else { this.value = 2; } } } try { new Child(); } catch (error) { console.log(error === sentinel); }',
        graph: 'reanalyzed',
        output: 'true\n',
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
        name: 'post-super direct eval expression stays on reanalysis',
        source:
          'var calls = 0; function Base() {} class Child extends Base { constructor() { super(); eval("calls += 1"); this.value = calls; } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 1 true\n',
      },
      {
        name: 'post-super receiver call with spread arguments stays on reanalysis',
        source:
          'var reads = 0, calls = 0, values = [4]; function Base() { return new Proxy({}, { get(target, key, receiver) { if (key === "setValue") { reads += 1; return function(value) { calls += 1; this.value = value; }; } return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); this.setValue(...values); } } var child = new Child(); console.log(child.value, reads, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '4 1 1 false\n',
      },
      {
        name: 'post-super computed receiver call stays on reanalysis',
        source:
          'var reads = 0, calls = 0, key = "setValue"; function Base() { return new Proxy({}, { get(target, property, receiver) { if (property === "setValue") { reads += 1; return function(value) { calls += 1; this.value = value; }; } return Reflect.get(target, property, receiver); } }); } class Child extends Base { constructor() { super(); this[key](4); } } var child = new Child(); console.log(child.value, reads, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '4 1 1 false\n',
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
        name: 'post-super branch receiver call with spread arguments stays on reanalysis',
        source:
          'var reads = 0, calls = 0, values = [4]; function Base() { return new Proxy({}, { get(target, key, receiver) { if (key === "setValue") { reads += 1; return function(value) { calls += 1; this.value = value; }; } return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (true) { this.setValue(...values); } else { this.value = 2; } } } var child = new Child(); console.log(child.value, reads, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '4 1 1 false\n',
      },
      {
        name: 'post-super branch optional receiver call stays on reanalysis',
        source:
          'var reads = 0, calls = 0; function Base() { return new Proxy({}, { get(target, key, receiver) { if (key === "setValue") { reads += 1; return function(value) { calls += 1; this.value = value; }; } return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (true) { this.setValue?.(4); } else { this.value = 2; } } } var child = new Child(); console.log(child.value, reads, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '4 1 1 false\n',
      },
      {
        name: 'post-super branch computed receiver call stays on reanalysis',
        source:
          'var reads = 0, calls = 0, key = "setValue"; function Base() { return new Proxy({}, { get(target, property, receiver) { if (property === "setValue") { reads += 1; return function(value) { calls += 1; this.value = value; }; } return Reflect.get(target, property, receiver); } }); } class Child extends Base { constructor() { super(); if (true) { this[key](4); } else { this.value = 2; } } } var child = new Child(); console.log(child.value, reads, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '4 1 1 false\n',
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
        name: 'post-super branch expressions preserve local identity and side-effect order',
        source:
          'var selected = true, trace = [], _this = 40; function Base() { return new Proxy({}, { set(target, key, value) { trace.push("set:" + key + ":" + value); target[key] = value; return true; } }); } function record(value) { trace.push("call:" + value); } class Child extends Base { constructor() { super(); var _this = 1; if (selected) { record("left"); _this++; this.value = _this; } else { record("right"); _this += 2; this.value = _this; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, _this, trace.join(","));',
        graph: 'retained',
        output: '2 3 40 call:left,set:value:2,call:right,set:value:3\n',
      },
      {
        name: 'post-super branch Proxy property updates preserve getter and setter counts',
        source:
          'var selected = true, reads = 0, writes = 0; function Base() { return new Proxy({ count: 1 }, { get(target, key, receiver) { if (key === "count") reads += 1; return Reflect.get(target, key, receiver); }, set(target, key, value, receiver) { if (key === "count") writes += 1; return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); if (selected) { this.count++; this.count += 2; } else { this.count++; } } } var first = new Child(); selected = false; var second = new Child(); var firstValue = first.count, secondValue = second.count; console.log(firstValue, secondValue, reads, writes);',
        graph: 'retained',
        output: '4 2 5 3\n',
      },
      {
        name: 'post-super branch receiver calls preserve Proxy receiver and getter count',
        source:
          'var selected = true, reads = 0, calls = [], receiverOk = []; function Base() { return new Proxy({}, { get(target, key, receiver) { if (key === "record") { reads += 1; return function(label) { calls.push(label); receiverOk.push(this === receiver); }; } return Reflect.get(target, key, receiver); } }); } class Child extends Base { constructor() { super(); if (selected) { this.record("left"); this.value = 1; } else { this.record("right"); this.value = 2; } } } var first = new Child(); selected = false; var second = new Child(); console.log(first.value, second.value, reads, calls.join(","), receiverOk.join(","), first instanceof Child, second instanceof Child);',
        graph: 'retained',
        output: '1 2 2 left,right true,true false false\n',
      },
      {
        name: 'post-super simple else-if chain retains the graph',
        source:
          'var first = false, second = true; function Base() {} class Child extends Base { constructor() { super(); if (first) this.value = 1; else if (second) this.value = 2; else this.value = 3; } } console.log(new Child().value);',
        graph: 'retained',
        output: '2\n',
      },
      {
        name: 'post-super else-if chain preserves exact locals and Proxy getter/write order',
        source:
          'var mode = 1, reads = 0, writes = [], _this = 70; function Base() { return new Proxy({ mode: mode }, { get(target, key, receiver) { if (key === "mode") reads += 1; return Reflect.get(target, key, receiver); }, set(target, key, value, receiver) { if (key === "kind") writes.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var _this = 1; if (this.mode === 1) { _this++; this.kind = _this; } else if (this.mode === 2) { _this += 3; this.kind = _this; } else if (this.mode === 3) { _this += 5; this.kind = _this; } else { _this += 7; this.kind = _this; } } } var first = new Child(); mode = 2; var second = new Child(); mode = 3; var third = new Child(); mode = 4; var fourth = new Child(); console.log(first.kind, second.kind, third.kind, fourth.kind, _this, reads, writes.length, writes.join(","), first instanceof Child);',
        graph: 'retained',
        output: '2 4 6 8 70 9 4 kind:2,kind:4,kind:6,kind:8 false\n',
      },
      {
        name: 'post-super switch preserves Proxy reads, exact locals, calls, and fallthrough order',
        source:
          'var mode = 1, events = [], _this = 70; function Base() { return new Proxy({}, { set(target, key, value, receiver) { if (key === "kind") events.push("set:" + key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } function record(value) { events.push("call:" + value); } class Child extends Base { constructor() { super(); var _this = 10; switch (mode) { case 1: record("one"); _this++; break; case 2: record("two"); _this += 3; case 3: _this++; break; default: record("other"); _this = 4; } this.kind = _this; } } var first = new Child(); mode = 2; var second = new Child(); mode = 3; var third = new Child(); mode = 4; var fourth = new Child(); console.log(first.kind, second.kind, third.kind, fourth.kind, _this, events.join("|"), first instanceof Child);',
        graph: 'retained',
        output:
          '11 14 11 4 70 call:one|set:kind:11|call:two|set:kind:14|set:kind:11|call:other|set:kind:4 false\n',
      },
      {
        name: 'post-super switch this-property discriminant stays on reanalysis',
        source:
          'function Base() { this.mode = 1; } class Child extends Base { constructor() { super(); switch (this.mode) { case 1: this.value = 1; break; default: this.value = 2; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super switch this-property case test stays on reanalysis',
        source:
          'function Base() { this.first = 1; } class Child extends Base { constructor() { super(); switch (1) { case this.first: this.value = 1; break; default: this.value = 2; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super switch this-property case body stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); switch (1) { case 1: this.value = 1; break; default: this.value = 2; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super switch with call discriminant stays on reanalysis',
        source:
          'var calls = 0; function readMode() { calls += 1; return 1; } function Base() {} class Child extends Base { constructor() { super(); switch (readMode()) { case 1: this.value = 1; break; default: this.value = 2; } } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '1 1\n',
      },
      {
        name: 'post-super switch with call case test stays on reanalysis',
        source:
          'var calls = 0; function readCase() { calls += 1; return 1; } function Base() {} class Child extends Base { constructor() { super(); switch (1) { case readCase(): this.value = 1; break; default: this.value = 2; } } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '1 1\n',
      },
      {
        name: 'post-super switch with lexical case binding stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); switch (1) { case 1: let value = 3; this.value = value; break; default: this.value = 0; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '3 true\n',
      },
      {
        name: 'post-super switch var call initializer stays on reanalysis',
        source:
          'var calls = 0; function readValue() { calls += 1; return 3; } function Base() {} class Child extends Base { constructor() { super(); switch (1) { case 1: var value = readValue(); this.value = value; break; default: this.value = 0; } } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '3 1\n',
      },
      {
        name: 'post-super try catch finally preserves catch identity and write order',
        source:
          'var sentinel = { value: 7 }, writes = [], baseCalls = 0; function Base() { baseCalls += 1; return new Proxy({}, { set(target, key, value, receiver) { writes.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var caught, finalized = false; try { throw sentinel; } catch (error) { caught = error; } finally { finalized = true; } this.same = caught === sentinel; this.finalized = finalized; } } var child = new Child(); console.log(child.same, child.finalized, baseCalls, writes.join(","), child instanceof Child);',
        graph: 'retained',
        output: 'true true 1 same:true,finalized:true false\n',
      },
      {
        name: 'post-super try this access in catch stays on reanalysis',
        source:
          'var sentinel = {}; function Base() {} class Child extends Base { constructor() { super(); try { throw sentinel; } catch (error) { this.value = error; } } } var child = new Child(); console.log(child.value === sentinel, child instanceof Child);',
        graph: 'reanalyzed',
        output: 'true true\n',
      },
      {
        name: 'post-super try call initializer stays on reanalysis',
        source:
          'var calls = 0; function readValue() { calls += 1; return 3; } function Base() {} class Child extends Base { constructor() { super(); var value; try { value = readValue(); } catch (error) { value = 0; } this.value = value; } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '3 1\n',
      },
      {
        name: 'post-super while preserves local identity, continue, and Proxy write order',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var _this = 10, i = 0; while (i < 3) { if (i === 1) { i++; continue; } this.value = i; i++; } this.total = i; } } var child = new Child(); console.log(child.value, child.total, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '2 3 90 value:0|value:2|total:3 false\n',
      },
      {
        name: 'post-super do while preserves first-iteration and Proxy write order',
        source:
          'var events = []; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var i = 0; do { this.value = i; i++; } while (i < 2); } } var child = new Child(); console.log(child.value, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '1 value:0|value:1 false\n',
      },
      {
        name: 'post-super classic for preserves continue and local binding identities',
        source:
          'var events = []; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var total = 0; for (var i = 0; i < 3; i++) { if (i === 1) continue; total += i; this.total = total; } } } var child = new Child(); console.log(child.total, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '2 total:0|total:2 false\n',
      },
      {
        name: 'post-super lexical for retains per-loop binding with this writes',
        source:
          'var events = []; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); for (let i = 0; i < 2; i++) { this.value = i; } } } var child = new Child(); console.log(child.value, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '1 value:0|value:1 false\n',
      },
      {
        name: 'post-super for of preserves iterator calls, temp collisions, and write order',
        source:
          'var iteratorReads = 0, nextCalls = 0, events = [], _iterator = 70, _step = 80; var values = { [Symbol.iterator]() { iteratorReads++; var i = 0; return { next() { nextCalls++; return i < 2 ? { value: ++i, done: false } : { done: true }; } }; } }; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var _iterator = 1, _step = 2, sum = 0; for (var value of values) { sum += value; this.total = sum; } } } var child = new Child(); console.log(child.total, iteratorReads, nextCalls, _iterator, _step, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '3 1 3 70 80 total:1|total:3 false\n',
      },
      {
        name: 'post-super for in preserves enumerated key order and writes',
        source:
          'var events = [], values = { a: 2, b: 3 }; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var count = 0; for (var key in values) { count++; this.last = key; } this.count = count; } } var child = new Child(); console.log(child.last, child.count, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: 'b 2 last:a|last:b|count:2 false\n',
      },
      {
        name: 'post-super lexical for in retains key binding and write order',
        source:
          'var events = [], values = { a: 2, b: 3 }; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var count = 0; for (let key in values) { count++; key += "!"; this.last = key; } this.count = count; } } var child = new Child(); console.log(child.last, child.count, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: 'b! 2 last:a!|last:b!|count:2 false\n',
      },
      {
        name: 'post-super lexical for of preserves let head writes',
        source:
          'var events = [], values = [1, 2]; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); for (let value of values) { value++; this.last = value; } } } var child = new Child(); console.log(child.last, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '3 last:2|last:3 false\n',
      },
      {
        name: 'post-super lexical for of closes its iterator on break',
        source:
          'var events = [], nextCalls = 0, closes = 0, _iterator = 70, _step = 80; var values = { [Symbol.iterator]() { return { next() { nextCalls++; return { value: 4, done: false }; }, return() { closes++; events.push("iterator:return"); return {}; } }; } }; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var _iterator = 1, _step = 2; for (const value of values) { this.value = value; break; } } } var child = new Child(); console.log(child.value, nextCalls, closes, _iterator, _step, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '4 1 1 70 80 value:4|iterator:return false\n',
      },
      {
        name: 'post-super while this condition stays on reanalysis',
        source:
          'function Base() { this.count = 0; } class Child extends Base { constructor() { super(); while (this.count < 2) { this.count++; } } } var child = new Child(); console.log(child.count, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super for of call iterable stays on reanalysis',
        source:
          'var calls = 0; function values() { calls++; return [1, 2]; } function Base() {} class Child extends Base { constructor() { super(); var sum = 0; for (var value of values()) sum += value; this.total = sum; } } console.log(new Child().total, calls);',
        graph: 'reanalyzed',
        output: '3 1\n',
      },
      {
        name: 'post-super loop nested switch with this stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); var i = 0; while (i < 1) { switch (i) { case 0: this.value = 1; break; } i++; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super nested while and lexical for preserve Proxy writes and identities',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var i = 0; while (i < 2) { for (let j = 0; j < 2; j++) { this.value = i * 10 + j; } i++; } } } var child = new Child(); console.log(child.value, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '11 90 value:0|value:1|value:10|value:11 false\n',
      },
      {
        name: 'post-super nested for of closes inner iterator on labeled continue',
        source:
          'var events = [], outerNext = 0, innerNext = 0, innerReturns = 0, _iterator = 70, _step = 80; var outerValues = { [Symbol.iterator]() { var i = 0; return { next() { outerNext++; return i < 2 ? { value: ++i, done: false } : { done: true }; } }; } }; var innerValues = { [Symbol.iterator]() { var i = 0; return { next() { innerNext++; return i < 1 ? { value: ++i, done: false } : { done: true }; }, return() { innerReturns++; events.push("inner:return"); return {}; } }; } }; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var outerIndex = 0, _iterator = 1, _step = 2; while (outerIndex < 2) { outer: for (var x of outerValues) { for (var y of innerValues) { this.pair = x + ":" + y; continue outer; } } outerIndex++; } this.iterations = outerNext; } } var child = new Child(); console.log(child.pair, child.iterations, innerNext, innerReturns, _iterator, _step, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output:
          '2:1 6 4 4 70 80 pair:1:1|inner:return|pair:2:1|inner:return|pair:1:1|inner:return|pair:2:1|inner:return|iterations:6 false\n',
      },
      {
        name: 'post-super top-level block preserves var identity and Proxy write order',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); { var _this = 10, local = 2; this.value = local; local++; } this.after = local; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '2 3 90 value:2|after:3 false\n',
      },
      {
        name: 'post-super top-level label preserves nested continue and labeled break',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var i = 0, j = 0; outer: while (i < 3) { i++; inner: for (j = 0; j < 3; j++) { if (i === 1 && j === 0) continue inner; this.value = i * 10 + j; if (i === 2 && j === 1) break outer; } } this.after = i + ":" + j; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '21 2:1 90 value:11|value:12|value:20|value:21|after:2:1 false\n',
      },
      {
        name: 'post-super top-level empty and debugger statements retain the graph',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); ; debugger; this.value = 1; } } console.log(new Child().value);',
        graph: 'retained',
        output: '1\n',
      },
      {
        name: 'post-super top-level block with a lexical binding stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); { let local = 2; this.value = local; } } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'post-super top-level block with a nested switch this access stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); { switch (1) { case 1: this.value = 2; break; } } } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'post-super top-level block with a nested try this access stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); { try { throw 2; } catch (error) { this.value = error; } } } } console.log(new Child().value);',
        graph: 'reanalyzed',
        output: '2\n',
      },
      {
        name: 'post-super top-level label with a this loop condition stays on reanalysis',
        source:
          'function Base() { this.keepGoing = false; } class Child extends Base { constructor() { super(); outer: while (this.keepGoing) { this.value++; } } } var child = new Child(); console.log(child.keepGoing, child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: 'false undefined true\n',
      },
      {
        name: 'post-super conditional branch nested block preserves var identity and Proxy write order',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); if (true) { { var _this = 10, local = 2; this.value = local; local++; } } this.after = local; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '2 3 90 value:2|after:3 false\n',
      },
      {
        name: 'post-super conditional branch label preserves continue and break',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var i = 0; if (true) { outer: while (i < 3) { i++; if (i === 1) continue outer; this.value = i; break outer; } } this.after = i; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '2 2 90 value:2|after:2 false\n',
      },
      {
        name: 'post-super conditional branch nested if preserves Proxy getter and write order',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({ ready: true }, { get(target, key, receiver) { if (key === "ready") events.push("get:ready"); return Reflect.get(target, key, receiver); }, set(target, key, value, receiver) { events.push("set:" + key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); if (true) { if (this.ready) { this.value = 1; } else { this.value = 2; } } this.after = 3; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '1 3 90 get:ready|set:value:1|set:after:3 false\n',
      },
      {
        name: 'post-super conditional branch nested else-if preserves reads and local identity',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({ ready: false, selected: true }, { get(target, key, receiver) { if (key === "ready" || key === "selected") events.push("get:" + key); return Reflect.get(target, key, receiver); }, set(target, key, value, receiver) { events.push("set:" + key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var result = 0; if (true) { if (this.ready) { result = 1; this.value = result; } else if (this.selected) { result = 2; this.value = result; } else { result = 3; this.value = result; } } this.after = result; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '2 2 90 get:ready|get:selected|set:value:2|set:after:2 false\n',
      },
      {
        name: 'post-super conditional branch nested if call condition stays on reanalysis',
        source:
          'var calls = 0; function choose() { calls++; return true; } function Base() {} class Child extends Base { constructor() { super(); if (true) { if (choose()) this.value = 1; else this.value = 2; } } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 1 true\n',
      },
      {
        name: 'post-super conditional branch while preserves continue and Proxy write order',
        source:
          'var events = [], _this = 90; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var i = 0; if (true) { while (i < 3) { i++; if (i === 2) continue; this.value = i; } } this.after = i; } } var child = new Child(); console.log(child.value, child.after, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '3 3 90 value:1|value:3|after:3 false\n',
      },
      {
        name: 'post-super conditional branch lexical for of closes iterator and preserves temp identity',
        source:
          'var events = [], iteratorReads = 0, nextCalls = 0, closes = 0, _iterator = 70, _step = 80; var values = { [Symbol.iterator]() { iteratorReads++; return { next() { nextCalls++; return { value: 4, done: false }; }, return() { closes++; events.push("iterator:return"); return {}; } }; } }; function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var _iterator = 1, _step = 2; if (true) { for (const value of values) { this.value = value; break; } } this.after = iteratorReads; } } var child = new Child(); console.log(child.value, iteratorReads, nextCalls, closes, _iterator, _step, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '4 1 1 1 70 80 value:4|iterator:return|after:1 false\n',
      },
      {
        name: 'post-super conditional branch switch preserves fallthrough and local identity',
        source:
          'var events = [], _this = 90; function record(value) { events.push(value); } function Base() { return new Proxy({}, { set(target, key, value, receiver) { events.push("set:" + key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var result = 0, selector = 1; if (true) { switch (selector) { case 1: result = 2; record("case1:" + result); case 2: result++; record("case2:" + result); break; default: record("default"); } } this.value = result; } } var child = new Child(); console.log(child.value, _this, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '3 90 case1:2|case2:3|set:value:3 false\n',
      },
      {
        name: 'post-super conditional branch switch this access stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { switch (1) { case 1: this.value = 2; break; } } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super conditional branch switch call discriminant stays on reanalysis',
        source:
          'var calls = 0; function select() { calls++; return 1; } function Base() {} class Child extends Base { constructor() { super(); var result = 0; if (true) { switch (select()) { case 1: result = 3; break; default: result = 0; } } this.value = result; } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '3 1 true\n',
      },
      {
        name: 'post-super conditional branch switch call case test stays on reanalysis',
        source:
          'var calls = 0; function select() { calls++; return 1; } function Base() {} class Child extends Base { constructor() { super(); var result = 0; if (true) { switch (0) { case select(): result = 3; break; default: result = 0; } } this.value = result; } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '0 1 true\n',
      },
      {
        name: 'post-super conditional branch switch lexical case binding stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); var result = 0; if (true) { switch (1) { case 1: let local = 2; result = local; break; default: result = 0; } } this.value = result; } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super switch case function declaration retains exact switch scope identity',
        source:
          'var choose = true, result = 0; function Base() {} class Child extends Base { constructor() { super(); if (choose) { switch (1) { case 1: read(); break; case 2: function read() { result = 1; } } } else { switch (1) { case 1: read(); break; case 2: function read() { result = 2; } } } this.value = result; } } var first = new Child(); choose = false; var second = new Child(); console.log(first.value, second.value, first instanceof Child, second instanceof Child);',
        graph: 'retained',
        output: '1 2 true true\n',
      },
      {
        name: 'post-super switch case function declaration with direct eval stays on reanalysis',
        source:
          'var result = 0; function Base() {} class Child extends Base { constructor() { super(); if (true) { switch (1) { case 1: read(); function read() { result = eval("2"); } break; } } this.value = result; } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super switch case async function declaration stays on reanalysis',
        source:
          'var result = 0; function Base() {} class Child extends Base { constructor() { super(); if (true) { switch (1) { case 1: read(); break; case 2: async function read() { result = 2; } } } this.value = result; } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super switch case generator declaration stays on reanalysis',
        source:
          'var result = 0; function Base() {} class Child extends Base { constructor() { super(); if (true) { switch (1) { case 1: read(); break; case 2: function* read() { result = 2; } } } this.value = result; } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '0 true\n',
      },
      {
        name: 'post-super conditional branch try preserves catch identity and finally write order',
        source:
          'var events = [], sentinel = {}, baseCalls = 0; function Base() { baseCalls++; return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); var caught, finalized = false; if (true) { try { throw sentinel; } catch (error) { caught = error; } finally { finalized = true; } } this.same = caught === sentinel; this.finalized = finalized; } } var child = new Child(); console.log(child.same, child.finalized, baseCalls, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: 'true true 1 same:true|finalized:true false\n',
      },
      {
        name: 'post-super conditional branch try this access stays on reanalysis',
        source:
          'var sentinel = {}; function Base() {} class Child extends Base { constructor() { super(); if (true) { try { throw sentinel; } catch (error) { this.value = error; } } } } var child = new Child(); console.log(child.value === sentinel, child instanceof Child);',
        graph: 'reanalyzed',
        output: 'true true\n',
      },
      {
        name: 'post-super conditional branch try call initializer stays on reanalysis',
        source:
          'var calls = 0; function readValue() { calls++; return 3; } function Base() {} class Child extends Base { constructor() { super(); var value; if (true) { try { value = readValue(); } catch (error) { value = 0; } } this.value = value; } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '3 1 true\n',
      },
      {
        name: 'post-super conditional branch empty and debugger statements retain the graph',
        source:
          'var events = [], baseCalls = 0; function Base() { baseCalls++; return new Proxy({}, { set(target, key, value, receiver) { events.push(key + ":" + value); return Reflect.set(target, key, value, receiver); } }); } class Child extends Base { constructor() { super(); if (true) { ; debugger; this.value = 1; } else { ; debugger; this.value = 2; } } } var child = new Child(); console.log(child.value, baseCalls, events.join("|"), child instanceof Child);',
        graph: 'retained',
        output: '1 1 value:1 false\n',
      },
      {
        name: 'post-super conditional branch no-ops do not admit call initializers',
        source:
          'function value() { return 2; } function Base() {} class Child extends Base { constructor() { super(); if (true) { ; debugger; this.value = value(); } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super conditional branch function declaration retains exact block scope identity',
        source:
          'var choose = true; var result = 0; function Base() {} class Child extends Base { constructor() { super(); if (choose) { read(); function read() { result = 1; } } else { read(); function read() { result = 2; } } this.value = result; } } var first = new Child(); choose = false; var second = new Child(); console.log(first.value, second.value, first instanceof Child, second instanceof Child);',
        graph: 'retained',
        output: '1 2 true true\n',
      },
      {
        name: 'post-super direct function declaration stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); function read() { return 2; } this.value = read(); } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super branch function declaration with direct eval stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { function read() { return eval("2"); } this.value = read(); } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super conditional branch while this condition stays on reanalysis',
        source:
          'function Base() { this.keepGoing = false; } class Child extends Base { constructor() { super(); if (true) { while (this.keepGoing) this.value++; } } } var child = new Child(); console.log(child.keepGoing, child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: 'false undefined true\n',
      },
      {
        name: 'post-super conditional branch for of call iterable stays on reanalysis',
        source:
          'var calls = 0; function values() { calls++; return [1, 2]; } function Base() {} class Child extends Base { constructor() { super(); if (true) { for (var value of values()) this.value = value; } } } var child = new Child(); console.log(child.value, calls, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 1 true\n',
      },
      {
        name: 'post-super conditional branch loop nested switch this stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { for (var i = 0; i < 1; i++) { switch (i) { case 0: this.value = 1; break; } } } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super conditional branch lexical for of closure capture stays on reanalysis',
        source:
          'var values = [1, 2], readers = []; function Base() {} class Child extends Base { constructor() { super(); if (true) { for (let value of values) readers.push(function() { return value; }); } this.total = readers[0]() + readers[1](); } } var child = new Child(); console.log(child.total, child instanceof Child);',
        graph: 'reanalyzed',
        output: '3 true\n',
      },
      {
        name: 'post-super conditional branch nested computed this condition stays on reanalysis',
        source:
          'var key = "ready"; function Base() { this.ready = true; } class Child extends Base { constructor() { super(); if (true) { if (this[key]) this.value = 1; else this.value = 2; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super conditional branch nested lexical block stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { { let local = 2; this.value = local; } } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super conditional branch nested switch this access stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { { switch (1) { case 1: this.value = 2; break; } } } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super conditional branch nested try this access stays on reanalysis',
        source:
          'function Base() {} class Child extends Base { constructor() { super(); if (true) { { try { throw 2; } catch (error) { this.value = error; } } } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '2 true\n',
      },
      {
        name: 'post-super conditional branch label with a this condition stays on reanalysis',
        source:
          'function Base() { this.keepGoing = false; } class Child extends Base { constructor() { super(); if (true) { outer: while (this.keepGoing) { this.value++; } } } } var child = new Child(); console.log(child.keepGoing, child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: 'false undefined true\n',
      },
      {
        name: 'post-super conditional branch nested return stays on reanalysis',
        source:
          'var resultObject = {}; function Base() {} class Child extends Base { constructor() { super(); if (true) { { return resultObject; this.value = 1; } } } } var child = new Child(); console.log(child === resultObject, child.value);',
        graph: 'reanalyzed',
        output: 'true undefined\n',
      },
      {
        name: 'post-super conditional branch nested throw stays on reanalysis',
        source:
          'var sentinel = {}; function Base() {} class Child extends Base { constructor() { super(); if (true) { { throw sentinel; this.value = 1; } } } } try { new Child(); } catch (error) { console.log(error === sentinel); }',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'post-super nested loop with this condition stays on reanalysis',
        source:
          'function Base() { this.keepGoing = false; } class Child extends Base { constructor() { super(); var i = 0; while (i < 1) { while (this.keepGoing) {} i++; this.value = i; } } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super lexical for of with closure capture stays on reanalysis',
        source:
          'var values = [1, 2], readers = []; function Base() {} class Child extends Base { constructor() { super(); for (let value of values) readers.push(function() { return value; }); this.total = readers[0]() + readers[1](); } } var child = new Child(); console.log(child.total, child instanceof Child);',
        graph: 'reanalyzed',
        output: '3 true\n',
      },
      {
        name: 'post-super destructuring for of head stays on reanalysis',
        source:
          'var values = [{ value: 1 }, { value: 2 }]; function Base() {} class Child extends Base { constructor() { super(); var total = 0; for (let { value } of values) total += value; this.total = total; } } var child = new Child(); console.log(child.total, child instanceof Child);',
        graph: 'reanalyzed',
        output: '3 true\n',
      },
      {
        name: 'post-super destructuring for in head stays on reanalysis',
        source:
          'var values = { a: 1 }; function Base() {} class Child extends Base { constructor() { super(); for (let { length } in values) this.value = length; } } var child = new Child(); console.log(child.value, child instanceof Child);',
        graph: 'reanalyzed',
        output: '1 true\n',
      },
      {
        name: 'post-super else-if call condition stays on reanalysis',
        source:
          'var calls = 0; function selected() { calls += 1; return true; } function Base() {} class Child extends Base { constructor() { super(); if (false) this.value = 1; else if (selected()) this.value = 2; else this.value = 3; } } console.log(new Child().value, calls);',
        graph: 'reanalyzed',
        output: '2 1\n',
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
  }, 120_000);

  test('native strict block function declarations keep exact scope identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-strict-block-function-'));
    const entry = join(dir, 'entry.mjs');
    const output = join(dir, 'out.cjs');
    writeFileSync(
      entry,
      'function outer() { if (true) { function local() { return 2; } return local(); } return 0; } console.log(outer());',
    );
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
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' }, encoding: 'utf8' },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const lines = (proc.stderr ?? '').replaceAll('\0', '\n').split(/\r?\n/);
      const report = lines.find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
      );
      expect(report, proc.stderr).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(
          Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
          `${counter}: ${report}`,
        ).toBe(0);
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      const graphMode = lines.find((line) => line.includes('symbol-identity-prepass-mode '));
      expect(graphMode).toContain('semantic_graph=retained');
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('2\n');

      // Syntax minification edits the AST, so the same source must take the
      // explicit reanalysis path even though identifier-only minification can
      // retain its unchanged graph.
      const syntaxOutput = join(dir, 'out-syntax.cjs');
      const syntaxProc = spawnSync(
        ZNTC_BIN,
        [
          '--bundle',
          entry,
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          '--minify-identifiers',
          '--minify-syntax',
          '-o',
          syntaxOutput,
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' }, encoding: 'utf8' },
      );
      expect(syntaxProc.status, syntaxProc.stderr).toBe(0);
      const syntaxLines = (syntaxProc.stderr ?? '').replaceAll('\0', '\n').split(/\r?\n/);
      const syntaxReport = syntaxLines.find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.mjs'),
      );
      expect(syntaxReport, syntaxProc.stderr).toBeDefined();
      expect(exactSchemaProblems(syntaxReport ?? ''), syntaxReport).toEqual([]);
      const syntaxMode = syntaxLines.find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.mjs'),
      );
      expect(syntaxMode, syntaxProc.stderr).toContain('semantic_graph=reanalyzed');
      const syntaxActual = spawnSync('node', [syntaxOutput], { encoding: 'utf8' });
      expect(syntaxActual.status, syntaxActual.stderr).toBe(0);
      expect(syntaxActual.stdout).toBe('2\n');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

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
