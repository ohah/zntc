import {
  describe,
  test,
  expect,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: bundle resolution options', () => {
  test('번들 + --node-paths=<csv> 추가 lookup directory에서 bare specifier resolve', () => {
    const npDir = mkdtempSync(join(tmpdir(), 'zntc-cli-node-paths-'));
    try {
      const vendor = join(npDir, 'vendor');
      mkdirSync(join(vendor, 'pkg'), { recursive: true });
      writeFileSync(join(vendor, 'pkg', 'package.json'), JSON.stringify({ main: 'index.js' }));
      writeFileSync(join(vendor, 'pkg', 'index.js'), "export const value = 'NODE_PATH_VALUE';");
      writeFileSync(join(npDir, 'entry.ts'), "import { value } from 'pkg'; console.log(value);");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(npDir, 'entry.ts'),
        `--node-paths=${vendor}`,
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('NODE_PATH_VALUE');
    } finally {
      rmSync(npDir, { recursive: true, force: true });
    }
  });

  test('번들 + --conditions=<csv> custom exports condition 적용', () => {
    const condDir = mkdtempSync(join(tmpdir(), 'zntc-cli-conditions-'));
    try {
      mkdirSync(join(condDir, 'node_modules', 'pkg'), { recursive: true });
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'package.json'),
        JSON.stringify({
          name: 'pkg',
          exports: {
            '.': {
              custom: './custom.js',
              default: './default.js',
            },
          },
        }),
      );
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'custom.js'),
        "export const value = 'custom';",
      );
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'default.js'),
        "export const value = 'default';",
      );
      writeFileSync(join(condDir, 'entry.ts'), "import { value } from 'pkg'; console.log(value);");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(condDir, 'entry.ts'),
        '--conditions=custom',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('custom');
      expect(stdout).not.toContain('default');
    } finally {
      rmSync(condDir, { recursive: true, force: true });
    }
  });

  test('번들 + --external', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-ext-'));
    try {
      writeFileSync(join(extDir, 'app.ts'), 'import React from "react";\nconsole.log(React);');
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(extDir, 'app.ts'),
        '--external',
        'react',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('react');
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });

  test('번들 + --packages=external 은 bare package만 external 처리', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-packages-ext-'));
    try {
      writeFileSync(
        join(extDir, 'app.ts'),
        'import React from "react";\nimport { local } from "./local";\nconsole.log(React, local);',
      );
      writeFileSync(join(extDir, 'local.ts'), "export const local = 'LOCAL_INCLUDED';");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(extDir, 'app.ts'),
        '--packages=external',
        '--format=esm',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('"react"');
      expect(stdout).toContain('LOCAL_INCLUDED');
      expect(stdout).not.toContain('from "./local"');
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });
});
