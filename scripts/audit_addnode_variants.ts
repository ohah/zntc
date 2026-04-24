#!/usr/bin/env bun
/**
 * #1797 follow-up — static audit of `addNode` direct-construction sites.
 *
 * Two-pass analysis:
 *   1. Extract the Tag→DataKind table from src/parser/ast.zig::getLayout.
 *   2. Parse `DATA_READER_DIRS` switches with proper brace-tracking and follow
 *      each arm's body (or inline `data.X` access) to collect the variants
 *      each reader file reads per tag. Function-variant propagation spans all
 *      reader files (same-name functions union their variants conservatively)
 *      to catch cross-file indirections like `visitNode → visitImportEquals`.
 *
 * For every `.addNode(.{ .tag = X, ..., .data = .{ .Y = ... } })` call in src/:
 *   - If Y ≠ layout-expected kind AND a reader reads a *different* variant for
 *     that tag, flag as a **REAL** (#1797-class) silent failure.
 *   - Otherwise surface as cosmetic and continue.
 *
 * Exits non-zero when any REAL mismatch is found. Cosmetic mismatches are
 * reported but do not fail the audit (tracked separately in #1802).
 *
 * Why multi-file scan: codegen is not the only data consumer. Transformer /
 * semantic analyzer also read `node.data.binary.left` etc. — restricting the
 * read-set to codegen.zig was how #1802 B2 initially misclassified
 * `ts_import_equals_declaration` / `flow_match_expression` arm as cosmetic.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, "..");
const AST_FILE = join(ROOT, "src", "parser", "ast.zig");
/** Files that read `node.data.<variant>` and decide tag layout. Scanned for
 * switch arms and function bodies; results unioned into a single tag→variants
 * map. Order doesn't matter. */
const DATA_READER_DIRS = [
	join(ROOT, "src", "codegen"),
	join(ROOT, "src", "transformer"),
	join(ROOT, "src", "semantic"),
];

const DATA_VARIANT_RE = /\.data\s*=\s*\.\{\s*\.(\w+)\s*=/;
const TAG_RE = /\.tag\s*=\s*\.(\w+)\s*,/;
/** `.tag = someVar,` — variable-typed tag (needs backward lookup). */
const TAG_VAR_RE = /\.tag\s*=\s*([a-zA-Z_][a-zA-Z_0-9]*)\s*,/;
const ADDNODE_START_RE = /\.addNode\(\s*\.\{/g;
const DATA_ACCESS_RE = /\.data\.(\w+)\b/g;

const LEAF_VARIANTS = new Set(["none", "string_ref", "number_bytes"]);
const KINDS = new Set(["leaf", "unary", "binary", "ternary", "list", "extra"]);
const ALL_DATA_VARIANTS = new Set([...LEAF_VARIANTS, "unary", "binary", "ternary", "list", "extra"]);


function findMatchingBrace(text: string, openIdx: number): number {
	let depth = 0;
	for (let i = openIdx; i < text.length; i++) {
		const c = text[i];
		if (c === "{") depth++;
		else if (c === "}") {
			depth--;
			if (depth === 0) return i + 1;
		}
	}
	throw new Error(`unterminated brace at ${openIdx}`);
}

/** Replace string literals and line comments with spaces while preserving offsets. */
function stripStringsAndComments(text: string): string {
	const out = Array.from(text);
	let i = 0;
	const n = text.length;
	while (i < n) {
		const c = text[i];
		// Line comment
		if (c === "/" && text[i + 1] === "/") {
			const end = text.indexOf("\n", i);
			const stop = end < 0 ? n : end;
			for (let j = i; j < stop; j++) out[j] = " ";
			i = stop;
			continue;
		}
		// String literal
		if (c === '"') {
			out[i] = " ";
			let j = i + 1;
			while (j < n && text[j] !== '"') {
				if (text[j] === "\\" && j + 1 < n) {
					out[j] = " ";
					out[j + 1] = " ";
					j += 2;
					continue;
				}
				out[j] = " ";
				j++;
			}
			if (j < n) out[j] = " ";
			i = j + 1;
			continue;
		}
		// Zig multiline string (`\\` prefix)
		if (c === "\\" && text[i + 1] === "\\") {
			const end = text.indexOf("\n", i);
			const stop = end < 0 ? n : end;
			for (let j = i; j < stop; j++) out[j] = " ";
			i = stop;
			continue;
		}
		i++;
	}
	return out.join("");
}

function parseLayoutTable(text: string): Map<string, string> {
	const start = text.indexOf("fn getLayout(tag: Tag) Layout {");
	if (start < 0) {
		console.error("could not find getLayout in ast.zig");
		process.exit(2);
	}
	const openIdx = text.indexOf("{", start);
	const end = findMatchingBrace(text, openIdx);
	const block = text.slice(openIdx, end);

	const mapping = new Map<string, string>();
	let pos = 0;
	while (pos < block.length) {
		const arrow = block.indexOf("=>", pos);
		if (arrow < 0) break;

		const prevEnd = block.lastIndexOf("=>", arrow - 1);
		const prevBrace = block.lastIndexOf("{", arrow - 1);
		const armStart = Math.max(prevEnd >= 0 ? prevEnd + 2 : -1, prevBrace >= 0 ? prevBrace + 1 : -1);
		const segmentStart = armStart < 0 ? 0 : armStart;
		const segment = block.slice(segmentStart, arrow);
		const tagNames = Array.from(segment.matchAll(/\.([a-zA-Z_][a-zA-Z_0-9]*)/g), (m) => m[1]);

		const tail = block.slice(arrow + 2, arrow + 200);
		const m = /\.kind\s*=\s*\.(\w+)/.exec(tail);
		if (m && KINDS.has(m[1])) {
			const kind = m[1];
			for (const t of tagNames) {
				if (KINDS.has(t) || ["kind", "child_offsets", "list_offsets", "start", "len"].includes(t)) continue;
				mapping.set(t, kind);
			}
		}
		pos = arrow + 2;
	}
	return mapping;
}

function extractFunctionBodies(text: string): Map<string, string> {
	const clean = stripStringsAndComments(text);
	const fns = new Map<string, string>();
	for (const m of clean.matchAll(/\bfn\s+(\w+)\s*\(/g)) {
		const fnName = m[1];
		const parenStart = m.index! + m[0].length - 1;
		let depth = 0;
		let i = parenStart;
		while (i < clean.length) {
			const ch = clean[i];
			if (ch === "(") depth++;
			else if (ch === ")") {
				depth--;
				if (depth === 0) break;
			}
			i++;
		}
		const brace = clean.indexOf("{", i);
		if (brace < 0) continue;
		let end: number;
		try {
			end = findMatchingBrace(clean, brace);
		} catch {
			continue;
		}
		fns.set(fnName, text.slice(brace + 1, end - 1));
	}
	return fns;
}

function splitTopLevelCommas(body: string): { offset: number; arm: string }[] {
	const arms: { offset: number; arm: string }[] = [];
	let dp = 0;
	let db = 0;
	let dk = 0;
	let start = 0;
	for (let i = 0; i < body.length; i++) {
		const c = body[i];
		if (c === "(") dp++;
		else if (c === ")") dp--;
		else if (c === "{") db++;
		else if (c === "}") db--;
		else if (c === "[") dk++;
		else if (c === "]") dk--;
		else if (c === "," && dp === 0 && db === 0 && dk === 0) {
			const arm = body.slice(start, i).trim();
			if (arm) arms.push({ offset: start, arm });
			start = i + 1;
		}
	}
	const tail = body.slice(start).trim();
	if (tail) arms.push({ offset: start, arm: tail });
	return arms;
}

function findSwitches(text: string): { start: number; end: number }[] {
	const clean = stripStringsAndComments(text);
	const out: { start: number; end: number }[] = [];
	for (const m of clean.matchAll(/\bswitch\s*\(/g)) {
		const parenStart = m.index! + m[0].length - 1;
		let depth = 0;
		let i = parenStart;
		while (i < clean.length) {
			const ch = clean[i];
			if (ch === "(") depth++;
			else if (ch === ")") {
				depth--;
				if (depth === 0) break;
			}
			i++;
		}
		const brace = clean.indexOf("{", i);
		if (brace < 0) continue;
		let end: number;
		try {
			end = findMatchingBrace(clean, brace);
		} catch {
			continue;
		}
		out.push({ start: brace + 1, end: end - 1 });
	}
	return out;
}

function analyzeArmBody(armBody: string, fnVariants: Map<string, Set<string>>): Set<string> {
	const variants = new Set<string>();
	for (const m of armBody.matchAll(DATA_ACCESS_RE)) {
		if (ALL_DATA_VARIANTS.has(m[1])) variants.add(m[1]);
	}
	DATA_ACCESS_RE.lastIndex = 0;
	for (const m of armBody.matchAll(/(?:try\s+)?self\.(\w+)\s*\(/g)) {
		const fv = fnVariants.get(m[1]);
		if (fv) for (const v of fv) variants.add(v);
	}
	return variants;
}

/** Union sets in place. */
function unionInto(dst: Set<string>, src: Set<string>): boolean {
	let changed = false;
	for (const v of src) {
		if (!dst.has(v)) {
			dst.add(v);
			changed = true;
		}
	}
	return changed;
}

/**
 * Scan all reader files, build a single `tag→variants` map spanning them.
 *
 * Cross-file function propagation: same-name functions in different files
 * have their variant-sets merged conservatively (if any file's `makeX` reads
 * `.binary`, callers of `makeX` anywhere get `.binary` attributed). This can
 * over-attribute for namespace-colliding names but in practice that surfaces
 * as extra cosmetic entries, not false REAL mismatches (caller must still
 * store an aliased variant).
 */
function analyzeDataReaders(files: string[]): Map<string, Set<string>> {
	// Per-file text kept for switch scanning. Function bodies merged globally.
	const fileTexts = files.map((f) => readFileSync(f, "utf8"));

	// Build merged fnVariants: union bodies for same name across files.
	const fnBodies = new Map<string, string[]>();
	for (const text of fileTexts) {
		for (const [name, body] of extractFunctionBodies(text)) {
			let list = fnBodies.get(name);
			if (!list) {
				list = [];
				fnBodies.set(name, list);
			}
			list.push(body);
		}
	}

	const fnVariants = new Map<string, Set<string>>();
	for (const [name, bodies] of fnBodies) {
		const v = new Set<string>();
		for (const body of bodies) {
			for (const m of body.matchAll(DATA_ACCESS_RE)) {
				if (ALL_DATA_VARIANTS.has(m[1])) v.add(m[1]);
			}
		}
		fnVariants.set(name, v);
	}

	// NOTE: 의도적으로 "전이적 propagation" 없음.
	//
	// 원래는 A → B → C 호출 체인의 C 에서 data 를 읽으면 A 에 전파되도록 여러
	// pass 를 돌렸다. 그러나 ZTS 의 codegen/transformer 구조가 switch-dispatcher
	// 기반 (A 는 switch-only; 각 tag 별 concrete B 함수에 dispatch; B 가 data
	// 직접 접근) 이므로 tag-level variant 는 switch arm scan 이 직접 매칭한다
	// (arm tail 의 1-level callee 조회면 충분).
	//
	// 전이적 propagation 은 dispatcher 자체 variant 가 "모든 tag 의 union" 이
	// 되어 호출자를 오염시키는 false-cosmetic 경로를 만들었다 (#1802 B2 리뷰 중
	// `ts_import_equals_declaration` 이 `reads={모든 variant}` 로 과잉 매칭). tag
	// 별 정확도를 희생시키지 않으면서 오염을 없애려면 — propagation 제거가
	// 정답. 2+ level helper 체인이 실제로 data 를 읽는 극소수 경우는 follow-up
	// 으로 arm body 내에서 해당 helper 를 직접 참조하면 같이 잡힌다.

	// Scan switches in every reader file; accumulate into a single tag map.
	const tagVariants = new Map<string, Set<string>>();
	for (const text of fileTexts) {
		for (const { start, end } of findSwitches(text)) {
			const body = text.slice(start, end);
			for (const { arm } of splitTopLevelCommas(body)) {
				const arrow = arm.indexOf("=>");
				if (arrow < 0) continue;
				const head = arm.slice(0, arrow);
				const tail = arm.slice(arrow + 2);
				const tags = Array.from(head.matchAll(/\.([a-zA-Z_][a-zA-Z_0-9]*)/g), (m) => m[1]).filter(
					(t) => !KINDS.has(t),
				);
				if (tags.length === 0) continue;
				const variants = analyzeArmBody(tail, fnVariants);
				for (const tag of tags) {
					let cur = tagVariants.get(tag);
					if (!cur) {
						cur = new Set();
						tagVariants.set(tag, cur);
					}
					unionInto(cur, variants);
				}
			}
		}
	}
	return tagVariants;
}

function extractStructLiteral(text: string, startDotBrace: number): { literal: string; end: number } {
	const braceOpen = text.indexOf("{", startDotBrace);
	const end = findMatchingBrace(text, braceOpen);
	return { literal: text.slice(startDotBrace, end), end };
}

/**
 * `.tag = someVar,` 로 쓰인 경우, 호출 사이트 위쪽 function scope 내에서
 * `const <var>: ... = if (...) .tagA else .tagB;` 또는
 * `const <var> = .tagA;` 패턴을 찾아 가능한 tag 값들을 돌려준다.
 *
 * `cleanText` 는 `stripStringsAndComments` 결과. 오프셋이 `fileText` 와 동일하게
 * 유지되므로 문자열/주석 안의 false-positive 를 차단하면서도 `lastIndexOf` /
 * regex 결과를 그대로 인덱스로 쓸 수 있다.
 */
function resolveTagVariable(cleanText: string, callStart: number, varName: string): string[] {
	const fnStart = Math.max(cleanText.lastIndexOf("\nfn ", callStart), cleanText.lastIndexOf("\npub fn ", callStart), 0);
	const scope = cleanText.slice(fnStart, callStart);
	const re = new RegExp(
		`\\bconst\\s+${varName}\\b[^=]*=\\s*([^;]+?);`,
		"s",
	);
	const m = re.exec(scope);
	if (!m) return [];
	const rhs = m[1];
	const tags = Array.from(rhs.matchAll(/\.([a-zA-Z_][a-zA-Z_0-9]*)\b/g), (x) => x[1]);
	// variant/kind 이름은 걸러냄. identifier fragments 가 섞일 수 있어 getLayout 에
	// 등록된 이름만 추린다 (호출자가 필터).
	return tags.filter((t) => !KINDS.has(t) && !ALL_DATA_VARIANTS.has(t));
}

function auditFile(path: string, layout: Map<string, string>): { lineNo: number; tag: string; variant: string }[] {
	const text = readFileSync(path, "utf8");
	// 파일당 1회만 string/comment strip — 변수형 tag 리졸브가 매번 재작업하지 않도록.
	let cleanText: string | null = null;
	const findings: { lineNo: number; tag: string; variant: string }[] = [];
	for (const m of text.matchAll(ADDNODE_START_RE)) {
		const start = m.index!;
		const lineStart = text.lastIndexOf("\n", start - 1) + 1;
		const linePrefix = text.slice(lineStart, start).trimStart();
		if (linePrefix.startsWith("//")) continue;

		const litStart = text.indexOf(".{", start);
		let lit: string;
		try {
			lit = extractStructLiteral(text, litStart).literal;
		} catch {
			continue;
		}

		const varMatch = DATA_VARIANT_RE.exec(lit);
		if (!varMatch) continue;

		const lineNo = text.slice(0, start).split("\n").length;
		const tagMatch = TAG_RE.exec(lit);
		if (tagMatch) {
			findings.push({ lineNo, tag: tagMatch[1], variant: varMatch[1] });
			continue;
		}
		// Fallback: variable-typed `.tag = name,`. 가능한 tag 값 전개.
		const tagVarMatch = TAG_VAR_RE.exec(lit);
		if (!tagVarMatch) continue;
		if (cleanText === null) cleanText = stripStringsAndComments(text);
		for (const t of resolveTagVariable(cleanText, start, tagVarMatch[1])) {
			if (layout.has(t)) findings.push({ lineNo, tag: t, variant: varMatch[1] });
		}
	}
	ADDNODE_START_RE.lastIndex = 0;
	return findings;
}

function resolveKind(variant: string): string {
	if (LEAF_VARIANTS.has(variant)) return "leaf";
	if (ALL_DATA_VARIANTS.has(variant)) return variant;
	return `unknown<${variant}>`;
}

function walk(dir: string): string[] {
	const out: string[] = [];
	for (const name of readdirSync(dir)) {
		const p = join(dir, name);
		const s = statSync(p);
		if (s.isDirectory()) out.push(...walk(p));
		else if (name.endsWith(".zig")) out.push(p);
	}
	return out;
}

function main(): number {
	const verbose = process.argv.includes("--verbose") || process.argv.includes("-v");
	const layout = parseLayoutTable(readFileSync(AST_FILE, "utf8"));
	const readerFiles = DATA_READER_DIRS.flatMap((d) => walk(d));
	const dataReads = analyzeDataReaders(readerFiles);
	const nonEmpty = Array.from(dataReads.values()).filter((v) => v.size > 0).length;
	console.log(`layout table: ${layout.size} tag entries`);
	console.log(
		`data reader set: ${readerFiles.length} files scanned (codegen / transformer / semantic), ` +
			`${dataReads.size} tags tracked, ${nonEmpty} with non-empty variants`,
	);

	type Mismatch = { path: string; lineNo: number; tag: string; variant: string; expected: string; reads: Set<string> };
	const real: Mismatch[] = [];
	const cosmeticList: Mismatch[] = [];
	let total = 0;

	for (const path of walk(join(ROOT, "src")).sort()) {
		if (path === AST_FILE) continue;
		for (const { lineNo, tag, variant } of auditFile(path, layout)) {
			const expected = layout.get(tag);
			if (!expected) continue;
			const actualKind = resolveKind(variant);
			if (actualKind === expected) continue;
			const reads = dataReads.get(tag) ?? new Set<string>();
			if (reads.size === 0 || reads.has(variant)) {
				cosmeticList.push({ path, lineNo, tag, variant, expected, reads });
				continue;
			}
			real.push({ path, lineNo, tag, variant, expected, reads });
		}
		total++;
	}

	console.log(`\nscanned ${total} .zig files`);
	console.log(
		`cosmetic mismatches (layout inconsistency, readers use no data or use same variant): ${cosmeticList.length}`,
	);

	if (verbose && cosmeticList.length > 0) {
		console.log(`\n--- cosmetic detail (--verbose) ---`);
		const byTag = new Map<string, Mismatch[]>();
		for (const m of cosmeticList) {
			let list = byTag.get(m.tag);
			if (!list) {
				list = [];
				byTag.set(m.tag, list);
			}
			list.push(m);
		}
		for (const [tag, list] of Array.from(byTag.entries()).sort((a, b) => b[1].length - a[1].length)) {
			const first = list[0];
			const readsS = first.reads.size === 0 ? "∅" : Array.from(first.reads).sort().join(",");
			const variants = Array.from(new Set(list.map((m) => m.variant))).sort().join(",");
			console.log(
				`  ${tag} (${list.length}, layout=${first.expected}, stored={${variants}}, reads={${readsS}})`,
			);
			for (const m of list) {
				console.log(`    ${relative(ROOT, m.path)}:${m.lineNo} .${m.variant}`);
			}
		}
	}

	if (real.length === 0) {
		console.log("\n✓ 0 REAL mismatches (#1797 class silent failures)");
		return 0;
	}

	console.log(`\n✗ ${real.length} REAL mismatch(es):\n`);
	for (const { path, lineNo, tag, variant, expected, reads } of real) {
		const rel = relative(ROOT, path);
		const readsS = Array.from(reads).sort().join(", ");
		console.log(`  ${rel}:${lineNo}`);
		console.log(`    tag=.${tag}  stored=.${variant}  layout=.${expected}  readers use: {${readsS}}`);
	}
	return 1;
}

process.exit(main());
