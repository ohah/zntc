import {
  describe,
  test,
  expect,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
  runNodeEval,
} from '../../helpers';

type Fixture = {
  name: string;
  source: string;
  expected: string;
  mapping?: Record<string, string>;
  noConfig?: boolean;
  mapped?: boolean;
};

const cases: Fixture[] = [
  {
    name: 'single named',
    source: "import {map} from './library.mjs';console.log(map)",
    expected: '43',
    mapped: true,
  },
  {
    name: 'multiple named',
    source: "import {map,filter} from './library.mjs';console.log(map+filter)",
    expected: '45',
    mapped: true,
  },
  {
    name: 'escaped named',
    source: String.raw`import {m\u0061p} from './library.mjs';console.log(map)`,
    expected: '43',
    mapped: true,
  },
  {
    name: 'binding shadow',
    source:
      "import {map} from './library.mjs';function read(map){return map};console.log(map+read(1))",
    expected: '44',
    mapped: true,
  },
  {
    name: 'alias excluded',
    source: "import {map as chosen} from './library.mjs';console.log(chosen)",
    expected: '42',
  },
  {
    name: 'default excluded',
    source: "import map from './library.mjs';console.log(map)",
    expected: '42',
  },
  {
    name: 'namespace excluded',
    source: "import * as values from './library.mjs';console.log(values.map)",
    expected: '42',
  },
  {
    name: 'unmapped source',
    source: "import {map} from './library.mjs';console.log(map)",
    mapping: { './other.mjs': './parts/{name}.mjs' },
    expected: '42',
  },
  {
    name: 'empty mapping',
    source: "import {map} from './library.mjs';console.log(map)",
    mapping: {},
    expected: '42',
  },
  {
    name: 'no config',
    source: "import {map} from './library.mjs';console.log(map)",
    noConfig: true,
    expected: '42',
  },
];

describe('CLI config moduleSpecifierMap', () => {
  for (const fixture of cases)
    for (const minify of [false, true]) {
      test(`${fixture.name}, minify=${minify}`, () => {
        const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-module-map-'));
        try {
          mkdirSync(join(dir, 'parts'));
          writeFileSync(join(dir, 'entry.mjs'), fixture.source);
          writeFileSync(
            join(dir, 'library.mjs'),
            'export const map=42,filter=1;export default 42;',
          );
          writeFileSync(join(dir, 'parts/map.mjs'), 'export default 43;');
          writeFileSync(join(dir, 'parts/filter.mjs'), 'export default 2;');
          writeFileSync(
            join(dir, 'zntc.config.json'),
            JSON.stringify({
              moduleSpecifierMap: fixture.mapping ?? { './library.mjs': './parts/{name}.mjs' },
            }),
          );
          const args = [
            '--bundle',
            'entry.mjs',
            '--format=cjs',
            '--outfile',
            'output.cjs',
            '--metafile=meta.json',
          ];
          if (fixture.noConfig) args.push('--no-config');
          if (minify) args.push('--minify');
          const built = runCli(args, { cwd: dir });
          expect(built.exitCode).toBe(0);
          const metadata = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
          const mappedInputs = Object.keys(metadata.inputs).filter((input) =>
            input.includes('parts/'),
          );
          expect(mappedInputs.length > 0).toBe(!!fixture.mapped);
          const source = readFileSync(join(dir, 'output.cjs'), 'utf8');
          const run = runNodeEval(source, { cwd: dir });
          expect(run.exitCode).toBe(0);
          expect(run.stdout.trim()).toBe(fixture.expected);
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      });
    }
});
