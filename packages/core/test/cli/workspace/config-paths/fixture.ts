import { join, mkdirSync, mkdtempSync, tmpdir, writeFileSync } from '../../helpers';

export function createWorkspaceFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-'));
  writeFileSync(
    join(dir, 'zntc.config.json'),
    JSON.stringify({ format: 'esm', logLevel: 'silent' }),
  );
  mkdirSync(join(dir, 'packages', 'app'), { recursive: true });
  writeFileSync(join(dir, 'packages', 'app', 'package.json'), JSON.stringify({ name: 'my-app' }));
  writeFileSync(join(dir, 'packages', 'app', 'entry.ts'), "console.log('app');");
  writeFileSync(
    join(dir, 'packages', 'app', 'zntc.config.json'),
    JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './dist' }),
  );
  mkdirSync(join(dir, 'packages', 'lib'));
  writeFileSync(join(dir, 'packages', 'lib', 'package.json'), JSON.stringify({ name: 'my-lib' }));
  writeFileSync(join(dir, 'packages', 'lib', 'entry.ts'), "console.log('lib');");
  writeFileSync(
    join(dir, 'packages', 'lib', 'zntc.config.json'),
    JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './out' }),
  );
  mkdirSync(join(dir, 'shared'));
  writeFileSync(join(dir, 'shared', 'x.ts'), "console.log('shared');");
  writeFileSync(
    join(dir, 'zntc.workspace.json'),
    JSON.stringify([
      './packages/app',
      './packages/lib',
      { name: 'inline-shared', entryPoints: ['./shared/x.ts'], outdir: './shared/dist' },
    ]),
  );
  return dir;
}
