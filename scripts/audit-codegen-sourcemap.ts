#!/usr/bin/env bun
/**
 * codegen sourcemap mapping audit (#2983 후속).
 *
 * `node_dispatch.emitNode` 가 dispatch 에서 자식 노드별로 호출하는 모든 emitter
 * 함수가 첫 줄에서 `try self.addSourceMapping(node.span);` 을 발행하는지
 * 검사. esbuild / oxc / swc 와 동일한 명시 발행 패턴이 깨지면 새 emitter
 * 추가 시 매핑 누락 회귀 (#2982 같은 패턴) 가 잠복하므로 CI 에서 정적 차단.
 *
 * 검사 규칙:
 *   - `pub fn emit*(self: anytype, node: Node, ...)` 시그니처 매치
 *   - 본문 첫 5 non-comment, non-blank 줄 안에 `try self.addSourceMapping(node.span);`
 *     호출이 있는지 확인
 *   - SKIP_FUNCS 에 명시된 컨테이너 / 위임 / 자체-위치-매핑 emitter 는 제외
 *
 * 누락 시 list 출력 + exit 1.
 */
import { readFileSync, readdirSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, "..");
const CODEGEN_DIR = join(ROOT, "src", "codegen");

const TARGET_FILES = [
	"statements.zig",
	"expressions.zig",
	"calls.zig",
	"function_class.zig",
	"bindings.zig",
	"modules.zig",
	"type_runtime.zig",
];

/**
 * 매핑 발행 면제 — 컨테이너 (자식이 매핑) 또는 자체적으로 다른 위치 매핑을
 * 발행하는 위임형 함수.
 */
const SKIP_FUNCS = new Map<string, string>([
	["emitProgram", "container — children carry mappings"],
	["emitBlock", "container — children carry mappings"],
	["emitBracedList", "container helper for block_statement / class_body"],
	["emitSwitch", "container — switch_case children carry mappings"],
	["emitTry", "container — block / catch / finally children carry mappings"],
	["emitClassBody", "container — delegates to emitBracedList"],
	["emitStaticBlock", "container — body carries mappings"],
	["emitNamespaceIIFE", "delegates to emitNamespaceIIFEInner"],
	["emitExportSpecifier", "leaf-token mapping at local_node.span (not outer node.span)"],
	["emitParen", "transparent (#4042) — operand 이 자기 매핑 발행, paren 노드는 토큰 미출력"],
]);

/** `pub fn emit<Name>(self: anytype, node: Node, ...)` 시그니처 매치. */
const EMITTER_SIGNATURE = /^pub fn (emit\w+)\(self:\s*anytype,\s*node:\s*Node[^)]*\)\s*[^{]*\{/;

const REQUIRED_CALL = "try self.addSourceMapping(node.span);";

interface Finding {
	file: string;
	line: number;
	name: string;
}

function checkFunctionBody(lines: string[], startIdx: number): boolean {
	// 본문 첫 5 non-comment, non-blank 줄 검사.
	let inspected = 0;
	for (let i = startIdx; i < lines.length && inspected < 5; i++) {
		const line = lines[i].trim();
		if (line.length === 0) continue;
		if (line.startsWith("//")) continue;
		if (line === "}") return false; // 함수 끝 도달 — 발견 못 함
		if (line.includes(REQUIRED_CALL)) return true;
		inspected++;
	}
	return false;
}

function auditFile(absPath: string): Finding[] {
	const text = readFileSync(absPath, "utf-8");
	const lines = text.split("\n");
	const findings: Finding[] = [];

	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(EMITTER_SIGNATURE);
		if (!m) continue;
		const name = m[1];
		if (SKIP_FUNCS.has(name)) continue;
		if (!checkFunctionBody(lines, i + 1)) {
			findings.push({
				file: relative(ROOT, absPath),
				line: i + 1,
				name,
			});
		}
	}
	return findings;
}

function main(): void {
	const allFindings: Finding[] = [];
	for (const file of TARGET_FILES) {
		const abs = join(CODEGEN_DIR, file);
		allFindings.push(...auditFile(abs));
	}

	if (allFindings.length === 0) {
		console.log(`✓ codegen sourcemap audit: 모든 emitter 가 \`${REQUIRED_CALL}\` 를 첫 줄에 발행 (총 ${TARGET_FILES.length} 파일)`);
		process.exit(0);
	}

	console.error("✗ codegen sourcemap audit: 매핑 발행 누락 emitter");
	for (const f of allFindings) {
		console.error(`  ${f.file}:${f.line}  pub fn ${f.name}`);
	}
	console.error("");
	console.error(`각 emitter 함수 첫 줄에 \`${REQUIRED_CALL}\` 추가 필요.`);
	console.error(`컨테이너 / 위임형 emitter 라면 scripts/audit-codegen-sourcemap.ts 의 SKIP_FUNCS 에 사유와 함께 추가.`);
	process.exit(1);
}

main();
