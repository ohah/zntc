#!/usr/bin/env bun
/**
 * #1797 follow-up — static audit of `addNode` direct-construction sites.
 *
 * Two-pass analysis:
 *   1. Extract the Tag→DataKind table from src/parser/ast.zig::getLayout.
 *   2. Parse codegen.zig switches with proper brace-tracking and follow each
 *      arm's emit-function body (or inline `data.X` access) to collect the
 *      variants codegen reads for each tag.
 *
 * For every `.addNode(.{ .tag = X, ..., .data = .{ .Y = ... } })` call in src/:
 *   - If Y ≠ layout-expected kind AND codegen reads a *different* variant for
 *     that tag, flag as a **REAL** (#1797-class) silent failure.
 *   - Otherwise surface as cosmetic and continue.
 *
 * Exits non-zero when any REAL mismatch is found. Cosmetic mismatches are
 * reported but do not fail the audit (tracked separately in #1802).
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, "..");
const AST_FILE = join(ROOT, "src", "parser", "ast.zig");
const CODEGEN_FILE = join(ROOT, "src", "codegen", "codegen.zig");

const DATA_VARIANT_RE = /\.data\s*=\s*\.\{\s*\.(\w+)\s*=/;
const TAG_RE = /\.tag\s*=\s*\.(\w+)\s*,/;
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
		const callee = m[1];
		const fv = fnVariants.get(callee);
		if (fv) for (const v of fv) variants.add(v);
	}
	return variants;
}

function analyzeCodegen(text: string): Map<string, Set<string>> {
	const fns = extractFunctionBodies(text);
	const fnVariants = new Map<string, Set<string>>();
	for (const [name, body] of fns) {
		const v = new Set<string>();
		for (const m of body.matchAll(DATA_ACCESS_RE)) {
			if (ALL_DATA_VARIANTS.has(m[1])) v.add(m[1]);
		}
		fnVariants.set(name, v);
	}
	// Propagate direct `self.fn2(...)` callee variants (up to 3 levels).
	for (let pass = 0; pass < 3; pass++) {
		let changed = false;
		for (const [name, body] of fns) {
			const before = fnVariants.get(name)!;
			for (const m of body.matchAll(/(?:try\s+)?self\.(\w+)\s*\(/g)) {
				const callee = m[1];
				const callV = fnVariants.get(callee);
				if (!callV) continue;
				for (const v of callV) {
					if (!before.has(v)) {
						before.add(v);
						changed = true;
					}
				}
			}
		}
		if (!changed) break;
	}

	const tagVariants = new Map<string, Set<string>>();
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
				for (const v of variants) cur.add(v);
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

function auditFile(path: string): { lineNo: number; tag: string; variant: string }[] {
	const text = readFileSync(path, "utf8");
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

		const tagMatch = TAG_RE.exec(lit);
		const varMatch = DATA_VARIANT_RE.exec(lit);
		if (!tagMatch || !varMatch) continue;

		const lineNo = text.slice(0, start).split("\n").length;
		findings.push({ lineNo, tag: tagMatch[1], variant: varMatch[1] });
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
	const layout = parseLayoutTable(readFileSync(AST_FILE, "utf8"));
	const codegenReads = analyzeCodegen(readFileSync(CODEGEN_FILE, "utf8"));
	const nonEmpty = Array.from(codegenReads.values()).filter((v) => v.size > 0).length;
	console.log(`layout table: ${layout.size} tag entries`);
	console.log(`codegen read-set: ${codegenReads.size} tags scanned, ${nonEmpty} with non-empty variants`);

	const real: { path: string; lineNo: number; tag: string; variant: string; expected: string; reads: Set<string> }[] = [];
	let cosmetic = 0;
	let total = 0;

	for (const path of walk(join(ROOT, "src")).sort()) {
		if (path === AST_FILE) continue;
		for (const { lineNo, tag, variant } of auditFile(path)) {
			const expected = layout.get(tag);
			if (!expected) continue;
			const actualKind = resolveKind(variant);
			if (actualKind === expected) continue;
			const reads = codegenReads.get(tag) ?? new Set<string>();
			if (reads.size === 0) {
				cosmetic++;
				continue;
			}
			if (reads.has(variant)) {
				cosmetic++;
				continue;
			}
			real.push({ path, lineNo, tag, variant, expected, reads });
		}
		total++;
	}

	console.log(`\nscanned ${total} .zig files`);
	console.log(`cosmetic mismatches (layout inconsistency, codegen reads no data or reads same variant): ${cosmetic}`);

	if (real.length === 0) {
		console.log("\n✓ 0 REAL mismatches (#1797 class silent failures)");
		return 0;
	}

	console.log(`\n✗ ${real.length} REAL mismatch(es):\n`);
	for (const { path, lineNo, tag, variant, expected, reads } of real) {
		const rel = relative(ROOT, path);
		const readsS = Array.from(reads).sort().join(", ");
		console.log(`  ${rel}:${lineNo}`);
		console.log(`    tag=.${tag}  stored=.${variant}  layout=.${expected}  codegen reads: {${readsS}}`);
	}
	return 1;
}

process.exit(main());
