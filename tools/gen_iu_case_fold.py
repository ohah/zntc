#!/usr/bin/env python3
# regexpu-core/data/iu-mappings.js (ECMAScript simple case folding, test262 검증)
# → src/regexp/iu_case_fold.zig 생성. 손타이핑 금지 — 레퍼런스 충실 이식.
import re, sys
src = sys.argv[1]; out = sys.argv[2]
txt = open(src, encoding="utf-8").read()
# 엔트리: [KEY, VAL] — VAL = 0xNN | [0xNN, 0xMM, ...] (멀티라인 가능)
pat = re.compile(r'\[\s*(0x[0-9A-Fa-f]+)\s*,\s*(0x[0-9A-Fa-f]+|\[[^\]]*\])\s*\]', re.S)
hexes = re.compile(r'0x[0-9A-Fa-f]+')
entries = []
for m in pat.finditer(txt):
    key = int(m.group(1), 16)
    raw = m.group(2)
    vals = [int(h, 16) for h in hexes.findall(raw)]
    entries.append((key, vals))
entries.sort(key=lambda e: e[0])
assert len({k for k, _ in entries}) == len(entries), "dup key"
lines = []
lines.append("//! ECMAScript simple case-fold 등가 매핑 (i+u flag downlevel, #3511).")
lines.append("//!")
lines.append("//! 자동 생성 — 절대 손수정 금지. 소스: regexpu-core/data/iu-mappings.js")
lines.append("//! (Unicode 17.0.0, test262 검증된 babel 가공 데이터). 재생성:")
lines.append("//!   python3 tools/gen_iu_case_fold.py <iu-mappings.js> src/regexp/iu_case_fold.zig")
lines.append("//! ASCII A-Z↔a-z 는 테이블 제외(호출부 fast-path).")
lines.append("")
lines.append("const std = @import(\"std\");")
lines.append("")
lines.append("const Entry = struct { cp: u32, eq: []const u32 };")
lines.append("")
lines.append("/// cp 오름차순 정렬 (binary search). babel iuMappings 동형.")
lines.append("const TABLE = [_]Entry{")
for k, vs in entries:
    vlist = ", ".join("0x{:X}".format(v) for v in vs)
    lines.append("    .{{ .cp = 0x{:X}, .eq = &.{{ {} }} }},".format(k, vlist))
lines.append("};")
lines.append("")
lines.append("/// cp 의 simple case-fold 등가 codepoint 들 (ASCII fast-path 포함).")
lines.append("/// out 에 append. 자기 자신은 호출부가 이미 보유하므로 제외.")
lines.append("pub fn hasEntry(cp: u32) bool {{
    var lo: usize = 0;
    var hi: usize = TABLE.len;
    while (lo < hi) {{
        const mid = lo + (hi - lo) / 2;
        if (TABLE[mid].cp == cp) return true;
        if (TABLE[mid].cp < cp) lo = mid + 1 else hi = mid;
    }}
    return false;
}}

pub fn appendEquivalents(cp: u32, out: *std.ArrayList(u32), a: std.mem.Allocator) !void {")
lines.append("    // ASCII swap 은 추가(early-return 아님) — k/K/s/S 는 테이블에도 존재")
lines.append("    // (Kelvin U+212A, ſ U+017F). regexpu getCaseEquivalents 와 동형.")
lines.append("    if (cp >= 'A' and cp <= 'Z') {")
lines.append("        try out.append(a, cp + 0x20);")
lines.append("    } else if (cp >= 'a' and cp <= 'z') {")
lines.append("        try out.append(a, cp - 0x20);")
lines.append("    }")
lines.append("    var lo: usize = 0;")
lines.append("    var hi: usize = TABLE.len;")
lines.append("    while (lo < hi) {")
lines.append("        const mid = lo + (hi - lo) / 2;")
lines.append("        if (TABLE[mid].cp == cp) {")
lines.append("            try out.appendSlice(a, TABLE[mid].eq);")
lines.append("            return;")
lines.append("        } else if (TABLE[mid].cp < cp) lo = mid + 1 else hi = mid;")
lines.append("    }")
lines.append("}")
lines.append("")
open(out, "w", encoding="utf-8").write("\n".join(lines))
print(f"generated {out}: {len(entries)} entries")
