import { expect } from 'bun:test';
import type { OutputFile } from '../../../index';

const SOURCE_MAP_VLQ_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function encodeSourceMapVlq(value: number): string {
  let vlq = value < 0 ? (-value << 1) | 1 : value << 1;
  let out = '';
  do {
    let digit = vlq & 31;
    vlq >>>= 5;
    if (vlq > 0) digit |= 32;
    out += SOURCE_MAP_VLQ_CHARS[digit];
  } while (vlq > 0);
  return out;
}

export function lineOffsetMappings(
  generatedStart: number,
  originalStart: number,
  lineCount: number,
) {
  const lines = Array.from({ length: generatedStart + lineCount }, () => '');
  let prevSource = 0;
  let prevOriginalLine = 0;
  let prevOriginalColumn = 0;
  for (let i = 0; i < lineCount; i++) {
    const originalLine = originalStart + i;
    lines[generatedStart + i] =
      encodeSourceMapVlq(0) +
      encodeSourceMapVlq(0 - prevSource) +
      encodeSourceMapVlq(originalLine - prevOriginalLine) +
      encodeSourceMapVlq(0 - prevOriginalColumn);
    prevSource = 0;
    prevOriginalLine = originalLine;
    prevOriginalColumn = 0;
  }
  return lines.join(';');
}

export function decodeSourceMapVlq(segment: string): number[] {
  const out: number[] = [];
  let value = 0;
  let shift = 0;
  for (const ch of segment) {
    const digit = SOURCE_MAP_VLQ_CHARS.indexOf(ch);
    if (digit < 0) throw new Error(`bad vlq char ${ch}`);
    value |= (digit & 31) << shift;
    shift += 5;
    if ((digit & 32) === 0) {
      const signed = value & 1 ? -(value >> 1) : value >> 1;
      out.push(signed);
      value = 0;
      shift = 0;
    }
  }
  return out;
}

export interface DecodedSourceMapSegment {
  genCol: number;
  sourceIndex: number;
  srcLine: number;
  srcCol: number;
}

export function decodeSourceMapMappings(mappings: string): DecodedSourceMapSegment[][] {
  const lines: DecodedSourceMapSegment[][] = [];
  let prevSource = 0;
  let prevSourceLine = 0;
  let prevSourceColumn = 0;
  for (const line of mappings.split(';')) {
    const segments: DecodedSourceMapSegment[] = [];
    let prevGeneratedColumn = 0;
    for (const rawSegment of line.split(',')) {
      if (!rawSegment) continue;
      const fields = decodeSourceMapVlq(rawSegment);
      prevGeneratedColumn += fields[0] ?? 0;
      if (fields.length >= 4) {
        prevSource += fields[1];
        prevSourceLine += fields[2];
        prevSourceColumn += fields[3];
        segments.push({
          genCol: prevGeneratedColumn,
          sourceIndex: prevSource,
          srcLine: prevSourceLine,
          srcCol: prevSourceColumn,
        });
      }
    }
    lines.push(segments);
  }
  return lines;
}

export function lookupSourceMapSegment(
  decoded: DecodedSourceMapSegment[][],
  line: number,
  column: number,
) {
  let found: DecodedSourceMapSegment | null = null;
  for (const segment of decoded[line] ?? []) {
    if (segment.genCol > column) break;
    found = segment;
  }
  return found;
}

export function findTextPosition(text: string, needle: string) {
  const index = text.indexOf(needle);
  expect(index).toBeGreaterThanOrEqual(0);
  const prefix = text.slice(0, index);
  const lines = prefix.split('\n');
  return { line: lines.length - 1, column: lines.at(-1)!.length };
}

export function parseBundleMap(result: { outputFiles: OutputFile[] }) {
  const jsFile =
    result.outputFiles.find((file) => file.path.endsWith('.js')) ?? result.outputFiles[0];
  const mapFile = result.outputFiles.find((f) => f.path.endsWith('.map'));
  expect(mapFile).toBeDefined();
  return { code: jsFile.text, map: JSON.parse(mapFile!.text) };
}

export function expectMarkerMappedToSourceLine(
  result: { outputFiles: OutputFile[] },
  marker: string,
  expectedSource: string,
  expectedLine: number,
) {
  const { code, map } = parseBundleMap(result);
  const generated = findTextPosition(code, marker);
  const segment = lookupSourceMapSegment(
    decodeSourceMapMappings(map.mappings ?? ''),
    generated.line,
    generated.column,
  );
  expect(segment).not.toBeNull();
  expect(map.sources[segment!.sourceIndex]).toContain(expectedSource);
  expect(segment!.srcLine).toBe(expectedLine);
}
