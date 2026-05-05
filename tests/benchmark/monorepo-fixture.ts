import { mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';

export interface SyntheticMonorepoOptions {
  packageCount: number;
  modulesPerPackage: number;
}

export interface SyntheticMonorepoFixture {
  entry: string;
  moduleCount: number;
  packageCount: number;
  packages: string[];
}

export interface ProfileRun {
  totalMs: number;
  phases: Record<string, number>;
}

export function makeSyntheticMonorepo(
  root: string,
  options: SyntheticMonorepoOptions,
): SyntheticMonorepoFixture {
  if (options.packageCount < 1) throw new Error('packageCount must be >= 1');
  if (options.modulesPerPackage < 1) throw new Error('modulesPerPackage must be >= 1');

  mkdirSync(join(root, 'apps', 'app', 'src'), { recursive: true });
  mkdirSync(join(root, 'packages'), { recursive: true });
  mkdirSync(join(root, 'node_modules', '@zts-fixture'), { recursive: true });

  writeFileSync(
    join(root, 'package.json'),
    JSON.stringify(
      { private: true, workspaces: ['apps/*', 'packages/*'], type: 'module' },
      null,
      2,
    ),
  );
  writeFileSync(
    join(root, 'tsconfig.json'),
    JSON.stringify(
      {
        compilerOptions: {
          target: 'es2020',
          module: 'esnext',
          moduleResolution: 'bundler',
          strict: true,
        },
      },
      null,
      2,
    ),
  );

  const packages: string[] = [];
  for (let p = 0; p < options.packageCount; p++) {
    const pkgName = `@zts-fixture/pkg-${p}`;
    packages.push(pkgName);
    const pkgDir = join(root, 'packages', `pkg-${p}`);
    const srcDir = join(pkgDir, 'src');
    mkdirSync(srcDir, { recursive: true });
    writeFileSync(
      join(pkgDir, 'package.json'),
      JSON.stringify(
        { name: pkgName, version: '0.0.0', type: 'module', exports: './src/index.ts' },
        null,
        2,
      ),
    );

    const indexLines: string[] = [];
    for (let m = 0; m < options.modulesPerPackage; m++) {
      const prevImport = m === 0 ? '' : `import { v${p}_${m - 1} } from "./mod-${m - 1}";\n`;
      const crossImport =
        m === 0 && p > 0
          ? `import { pkgValue as prevPkgValue } from "@zts-fixture/pkg-${p - 1}";\n`
          : '';
      const prevValue = m === 0 ? (p > 0 ? 'prevPkgValue' : '0') : `v${p}_${m - 1}`;
      writeFileSync(
        join(srcDir, `mod-${m}.ts`),
        `${crossImport}${prevImport}export const v${p}_${m}: number = ${prevValue} + ${p + m + 1};\n`,
      );
      indexLines.push(`export { v${p}_${m} } from "./mod-${m}";`);
    }
    indexLines.push(
      `export { v${p}_${options.modulesPerPackage - 1} as pkgValue } from "./mod-${options.modulesPerPackage - 1}";`,
    );
    writeFileSync(join(srcDir, 'index.ts'), indexLines.join('\n') + '\n');

    const linkPath = join(root, 'node_modules', '@zts-fixture', `pkg-${p}`);
    try {
      symlinkSync(relative(join(root, 'node_modules', '@zts-fixture'), pkgDir), linkPath, 'dir');
    } catch (err) {
      // Windows 는 비-Admin 에서 dir symlink 가 EPERM, 같은 경로 재실행이면 EEXIST.
      // 그 외 에러는 fixture 셋업 자체의 버그라 surface 시킨다.
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== 'EPERM' && code !== 'EEXIST') throw err;
      const proxySrcDir = join(linkPath, 'src');
      mkdirSync(proxySrcDir, { recursive: true });
      writeFileSync(
        join(linkPath, 'package.json'),
        JSON.stringify(
          { name: pkgName, version: '0.0.0', type: 'module', exports: './src/index.ts' },
          null,
          2,
        ),
      );
      writeFileSync(
        join(proxySrcDir, 'index.ts'),
        `export * from "${relative(proxySrcDir, join(srcDir, 'index.ts')).replaceAll('\\', '/')}";\n`,
      );
    }
  }

  const entryLines: string[] = [];
  for (let p = 0; p < options.packageCount; p++) {
    entryLines.push(`import { pkgValue as pkg${p} } from "@zts-fixture/pkg-${p}";`);
  }
  entryLines.push(
    `console.log(${Array.from({ length: options.packageCount }, (_, p) => `pkg${p}`).join(' + ')});`,
  );
  const entry = join(root, 'apps', 'app', 'src', 'entry.ts');
  writeFileSync(entry, entryLines.join('\n') + '\n');

  return {
    entry,
    moduleCount: options.packageCount * options.modulesPerPackage + options.packageCount + 1,
    packageCount: options.packageCount,
    packages,
  };
}

export function parseProfileOutput(output: string): ProfileRun {
  const phases: Record<string, number> = {};
  let totalMs = 0;

  for (const line of output.split('\n')) {
    const m = line.match(/^([\w.]+)\s+([\d.]+)ms\s+/);
    if (!m) continue;
    const [, phase, msStr] = m;
    const ms = Number.parseFloat(msStr);
    if (phase === 'total') totalMs = ms;
    else phases[phase] = ms;
  }

  if (totalMs === 0) {
    throw new Error('profile output did not contain total phase');
  }
  return { totalMs, phases };
}
