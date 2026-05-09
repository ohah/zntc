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

describe('@zntc/core buildSync - basic output errors and external', () => {
  test('에러 반환', () => {
    const badDir = mkdtempSync(join(tmpdir(), 'zntc-napi-err-'));
    try {
      writeFileSync(join(badDir, 'bad.ts'), 'import { x } from "./nonexistent";\nconsole.log(x);');
      const result = buildSync({ entryPoints: [join(badDir, 'bad.ts')] });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(badDir, { recursive: true, force: true });
    }
  });

  test('external', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-napi-ext-'));
    try {
      writeFileSync(join(extDir, 'app.ts'), 'import React from "react";\nconsole.log(React);');
      const result = buildSync({
        entryPoints: [join(extDir, 'app.ts')],
        external: ['react'],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('react');
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });
});
