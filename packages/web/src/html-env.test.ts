import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { applyHtmlEnvTokens, transformHtmlEnvTokens } from './html-env.ts';

describe('transformHtmlEnvTokens', () => {
  test('replaces token with env value', () => {
    const { html, changed, warnings } = transformHtmlEnvTokens(
      '<title><%= ZNTC_APP_TITLE %></title>',
      { ZNTC_APP_TITLE: 'My App' },
    );
    expect(html).toBe('<title>My App</title>');
    expect(changed).toBe(true);
    expect(warnings).toEqual([]);
  });

  test('replaces multiple tokens', () => {
    const { html } = transformHtmlEnvTokens('<a href="<%= ZNTC_BASE %>"><%= ZNTC_LABEL %></a>', {
      ZNTC_BASE: '/app/',
      ZNTC_LABEL: 'Home',
    });
    expect(html).toBe('<a href="/app/">Home</a>');
  });

  test('tolerates whitespace variants', () => {
    const { html } = transformHtmlEnvTokens('<%=ZNTC_A%>|<%= ZNTC_A %>|<%=   ZNTC_A   %>', {
      ZNTC_A: 'x',
    });
    expect(html).toBe('x|x|x');
  });

  test('missing env replaces with empty string and warns', () => {
    const { html, warnings, changed } = transformHtmlEnvTokens(
      '<meta name="v" content="<%= ZNTC_VERSION %>">',
      {},
    );
    expect(html).toBe('<meta name="v" content="">');
    expect(changed).toBe(true);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain('ZNTC_VERSION');
  });

  test('keeps token as-is when prefix mismatches (no leakage)', () => {
    const { html, warnings, changed } = transformHtmlEnvTokens(
      '<meta name="api" content="<%= VITE_API_URL %>">',
      { VITE_API_URL: 'https://api.example.com', ZNTC_OK: 'ok' },
    );
    expect(html).toBe('<meta name="api" content="<%= VITE_API_URL %>">');
    expect(changed).toBe(false);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain('VITE_API_URL');
  });

  test('custom prefix', () => {
    const { html } = transformHtmlEnvTokens(
      '<title><%= NEXT_PUBLIC_TITLE %></title>',
      { NEXT_PUBLIC_TITLE: 'X' },
      'NEXT_PUBLIC_',
    );
    expect(html).toBe('<title>X</title>');
  });

  test('non-token-like sequences are left alone', () => {
    const html = '<!-- <% comment %> --> <%= 1 + 1 %> <%=invalid-key%>';
    const out = transformHtmlEnvTokens(html, { ZNTC_X: 'y' });
    expect(out.html).toBe(html);
    expect(out.changed).toBe(false);
  });

  test('changed=false when no token present', () => {
    const html = '<html><body>no tokens here</body></html>';
    const out = transformHtmlEnvTokens(html, { ZNTC_X: 'y' });
    expect(out.html).toBe(html);
    expect(out.changed).toBe(false);
    expect(out.warnings).toEqual([]);
  });

  test('missing key alone keeps changed=false when both sides equal', () => {
    const out = transformHtmlEnvTokens('<x><%= ZNTC_X %></x>', {});
    expect(out.html).toBe('<x></x>');
    expect(out.changed).toBe(true);
    const stable = transformHtmlEnvTokens('<x></x>', {});
    expect(stable.changed).toBe(false);
  });

  test('escapes <, >, &, " in env values', () => {
    const { html } = transformHtmlEnvTokens('<div data="<%= ZNTC_BIO %>"></div>', {
      ZNTC_BIO: `<script>alert("&")</script>`,
    });
    expect(html).toBe('<div data="&lt;script&gt;alert(&quot;&amp;&quot;)&lt;/script&gt;"></div>');
  });

  test('attribute value with " stays safe', () => {
    const { html } = transformHtmlEnvTokens('<meta content="<%= ZNTC_X %>">', {
      ZNTC_X: '" onerror="alert(1)',
    });
    expect(html).toBe('<meta content="&quot; onerror=&quot;alert(1)">');
  });

  test('same key multiple times all replaced', () => {
    const { html } = transformHtmlEnvTokens('<%= ZNTC_X %>-<%= ZNTC_X %>-<%= ZNTC_X %>', {
      ZNTC_X: 'v',
    });
    expect(html).toBe('v-v-v');
  });
});

describe('applyHtmlEnvTokens', () => {
  let outdir: string;
  let htmlPath: string;

  beforeEach(() => {
    outdir = mkdtempSync(join(tmpdir(), 'zntc-html-env-'));
    htmlPath = join(outdir, 'index.html');
  });

  afterEach(() => {
    rmSync(outdir, { recursive: true, force: true });
  });

  test('writes file when changed', () => {
    mkdirSync(outdir, { recursive: true });
    writeFileSync(htmlPath, '<title><%= ZNTC_APP_TITLE %></title>');
    const { warnings } = applyHtmlEnvTokens(outdir, { ZNTC_APP_TITLE: 'Hi' });
    expect(warnings).toEqual([]);
    expect(readFileSync(htmlPath, 'utf8')).toBe('<title>Hi</title>');
  });

  test('does not touch file when no token present', () => {
    mkdirSync(outdir, { recursive: true });
    const original = '<title>static</title>';
    writeFileSync(htmlPath, original);
    const stat1 = readFileSync(htmlPath, 'utf8');
    applyHtmlEnvTokens(outdir, { ZNTC_APP_TITLE: 'Hi' });
    const stat2 = readFileSync(htmlPath, 'utf8');
    expect(stat2).toBe(stat1);
    expect(stat2).toBe(original);
  });

  test('silent on ENOENT', () => {
    const { warnings } = applyHtmlEnvTokens(outdir, { ZNTC_X: 'y' });
    expect(warnings).toEqual([]);
  });
});
