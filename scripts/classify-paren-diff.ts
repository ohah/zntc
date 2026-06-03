/**
 * classify-paren-diff — #4042 precedence 전환 스냅샷 변화 분류기.
 *
 * codegen 의 paren-node→precedence 전환은 byte 를 의도적으로 바꾼다(군더더기 괄호
 * 제거 + load-bearing 재유도). 회귀 기준은 byte 가 아니라 **semantic equivalence**
 * 이므로, 스냅샷 변화를 무지성 `--update` 하기 전에 각 변화가 EQUIVALENT(군더더기
 * 괄호 차이) 인지 SUSPECT(load-bearing 유실 의심) 인지 기계 분류한다.
 *
 * 방법: 각 bun `.snap` 파일을 git HEAD(old) 와 working tree(new) 로 파싱해 key 별
 * 값을 비교하고, 바뀐 값마다 esbuild 정규화(paren-equiv) 로 astEquivalent 를 잰다.
 * SUSPECT(비동등) 가 0 이어야 스냅샷 갱신이 안전하다.
 *
 * 사용: `bun scripts/classify-paren-diff.ts [snapshot_glob_dir]`
 *   기본 dir = tests/integration/tests/tsc/__snapshots__
 */
import { execSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { normalize as esbuildNormalize } from '../tests/benchmark/paren-equiv.ts';

/** esbuild 로 재파싱·재출력해 정규화. 실패(파싱 불가)면 null. */
function normalize(src: string): string | null {
  try {
    return esbuildNormalize(src);
  } catch {
    return null;
  }
}

type Verdict = 'EQUIVALENT' | 'SUSPECT' | 'UNPARSEABLE';
/** old/new 코드를 esbuild 정규화 비교. 둘 다 파싱 불가면 UNPARSEABLE(이미-transpiled 산출물에
 *  esbuild-js 가 못 다루는 구문 — 보통 paren 차이만, 수동 확인 버킷). 한쪽만 깨지면 SUSPECT. */
function classify(oldCode: string, newCode: string): Verdict {
  const no = normalize(oldCode);
  const nn = normalize(newCode);
  if (no === null && nn === null) return 'UNPARSEABLE';
  if (no === null || nn === null) return 'SUSPECT';
  return no === nn ? 'EQUIVALENT' : 'SUSPECT';
}

const REPO = execSync('git rev-parse --show-toplevel').toString().trim();
const snapDir = process.argv[2] ?? 'tests/integration/tests/tsc/__snapshots__';

/** bun snapshot 파일을 {key: value} 로 파싱. value 는 ``...`` 안의 raw 문자열. */
function parseSnap(content: string): Map<string, string> {
  const map = new Map<string, string>();
  // exports[`key`] = `value`;  — value 는 multiline, 백틱은 \` 로 escape.
  const re = /exports\[`((?:[^`\\]|\\.)*)`\] = `((?:[^`\\]|\\.)*)`;/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(content)) !== null) {
    map.set(m[1].replace(/\\`/g, '`'), m[2]);
  }
  return map;
}

/** snapshot 값(`\n"<code>"\n` 형태)에서 실제 코드 문자열을 추출. */
function extractCode(raw: string): string {
  let s = raw.replace(/^\n/, '').replace(/\n$/, '');
  // 문자열 스냅샷은 `"..."` 로 감싸짐 — 벗기고 escape 해제.
  if (s.startsWith('"') && s.endsWith('"')) {
    s = s.slice(1, -1);
  }
  return s
    .replace(/\\\$/g, '$') // bun 은 template 의 `${` 를 `\${` 로 escape
    .replace(/\\`/g, '`')
    .replace(/\\"/g, '"')
    .replace(/\\\\/g, '\\');
}

function gitShow(relPath: string): string | null {
  try {
    return execSync(`git show HEAD:${relPath}`, { cwd: REPO, maxBuffer: 64 * 1024 * 1024 }).toString();
  } catch {
    return null; // 신규 파일
  }
}

const changed = execSync(`git diff --name-only -- ${snapDir}`, { cwd: REPO })
  .toString().trim().split('\n').filter(Boolean);

let equivalent = 0;
let suspect = 0;
let unparseable = 0;
const suspects: { file: string; key: string; old: string; neu: string }[] = [];
const unparse: { file: string; key: string }[] = [];

for (const rel of changed) {
  const abs = join(REPO, rel);
  if (!existsSync(abs)) continue;
  const oldRaw = gitShow(rel);
  if (oldRaw === null) continue;
  const oldMap = parseSnap(oldRaw);
  const newMap = parseSnap(readFileSync(abs, 'utf8'));
  for (const [key, newVal] of newMap) {
    const oldVal = oldMap.get(key);
    if (oldVal === undefined || oldVal === newVal) continue;
    const oldCode = extractCode(oldVal);
    const newCode = extractCode(newVal);
    const v = classify(oldCode, newCode);
    if (v === 'EQUIVALENT') equivalent++;
    else if (v === 'UNPARSEABLE') {
      unparseable++;
      unparse.push({ file: rel.split('/').pop()!, key });
    } else {
      suspect++;
      suspects.push({ file: rel.split('/').pop()!, key, old: oldCode, neu: newCode });
    }
  }
}

console.log(`\n=== classify-paren-diff (#4042) ===`);
console.log(`changed snap files : ${changed.length}`);
console.log(`EQUIVALENT (군더더기 괄호 제거, 정상): ${equivalent}`);
console.log(`UNPARSEABLE (esbuild-js 미파싱 양쪽 동일, 수동확인): ${unparseable}`);
console.log(`SUSPECT    (load-bearing 유실 의심)   : ${suspect}`);

for (const u of unparse) console.log(`  · UNPARSEABLE [${u.file}] ${u.key}`);
for (const s of suspects) {
  console.log(`\n──── SUSPECT [${s.file}] ${s.key} ────`);
  console.log(`OLD:\n${s.old.slice(0, 600)}`);
  console.log(`NEW:\n${s.neu.slice(0, 600)}`);
}

process.exit(suspect === 0 ? 0 : 1);
