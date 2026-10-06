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
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import ts from 'typescript';
import { ZNTC_BIN } from './helpers';

const FIXTURE_DIR = join(import.meta.dir, '../fixtures/downlevel-oracle');
const TARGETS = [
  { name: 'es5', arg: '--target=es5' },
  { name: 'es2015', arg: '--target=es2015' },
  { name: 'es2017', arg: '--target=es2017' },
  { name: 'es2022', arg: '--target=es2022' },
  { name: 'esnext', arg: '--target=esnext' },
  { name: 'hermes', arg: '--platform=react-native' },
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
  'declaration_scope_mismatch',
  'scope_map_mismatch',
  'scope_owner_mismatch',
  'scope_owner_parent_mismatch',
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
const EXACT_OBSERVATION_FIELD_COUNT = 6;
const EXACT_DIAGNOSTIC_FIELD_COUNT = 11;

function exactSchemaProblems(identity: string): string[] {
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

function runCoverage(
  file: string,
  target: (typeof TARGETS)[number],
  outDir: string,
): { stderr: string; exitCode: number } {
  const stderrPath = join(outDir, 'stderr.log');
  const isFlow = file.endsWith('.flow.mjs') || file.endsWith('.flow');
  const proc = spawnSync(
    '/bin/sh',
    [
      '-c',
      isFlow ? 'exec "$1" "$2" "$3" "$4" "$5" "$6" 2>"$7"' : 'exec "$1" "$2" "$3" "$4" "$5" 2>"$6"',
      'zntc-symbol-coverage',
      ZNTC_BIN,
      file,
      target.arg,
      ...(isFlow ? ['--flow'] : []),
      '-o',
      join(outDir, 'out.js'),
      stderrPath,
    ],
    {
      env: {
        ...process.env,
        ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    },
  );
  return {
    stderr: readFileSync(stderrPath, 'utf8'),
    exitCode: proc.status ?? -1,
  };
}

describe('symbol identity coverage gate (#4819)', () => {
  const fixtures = collectFixtures(FIXTURE_DIR);

  test('report selection ignores marker text embedded in diagnostic paths', () => {
    const lines = [
      'zntc: symbol-source-scope-owner /tmp/symbol-coverage-worktree/input.mjs: scope_owner_parent_mismatch=0',
      'zntc: symbol-coverage /tmp/symbol-coverage-worktree/input.mjs: new_user_idents=0 missing=0 wrong=0',
      'zntc: symbol-identity /tmp/symbol-coverage-worktree/input.mjs: clean=1',
      'zntc: symbol-identity-detail /tmp/zntc: symbol-identity /tmp/input.mjs: clean=1',
      'zntc: synthetic-coverage-detail /tmp/zntc: synthetic-coverage /tmp/input.mjs: symbol_identity_complete=1',
      'zntc: symbol-source-scope-owner-detail /tmp/zntc: symbol-source-scope-owner /tmp/input.mjs: scope_owner_parent_mismatch=0',
    ];
    expect(lines.filter((line) => line.startsWith('zntc: symbol-coverage '))).toEqual([lines[1]]);
    expect(lines.filter((line) => line.startsWith('zntc: symbol-identity '))).toEqual([lines[2]]);
    expect(lines.filter((line) => line.startsWith('zntc: synthetic-coverage '))).toEqual([]);
    expect(lines.filter((line) => line.startsWith('zntc: symbol-source-scope-owner '))).toEqual([
      lines[0],
    ]);
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
    ]
      .concat(EXACT_ZERO_COUNTERS.map((counter) => counter + '=0'))
      .join(' ');
    expect(exactSchemaProblems(complete)).toEqual([]);
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
        complete.replace(/invariant_counter_count=\d+/, 'invariant_counter_count=23'),
      ),
    ).toContain(`invariant_counter_count=23, expected ${EXACT_ZERO_COUNTERS.length}`);
    expect(
      exactSchemaProblems(
        complete.replace(/observation_field_count=\d+/, 'observation_field_count=7'),
      ),
    ).toContain(`observation_field_count=7, expected ${EXACT_OBSERVATION_FIELD_COUNT}`);
    expect(
      exactSchemaProblems(
        complete.replace(/diagnostic_field_count=\d+/, 'diagnostic_field_count=12'),
      ),
    ).toContain(`diagnostic_field_count=12, expected ${EXACT_DIAGNOSTIC_FIELD_COUNT}`);
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
        expect(audit).toMatch(/scope_owner_parent_mismatch=0(?:\s|$)/);
      }

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
        /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
          /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
        );

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${target}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, target).toBe('1,2,3\n');
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
            /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
            /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
            /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
          /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
          /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
            /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
            /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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

  test('native for-of and for-in do not retain graphs when companion syntax needs lowering', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-for-of-resync-boundaries-'));
    const cases = [
      {
        name: 'optional-chain',
        target: '--target=es2015',
        graph: 'reanalyzed',
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
        'function Foo(_newTarget = 11, value = () => () => new.target) {',
        '  this.name = value.name;',
        '  this.target = value()();',
        '  this.parameter = _newTarget;',
        '}',
        'class Derived extends Foo {}',
        'class NativeBase { constructor(_newTarget = 13, value = () => () => new.target) { this.target = value()(); this.parameter = _newTarget; } }',
        'class NativeDerived extends NativeBase {}',
        'class ExplicitNativeDerived extends NativeBase { constructor(value = () => new.target) { super(); this.explicitTarget = value(); } }',
        'var plain = new Foo();',
        'var derived = Reflect.construct(Foo, [undefined, undefined], Derived);',
        'var nativeDerived = new NativeDerived();',
        'var explicitNativeDerived = new ExplicitNativeDerived();',
        'console.log(plain.target === Foo, derived.target === Derived, plain.parameter, plain.name, nativeDerived.target === NativeDerived, explicitNativeDerived.explicitTarget === ExplicitNativeDerived);',
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
      expect(actual.stdout).toBe('true true 11 value true true\n');
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

  test('ES5 downlevel forms with generated state keep arrow modules on semantic resync', () => {
    const cases = [
      {
        name: 'exponentiation',
        source: 'function square(value) { return (() => value ** 2)(); }\nconsole.log(square(6));',
        output: '36\n',
      },
      {
        name: 'nullish coalescing',
        source:
          'function choose(value) { return (() => value ?? 7)(); }\nconsole.log(choose(null));',
        output: '7\n',
      },
      {
        name: 'exponentiation assignment',
        source: [
          'function square(value) { var result = value; return (() => (result **= 2))(); }',
          'console.log(square(6));',
        ].join('\n'),
        output: '36\n',
      },
      {
        name: 'nullish assignment',
        source: [
          'function choose(value) { var result = value; return (() => (result ??= 7))(); }',
          'console.log(choose(null));',
        ].join('\n'),
        output: '7\n',
      },
      {
        name: 'logical AND assignment',
        source: [
          'function choose(value) { var result = value; return (() => (result &&= 7))(); }',
          'console.log(choose(0));',
        ].join('\n'),
        output: '0\n',
      },
      {
        name: 'logical OR assignment',
        source: [
          'function choose(value) { var result = value; return (() => (result ||= 7))(); }',
          'console.log(choose(0));',
        ].join('\n'),
        output: '7\n',
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
            expect(
              Number(report?.match(new RegExp(`${counter}=(\\d+)`))?.[1] ?? -1),
              `${fixture.name}: ${counter}: ${report}`,
            ).toBe(0);
          }
          expect(report, fixture.name).toMatch(/clean=1(?:\s|$)/);
        }
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout).toBe(fixture.output);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });

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
        '  const sent: Count = yield start;',
        '  return sent;',
        '}',
        'const iterator = numbers(41);',
        'const first = iterator.next();',
        'const second = iterator.next(42);',
        'console.log(first.value, first.done, second.value, second.done);',
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
      expect(nativeOutput.stdout).toBe('41 false 42 true\n');

      // Generator downlevel replaces the native source body and remains on
      // semantic reanalysis.
      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expect(graphMode(downlevel.stderr), downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('41 false 42 true\n');

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

      // ES5 lowering must retain the per-site template object identity while
      // using the existing semantic reanalysis path for generated helpers.
      const downlevel = run('--target=es5');
      expect(downlevel.status, downlevel.stderr).toBe(0);
      expect(graphMode(downlevel.stderr), downlevel.stderr).toContain('semantic_graph=reanalyzed');
      const downlevelOutput = spawnSync('node', [output], { encoding: 'utf8' });
      expect(downlevelOutput.status, downlevelOutput.stderr).toBe(0);
      expect(downlevelOutput.stdout).toBe('n=41!:false n=42!:true\n');
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

  test('array and call spread lowering retain only helper-free literal graphs', () => {
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
        name: 'constructor spread literal lowering on node4',
        target: 'node4',
        graph: 'reanalyzed',
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
        graph: 'reanalyzed',
        source: [
          'function list(values) { return (() => [...values, 3])(); }',
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
              /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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
              /missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
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

  test('오라클 전체에서 exact 구조 불변식과 심볼 부채가 모두 0', async () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-symcov-'));
    const problems: string[] = [];
    const exactCounts = new Map<string, number>();
    const exactExamples = new Map<string, string[]>();
    let generatedBindings = 0;
    let generatedReferences = 0;
    let strictExternalReferences = 0;
    let strictRawScopeMismatches = 0;
    let runs = 0;
    try {
      for (const file of fixtures) {
        const name = relative(FIXTURE_DIR, file);
        for (const target of TARGETS) {
          const { stderr, exitCode } = runCoverage(file, target, outDir);
          if (exitCode !== 0) {
            problems.push(`${name} ${target.name}: exit=${exitCode} ${stderr.trim()}`);
            continue;
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
          const sourceScopeOwnerLines = stderr
            .split('\n')
            .filter((line) => line.startsWith('zntc: symbol-source-scope-owner '));
          if (sourceScopeOwnerLines.length !== 1) {
            problems.push(
              `${name} ${target.name}: expected one source scope-owner audit, got ${sourceScopeOwnerLines.length}`,
            );
          } else if (
            !/(?:^| )scope_owner_parent_mismatch=0(?: |$)/.test(sourceScopeOwnerLines[0])
          ) {
            problems.push(
              `${name} ${target.name}: source scope-owner audit failed: ${sourceScopeOwnerLines[0]}`,
            );
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
          if (!generatedBindingsMatch || !generatedReferencesMatch) {
            problems.push(`${name} ${target.name}: missing generated-node totals: ${identity}`);
          } else {
            generatedBindings += Number(generatedBindingsMatch[1]);
            generatedReferences += Number(generatedReferencesMatch[1]);
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
        /symbol-identity-post-minify .* missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
      );
      expect(readFileSync(output, 'utf8')).toContain('function');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('ES5 empty, plain methods and compatible accessors retain their graph; other forms resync', () => {
    const cases = [
      {
        name: 'empty named class',
        source: 'class Empty {}\nconsole.log(new Empty() instanceof Empty);\n',
        graph: 'retained',
        output: 'true\n',
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
        name: 'constructor with a default parameter stays on reanalysis',
        source:
          'class Defaulted { constructor(value = 3) { this.value = value; } } console.log(new Defaulted().value);',
        graph: 'reanalyzed',
        output: '3\n',
      },
      {
        name: 'constructor with a simple literal assignment retains its graph',
        source:
          'class WithConstructorBody { constructor() { this.value = 7; } } console.log(new WithConstructorBody().value);',
        graph: 'retained',
        output: '7\n',
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
        name: 'constructor binary initializer stays on reanalysis',
        source:
          'var initialValue = 7; class BinaryInitializer { constructor() { this.value = initialValue + 1; } } console.log(new BinaryInitializer().value);',
        graph: 'reanalyzed',
        output: '8\n',
      },
      {
        name: 'constructor compound initializer stays on reanalysis',
        source:
          'class CompoundInitializer { constructor() { this.value += 2; } } console.log(new CompoundInitializer().value);',
        graph: 'reanalyzed',
        output: 'NaN\n',
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
        name: 'function local empty class',
        source:
          'function make() { class Local {} return new Local() instanceof Local; }\nconsole.log(make());\n',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'class with a base class',
        source:
          'function Base() {}\nclass Derived extends Base {}\nconsole.log(new Derived() instanceof Base);\n',
        graph: 'reanalyzed',
        output: 'true\n',
      },
      {
        name: 'anonymous class expression',
        source: 'const Holder = class {};\nconsole.log(new Holder() instanceof Holder);\n',
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
  });

  test('ES5와 ESNext minify 출력에서 전체 oracle의 살아 있는 심볼 연결이 정확하다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-post-minify-matrix-'));
    try {
      const minifyTargets = [TARGETS[0], TARGETS[4]];
      const minifyModes = [
        ['--minify-syntax'],
        ['--minify-identifiers'],
        ['--minify-syntax', '--minify-identifiers'],
      ];
      const problems: string[] = [];
      let runs = 0;
      for (const file of fixtures) {
        const isFlow = file.endsWith('.flow.mjs') || file.endsWith('.flow');
        for (const target of minifyTargets) {
          for (const mode of minifyModes) {
            const output = join(dir, `${runs}.js`);
            const proc = spawnSync(
              ZNTC_BIN,
              [file, target.arg, ...(isFlow ? ['--flow'] : []), ...mode, '-o', output],
              {
                env: {
                  ...process.env,
                  ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
                  PATH: process.env.PATH ?? '/usr/bin:/bin',
                },
                encoding: 'utf8',
              },
            );
            const stderr = proc.stderr ?? '';
            const audit = stderr
              .split('\n')
              .find((line) => line.startsWith('zntc: symbol-identity-post-minify '));
            if (proc.status !== 0 || !audit || !audit.includes('clean=1')) {
              problems.push(
                `${relative(FIXTURE_DIR, file)} [${target.name}; ${mode.join('+')}]: ${stderr}`,
              );
            }
            runs += 1;
          }
        }
      }
      expect(fixtures.length).toBeGreaterThan(0);
      expect(runs).toBe(fixtures.length * minifyTargets.length * minifyModes.length);
      expect(problems).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 600_000);
});
