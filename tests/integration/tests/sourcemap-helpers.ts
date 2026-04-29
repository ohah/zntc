/// Sourcemap 디코드/lookup 공용 헬퍼.
/// 여러 sourcemap 검증 테스트가 공유.
const VLQ_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** base64 VLQ 시퀀스를 부호 있는 정수 배열로 디코드. */
export function decodeVlq(s: string): number[] {
  const out: number[] = [];
  let value = 0,
    shift = 0;
  for (let i = 0; i < s.length; i++) {
    const digit = VLQ_CHARS.indexOf(s[i]);
    if (digit < 0) throw new Error(`bad vlq char ${s[i]}`);
    const cont = digit & 32;
    value |= (digit & 31) << shift;
    shift += 5;
    if (!cont) {
      const sign = value & 1;
      value >>= 1;
      out.push(sign ? -value : value);
      value = 0;
      shift = 0;
    }
  }
  return out;
}

export interface Segment {
  genCol: number;
  srcLine: number;
  srcCol: number;
}

/** sourcemap `mappings` 필드를 줄별 segment 배열로 디코드 (genLine 은 배열 index). */
export function decodeMappings(mappings: string): Segment[][] {
  const lines: Segment[][] = [];
  let prevSrcLine = 0,
    prevSrcCol = 0;
  for (const lineStr of mappings.split(";")) {
    const segs: Segment[] = [];
    let prevGenCol = 0;
    for (const seg of lineStr.split(",")) {
      if (!seg) continue;
      const v = decodeVlq(seg);
      prevGenCol += v[0] || 0;
      const tuple: Segment = { genCol: prevGenCol, srcLine: prevSrcLine, srcCol: prevSrcCol };
      if (v.length >= 4) {
        prevSrcLine += v[2];
        prevSrcCol += v[3];
        tuple.srcLine = prevSrcLine;
        tuple.srcCol = prevSrcCol;
      }
      segs.push(tuple);
    }
    lines.push(segs);
  }
  return lines;
}

/** debugger-style lookup: genLine 의 segment 중 genCol 이 target 보다 작거나 같은 마지막 것을 반환. */
export function lookupMapping(
  mappings: Segment[][],
  genLine: number,
  genCol: number,
): Segment | null {
  if (genLine >= mappings.length) return null;
  let found: Segment | null = null;
  for (const s of mappings[genLine]) {
    if (s.genCol > genCol) break;
    found = s;
  }
  return found;
}

export interface MarkerHit {
  line: number;
  col: number;
  name: string;
}

/** `MARKER_*` 식별자 위치를 텍스트에서 모두 추출. round5 sourcemap 회귀 테스트 용. */
export function findMarkers(text: string): MarkerHit[] {
  const hits: MarkerHit[] = [];
  const lines = text.split("\n");
  for (let li = 0; li < lines.length; li++) {
    const re = /\bMARKER_[A-Z_]+\b/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(lines[li])) !== null) {
      hits.push({ line: li, col: m.index, name: m[0] });
    }
  }
  return hits;
}
