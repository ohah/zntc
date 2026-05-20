/**
 * llms.txt — LLM-friendly site overview (https://llmstxt.org/).
 *
 * Lists all English docs pages with title + description + URL as plain text so
 * LLMs (Claude / GPT etc.) can quickly understand the site structure and fetch
 * individual pages. RAG / context-loading workflow standard.
 *
 * Only English docs are listed here — Korean docs are excluded to keep this
 * file LLM-optimal. Korean readers should browse the docs site directly.
 */

import { getCollection } from 'astro:content';

const SITE = 'https://ohah.github.io/zntc';

export async function GET() {
  const docs = await getCollection('docs');

  // Only English documents
  const enDocs = docs.filter((d) => d.id.startsWith('en/'));

  const items = enDocs
    .filter((d) => d.id !== 'en/index')
    .map((d) => {
      const slug = d.id.replace(/\.(md|mdx)$/, '');
      const url = `${SITE}/${slug}/`;
      const title = d.data.title ?? slug;
      const desc = d.data.description ?? '';
      return `- [${title}](${url})${desc ? ` — ${desc}` : ''}`;
    })
    .join('\n');

  const body = `# ZNTC

> Zig Native Transpiler & Compiler for JavaScript/TypeScript. Transpile and bundle JS · TS · JSX · Flow at native speed with a Vite/Rollup-compatible plugin system.

## Core features

- TypeScript / JSX / Flow stripping (~3 ms / 1K lines)
- ES2015+ downleveling (target=es5/es2015/es2020/es2022)
- Tree-shake + minify (on par with or smaller than rolldown/esbuild/rspack)
- Bundle (rollup-style + esbuild-style API)
- React Native (Metro / Hermes compatible)
- C NAPI in-process calls (Node/Bun, ~50× faster than CLI spawn)
- Vite / Rollup plugin adapter

## Performance (2026-05-21, darwin arm64, 20-run median)

- Transpile small (100 lines): **1.79 ms** (1st, vs esbuild 3.90 / Bun 5.16)
- Bundle small (10 modules): **2.62 ms** (1st, vs Bun 8.05 / esbuild 10.8)
- Bundle medium (1000 modules): **17.0 ms** (1st, vs Bun 23.3 / esbuild 26.8)
- Warm incremental rebuild (lodash-es, 641 modules): **21.7 ms** (47.3 → 21.7 ms after graph_discover optimization epic, -54%)

## Documentation

${items}

## Additional resources

- [Full documentation as a single plain-text file (for LLM context injection)](${SITE}/llms-full.txt)
- [Claude Code skill — install as ~/.claude/skills/zntc-cli/SKILL.md](${SITE}/zntc-cli.skill.md)
- [GitHub](https://github.com/ohah/zntc)
- [Playground](${SITE}/en/playground/)
- [Korean docs site (separate language)](${SITE}/)
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
