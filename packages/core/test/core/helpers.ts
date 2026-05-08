import { afterAll as setupAfterAll, beforeAll as setupBeforeAll } from 'bun:test';
import { close, init } from '../../index';

setupBeforeAll(() => {
  init();
});

setupAfterAll(() => {
  close();
});

export { afterAll, beforeAll, describe, expect, test } from 'bun:test';
export { build, buildSync, close, init, transpile, vitePlugin, watch } from '../../index';
export type { OutputFile, RollupPlugin, ZntcPlugin } from '../../index';
export {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
export { join, resolve } from 'node:path';
export { tmpdir } from 'node:os';

export { ROOT_NODE_MODULES } from './helpers/paths';
export { diagText, expectPluginDiagnostic } from './helpers/diagnostics';
export {
  encodeSourceMapVlq,
  lineOffsetMappings,
  decodeSourceMapVlq,
  decodeSourceMapMappings,
  lookupSourceMapSegment,
  findTextPosition,
  parseBundleMap,
  expectMarkerMappedToSourceLine,
} from './helpers/source-map';
export type { DecodedSourceMapSegment } from './helpers/source-map';
export { runBundleStdout } from './helpers/runtime';
