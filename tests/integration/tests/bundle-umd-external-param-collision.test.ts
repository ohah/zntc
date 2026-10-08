import { afterAll, afterEach, beforeAll, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { build, close, init } from '../../../packages/core/index';
import { createFixture, runNode } from './helpers';

describe('UMD external factory parameter collisions', () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('separates external aliases and preserves a colliding source binding', async () => {
    const fixture = await createFixture({
      'entry.js': `
        import { one } from "@scope/foo";
        import { two } from "foo";
        import { value } from "react";
        const React = "local";
        export const result = [one, two, value, React];
      `,
      'node_modules/@scope/foo/package.json': '{"name":"@scope/foo","main":"index.js"}',
      'node_modules/@scope/foo/index.js': 'exports.one = "first";\n',
      'node_modules/foo/package.json': '{"name":"foo","main":"index.js"}',
      'node_modules/foo/index.js': 'exports.two = "second";\n',
      'node_modules/react/package.json': '{"name":"react","main":"index.js"}',
      'node_modules/react/index.js': 'exports.value = "external";\n',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.js')],
      external: ['@scope/foo', 'foo', 'react'],
      format: 'umd',
      globalName: 'Lib',
    });
    const bundle = result.outputFiles!.find((file) => file.path.endsWith('.js'))!;
    expect(bundle.text).toContain('function(Foo, Foo$1, React)');
    expect(bundle.text).toContain('else root.Lib = factory(root.Foo, root.Foo, root.React);');

    const umdPath = join(fixture.dir, 'bundle-umd.js');
    writeFileSync(umdPath, bundle.text);
    const driver = join(fixture.dir, 'run-umd.cjs');
    writeFileSync(
      driver,
      `console.log(JSON.stringify(require(${JSON.stringify(umdPath)}).result));\n`,
    );
    const run = await runNode(driver);
    expect(run.stdout.trim()).toBe('["first","second","external","local"]');

    const umdGlobalDriver = join(fixture.dir, 'run-umd-global.cjs');
    writeFileSync(
      umdGlobalDriver,
      `const fs=require("node:fs");\n` +
        `const vm=require("node:vm");\n` +
        `globalThis.Foo={one:"first",two:"second"};\n` +
        `globalThis.React={value:"external"};\n` +
        `vm.runInThisContext(fs.readFileSync(${JSON.stringify(umdPath)},"utf8"));\n` +
        `console.log(JSON.stringify(globalThis.Lib.result));\n`,
    );
    const umdGlobalRun = await runNode(umdGlobalDriver);
    expect(umdGlobalRun.stdout.trim()).toBe('["first","second","external","local"]');

    const amd = await build({
      entryPoints: [join(fixture.dir, 'entry.js')],
      external: ['@scope/foo', 'foo', 'react'],
      format: 'amd',
    });
    const amdBundle = amd.outputFiles!.find((file) => file.path.endsWith('.js'))!;
    expect(amdBundle.text).toContain('function(Foo, Foo$1, React)');
    const amdPath = join(fixture.dir, 'bundle-amd.js');
    writeFileSync(amdPath, amdBundle.text);
    const amdDriver = join(fixture.dir, 'run-amd.cjs');
    writeFileSync(
      amdDriver,
      `const fs=require("node:fs");\n` +
        `globalThis.Lib=undefined;\n` +
        `globalThis.define=(deps,factory)=>{globalThis.Lib=factory(...deps.map((d)=>require(d)));};\n` +
        `globalThis.define.amd={};\n` +
        `eval(fs.readFileSync(${JSON.stringify(amdPath)},"utf8"));\n` +
        `console.log(JSON.stringify(globalThis.Lib.result));\n`,
    );
    const amdRun = await runNode(amdDriver);
    expect(amdRun.stdout.trim()).toBe('["first","second","external","local"]');

    const iife = await build({
      entryPoints: [join(fixture.dir, 'entry.js')],
      external: ['@scope/foo', 'foo', 'react'],
      format: 'iife',
      globalName: 'Lib',
      globals: { '@scope/foo': 'Foo', foo: 'Foo', react: 'React' },
    });
    const iifeBundle = iife.outputFiles!.find((file) => file.path.endsWith('.js'))!;
    expect(iifeBundle.text).toContain('Foo$1');
    expect(iifeBundle.text).toContain('})(Foo, Foo, React);');
    const iifePath = join(fixture.dir, 'bundle-iife.js');
    writeFileSync(iifePath, iifeBundle.text);
    const iifeDriver = join(fixture.dir, 'run-iife.cjs');
    writeFileSync(
      iifeDriver,
      `const fs=require("node:fs");\n` +
        `const vm=require("node:vm");\n` +
        `globalThis.Foo={one:"first",two:"second"};\n` +
        `globalThis.React={value:"external"};\n` +
        `vm.runInThisContext(fs.readFileSync(${JSON.stringify(iifePath)},"utf8"));\n` +
        `console.log(JSON.stringify(globalThis.Lib.result));\n`,
    );
    const iifeRun = await runNode(iifeDriver);
    expect(iifeRun.stdout.trim()).toBe('["first","second","external","local"]');
  });

  test('keeps an external parameter separate from a generated CJS wrapper binding', async () => {
    const fixture = await createFixture({
      'entry.js': `
        import { value } from "ext";
        import legacy from "./legacy.cjs";
        export const result = [value, legacy];
      `,
      'legacy.cjs': 'module.exports = "local-module";\n',
      'node_modules/ext/package.json': '{"name":"ext","main":"index.js"}',
      'node_modules/ext/index.js': 'exports.value = "external";\n',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.js')],
      external: ['ext'],
      format: 'umd',
      globalName: 'Lib',
      globals: { ext: 'require_legacy' },
    });
    const bundle = result.outputFiles!.find((file) => file.path.endsWith('.js'))!;
    expect(bundle.text).toContain('function(require_legacy$1)');
    expect(bundle.text).toContain('var require_legacy =');

    const output = join(fixture.dir, 'bundle-wrapper-collision.js');
    writeFileSync(output, bundle.text);
    const driver = join(fixture.dir, 'run-wrapper-collision.cjs');
    writeFileSync(
      driver,
      `console.log(JSON.stringify(require(${JSON.stringify(output)}).result));\n`,
    );
    const run = await runNode(driver);
    expect(run.stdout.trim()).toBe('["external","local-module"]');
  });
});
