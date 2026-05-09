import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

function createBasicFixture(): string {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-napi-build-'));
  writeFileSync(
    join(dir, 'entry.ts'),
    'import { hello } from "./util";\nconsole.log(hello("world"));',
  );
  writeFileSync(
    join(dir, 'util.ts'),
    'export function hello(name: string): string { return `Hello, ${name}!`; }',
  );
  return dir;
}

describe('@zntc/core buildSync - basic output defaults and formats', () => {
  test('기본 번들링', () => {
    const dir = createBasicFixture();
    try {
      const result = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
      expect(result.outputFiles.length).toBeGreaterThan(0);
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('hello');
      expect(result.outputFiles[0].text).toContain('Hello');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('browser bundle defaults process.env.NODE_ENV to production', () => {
    const nodeEnvDir = mkdtempSync(join(tmpdir(), 'zntc-napi-node-env-'));
    try {
      writeFileSync(join(nodeEnvDir, 'entry.ts'), 'console.log(process.env.NODE_ENV);');
      const result = buildSync({ entryPoints: [join(nodeEnvDir, 'entry.ts')] });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('"production"');
      expect(result.outputFiles[0].text).not.toContain('process.env.NODE_ENV');
    } finally {
      rmSync(nodeEnvDir, { recursive: true, force: true });
    }
  });

  test('react-native bundle defaults __DEV__ and NODE_ENV from devMode', () => {
    const rnDir = mkdtempSync(join(tmpdir(), 'zntc-napi-rn-env-'));
    try {
      writeFileSync(join(rnDir, 'entry.ts'), 'console.log(__DEV__, process.env.NODE_ENV);');
      const result = buildSync({
        entryPoints: [join(rnDir, 'entry.ts')],
        platform: 'react-native',
        devMode: true,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('true');
      expect(result.outputFiles[0].text).toContain('"development"');
      expect(result.outputFiles[0].text).not.toContain('__DEV__');
      expect(result.outputFiles[0].text).not.toContain('process.env.NODE_ENV');
    } finally {
      rmSync(rnDir, { recursive: true, force: true });
    }
  });

  test('CJS 포맷', () => {
    const dir = createBasicFixture();
    try {
      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'cjs',
      });
      expect(result.outputFiles[0].text).toContain('use strict');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
