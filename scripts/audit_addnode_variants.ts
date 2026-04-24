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
	join(ROOT, "src", "bundler"),
	// parser 내부 — ast_walk / 재방문 코드가 data 를 읽는다. parser 가 addNode
	// 을 하는 파일이지만 동시에 data reader 이기도 해서 넣어야 일관성 확보.
	join(ROOT, "src", "parser"),
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

/**
 * cosmetic fail-gate 예외 — `--strict-cosmetic` 모드에서 허용되는 의도된 mismatch.
 *
 * - `flow_match_expression`: outer expression 은 `.extra` (discriminant + arms
 *   list), 각 arm 은 `.binary` (pattern + body) 로 **동일 tag 를 dual-site 재사용**.
 *   transformer `visitFlowMatch` 가 두 구조를 모두 읽는다. 단일 layout 선택
 *   불가능. 해결책은 arm tag 를 분리 (예: `flow_match_arm`) 하는 것이나
 *   audit 정리 범위 밖.
 */
const COSMETIC_EXEMPT_TAGS = new Set(["flow_match_expression"]);


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
		// String literal — Zig 정규 문자열 / 쿼트된 식별자 `@"var"` 모두 한 줄
		// 이내에서 닫힌다 (multi-line 은 `\\` prefix 를 사용). newline 경계에서
		// 강제 종료해야 `.@"var"` 같은 quoted identifier 가 거대 영역을 잘못
		// strip 하는 버그 방지.
		if (c === '"') {
			out[i] = " ";
			let j = i + 1;
			while (j < n && text[j] !== '"' && text[j] !== "\n") {
				if (text[j] === "\\" && j + 1 < n && text[j + 1] !== "\n") {
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

/** 함수 본문 + 해당 body 가 파일 내에서 시작하는 절대 offset. */
type FnBody = { body: string; fileOffset: number };

function extractFunctionBodies(text: string): Map<string, FnBody[]> {
	const clean = stripStringsAndComments(text);
	const fns = new Map<string, FnBody[]>();
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
		let list = fns.get(fnName);
		if (!list) {
			list = [];
			fns.set(fnName, list);
		}
		list.push({ body: text.slice(brace + 1, end - 1), fileOffset: brace + 1 });
	}
	return fns;
}

/** text 에서 offset 위치의 1-based line 번호. */
function offsetToLine(text: string, offset: number): number {
	let line = 1;
	for (let i = 0; i < offset && i < text.length; i++) {
		if (text[i] === "\n") line++;
	}
	return line;
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

/** variant → Set<"path:line"> — 어느 위치에서 해당 variant 를 읽었는지. */
type VariantLocations = Map<string, Set<string>>;

/** Union `src` into `dst`, reporting if anything was added (variant key or
 * location membership). */
function unionVariantLocations(dst: VariantLocations, src: VariantLocations): boolean {
	let changed = false;
	for (const [variant, locs] of src) {
		let cur = dst.get(variant);
		if (!cur) {
			cur = new Set();
			dst.set(variant, cur);
			changed = true;
		}
		for (const loc of locs) {
			if (!cur.has(loc)) {
				cur.add(loc);
				changed = true;
			}
		}
	}
	return changed;
}

function addLoc(dst: VariantLocations, variant: string, loc: string): void {
	let cur = dst.get(variant);
	if (!cur) {
		cur = new Set();
		dst.set(variant, cur);
	}
	cur.add(loc);
}

/** body 에서 DATA_ACCESS 매치를 돌면서 각 접근의 절대 위치 를 수집. */
function collectDirectAccesses(
	body: string,
	bodyFileOffset: number,
	fullText: string,
	displayPath: string,
	out: VariantLocations,
): void {
	for (const m of body.matchAll(DATA_ACCESS_RE)) {
		const variant = m[1];
		if (!ALL_DATA_VARIANTS.has(variant)) continue;
		const line = offsetToLine(fullText, bodyFileOffset + m.index!);
		addLoc(out, variant, `${displayPath}:${line}`);
	}
	DATA_ACCESS_RE.lastIndex = 0;
}

function analyzeArmBody(
	armBody: string,
	armFileOffset: number,
	fullText: string,
	displayPath: string,
	fnVariants: Map<string, VariantLocations>,
): VariantLocations {
	const out: VariantLocations = new Map();
	collectDirectAccesses(armBody, armFileOffset, fullText, displayPath, out);
	for (const m of armBody.matchAll(/(?:try\s+)?self\.(\w+)\s*\(/g)) {
		const fv = fnVariants.get(m[1]);
		if (fv) unionVariantLocations(out, fv);
	}
	return out;
}

/**
 * Scan all reader files, build a single `tag → (variant → Set<file:line>)` map.
 *
 * Cross-file function propagation: same-name functions in different files have
 * their variant-location maps merged conservatively. Over-attribution surfaces
 * as cosmetic noise, never false REAL.
 */
function analyzeDataReaders(files: string[]): Map<string, VariantLocations> {
	// Per-file text kept for switch scanning. Function bodies merged globally.
	const fileTexts = files.map((f) => ({ path: f, text: readFileSync(f, "utf8") }));

	// Build merged fn entries keyed by name. Each entry remembers the origin
	// file + offset so location attribution stays accurate.
	type FnEntry = { body: string; fileOffset: number; fileText: string; displayPath: string };
	const fnEntries = new Map<string, FnEntry[]>();
	for (const { path, text } of fileTexts) {
		const displayPath = relative(ROOT, path);
		for (const [name, bodies] of extractFunctionBodies(text)) {
			let list = fnEntries.get(name);
			if (!list) {
				list = [];
				fnEntries.set(name, list);
			}
			for (const { body, fileOffset } of bodies) {
				list.push({ body, fileOffset, fileText: text, displayPath });
			}
		}
	}

	const fnVariants = new Map<string, VariantLocations>();
	for (const [name, entries] of fnEntries) {
		const locs: VariantLocations = new Map();
		for (const { body, fileOffset, fileText, displayPath } of entries) {
			collectDirectAccesses(body, fileOffset, fileText, displayPath, locs);
		}
		fnVariants.set(name, locs);
	}

	// NOTE: 전이적 propagation 은 의도적으로 없다. switch-dispatcher 아키텍처
	// 에서 tag-level variant 는 switch arm 의 1-level callee 조회로 충분하고,
	// dispatcher 의 variants ("모든 tag union") 가 호출자를 오염시키던
	// false-cosmetic 경로를 차단하기 위함 (#1802 B2 리뷰에서 확립).

	const tagVariants = new Map<string, VariantLocations>();
	for (const { path, text } of fileTexts) {
		const displayPath = relative(ROOT, path);
		for (const { start, end } of findSwitches(text)) {
			const body = text.slice(start, end);
			for (const { offset, arm } of splitTopLevelCommas(body)) {
				const arrow = arm.indexOf("=>");
				if (arrow < 0) continue;
				const head = arm.slice(0, arrow);
				const tail = arm.slice(arrow + 2);
				const tags = Array.from(head.matchAll(/\.([a-zA-Z_][a-zA-Z_0-9]*)/g), (m) => m[1]).filter(
					(t) => !KINDS.has(t),
				);
				if (tags.length === 0) continue;
				const tailFileOffset = start + offset + arrow + 2;
				const variants = analyzeArmBody(tail, tailFileOffset, text, displayPath, fnVariants);
				for (const tag of tags) {
					let cur = tagVariants.get(tag);
					if (!cur) {
						cur = new Map();
						tagVariants.set(tag, cur);
					}
					unionVariantLocations(cur, variants);
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

function formatReads(reads: VariantLocations): string {
	if (reads.size === 0) return "∅";
	return Array.from(reads.keys()).sort().join(",");
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
	const strictCosmetic = process.argv.includes("--strict-cosmetic");
	const layout = parseLayoutTable(readFileSync(AST_FILE, "utf8"));
	const readerFiles = DATA_READER_DIRS.flatMap((d) => walk(d));
	const dataReads = analyzeDataReaders(readerFiles);
	const nonEmpty = Array.from(dataReads.values()).filter((v) => v.size > 0).length;
	console.log(`layout table: ${layout.size} tag entries`);
	console.log(
		`data reader set: ${readerFiles.length} files scanned (codegen / transformer / semantic), ` +
			`${dataReads.size} tags tracked, ${nonEmpty} with non-empty variants`,
	);

	type Mismatch = {
		path: string;
		lineNo: number;
		tag: string;
		variant: string;
		expected: string;
		reads: VariantLocations;
	};
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
			const reads = dataReads.get(tag) ?? new Map<string, Set<string>>();
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
			const readsS = formatReads(first.reads);
			const variants = Array.from(new Set(list.map((m) => m.variant))).sort().join(",");
			console.log(
				`  ${tag} (${list.length}, layout=${first.expected}, stored={${variants}}, reads={${readsS}})`,
			);
			for (const m of list) {
				console.log(`    ${relative(ROOT, m.path)}:${m.lineNo} .${m.variant}`);
			}
			// --verbose 에서는 각 variant 의 대표 reader 위치 (최대 3개) 를 같이 보여줌.
			for (const [variant, locs] of Array.from(first.reads.entries()).sort()) {
				const sample = Array.from(locs).sort().slice(0, 3);
				console.log(`      reader.${variant}: ${sample.join(", ")}${locs.size > sample.length ? `, ...(+${locs.size - sample.length})` : ""}`);
			}
		}
	}

	if (real.length > 0) {
		console.log(`\n✗ ${real.length} REAL mismatch(es):\n`);
		for (const { path, lineNo, tag, variant, expected, reads } of real) {
			const rel = relative(ROOT, path);
			console.log(`  ${rel}:${lineNo}`);
			console.log(`    tag=.${tag}  stored=.${variant}  layout=.${expected}  readers use: {${formatReads(reads)}}`);
			for (const [v, locs] of Array.from(reads.entries()).sort()) {
				const sample = Array.from(locs).sort().slice(0, 3);
				console.log(`      reader.${v}: ${sample.join(", ")}${locs.size > sample.length ? `, ...(+${locs.size - sample.length})` : ""}`);
			}
		}
		return 1;
	}
	console.log("\n✓ 0 REAL mismatches (#1797 class silent failures)");

	// --strict-cosmetic: #1802 최종 gate — 의도된 예외 (`COSMETIC_EXEMPT_TAGS`)
	// 를 제외한 cosmetic 이 0 이어야 한다. 신규 PR 이 cosmetic mismatch 를
	// 도입하면 CI 실패.
	if (strictCosmetic) {
		const unexpected = cosmeticList.filter((m) => !COSMETIC_EXEMPT_TAGS.has(m.tag));
		if (unexpected.length > 0) {
			console.log(
				`\n✗ --strict-cosmetic: ${unexpected.length} unexempted cosmetic mismatch(es) — ` +
					`add to COSMETIC_EXEMPT_TAGS only with justification.`,
			);
			for (const { path, lineNo, tag, variant, expected } of unexpected) {
				console.log(`  ${relative(ROOT, path)}:${lineNo}  tag=.${tag}  stored=.${variant}  layout=.${expected}`);
			}
			return 1;
		}
		const exemptCount = cosmeticList.length;
		console.log(
			`✓ --strict-cosmetic: 0 unexempted cosmetic (${exemptCount} exempted by design: ` +
				`${Array.from(COSMETIC_EXEMPT_TAGS).join(", ")})`,
		);
	}
	return 0;
}

process.exit(main());
