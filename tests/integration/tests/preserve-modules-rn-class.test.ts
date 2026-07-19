import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

/**
 * #4574 — `--preserve-modules --platform=react-native` 에서 class export.
 *
 * RN 다운레벨은 class 를 `__classCallCheck`/`__extends` 헬퍼로 낮추고 그 헬퍼를 runtime helper
 * **virtual module** 에서 import 한다. 두 버그가 겹쳐 있었다:
 *  (1) transform 이 헬퍼를 `var __classCallCheck = function(){…}` 로 인라인한 흔적(이름만 남음)이
 *      hoisted var 로 수집돼 `import { __classCallCheck }` 와 이중 선언(SyntaxError).
 *  (2) 그 헬퍼 모듈 import 의 상대 경로가 `../../../../runtime-…` 로 잘못 계산(ERR_MODULE_NOT_FOUND).
 *      → helper-module import 로컬명을 hoisted var 에서 제외 + bare-id dep 을 root-level 로 상대 계산.
 *
 * RN(Metro)은 project root 를 주므로 `--preserve-modules-root` 로 빌드한다.
 */

async function buildRnPm(files: Record<string, string>, format: 'esm' | 'cjs', minify: boolean) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const res = await runZntc([
    '--bundle',
    join(dir, 'entry.js'),
    '--preserve-modules',
    `--preserve-modules-root=${dir}`,
    '--outdir',
    outDir,
    `--format=${format}`,
    '--platform=react-native',
    ...(minify ? ['--minify'] : []),
  ]);
  if (res.exitCode !== 0) {
    await cleanup();
    throw new Error(`빌드 실패:\n${res.stderr}`);
  }
  writeFileSync(
    join(outDir, 'package.json'),
    JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
  );
  return { outDir, cleanup };
}

const FORMATS = ['esm', 'cjs'] as const;
const MINIFY = [false, true] as const;

describe('#4574: preserve-modules × RN downlevel class', () => {
  for (const format of FORMATS) {
    for (const minify of MINIFY) {
      test(`class(named/default/extends) + 헬퍼 import [${format}${minify ? ' minify' : ''}]`, async () => {
        const { outDir, cleanup } = await buildRnPm(
          {
            'b.js':
              'export class Named { greet(){ return "N"; } }\n' +
              'export default class { greet(){ return "D"; } }\n' +
              'export function plain(){ return "P"; }',
            'ext.js':
              'class Base { b(){ return "B"; } }\n' +
              'export class Ext extends Base { greet(){ return "E-" + this.b(); } }',
            'a.cjs': 'module.exports = require("./b.js");\nrequire("./ext.js");', // ESM-wrap 강제
            'entry.js':
              'import D, { Named, plain } from "./b.js";\nimport { Ext } from "./ext.js";\nimport "./a.cjs";\n' +
              'console.log(new Named().greet() + new D().greet() + plain() + new Ext().greet());',
          },
          format,
          minify,
        );
        try {
          const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
          expect(stderr).not.toContain('SyntaxError'); // 수정 전(1): __classCallCheck 중복 선언
          expect(stderr).not.toContain('ERR_MODULE_NOT_FOUND'); // 수정 전(2): 헬퍼 경로
          expect(stdout.trim()).toBe('NDPE-B');
        } finally {
          await cleanup();
        }
      });
    }
  }
});

/**
 * [0] 스모크 — 헬퍼-이름 제외 필터는 `preserve_modules` 로 게이트돼 **non-preserve** 에선 no-op 다.
 * non-preserve 는 헬퍼를 virtual 모듈에서 import 하지 않고 **inline** 하므로(is_helper hoist 의
 * `var __extends; __extends = …` assign-only preamble, #1209) 필터가 그 var 를 건드리면 안 된다.
 * 게이트가 그걸 보장한다 — 본 테스트는 non-preserve ESM-wrap × RN downlevel 이 정상 실행됨을 고정한다.
 */
describe('#4574 [0]: non-preserve ESM-wrap 은 헬퍼 var 를 보존한다', () => {
  for (const minify of MINIFY) {
    test(`extends 헬퍼 var 보존 [esm${minify ? ' minify' : ''}]`, async () => {
      const { dir, cleanup } = await createFixture({
        'b.js':
          'class Base { b(){ return "B"; } }\n' +
          'export class Ext extends Base { greet(){ return "E-" + this.b(); } }',
        'a.cjs': 'module.exports = require("./b.js");', // b 를 ESM-wrap 강제
        'entry.js':
          'import { Ext } from "./b.js";\nimport "./a.cjs";\nconsole.log(new Ext().greet());',
      });
      const out = join(dir, 'out.mjs');
      try {
        const res = await runZntc([
          '--bundle',
          join(dir, 'entry.js'),
          '--format=esm',
          '--platform=react-native',
          ...(minify ? ['--minify'] : []),
          '-o',
          out,
        ]);
        expect(res.exitCode).toBe(0);
        const { stdout, stderr } = await runNode(out);
        expect(stderr).not.toContain('ReferenceError'); // 필터 과도 → 헬퍼 var 소멸
        expect(stderr).not.toContain('SyntaxError');
        expect(stdout.trim()).toBe('E-B');
      } finally {
        await cleanup();
      }
    });
  }
});

/**
 * [1] 회귀 가드 — 소스가 `--preserve-modules-root` **밖**이면 stem-only 로 outdir 최상위에 놓인다.
 * virtual helper 도 최상위이므로 helper import 는 `./runtime-…` 여야 한다(기존 `../../…` → ERR_MODULE_NOT_FOUND).
 * entry·widget 을 같은 out-of-root dir 에 두어 모듈 간 경로도 정상 실행되게 한다.
 */
describe('#4574 [1]: out-of-root 소스의 헬퍼 경로', () => {
  for (const format of FORMATS) {
    test(`out-of-root class 헬퍼 → ./runtime-… [${format}]`, async () => {
      const { dir, cleanup } = await createFixture({
        'app/widget.js': 'export class Widget { greet(){ return "W"; } }',
        'app/entry.js': 'import { Widget } from "./widget.js";\nconsole.log(new Widget().greet());',
        'root/.keep': '', // root 는 app 을 포함하지 않는 무관 dir
      });
      const outDir = join(dir, 'dist');
      try {
        const res = await runZntc([
          '--bundle',
          join(dir, 'app/entry.js'),
          '--preserve-modules',
          `--preserve-modules-root=${join(dir, 'root')}`,
          '--outdir',
          outDir,
          `--format=${format}`,
          '--platform=react-native',
        ]);
        expect(res.exitCode).toBe(0);
        const widget = await Bun.file(join(outDir, 'widget.js')).text();
        expect(widget).not.toMatch(/from ["']\.\.\//); // `../…/runtime-…` 이면 회귀
        writeFileSync(
          join(outDir, 'package.json'),
          JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
        );
        const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
        expect(stderr).not.toContain('ERR_MODULE_NOT_FOUND');
        expect(stdout.trim()).toBe('W');
      } finally {
        await cleanup();
      }
    });
  }
});
