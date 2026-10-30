import { test, expect, type Browser } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const ZNTC_BIN = process.env.ZNTC_BIN ?? resolve(__dirname, '../../../zig-out/bin/zntc');
const variants = ['plain', 'identifiers', 'full'] as const;

// The superclass returns the actual host object, so the derived constructor
// installs its private field/method brand on document.all itself.
const cases = [
  {
    name: 'field stamp',
    body: `class Base { constructor(value) { return value; } }
class Stamp extends Base { #x = 1; static has(value) { return #x in value; } }
new Stamp(document.all);
return [Stamp.has(document.all)];`,
    expected: [true],
  },
  {
    name: 'method stamp',
    body: `class Base { constructor(value) { return value; } }
class Stamp extends Base { #x() {} static has(value) { return #x in value; } }
new Stamp(document.all);
return [Stamp.has(document.all)];`,
    expected: [true],
  },
  {
    name: 'unbranded empty key across four brands',
    body: `Object.defineProperty(document.all, '', { value: true, configurable: true });
if (document.all[''] !== true) throw new Error('HTMLDDA empty-key fixture failed');
class Field { #x = 1; static has(value) { return #x in value; } }
class Method { #x() {} static has(value) { return #x in value; } }
class StaticField { static #x = 1; static has(value) { return #x in value; } }
class StaticMethod { static #x() {} static has(value) { return #x in value; } }
return [Field.has(document.all), Method.has(document.all),
  StaticField.has(document.all), StaticMethod.has(document.all)];`,
    expected: [false, false, false, false],
  },
];

function sourceFor(body: string): string {
  return `globalThis.__privateInHtmlDda = (function () {
const stamp = [typeof document.all, document.all === void 0, document.all == null];
const brands = (function () { ${body} })();
return { stamp, brands };
})();`;
}

async function observe(browser: Browser, source: string) {
  // Each native/emitted execution gets its own page: private stamps must never
  // leak between variants through the same document.all host object.
  const page = await browser.newPage();
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  try {
    await page.goto('about:blank');
    await page.addScriptTag({ content: source });
    const result = await page.evaluate(
      () => (globalThis as typeof globalThis & { __privateInHtmlDda?: unknown }).__privateInHtmlDda,
    );
    expect(errors).toEqual([]);
    return result;
  } finally {
    await page.close();
  }
}

for (const fixture of cases) {
  test(`private in accepts actual HTMLDDA: ${fixture.name}`, async ({ browser }, testInfo) => {
    test.setTimeout(120_000);
    const dir = await mkdtemp(join(tmpdir(), 'zntc-private-in-html-dda-'));
    const source = sourceFor(fixture.body);
    try {
      const native = await observe(browser, source);
      expect(native).toEqual({ stamp: ['undefined', false, true], brands: fixture.expected });
      const input = join(dir, 'input.js');
      await writeFile(input, source);
      for (const target of ['es2020', 'es5']) {
        for (const variant of variants) {
          const output = join(dir, `${target}-${variant}.js`);
          const flags =
            variant === 'full'
              ? ['--minify']
              : variant === 'identifiers'
                ? ['--minify-identifiers']
                : [];
          const build = spawnSync(ZNTC_BIN, [input, `--target=${target}`, ...flags, '-o', output], {
            encoding: 'utf8',
            timeout: 30_000,
          });
          expect(build.error, `${target}/${variant}`).toBeUndefined();
          expect(build.status, `${target}/${variant}: ${build.stderr}`).toBe(0);
          const emitted = await readFile(output, 'utf8');
          await testInfo.attach(`${target}-${variant}.js`, {
            body: emitted,
            contentType: 'text/javascript',
          });
          expect(await observe(browser, emitted), `${target}/${variant}`).toEqual(native);
        }
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}
