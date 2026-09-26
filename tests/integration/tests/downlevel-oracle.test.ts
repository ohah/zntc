// 다운레벨 런타임 오라클 (#4746).
//
// fixtures/downlevel-oracle 의 각 프로그램을 **네이티브 node 로 실행한 결과**를 정답으로 삼고,
// zntc 로 타겟별(es5·es2015·es2017·esnext·Hermes) × ±minify 로 번들한 결과와, 단일 파일
// fixture 는 **번들 없이 변환**(`zntc x.mjs`)한 결과까지 실행해 비교한다. 두 경로는 리네임
// 방식이 달라(번들=링커 리네이머, 변환=변환 전에 도는 mangler) 한쪽에서만 깨지는 결함이 있다.
// 문자열 테스트로는 못 잡는 "빌드는 되는데 값이 틀리는" 다운레벨 결함(스코프·반복별 바인딩·
// iterator close·super·using …)을 잡는 게 목적이다.
//
// - fixture 는 `*.mjs` 한 파일, 또는 `main.mjs` 가 있는 디렉토리(여러 모듈)다.
// - 칸 이름은 번들이 `<target>/<mode>`, 변환이 `transpile/<target>/<mode>` 다.
// - fixture 의 변수 이름은 2글자 이상으로 쓴다 — mangler 는 1글자 이름을 바꾸지 않아서,
//   1글자면 minify 칸이 리네임 결함(심볼 누락 #4760)을 보지 못한다.
// - 알려진 결함은 KNOWN_FAILURES 에 이슈 번호와 함께 칸 단위로 적는다. 실패 칸 집합이 목록과
//   **정확히** 같아야 통과한다 — 고쳐지면 목록에서 빼라는 뜻으로 실패한다.
// - 한계: 정답이 호스트 node(24+) 실행이라, 출력에 남은 **최신 문법**(es5 산출물의 `using` 등)은
//   node 가 그냥 실행해 버려 잡지 못한다.

import { describe, test, expect } from 'bun:test';
import { spawn } from 'bun';
import { mkdtempSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZNTC_BIN } from './helpers';

const FIXTURE_DIR = join(import.meta.dir, '../fixtures/downlevel-oracle');

const TARGETS: { name: string; args: string[] }[] = [
  { name: 'es5', args: ['--target=es5'] },
  { name: 'es2015', args: ['--target=es2015'] },
  { name: 'es2017', args: ['--target=es2017'] },
  { name: 'esnext', args: ['--target=esnext'] },
  { name: 'hermes', args: ['--platform=react-native'] },
];
const MODES: { name: string; args: string[] }[] = [
  { name: 'plain', args: [] },
  { name: 'minify', args: ['--minify'] },
];

/// fixture 이름 → 실패가 알려진 칸(`<target>/<mode>`). 각 줄에 이슈 번호.
const KNOWN_FAILURES: Record<string, string[]> = {
  // #4732 객체 spread 가 섞이면 메서드의 home object 를 잃는다 (esbuild·rolldown 도 동일)
  '4729-super-10': [
    'es2015/plain',
    'es2015/minify',
    'es2017/plain',
    'es2017/minify',
    'transpile/es2015/plain',
    'transpile/es2015/minify',
    'transpile/es2017/plain',
    'transpile/es2017/minify',
  ],
  // #4733 Hermes 에서 객체 리터럴 async generator 메서드
  '4729-super-24': ['hermes/plain', 'hermes/minify'],
  // #4733 Hermes 번들의 async generator 메서드. #4819 이전 main에서도 두 칸 실패 확인.
  '4819-generator-state-computed': ['hermes/plain', 'hermes/minify'],
  // #4735 클래스 계산된 키 안 super 가 바깥 home 대신 클래스 자신의 super 문맥으로 낮춰진다
  '4729-super-41': [
    'es5/plain',
    'es5/minify',
    'es2015/plain',
    'es2015/minify',
    'hermes/plain',
    'hermes/minify',
    'transpile/es5/plain',
    'transpile/es5/minify',
    'transpile/es2015/plain',
    'transpile/es2015/minify',
  ],
  // #4739 상수 접기가 const 의 TDZ 를 무시한다
  '4730-using-25': [
    'es5/plain',
    'es5/minify',
    'es2015/plain',
    'es2015/minify',
    'es2017/plain',
    'es2017/minify',
    'esnext/plain',
    'esnext/minify',
    'hermes/plain',
    'hermes/minify',
    'transpile/es5/plain',
    'transpile/es5/minify',
    'transpile/es2015/minify',
    'transpile/es2017/minify',
    'transpile/esnext/minify',
    'transpile/hermes/minify',
  ],
  // #4740 esnext 번들에서 의존 모듈 최상위 using 의 dispose 가 번들 끝으로 밀린다
  // #4749 __esm 래퍼(RN)가 블록 안 최상위 var 를 끌어올리지 않는다
  '4730-using-module': ['esnext/plain', 'esnext/minify', 'hermes/plain', 'hermes/minify'],
  // #4733 Hermes 에서 async generator 를 for-await 로 돌 때
  'forof-asyncgen-close-break': ['hermes/plain', 'hermes/minify'],
  'forof-in-forawait-yield-capture': ['hermes/plain', 'hermes/minify'],
  'forof-in-forawait-yield-capture-inner': ['hermes/plain', 'hermes/minify'],
  'forin-in-forawait-yield-capture': ['hermes/plain', 'hermes/minify'],
  'forawait-asyncgen-src': ['hermes/plain', 'hermes/minify'],
  'forawait-break-closes': ['hermes/plain', 'hermes/minify'],
  'forawait-return-closes': ['hermes/plain', 'hermes/minify'],
  'forawait-source-throws': ['hermes/plain', 'hermes/minify'],
  'forawait-throw-in-body': ['hermes/plain', 'hermes/minify'],
  'forawait-in-asyncgen': ['hermes/plain', 'hermes/minify'],
  'forawait-in-asyncgen-capture': ['hermes/plain', 'hermes/minify'],
  'forawait-asyncgen-labeled': ['hermes/plain', 'hermes/minify'],
  'forawait-close-awaited-order': ['hermes/plain', 'hermes/minify'],
  'forawait-asyncgen-nested-yieldstar': ['hermes/plain', 'hermes/minify'],
  'forawait-asyncgen-method-and-arrow': ['hermes/plain', 'hermes/minify'],
  'forawait-asyncgen-consumer-return': ['hermes/plain', 'hermes/minify'],
  'forawait-asyncgen-await-in-body-and-finally': ['hermes/plain', 'hermes/minify'],
  // #4756 async generator 기본값 검사가 바깥 래퍼·안쪽 함수에 같은 노드로 들어가 minify 이름이
  // 어긋난다 (+ Hermes #4733)
  'asyncgen-default-param': ['es5/minify', 'hermes/plain', 'hermes/minify', 'transpile/es5/minify'],
  // #4733 Hermes 에서 async generator 를 for-await 로 돌 때
  '4730-using-30': ['hermes/plain', 'hermes/minify'],
  // #4766 `_loop` 의 return 스캔이 메서드 경계를 무시해 모듈 최상위에 `return _ret.v` 를 낸다
  // (번들은 IIFE 로 감싸 가려진다)
  '4729-super-16': ['transpile/es5/plain', 'transpile/es5/minify'],
  '4743-capture-11': ['transpile/es5/plain', 'transpile/es5/minify'],
};

type Run = { stdout: string; exitCode: number };

async function run(cmd: string[], cwd?: string): Promise<Run & { stderr: string }> {
  const proc = spawn({ cmd, cwd, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
}

function listFixtures(): {
  name: string;
  entry: string;
  singleFile: boolean;
}[] {
  return readdirSync(FIXTURE_DIR)
    .sort()
    .flatMap((f) => {
      const p = join(FIXTURE_DIR, f);
      if (statSync(p).isDirectory())
        return [{ name: f, entry: join(p, 'main.mjs'), singleFile: false }];
      if (f.endsWith('.mjs')) return [{ name: f.slice(0, -4), entry: p, singleFile: true }];
      return [];
    });
}

const PATHS: { name: string; args: string[]; ext: string }[] = [
  { name: 'bundle', args: ['--bundle'], ext: 'js' },
  // 여러 모듈 fixture 는 의존 모듈이 변환되지 않은 채 import 되므로 단일 파일만 돈다.
  { name: 'transpile', args: [], ext: 'mjs' },
];

/// 네이티브 결과와 다른 칸 목록. 빌드 실패도 실패 칸이다.
async function failingCells(
  entry: string,
  singleFile: boolean,
  expected: Run,
  outDir: string,
): Promise<string[]> {
  const cells = PATHS.filter((p) => singleFile || p.name === 'bundle').flatMap((p) =>
    TARGETS.flatMap((t) => MODES.map((m) => ({ p, t, m }))),
  );
  const results = await Promise.all(
    cells.map(async ({ p, t, m }) => {
      const id = `${p.name === 'bundle' ? '' : `${p.name}/`}${t.name}/${m.name}`;
      const out = join(outDir, `${p.name}-${t.name}-${m.name}.${p.ext}`);
      const build = await run([ZNTC_BIN, ...p.args, entry, ...t.args, ...m.args, '-o', out]);
      if (build.exitCode !== 0) return id;
      const got = await run(['node', out]);
      return got.stdout === expected.stdout && got.exitCode === expected.exitCode ? null : id;
    }),
  );
  return results.filter((x): x is string => x !== null);
}

/// 정답이 되는 node 는 `using`·`SuppressedError` 를 알아야 한다(24+). 더 낮으면 건너뛴다.
const NODE_MAJOR = Number(
  Bun.spawnSync(['node', '-p', 'process.versions.node.split(".")[0]']).stdout.toString().trim(),
);

describe.skipIf(!(NODE_MAJOR >= 24))(
  '다운레벨 런타임 오라클: 네이티브 node 결과 = 번들 결과 (#4746)',
  () => {
    for (const { name, entry, singleFile } of listFixtures()) {
      test(name, async () => {
        const expected = await run(['node', entry]);
        const outDir = mkdtempSync(join(tmpdir(), 'zntc-oracle-'));
        try {
          const failing = await failingCells(entry, singleFile, expected, outDir);
          expect(failing).toEqual(KNOWN_FAILURES[name] ?? []);
        } finally {
          rmSync(outDir, { recursive: true, force: true });
        }
      });
    }

    test('KNOWN_FAILURES 의 fixture 이름이 모두 존재한다', () => {
      const names = new Set(listFixtures().map((f) => f.name));
      expect(Object.keys(KNOWN_FAILURES).filter((n) => !names.has(n))).toEqual([]);
    });
  },
);
