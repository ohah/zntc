import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const native = require(
  join(dirname(fileURLToPath(import.meta.url)), '../../zig-out/lib/zntc.node'),
);
const directory = mkdtempSync(join(tmpdir(), 'zntc-dynamic-callsite-napi-'));
after(() => rmSync(directory, { recursive: true, force: true }));
writeFileSync(join(directory, 'dep.cjs'), 'exports.answer=42;');
writeFileSync(
  join(directory, 'dep.mjs'),
  'globalThis.effects=(globalThis.effects||0)+1;export const answer=43;',
);
const cases = [
  ['simple', "import('./dep.cjs').then(m=>console.log(m.answer));", '42'],
  [
    'Promise parameter',
    "function read(Promise){return import('./dep.cjs').then(m=>console.log(m.answer,Promise));}read(5);",
    '42 5',
  ],
  [
    'interop parameter',
    "function read(__toESM){return import('./dep.cjs').then(m=>console.log(m.answer,__toESM));}read(6);",
    '42 6',
  ],
  [
    'require parameter',
    "function read(require){return import('./dep.cjs').then(m=>console.log(m.answer,require));}read(7);",
    '42 7',
  ],
  [
    'scheduler parameter',
    "function read(__dynamicImport){return import('./dep.cjs').then(m=>console.log(m.answer,__dynamicImport));}read(8);",
    '42 8',
  ],
  [
    'parameter default',
    "function read(value=import('./dep.cjs')){let local=9;return value.then(m=>console.log(m.answer,local));}read();",
    '42 9',
  ],
  [
    'constructor default',
    "class Read{constructor(value=import('./dep.cjs')){let local=10;value.then(m=>console.log(m.answer,local));}}new Read();",
    '42 10',
  ],
  [
    'nested default',
    "function read(value=()=>import('./dep.cjs')){let local=11;return value().then(m=>console.log(m.answer,local));}read();",
    '42 11',
  ],
  [
    'strict factory',
    "class Read{static value=import('./dep.cjs');}Read.value.then(m=>console.log(m.answer));",
    '42',
  ],
  ['ESM target', "import('./dep.mjs').then(m=>console.log(m.answer,globalThis.effects));", '43 1'],
];
const modes = [{}, { minify: true }, { target: 'es5' }, { target: 'es5', minify: true }];
let sequence = 0;
function execute(source, options = {}, extension = 'mjs') {
  const entry = join(directory, `input-${sequence++}.${extension}`);
  writeFileSync(entry, source);
  const result = native.buildSync({
    entryPoints: [entry],
    inlineDynamicImports: true,
    format: 'cjs',
    ...options,
  });
  assert.deepEqual(result.errors, []);
  const output =
    result.outputFiles.find((file) => /\.[mc]?js$/.test(file.path)) ?? result.outputFiles[0];
  assert.ok(output);
  const code = new TextDecoder().decode(output.contents);
  const path = join(directory, `output-${sequence++}.${options.format === 'esm' ? 'mjs' : 'cjs'}`);
  writeFileSync(path, code);
  return { stdout: execFileSync(process.execPath, [path], { encoding: 'utf8' }).trim(), code };
}

describe('dynamic import actual callsite references (#4819)', () => {
  for (const [name, source, expected] of cases) {
    for (const mode of modes) {
      for (const format of ['esm', 'cjs', 'iife']) {
        it(`${name} ${format} ${JSON.stringify(mode)}`, () => {
          assert.equal(execute(source, { ...mode, format }).stdout, expected);
        });
      }
    }
  }

  const evalCases = [
    ["eval('__dynamicImport=0');", '42'],
    ["console.log(eval('typeof __dynamicImport'));", 'undefined\n42'],
    ["eval('__dynamicImport=0;__dynamicImport$1=0');", '42'],
    ["eval('__dynamic\\\\u0049mport=0');", '42'],
    ["eval('__dynamic'+'Import=0');", '42'],
    ["eval(`__dynamic${'Import'}=0`);", '42'],
    ["var __dynamicImport=7;console.log(eval('__dynamicImport'));", '7\n42'],
    ["var __dynamicImport=7;eval('__dynamicImport=0');console.log(__dynamicImport);", '0\n42'],
  ];
  for (const [prefix, expected] of evalCases) {
    for (const mode of modes) {
      it(
        `literal eval collision ${prefix} ${JSON.stringify(mode)}`,
        {
          todo:
            mode.minify && prefix === "var __dynamicImport=7;console.log(eval('__dynamicImport'));"
              ? 'Existing baseline DCE removes a binding observed only by literal eval'
              : false,
        },
        () => {
          assert.equal(
            execute(prefix + "import('./dep.cjs').then(m=>console.log(m.answer));", mode, 'js')
              .stdout,
            expected,
          );
        },
      );
    }
  }

  const sloppy = 'var plain=function(){return this===globalThis&&arguments.callee===plain};';
  const cjsSource =
    sloppy +
    "module.exports={ready:import('./dep.cjs').then(m=>console.log(m.answer,plain(),typeof module.exports))};";
  const umdSource =
    "(function(factory){if(typeof module==='object'&&typeof exports==='object'){module.exports=factory();}else{globalThis.Library=factory();}})(function(){" +
    sloppy +
    "return {ready:import('./dep.cjs').then(m=>console.log(m.answer,plain(),typeof module.exports))};});";
  for (const extension of ['cjs', 'js']) {
    for (const [name, source] of [
      ['CJS source', cjsSource],
      ['UMD host source', umdSource],
    ]) {
      for (const mode of modes) {
        it(`${name} keeps sloppy host scope ${extension} ${JSON.stringify(mode)}`, () => {
          assert.equal(execute(source, mode, extension).stdout, '42 true object');
        });
      }
    }
  }

  writeFileSync(join(directory, 'async-leaf.mjs'), 'export const value=42;');
  for (const extension of ['cjs', 'js']) {
    const host = `async-host.${extension}`;
    writeFileSync(
      join(directory, host),
      "(function(exports){exports.load=async function(){const loaded=await import('./async-leaf.mjs');return [loaded.value,typeof module,typeof exports];};})(exports);",
    );
    for (const target of ['es5', 'es2017']) {
      for (const minify of [false, true]) {
        it(`UMD async ESM namespace handles ${extension} ${target} minify=${minify}`, () => {
          const source = `import value from './${host}';value.load().then(v=>console.log(JSON.stringify(v)));`;
          assert.equal(execute(source, { target, minify }).stdout, '[42,"object","object"]');
        });
      }
    }
  }

  writeFileSync(
    join(directory, 'tla-leaf.mjs'),
    'await new Promise(resolve=>setTimeout(resolve,10));export const value=42;',
  );
  for (const format of ['esm', 'cjs', 'iife']) {
    for (const minify of [false, true]) {
      it(
        `dynamic target top-level await ${format} minify=${minify}`,
        {
          todo:
            format !== 'cjs'
              ? 'Existing baseline ESM/IIFE import promise does not wait for async init'
              : false,
        },
        () => {
          assert.equal(
            execute("import('./tla-leaf.mjs').then(m=>console.log(m.value));", { format, minify })
              .stdout,
            '42',
          );
        },
      );
    }
  }

  const promisePatch =
    "const OriginalPromise=globalThis.Promise;let reads=0;Object.defineProperty(globalThis,'Promise',{configurable:true,get(){reads++;return OriginalPromise}});";
  for (const mode of [{}, { minify: true }]) {
    it(`live Promise getter timing ${JSON.stringify(mode)}`, () => {
      assert.equal(
        execute(promisePatch + "import('./dep.cjs').then(m=>console.log(m.answer,reads));", mode)
          .stdout,
        '42 1',
      );
    });
    it(`dead import does not read Promise ${JSON.stringify(mode)}`, () => {
      const result = execute(
        promisePatch + "function dead(){return import('./dep.cjs')}console.log(reads);",
        mode,
      );
      assert.equal(result.stdout, '0');
    });
    it(`removed dead callsite emits no scheduler ${JSON.stringify(mode)}`, () => {
      const result = execute(
        promisePatch + "function dead(){return import('./dep.cjs')}console.log(reads);",
        { ...mode, minifySyntax: true },
      );
      assert.equal(result.stdout, '0');
      assert.ok(!result.code.includes('function __dynamicImport'));
    });
    it(`microtask evaluation order ${JSON.stringify(mode)}`, () => {
      writeFileSync(
        join(directory, 'ordered.cjs'),
        "globalThis.order.push('dep');exports.answer=42;",
      );
      assert.equal(
        execute(
          "globalThis.order=['before'];const result=import('./ordered.cjs');globalThis.order.push('after');result.then(m=>console.log(globalThis.order.join(',')));",
          mode,
        ).stdout,
        'before,after,dep',
      );
    });
  }

  it(
    'inactive provider does not reserve Promise away from source eval',
    { todo: 'Existing baseline DCE removes the eval-observed Promise binding' },
    () => {
      const result = execute(
        "var Promise=6;console.log(eval('Promise'));if(false){import('./dep.cjs')}",
        { minifySyntax: true },
        'js',
      );
      assert.equal(result.stdout, '6');
      assert.ok(!result.code.includes('function __dynamicImport'));
    },
  );

  const withObjects = [
    '{__dynamicImport:0}',
    'Object.create({__dynamicImport:0})',
    "new Proxy({__dynamicImport:0},{has(t,k){return k==='__dynamicImport'}})",
    '{__dynamicImport:0,[Symbol.unscopables]:{__dynamicImport:true}}',
  ];
  for (const object of withObjects) {
    for (const mode of modes) {
      it(`explicit with legacy boundary ${object} ${JSON.stringify(mode)}`, () => {
        assert.equal(
          execute(
            `var result;with(${object}){result=import('./dep.cjs')}result.then(m=>console.log(m.answer));`,
            mode,
            'js',
          ).stdout,
          '42',
        );
      });
    }
  }
  for (const mode of modes) {
    it(`with receiver executes outside the with environment ${JSON.stringify(mode)}`, () => {
      assert.equal(
        execute(
          "var result;with((result=import('./dep.cjs'),{})){}result.then(m=>console.log(m.answer));",
          mode,
          'js',
        ).stdout,
        '42',
      );
    });
    it(
      `native attributes retain getter and changed argument evaluation ${JSON.stringify(mode)}`,
      {
        todo: mode.minify
          ? 'Existing baseline DCE removes the native import options binding'
          : false,
      },
      () => {
        assert.equal(
          execute(
            "let reads=0;const options={get with(){reads++;return {}}};import('./dep.cjs',(()=>options)()).then(m=>console.log(m.answer,reads));",
            mode,
          ).stdout,
          '42 1',
        );
      },
    );
  }
  for (const mode of [{}, { minify: true }]) {
    it(`disk cache cold/warm/current provider ${JSON.stringify(mode)}`, () => {
      const entry = join(directory, `cached-${sequence++}.mjs`);
      const cacheDir = join(directory, `cache-${sequence++}`);
      const dep = join(directory, `cached-dep-${sequence++}.cjs`);
      const specifier = './' + dep.split('/').at(-1);
      writeFileSync(
        entry,
        `function read(Promise){return import(${JSON.stringify(specifier)}).then(m=>console.log(m.answer,Promise))}read(6);`,
      );
      for (const answer of [42, 42, 43]) {
        writeFileSync(dep, `exports.answer=${answer};`);
        const result = native.buildSync({
          entryPoints: [entry],
          format: 'cjs',
          inlineDynamicImports: true,
          cacheDir,
          ...mode,
        });
        assert.deepEqual(result.errors, []);
        const output = join(directory, `cached-output-${sequence++}.cjs`);
        writeFileSync(output, result.outputFiles[0].contents);
        assert.equal(
          execFileSync(process.execPath, [output], { encoding: 'utf8' }).trim(),
          `${answer} 6`,
        );
      }
    });
  }
});
