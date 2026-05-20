/**
 * llms-full.txt — Single plain-text dump for direct LLM context injection.
 *
 * Concatenates every English docs page in order. Designed to be fed to an LLM's
 * long-context window in one shot — no RAG infrastructure needed. Korean docs
 * are excluded; readers wanting Korean should browse the docs site.
 *
 * Note: response is large (hundreds of KB to a few MB). Not intended for end users.
 */

import { getCollection } from 'astro:content';

export async function GET() {
  const docs = await getCollection('docs');

  // English docs only, sorted by id for stable ordering
  const sorted = [...docs.filter((d) => d.id.startsWith('en/'))].sort((a, b) =>
    a.id.localeCompare(b.id),
  );

  const parts = sorted.map((d) => {
    const slug = d.id.replace(/\.(md|mdx)$/, '');
    const url = `https://ohah.github.io/zntc/${slug}/`;
    const title = d.data.title ?? slug;
    const desc = d.data.description ?? '';
    const body = d.body ?? '';
    return `# ${title}\n\nURL: ${url}\n${desc ? `Description: ${desc}\n` : ''}\n${body}\n\n---\n`;
  });

  const header = `# ZNTC — All Documentation (LLM-readable single file)

# This is a plain-text concatenation of every English page on https://ohah.github.io/zntc/
# Intended for direct LLM context injection. For a sitemap-style index, see /llms.txt.
# Korean documentation is not included here; visit the docs site directly for Korean.

`;

  return new Response(header + parts.join('\n'), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
