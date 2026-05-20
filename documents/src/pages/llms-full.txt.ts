/**
 * llms-full.txt — LLM context 직접 주입용 단일 plain text dump.
 *
 * docs collection 의 모든 페이지 본문을 *순서대로 concat*. LLM 의 long-context
 * window 에 통째로 넣어 사이트 전체를 컨텍스트로 활용 가능. RAG 보조 시스템 없이도
 * 한 번의 fetch 로 모든 문서 학습 가능.
 *
 * 주의: 매우 큰 응답 (수 MB 가능). 일반 사용자는 사용 안 함.
 */

import { getCollection } from 'astro:content';

export async function GET() {
  const docs = await getCollection('docs');

  // 한국어 → 영어 순서 (가독성)
  const sorted = [...docs].sort((a, b) => {
    const aEn = a.id.startsWith('en/') ? 1 : 0;
    const bEn = b.id.startsWith('en/') ? 1 : 0;
    if (aEn !== bEn) return aEn - bEn;
    return a.id.localeCompare(b.id);
  });

  const parts = sorted.map((d) => {
    const slug = d.id.replace(/\.(md|mdx)$/, '');
    const url = `https://ohah.github.io/zntc/${slug}/`;
    const title = d.data.title ?? slug;
    const desc = d.data.description ?? '';
    const body = d.body ?? '';
    return `# ${title}\n\nURL: ${url}\n${desc ? `Description: ${desc}\n` : ''}\n${body}\n\n---\n`;
  });

  const header = `# ZNTC — All Documentation (LLM-readable single file)

# This is a plain-text concatenation of every page on https://ohah.github.io/zntc/
# Intended for direct LLM context injection. For sitemap-style links, see /llms.txt.

`;

  return new Response(header + parts.join('\n'), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
