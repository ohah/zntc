//! Import/Export 파싱
//!
//! ESM import/export 선언, import 호출 표현식, import attributes,
//! 모듈 소스 경로 파싱 등 모듈 관련 함수들.
//! oxc의 js/module.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/js/module.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;
const binding_mod = @import("binding.zig");
const scan_results_mod = @import("scan_results.zig");
const import_scanner = @import("../bundler/import_scanner.zig");

/// import() / import.source() / import.defer() 호출의 인자를 파싱한다.
/// `(` 를 소비하고, 1~2개 인자를 파싱하고, `)` 를 기대한다.
/// import() 내부에서는 `in` 연산자를 허용 (+In context).
pub fn parseImportCallArgs(self: *Parser, start: u32) ParseError2!NodeIndex {
    try self.expect(.l_paren);
    const saved_ctx = self.enterAllowInContext(true);
    defer self.restoreContext(saved_ctx);
    const arg = try self.parseAssignmentExpression();
    // 두 번째 인자 (import attributes/options) — 있으면 파싱하고 무시
    if (try self.eat(.comma)) {
        if (self.current() != .r_paren) {
            _ = try self.parseAssignmentExpression();
            _ = try self.eat(.comma); // trailing comma
        }
    }
    try self.expect(.r_paren);

    // Inline scan: dynamic import — 인자가 string_literal이면 레코드 추가
    if (self.enable_scan and !arg.isNone() and @intFromEnum(arg) < self.ast.nodes.items.len) {
        const arg_node = self.ast.getNode(arg);
        if (arg_node.tag == .string_literal) {
            const raw = self.ast.source[arg_node.span.start..arg_node.span.end];
            const spec = stripImportQuotes(raw);
            _ = appendImportRecord(self, spec, .dynamic_import, arg_node.span);
        }
    }

    return try self.ast.addNode(.{
        .tag = .import_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
    });
}

pub fn parseImportDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // Unambiguous 모드: has_module_syntax 설정은 ESM import 확정 후 (아래 참조)
    // TS import-equals (import x = require('y'))는 module syntax가 아님
    // ECMAScript 15.2: import 선언은 module의 top-level에서만 허용
    // namespace body 안에서도 import 허용 (in_namespace)
    if (!self.is_module and !self.in_namespace) {
        try self.addError(self.currentSpan(), "'import' declaration is only allowed in module code");
    } else if (!self.ctx.is_top_level) {
        try self.addError(self.currentSpan(), "'import' declaration must be at the top level");
    }
    try self.advance(); // skip 'import'

    // TS/Flow: import type — type-only import (완전 제거)
    // import type Foo from 'bar'
    // import type { Foo } from 'bar'
    // import type * as ns from 'bar'
    // Flow: import typeof — type-only import (완전 제거)
    // import typeof Foo from 'bar'
    // import typeof * as ns from 'bar'
    var is_type_only = false;

    // Flow: import typeof — typeof는 키워드(.kw_typeof)이므로 별도 감지
    if (self.is_flow and self.current() == .kw_typeof) {
        const next = try self.peekNextKind();
        if (next == .star or next == .identifier or next == .l_curly) {
            is_type_only = true;
            try self.advance(); // skip 'typeof'
        }
    }

    if (!is_type_only and self.current() == .identifier and self.isContextual("type")) {
        const next = try self.peekNextKind();
        // import type { ... } / import type * / import type Foo from
        // 주의: import type from 'bar'는 'type'이라는 이름의 default import
        //   → next가 kw_from이고 그 다음이 string_literal이면 type-only가 아님
        //   → next가 kw_from이고 그 다음이 string이 아니면 type-only
        //     (예: import type from from 'bar' — from이 default import 이름)
        // 비예약 키워드도 타입 이름으로 유효 (import type async from 'bar')
        if (next == .l_curly or next == .star or next == .identifier or
            (next != .kw_from and next.isKeyword() and !next.isReservedKeyword()) or
            (next == .kw_from and blk: {
                // 2-token lookahead: from 다음이 string이 아니면 type-only
                const saved = self.saveState();
                const err_count = self.errors.items.len;
                self.advance() catch break :blk false; // skip 'type'
                self.advance() catch break :blk false; // skip 'from'
                const after_from = self.current();
                self.restoreState(saved);
                self.errors.shrinkRetainingCapacity(err_count);
                break :blk after_from != .string_literal;
            }))
        {
            is_type_only = true;
            try self.advance(); // skip 'type'
        }
    }

    // import defer / import source — Stage 3 proposals
    // defer/source를 스킵하고 나머지는 일반 import로 처리
    // 주의: `import defer from "..."` 는 default import (defer가 로컬 이름)
    // `import defer "..."` 또는 `import defer * as ns from "..."` 가 phase modifier
    var has_phase_modifier = false;
    if (self.current() == .kw_defer or self.current() == .kw_source) {
        const next = try self.peekNextKind();
        // defer/source 뒤에 from 또는 , 가 오면 default import (defer가 binding name)
        if (next != .kw_from and next != .comma) {
            has_phase_modifier = true;
            try self.advance(); // skip defer/source
        }
    }

    // import "module" — side-effect import
    // specs_len=0으로 저장하여 specifier가 있는 import와 같은 extra 형식 사용.
    // unary를 쓰면 extern union의 나머지 바이트가 초기화되지 않아
    // codegen에서 .unary.flags를 읽을 때 플랫폼별 UB 발생 (Linux에서 실패).
    if (self.current() == .string_literal) {
        if (has_phase_modifier) {
            try self.addError(self.currentSpan(), "'import defer/source' requires a binding");
        }
        const source_node = try parseModuleSource(self);
        _ = try self.eat(.semicolon);

        // Inline scan: side-effect import (no bindings)
        if (self.enable_scan and !is_type_only and !source_node.isNone()) {
            const src_node = self.ast.getNode(source_node);
            const raw = self.ast.source[src_node.span.start..src_node.span.end];
            const spec = stripImportQuotes(raw);
            _ = appendImportRecord(self, spec, .side_effect, src_node.span);
            self.scan_result.has_esm_syntax = true;
        }

        const extra_start = try self.ast.addExtra(0); // specs_start (unused)
        _ = try self.ast.addExtra(0); // specs_len = 0 (side-effect)
        _ = try self.ast.addExtra(@intFromEnum(source_node));
        return try self.ast.addNode(.{
            .tag = .import_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // import(...) — dynamic import는 expression. expression statement로 파싱.
    if (self.current() == .l_paren) {
        // import 키워드는 이미 advance()됨. parsePrimaryExpression에 위임하기 위해
        // 수동으로 import expression 생성.
        try self.expect(.l_paren);
        const arg = try self.parseAssignmentExpression();
        try self.expect(.r_paren);
        const import_expr = try self.ast.addNode(.{
            .tag = .import_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
        // 후속 .then() 등의 member/call 체이닝 처리
        _ = try self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = import_expr, .flags = 0 } },
        });
    }

    // 스펙ifier 파싱
    const scratch_top = self.saveScratch();

    // TS import-equals: import x = require('y') → const x = require('y')
    // import x = Namespace.Member → const x = Namespace.Member
    if (self.current() == .identifier or
        (self.current().isKeyword() and !self.current().isReservedKeyword()))
    {
        const next = try self.peekNextKind();
        if (next == .eq) {
            // import-equals는 TS CJS 호환 구문 → module syntax로 취급하지 않음
            const name_span = self.currentSpan();
            try self.advance(); // skip name
            try self.advance(); // skip =
            // require('y') 또는 Namespace.Member
            const value = try self.parseAssignmentExpression();
            _ = try self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .ts_import_equals_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = name_span,
                    .data = .{ .string_ref = name_span },
                }), .right = value, .flags = 0 } },
            });
        }
    }

    // import-equals가 아니면 ESM import → module syntax 확정
    if (self.is_unambiguous and !self.in_namespace) {
        self.has_module_syntax = true;
    }

    // default import: import foo from "module"
    // contextual keyword (get/set/number/string/object/type 등)도 import 이름으로 유효
    var has_default = false;
    if (self.current() == .identifier or
        (self.current().isKeyword() and !self.current().isReservedKeyword()))
    {
        const next = try self.peekNextKind();
        if (next == .comma or next == .kw_from) {
            const spec_span = self.currentSpan();
            try self.advance();
            const spec = try self.ast.addNode(.{
                .tag = .import_default_specifier,
                .span = spec_span,
                .data = .{ .string_ref = spec_span },
            });
            try self.scratch.append(self.allocator, spec);
            has_default = true;

            if (try self.eat(.comma)) {
                // import default, { ... } from "module"
                // import default, * as ns from "module"
            } else {
                // import default from "module"
                try self.expect(.kw_from);
                const source_node = try parseModuleSource(self);
                _ = try self.eat(.semicolon);

                if (is_type_only) {
                    self.restoreScratch(scratch_top);
                    return NodeIndex.none;
                }

                // Inline scan: default-only import
                if (self.enable_scan and !source_node.isNone()) {
                    const src_node = self.ast.getNode(source_node);
                    const raw = self.ast.source[src_node.span.start..src_node.span.end];
                    const specifier = stripImportQuotes(raw);
                    const rec_idx = appendImportRecord(self, specifier, .static_import, src_node.span);
                    collectImportBindings(self, scratch_top, rec_idx);
                    self.scan_result.has_esm_syntax = true;
                }

                const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                self.restoreScratch(scratch_top);
                const extra_start = try self.ast.addExtra(specifiers.start);
                _ = try self.ast.addExtra(specifiers.len);
                _ = try self.ast.addExtra(@intFromEnum(source_node));

                return try self.ast.addNode(.{
                    .tag = .import_declaration,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = extra_start },
                });
            }
        }
    }

    // namespace import: import * as ns from "module"
    if (self.current() == .star) {
        try self.advance(); // skip *
        try self.expectContextual("as");
        const local_span = self.currentSpan();
        // TS contextual keywords (number, string, object 등)도 유효한 바인딩 이름이므로
        // expect(.identifier) 대신 parseSimpleIdentifier를 사용한다.
        // 예: import * as number from "effect/Number"
        const binding = try binding_mod.parseSimpleIdentifier(self);
        _ = binding;
        const spec = try self.ast.addNode(.{
            .tag = .import_namespace_specifier,
            .span = local_span,
            .data = .{ .string_ref = local_span },
        });
        try self.scratch.append(self.allocator, spec);
    }

    // named imports: import { a, b as c } from "module"
    if (self.current() == .l_curly) {
        try self.advance(); // skip {
        while (self.current() != .r_curly and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            const spec = try parseImportSpecifier(self);
            try self.scratch.append(self.allocator, spec);
            if (!try self.eat(.comma)) break;

            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }
        try self.expect(.r_curly);
    }

    try self.expect(.kw_from);
    const source_node = try parseModuleSource(self);
    _ = try self.eat(.semicolon);

    if (is_type_only) {
        self.restoreScratch(scratch_top);
        return NodeIndex.none;
    }

    // Inline scan: full import (namespace/named/mixed)
    if (self.enable_scan and !source_node.isNone()) {
        const src_node = self.ast.getNode(source_node);
        const raw = self.ast.source[src_node.span.start..src_node.span.end];
        const spec = stripImportQuotes(raw);
        const rec_idx = appendImportRecord(self, spec, .static_import, src_node.span);
        collectImportBindings(self, scratch_top, rec_idx);
        self.scan_result.has_esm_syntax = true;
    }

    const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    const extra_start = try self.ast.addExtra(specifiers.start);
    _ = try self.ast.addExtra(specifiers.len);
    _ = try self.ast.addExtra(@intFromEnum(source_node));

    return try self.ast.addNode(.{
        .tag = .import_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseImportSpecifier(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // inline type import: import { type Config } from './config'
    // 주의: import { type } from ... → 'type'이라는 값을 import (modifier 아님)
    // 주의: import { type as alias } from ... → 'type'을 alias로 import (modifier 아님)
    // \u0074ype 같은 unicode escape도 type modifier로 인식 (esbuild 호환)
    var is_type_only: u16 = 0;

    // Flow: import { typeof X as Y } — typeof는 키워드(.kw_typeof)이므로 별도 감지
    if (self.is_flow and self.current() == .kw_typeof) {
        const next = try self.peekNextKind();
        if (next == .identifier or next == .string_literal or (next.isKeyword() and next != .r_curly and next != .comma)) {
            is_type_only = 1;
            try self.advance(); // skip 'typeof'
        }
    }

    if (is_type_only == 0 and (self.isContextual("type") or
        (self.current() == .identifier and self.scanner.token.has_escape and self.isEscapedKeyword("type"))))
    {
        const next = try self.peekNextKind();
        // 다음이 바인딩 이름으로 사용 가능한 토큰이면 type modifier
        // (identifier 또는 keyword — TS도 모든 keyword 뒤에서 type modifier로 판단)
        // string_literal도 허용: import { type 'y' as z } (ModuleExportName)
        // 단, '}', ',', 'as'는 제외: import { type }, import { type, x }, import { type as y }
        // 'as'는 contextual keyword이므로 identifier로 토큰화됨 — save/restore로 텍스트 확인
        if (next != .r_curly and next != .comma and
            (next == .identifier or next == .string_literal or next.isKeyword()))
        {
            const saved = self.saveState();
            try self.advance(); // tentatively skip 'type'
            if (self.isContextual("as")) {
                // "import { type as }" → type modifier, 'as'가 imported name
                // "import { type as as foo }" → type modifier, 'as' imported, 'foo' local
                // "import { type as alias }" → 'type'은 값 이름, 'alias'는 로컬 바인딩
                const after_as = try self.peekNextKind();
                if (after_as == .r_curly or after_as == .comma) {
                    // "import { type as }" — 'as'가 imported name, type modifier 확정
                    is_type_only = 1;
                } else if (after_as == .identifier or after_as.isKeyword()) {
                    // 다음 토큰 텍스트를 확인: "type as as foo" vs "type as alias"
                    const saved2 = self.saveState();
                    try self.advance(); // skip 'as'
                    if (try resolveTypeAsAs(self, saved, saved2)) {
                        is_type_only = 1;
                    }
                } else {
                    self.restoreState(saved);
                }
            } else {
                is_type_only = 1;
                // 'type' modifier 확정 — 이미 advance됨
            }
        }
    }

    // imported name — ModuleExportName (identifier or string literal)
    const imported = try self.parseModuleExportName();

    // string literal import 시 반드시 `as` 바인딩 필요:
    // import { "☿" as Ami } from ... (OK)
    // import { "☿" } from ... (Error — string cannot be used as binding)
    var local = imported;
    if (try self.eatContextual("as")) {
        // `as` 뒤는 반드시 BindingIdentifier (string literal 불가)
        local = try self.parseIdentifierName();
    } else if (!imported.isNone() and @intFromEnum(imported) < self.ast.nodes.items.len and
        self.ast.getNode(imported).tag == .string_literal)
    {
        // string literal without `as` — binding 이름이 없으므로 에러
        try self.addError(self.ast.getNode(imported).span, "String literal in import specifier requires 'as' binding");
    }

    return try self.ast.addNode(.{
        .tag = .import_specifier,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = imported, .right = local, .flags = is_type_only } },
    });
}

pub fn parseExportDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // @__NO_SIDE_EFFECTS__ 주석이 export 키워드 앞에 있으면 캡처.
    // export function f() {} 형태에서 주석은 export 토큰에 붙지만,
    // function 파서에서 확인해야 하므로 여기서 미리 저장한다.
    const had_no_side_effects = self.scanner.token.has_no_side_effects_comment;
    // Unambiguous 모드: top-level ESM export → module 확정
    // export = (TS CJS) 제외, namespace 내부 제외
    if (self.is_unambiguous and !self.in_namespace) {
        const next_kind = try self.peekNextKind();
        if (next_kind != .eq) {
            self.has_module_syntax = true;
        }
    }
    // ECMAScript 15.2: export 선언은 module의 top-level에서만 허용
    // namespace body 안에서도 export 허용 (in_namespace)
    if (!self.is_module and !self.in_namespace) {
        try self.addError(self.currentSpan(), "'export' declaration is only allowed in module code");
    } else if (!self.ctx.is_top_level) {
        try self.addError(self.currentSpan(), "'export' declaration must be at the top level");
    }
    try self.advance(); // skip 'export'
    // export 토큰의 @__NO_SIDE_EFFECTS__를 다음 토큰(function)에 전파
    if (had_no_side_effects) {
        self.scanner.token.has_no_side_effects_comment = true;
    }

    // export default
    if (try self.eat(.kw_default)) {
        // export default function: default 소비 후 다시 function 토큰에 전파
        if (had_no_side_effects) {
            self.scanner.token.has_no_side_effects_comment = true;
        }
        const decl = switch (self.current()) {
            // export default function / export default function* — 이름 선택적
            .kw_function => blk: {
                const fn_decl = try self.parseFunctionDeclarationDefaultExport();
                // anonymous function declaration은 호출 불가 (IIFE가 아님)
                // export default function() {}() → SyntaxError
                if (self.current() == .l_paren) {
                    try self.addError(self.currentSpan(), "Anonymous function declaration cannot be invoked");
                }
                break :blk fn_decl;
            },
            .kw_class => try self.parseClassDeclaration(),
            else => blk: {
                // export default interface Foo {} — TS 전용, 런타임에 제거
                if (self.current() == .kw_interface) {
                    _ = try self.parseTsInterfaceDeclaration();
                    break :blk NodeIndex.none;
                }
                // export default abstract class Foo {}
                // export default abstract (abstract를 식별자 표현식으로)
                if (self.current() == .identifier and self.isContextual("abstract")) {
                    const peek = try self.peekNext();
                    if (peek.kind == .kw_class and !peek.has_newline_before) {
                        try self.advance(); // skip 'abstract'
                        break :blk try self.parseClassDeclaration();
                    }
                    // abstract 단독 → 식별자 expression (fallthrough)
                }
                // export default async function / export default async function* — 이름 선택적
                if (self.current() == .kw_async) {
                    const peek = try self.peekNext();
                    if (peek.kind == .kw_function and !peek.has_newline_before) {
                        const fn_decl = try self.parseAsyncFunctionDeclarationDefaultExport();
                        if (self.current() == .l_paren) {
                            try self.addError(self.currentSpan(), "Anonymous function declaration cannot be invoked");
                        }
                        break :blk fn_decl;
                    }
                }
                const expr = try self.parseAssignmentExpression();
                try self.expectSemicolon();
                break :blk expr;
            },
        };
        // TS type-only default export (interface) → 전체 제거
        if (decl.isNone()) return NodeIndex.none;

        // Inline scan: export default
        if (self.enable_scan) {
            self.scan_result.has_esm_syntax = true;
            var local_name: []const u8 = "_default";
            if (!decl.isNone()) {
                const inner = self.ast.getNode(decl);
                if (inner.tag == .function_declaration or inner.tag == .class_declaration) {
                    const e = inner.data.extra;
                    if (e < self.ast.extra_data.items.len) {
                        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                        if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
                            const name_node = self.ast.getNode(name_idx);
                            const n = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                            if (n.len > 0) local_name = n;
                        }
                    }
                } else if (inner.tag == .identifier_reference) {
                    const n = self.ast.getText(inner.span);
                    if (n.len > 0) local_name = n;
                }
            }
            // barrel re-export check
            const re = checkBarrelReExport(self, local_name);
            self.scan_export_bindings.append(self.allocator, .{
                .exported_name = "default",
                .local_name = re.local_name,
                .local_span = .{ .start = start, .end = self.currentSpan().start },
                .kind = re.kind,
                .import_record_index = re.import_record_index,
            }) catch {};
        }

        return try self.ast.addNode(.{
            .tag = .export_default_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = decl, .flags = 0 } },
        });
    }

    // TS: export type — type-only export (완전 제거)
    // export type { Foo } from 'bar'
    // export type * from 'bar'
    // export type * as ns from 'bar'
    var is_type_only_export = false;
    if (self.current() == .identifier and self.isContextual("type")) {
        const next = try self.peekNextKind();
        if (next == .l_curly or next == .star) {
            is_type_only_export = true;
            try self.advance(); // skip 'type'
        }
    }

    // export * from "module" / export * as ns from "module"
    if (self.current() == .star) {
        try self.advance(); // skip *
        var exported_name = NodeIndex.none;
        if (try self.eatContextual("as")) {
            exported_name = try self.parseModuleExportName();
        }
        try self.expect(.kw_from);
        const source_node = try parseModuleSource(self);
        try self.expectSemicolon();

        if (is_type_only_export) return NodeIndex.none;

        // Inline scan: export * from "module" / export * as ns from "module"
        if (self.enable_scan and !source_node.isNone()) {
            self.scan_result.has_esm_syntax = true;
            const src_node = self.ast.getNode(source_node);
            const raw = self.ast.source[src_node.span.start..src_node.span.end];
            const spec = stripImportQuotes(raw);
            const rec_idx = appendImportRecord(self, spec, .re_export, src_node.span);

            if (!exported_name.isNone() and @intFromEnum(exported_name) < self.ast.nodes.items.len) {
                // export * as ns from "module"
                const name_node = self.ast.getNode(exported_name);
                const name_text = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                self.scan_export_bindings.append(self.allocator, .{
                    .exported_name = name_text,
                    .local_name = name_text,
                    .local_span = .{ .start = start, .end = self.currentSpan().start },
                    .kind = .re_export_all,
                    .import_record_index = rec_idx,
                }) catch {};
            } else {
                // export * from "module"
                self.scan_export_bindings.append(self.allocator, .{
                    .exported_name = "*",
                    .local_name = "*",
                    .local_span = .{ .start = start, .end = self.currentSpan().start },
                    .kind = .re_export_all,
                    .import_record_index = rec_idx,
                }) catch {};
            }
        }

        return try self.ast.addNode(.{
            .tag = .export_all_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = exported_name, .right = source_node, .flags = 0 } },
        });
    }

    // export { a, b } / export { a } from "module"
    if (self.current() == .l_curly) {
        try self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            const spec = try parseExportSpecifier(self);
            try self.scratch.append(self.allocator, spec);
            if (!try self.eat(.comma)) break;

            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }
        try self.expect(.r_curly);

        // re-export: export { a } from "module"
        var source_node = NodeIndex.none;
        if (try self.eat(.kw_from)) {
            source_node = try parseModuleSource(self);
        }
        try self.expectSemicolon();

        // export NamedExports ; (without `from`) →
        // local 이름에 string literal 사용 불가
        // (ECMAScript: ReferencedBindings에 StringLiteral이 있으면 SyntaxError)
        if (source_node.isNone()) {
            for (self.scratch.items[scratch_top..]) |spec_idx| {
                if (spec_idx.isNone()) continue;
                if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
                const spec_node = self.ast.getNode(spec_idx);
                if (spec_node.tag == .export_specifier) {
                    const local_idx = spec_node.data.binary.left;
                    if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                        const local_node = self.ast.getNode(local_idx);
                        if (local_node.tag == .string_literal) {
                            try self.addError(local_node.span, "String literal cannot be used as local binding in export");
                        }
                    }
                }
            }
        }

        // Inline scan: export { a, b } / export { a } from "module"
        if (self.enable_scan and !is_type_only_export) {
            self.scan_result.has_esm_syntax = true;
            const has_source = !source_node.isNone();
            var rec_idx: ?u32 = null;
            if (has_source) {
                const src_node = self.ast.getNode(source_node);
                const raw = self.ast.source[src_node.span.start..src_node.span.end];
                const spec = stripImportQuotes(raw);
                rec_idx = appendImportRecord(self, spec, .re_export, src_node.span);
            }

            for (self.scratch.items[scratch_top..]) |spec_idx| {
                if (spec_idx.isNone()) continue;
                if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
                const spec_node = self.ast.getNode(spec_idx);
                if (spec_node.tag != .export_specifier) continue;
                // skip type-only specifiers
                if (spec_node.data.binary.flags & 1 != 0) continue;

                const local_idx = spec_node.data.binary.left;
                const exported_idx = spec_node.data.binary.right;
                if (local_idx.isNone()) continue;

                const local_node = self.ast.getNode(local_idx);
                const local_name = self.ast.source[local_node.span.start..local_node.span.end];

                const exported_node = if (!exported_idx.isNone() and @intFromEnum(exported_idx) != @intFromEnum(local_idx))
                    self.ast.getNode(exported_idx)
                else
                    local_node;
                const exported_name = self.ast.source[exported_node.span.start..exported_node.span.end];

                if (has_source) {
                    // export { a } from "module" → re-export
                    self.scan_export_bindings.append(self.allocator, .{
                        .exported_name = exported_name,
                        .local_name = local_name,
                        .local_span = local_node.span,
                        .kind = .re_export,
                        .import_record_index = rec_idx,
                    }) catch {};
                } else {
                    // export { a } — local or barrel re-export
                    const re = checkBarrelReExport(self, local_name);
                    self.scan_export_bindings.append(self.allocator, .{
                        .exported_name = exported_name,
                        .local_name = re.local_name,
                        .local_span = local_node.span,
                        .kind = re.kind,
                        .import_record_index = re.import_record_index,
                    }) catch {};
                }
            }
        }

        const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        if (is_type_only_export) return NodeIndex.none;

        // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(NodeIndex.none), // declaration 없음
            specifiers.start,
            specifiers.len,
            @intFromEnum(source_node),
        });

        return try self.ast.addNode(.{
            .tag = .export_named_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // TS: export as namespace ns — 타입 전용 (완전 제거)
    // peek로 'as' 소비 전에 'namespace'가 따르는지 확인 (잘못된 구문에서 복구 불능 방지)
    if (self.current() == .identifier and self.isContextual("as")) {
        const peek = try self.peekNextKind();
        if (peek == .identifier) {
            try self.advance(); // skip 'as'
            try self.advance(); // skip 'namespace'
            if (self.current() == .identifier or self.current().isKeyword())
                try self.advance(); // skip name
            _ = try self.eat(.semicolon);
            return NodeIndex.none;
        }
    }

    // TS: export = expr — export assignment (타입 전용)
    if (try self.eat(.eq)) {
        _ = try self.parseAssignmentExpression();
        _ = try self.eat(.semicolon);
        return NodeIndex.none;
    }

    // export var/let/const/function/class
    const decl = try self.parseStatement();
    // type-only 선언이면 export_named_declaration을 생성하지 않음.
    // 남으면 import_scanner가 has_esm_syntax=true로 잘못 판별하여
    // CJS 모듈이 __esm으로 래핑됨.
    if (decl.isNone()) return NodeIndex.none;
    if (self.ast.getNode(decl).tag.isTypeOnlyDeclaration()) return NodeIndex.none;

    // Inline scan: export var/let/const/function/class
    if (self.enable_scan) {
        self.scan_result.has_esm_syntax = true;
        collectDeclExportBindings(self, decl);
    }

    // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(decl),
        0, // specifiers_start (사용 안 함)
        0, // specifiers_len = 0
        @intFromEnum(NodeIndex.none), // source 없음
    });
    return try self.ast.addNode(.{
        .tag = .export_named_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseExportSpecifier(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // TS inline type modifier: export { type Foo } from 'mod'
    // 주의: export { type } from ... → 'type'이라는 값을 export (modifier 아님)
    // 주의: export { type as alias } from ... → 'type'을 alias로 export (modifier 아님)
    // \u0074ype 같은 unicode escape도 type modifier로 인식 (esbuild 호환)
    var is_type_only: u16 = 0;
    if (self.isContextual("type") or
        (self.current() == .identifier and self.scanner.token.has_escape and self.isEscapedKeyword("type")))
    {
        const next = try self.peekNextKind();
        // 다음이 이름으로 사용 가능한 토큰이면 type modifier
        // string_literal도 허용: export { type "x" as y } from 'mod'
        // 단, '}', ',', 'as'는 제외
        if (next != .r_curly and next != .comma and
            (next == .identifier or next == .string_literal or next.isKeyword()))
        {
            const saved = self.saveState();
            try self.advance(); // tentatively skip 'type'
            if (self.isContextual("as")) {
                const after_as = try self.peekNextKind();
                if (after_as == .r_curly or after_as == .comma) {
                    // "export { type as }" — 'as'가 local name, type modifier 확정
                    is_type_only = 1;
                } else if (after_as == .identifier or after_as == .string_literal or after_as.isKeyword()) {
                    const saved2 = self.saveState();
                    try self.advance(); // skip 'as'
                    if (try resolveTypeAsAs(self, saved, saved2)) {
                        is_type_only = 1;
                    }
                } else {
                    self.restoreState(saved);
                }
            } else {
                is_type_only = 1;
                // 'type' modifier 확정 — 이미 advance됨
            }
        }
    }

    const local = try self.parseModuleExportName();

    var exported = local;
    if (try self.eatContextual("as")) {
        exported = try self.parseModuleExportName();
    }

    return try self.ast.addNode(.{
        .tag = .export_specifier,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = local, .right = exported, .flags = is_type_only } },
    });
}

/// "type as as ..." 패턴을 판별한다.
/// import/export 양쪽에서 동일한 로직: 4번째 토큰이 } 또는 ,이면
/// 'type'은 값 이름 (modifier 아님), 그 외면 type modifier 확정.
/// 반환: true = type modifier 확정 (saved2로 복원), false = modifier 아님 (saved로 복원)
fn resolveTypeAsAs(self: *Parser, saved: Parser.ScannerState, saved2: Parser.ScannerState) ParseError2!bool {
    if (self.isContextual("as")) {
        const after_second_as = try self.peekNextKind();
        if (after_second_as == .r_curly or after_second_as == .comma) {
            // "type as as }" — 'type'은 값 이름 (modifier 아님)
            self.restoreState(saved);
            return false;
        } else {
            // "type as as foo" — type modifier 확정
            self.restoreState(saved2);
            return true;
        }
    } else {
        // "type as alias" — 'type'은 값 이름, modifier 아님
        self.restoreState(saved);
        return false;
    }
}

fn parseModuleSource(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .string_literal) {
        try self.advance();
        // import attributes: with { type: 'json' } 또는 assert { type: 'json' }
        try skipImportAttributes(self);
        return try self.ast.addNode(.{
            .tag = .string_literal,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    try self.addError(span, "Module source string expected");
    return NodeIndex.none;
}

/// import attributes (with/assert { ... })를 파싱한다.
/// AST에 저장하지 않고 소비만 한다 (트랜스포머에서 필요 시 추가).
/// 중복 키 검사도 수행한다 (ECMAScript: WithClauseToAttributes 중복 에러).
fn skipImportAttributes(self: *Parser) !void {
    // with { ... }: 줄바꿈 허용 (ECMAScript: AttributesKeyword = with)
    // assert { ... }: 줄바꿈 불허 (ECMAScript: [no LineTerminator here] assert)
    const is_with = self.current() == .kw_with;
    const is_assert = self.isContextual("assert") and !self.scanner.token.has_newline_before;
    if (!is_with and !is_assert) return;

    try self.advance(); // skip with/assert
    if (self.current() == .l_curly) {
        try self.advance(); // skip {

        // 중복 키 검사를 위한 키 수집 (최대 16개, 초과 시 검사 생략)
        var keys: [16][]const u8 = undefined;
        var key_spans: [16]Span = undefined;
        var key_count: usize = 0;

        while (self.current() != .r_curly and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            // key: identifier 또는 string literal
            const key_span = self.currentSpan();
            const key_text = self.ast.source[key_span.start..key_span.end];
            try self.advance(); // key

            // 중복 키 검사
            if (key_count < 16) {
                // 키 값 결정: string literal은 따옴표 제거 후 escape 해석
                var decoded_buf: [256]u8 = undefined;
                const effective_key = if (key_text.len >= 2 and (key_text[0] == '\'' or key_text[0] == '"'))
                    decodeStringKey(key_text[1 .. key_text.len - 1], &decoded_buf)
                else
                    key_text;

                for (0..key_count) |i| {
                    if (std.mem.eql(u8, keys[i], effective_key)) {
                        try self.addError(key_span, "Duplicate import attribute key");
                        break;
                    }
                }
                keys[key_count] = effective_key;
                key_spans[key_count] = key_span;
                key_count += 1;
            }

            _ = try self.eat(.colon);
            if (self.current() != .r_curly and self.current() != .eof) {
                try self.advance(); // value
            }
            _ = try self.eat(.comma);

            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }
        _ = try self.eat(.r_curly);
    }
}

/// import attribute 키의 unicode escape를 해석한다.
/// 예: "typ\u0065" → "type"
/// buf에 결과를 쓰고, escape가 없으면 원본 슬라이스를 반환.
fn decodeStringKey(input: []const u8, buf: *[256]u8) []const u8 {
    // escape가 없으면 원본 그대로 반환 (빠른 경로)
    if (std.mem.indexOf(u8, input, "\\") == null) return input;

    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len and out < 256) {
        if (input[i] == '\\' and i + 1 < input.len) {
            if (input[i + 1] == 'u') {
                // \uHHHH
                if (i + 5 < input.len) {
                    i += 2; // skip \u
                    var codepoint: u21 = 0;
                    var valid = true;
                    for (0..4) |_| {
                        if (i >= input.len) {
                            valid = false;
                            break;
                        }
                        const c = input[i];
                        const digit: u21 = if (c >= '0' and c <= '9')
                            c - '0'
                        else if (c >= 'a' and c <= 'f')
                            c - 'a' + 10
                        else if (c >= 'A' and c <= 'F')
                            c - 'A' + 10
                        else {
                            valid = false;
                            break;
                        };
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                    if (valid and codepoint < 128 and out < 256) {
                        buf[out] = @intCast(codepoint);
                        out += 1;
                    }
                    continue;
                }
            }
            // 기타 escape: 그대로 복사
            if (out < 256) {
                buf[out] = input[i + 1];
                out += 1;
            }
            i += 2;
        } else {
            if (out < 256) {
                buf[out] = input[i];
                out += 1;
            }
            i += 1;
        }
    }
    return buf[0..out];
}

// ============================================================
// Inline scan helpers — enable_scan=true일 때 파서가 호출
// ============================================================

/// 문자열 리터럴 텍스트에서 따옴표를 제거한다.
/// import_scanner.stripQuotes에 위임한다.
fn stripImportQuotes(text: []const u8) []const u8 {
    return import_scanner.stripQuotes(text) orelse text;
}

/// import 선언에서 수집한 specifier들의 바인딩을 scan_import_bindings에 추가한다.
/// scratch_top..scratch.items.len 범위의 specifier 노드를 순회한다.
fn collectImportBindings(self: *Parser, scratch_top: usize, rec_idx: u32) void {
    for (self.scratch.items[scratch_top..]) |spec_idx| {
        if (spec_idx.isNone()) continue;
        if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
        const spec_node = self.ast.getNode(spec_idx);
        switch (spec_node.tag) {
            .import_default_specifier => {
                self.scan_import_bindings.append(self.allocator, .{
                    .kind = .default,
                    .local_name = self.ast.source[spec_node.span.start..spec_node.span.end],
                    .imported_name = "default",
                    .local_span = spec_node.span,
                    .import_record_index = rec_idx,
                }) catch {};
            },
            .import_namespace_specifier => {
                self.scan_import_bindings.append(self.allocator, .{
                    .kind = .namespace,
                    .local_name = self.ast.source[spec_node.span.start..spec_node.span.end],
                    .imported_name = "*",
                    .local_span = spec_node.span,
                    .import_record_index = rec_idx,
                }) catch {};
            },
            .import_specifier => {
                // binary: left=imported, right=local, flags (flags&1 = type-only)
                if (spec_node.data.binary.flags & 1 != 0) continue; // skip type-only
                const imported_idx = spec_node.data.binary.left;
                const local_idx = spec_node.data.binary.right;
                if (imported_idx.isNone()) continue;

                const imported_node = self.ast.getNode(imported_idx);
                const imported_name = self.ast.source[imported_node.span.start..imported_node.span.end];

                const local_node = if (!local_idx.isNone() and @intFromEnum(local_idx) != @intFromEnum(imported_idx))
                    self.ast.getNode(local_idx)
                else
                    imported_node;
                const local_name = self.ast.source[local_node.span.start..local_node.span.end];

                self.scan_import_bindings.append(self.allocator, .{
                    .kind = .named,
                    .local_name = local_name,
                    .imported_name = imported_name,
                    .local_span = local_node.span,
                    .import_record_index = rec_idx,
                }) catch {};
            },
            else => {},
        }
    }
}

/// import 레코드를 추가하고 인덱스를 반환한다.
fn appendImportRecord(self: *Parser, specifier: []const u8, kind: scan_results_mod.ImportKind, span: Span) u32 {
    const rec_idx: u32 = @intCast(self.scan_import_records.items.len);
    self.scan_import_records.append(self.allocator, .{
        .specifier = specifier,
        .kind = kind,
        .span = span,
    }) catch {};
    return rec_idx;
}

/// export 선언 내부의 declaration 노드에서 export binding을 추출한다.
/// variable_declaration, function_declaration, class_declaration을 처리한다.
fn collectDeclExportBindings(self: *Parser, decl_idx: NodeIndex) void {
    if (decl_idx.isNone()) return;
    if (@intFromEnum(decl_idx) >= self.ast.nodes.items.len) return;
    const decl_node = self.ast.getNode(decl_idx);

    switch (decl_node.tag) {
        .variable_declaration => {
            // extra [kind_flags, list.start, list.len]
            const e = decl_node.data.extra;
            if (e + 2 >= self.ast.extra_data.items.len) return;
            const list_start = self.ast.extra_data.items[e + 1];
            const list_len = self.ast.extra_data.items[e + 2];
            if (list_len == 0) return;

            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const idx = list_start + i;
                if (idx >= self.ast.extra_data.items.len) break;
                const d_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[idx]);
                if (d_idx.isNone()) continue;
                if (@intFromEnum(d_idx) >= self.ast.nodes.items.len) continue;
                const d_node = self.ast.getNode(d_idx);
                if (d_node.tag != .variable_declarator) continue;
                // variable_declarator: extra [name, type_ann, init_expr]
                const de = d_node.data.extra;
                if (de >= self.ast.extra_data.items.len) continue;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
                if (name_idx.isNone()) continue;
                if (@intFromEnum(name_idx) >= self.ast.nodes.items.len) continue;
                const name_node = self.ast.getNode(name_idx);

                if (name_node.tag == .object_pattern) {
                    collectObjectPatternExportBindings(self, name_node);
                } else {
                    const name = self.ast.source[name_node.span.start..name_node.span.end];
                    self.scan_export_bindings.append(self.allocator, .{
                        .exported_name = name,
                        .local_name = name,
                        .local_span = name_node.span,
                        .kind = .local,
                    }) catch {};
                }
            }
        },
        .function_declaration, .class_declaration => {
            const e = decl_node.data.extra;
            if (e >= self.ast.extra_data.items.len) return;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (name_idx.isNone()) return;
            const name_node = self.ast.getNode(name_idx);
            const name = self.ast.source[name_node.span.start..name_node.span.end];
            self.scan_export_bindings.append(self.allocator, .{
                .exported_name = name,
                .local_name = name,
                .local_span = name_node.span,
                .kind = .local,
            }) catch {};
        },
        else => {},
    }
}

/// object_pattern에서 export binding name을 추출한다.
fn collectObjectPatternExportBindings(self: *Parser, pattern: Node) void {
    const list = pattern.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > self.ast.extra_data.items.len) return;
    const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const prop_idx: NodeIndex = @enumFromInt(raw_idx);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) continue;
        const prop = self.ast.getNode(prop_idx);
        if (prop.tag == .binding_property) {
            const key = self.ast.getNode(prop.data.binary.left);
            const name = self.ast.source[key.span.start..key.span.end];
            self.scan_export_bindings.append(self.allocator, .{
                .exported_name = name,
                .local_name = name,
                .local_span = key.span,
                .kind = .local,
            }) catch {};
        }
    }
}

/// local_name이 import binding에 존재하면 barrel re-export로 분류한다.
/// 반환: { kind, import_record_index, local_name } — re-export이면 imported_name으로 교체.
fn checkBarrelReExport(self: *Parser, local_name: []const u8) struct {
    kind: scan_results_mod.ExportBindingKind,
    import_record_index: ?u32,
    local_name: []const u8,
} {
    // lazy 구축: 첫 호출 시 local_name → 인덱스 맵 생성 (O(n) → O(1) 조회)
    if (self.scan_import_binding_map.count() == 0 and self.scan_import_bindings.items.len > 0) {
        for (self.scan_import_bindings.items, 0..) |ib, i| {
            if (ib.kind != .namespace) {
                self.scan_import_binding_map.put(self.allocator, ib.local_name, @intCast(i)) catch {};
            }
        }
    }

    if (self.scan_import_binding_map.get(local_name)) |idx| {
        const ib = self.scan_import_bindings.items[idx];
        return .{
            .kind = .re_export,
            .import_record_index = ib.import_record_index,
            .local_name = ib.imported_name,
        };
    }
    return .{
        .kind = .local,
        .import_record_index = null,
        .local_name = local_name,
    };
}
