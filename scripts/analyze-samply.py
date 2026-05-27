#!/usr/bin/env python3
"""samply profile.json + presymbolicate sidecar 를 분석해 함수별 self/inclusive sample 수를 표로 출력.

사용법:
  python3 scripts/analyze-samply.py [profile_dir] [--top N] [--filter SUBSTR]

profile_dir 의 기본값은 /tmp/zntc-samply 이고 scripts/profile-parse-samply.sh 가 만들어둔
profile.json.gz + profile.json.syms.json 쌍을 가정한다. samply 의 `--unstable-presymbolicate`
플래그가 켜져 있어야 .syms.json 가 같이 생성된다.

매핑 흐름:
  thread.samples.stack[i] -> stackTable.frame[stack] -> frameTable.address[frame] (lib-relative RVA)
  syms.data[lib].known_addresses[(addr, sym_idx)] -> syms.data[lib].symbol_table[sym_idx]
  symbol_table.{symbol, frames[-1].function} -> syms.string_table -> 실 함수명.

samply UI 가 같은 매핑을 lazy 하게 적용하지만, CLI 에서 한 번에 전체 self/inclusive 표를
보고 싶을 때 본 스크립트가 더 편하다 (특히 회귀 비교 시).
"""
from __future__ import annotations

import argparse
import gzip
import json
import sys
from collections import Counter
from pathlib import Path


def load_profile(profile_dir: Path):
    profile_path = profile_dir / "profile.json.gz"
    syms_path = profile_dir / "profile.json.syms.json"
    if not profile_path.exists():
        sys.exit(f"error: {profile_path} not found. run scripts/profile-parse-samply.sh first.")
    if not syms_path.exists():
        sys.exit(
            f"error: {syms_path} not found. samply must have been invoked with "
            "--unstable-presymbolicate (scripts/profile-parse-samply.sh handles this)."
        )
    with gzip.open(profile_path, "rt") as fh:
        prof = json.load(fh)
    with syms_path.open() as fh:
        syms = json.load(fh)
    return prof, syms


def build_addr_map(syms: dict) -> tuple[dict[int, tuple[str, str]], list]:
    """profile.json frame.address (lib-relative RVA) -> (lib_name, function_name).

    Note: known_addresses is a union across all libs. samply doesn't currently emit
    enough metadata in --unstable-presymbolicate output for us to identify which lib
    a given frame.address belongs to (frameTable.nativeSymbol[] is null and
    nativeSymbols.length=0 in practice). So this map can in theory mislabel a frame
    if two libs publish the same RVA in their known_addresses lists. We detect those
    collisions and surface them; in observed runs the count is 0, but we warn loudly
    if it ever happens so the table's lib labels aren't silently wrong.
    """
    string_table = syms["string_table"]
    addr_map: dict[int, tuple[str, str]] = {}
    collisions: list = []
    for lib_entry in syms["data"]:
        lib_name = lib_entry.get("debug_name", "?")
        sts = lib_entry.get("symbol_table", [])
        for addr, sym_idx in lib_entry.get("known_addresses", []):
            if not (0 <= sym_idx < len(sts)):
                continue
            sym_entry = sts[sym_idx]
            si = sym_entry.get("symbol", -1)
            name = string_table[si] if 0 <= si < len(string_table) else "<?>"
            frames = sym_entry.get("frames", [])
            if frames:
                fn_idx = frames[-1].get("function")
                if fn_idx is not None and 0 <= fn_idx < len(string_table):
                    name = string_table[fn_idx]
            new_entry = (lib_name, name)
            existing = addr_map.get(addr)
            if existing is not None and existing != new_entry:
                collisions.append((addr, existing, new_entry))
            addr_map[addr] = new_entry
    return addr_map, collisions


def collect_counts(prof: dict, addr_map: dict[int, tuple[str, str]]):
    self_count: Counter[str] = Counter()
    inclusive_count: Counter[str] = Counter()
    total = 0
    unmapped = 0
    for thread in prof["threads"]:
        samples = thread["samples"]
        stack_table = thread["stackTable"]
        frame_addr = thread["frameTable"]["address"]
        stack_frame = stack_table["frame"]
        stack_prefix = stack_table["prefix"]
        for stack_idx in samples["stack"]:
            if stack_idx is None or stack_idx < 0:
                continue
            total += 1
            chain: list[str] = []
            cur = stack_idx
            while cur is not None and cur >= 0:
                f_idx = stack_frame[cur]
                addr = frame_addr[f_idx]
                # samply currently always writes a non-negative RVA, but guard against
                # 0/-1 sentinels in case the format gains synthesized inline frames.
                if addr is None or addr < 0:
                    chain.append("[?] <synthetic>")
                else:
                    mapped = addr_map.get(addr)
                    if mapped is None:
                        unmapped += 1
                        chain.append(f"[?] <0x{addr:x}>")
                    else:
                        lib, fn = mapped
                        chain.append(f"[{lib}] {fn}")
                cur = stack_prefix[cur]
            if not chain:
                continue
            self_count[chain[0]] += 1
            for name in set(chain):
                inclusive_count[name] += 1
    return total, unmapped, self_count, inclusive_count


def print_table(title: str, counter: Counter[str], total: int, top: int, filt: str | None):
    print(f"=== {title} ===")
    rows = counter.most_common()
    if filt:
        rows = [r for r in rows if filt in r[0]]
    for name, cnt in rows[:top]:
        pct = 100.0 * cnt / total if total else 0.0
        print(f"{cnt:6d} ({pct:5.2f}%)  {name[:150]}")
    print()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profile_dir", nargs="?", default="/tmp/zntc-samply", type=Path)
    ap.add_argument("--top", type=int, default=40, help="number of rows per table (default 40)")
    ap.add_argument("--filter", default=None, help="substring filter applied to function name (case-sensitive)")
    args = ap.parse_args()

    prof, syms = load_profile(args.profile_dir)
    addr_map, collisions = build_addr_map(syms)
    total, unmapped, self_count, inclusive_count = collect_counts(prof, addr_map)

    print(f"profile_dir   : {args.profile_dir}")
    print(f"total samples : {total}  (unmapped frame addresses: {unmapped})")
    if collisions:
        # In observed runs this is 0; if it ever fires the table's lib labels for
        # those RVAs are not reliable and the analyzer needs to be revisited.
        print(
            f"warning       : {len(collisions)} known_addresses collisions across libs "
            "— lib labels for affected RVAs may be wrong.",
            file=sys.stderr,
        )
        for addr, a, b in collisions[:5]:
            print(f"  0x{addr:x}: {a} vs {b}", file=sys.stderr)
    print()
    print_table("Top self count", self_count, total, args.top, args.filter)
    print_table("Top inclusive count", inclusive_count, total, args.top, args.filter)
    return 0


if __name__ == "__main__":
    sys.exit(main())
