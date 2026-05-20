/**
 * llms.txt — LLM 친화적 사이트 overview (https://llmstxt.org/).
 *
 * docs collection 의 모든 페이지 title + description + URL 을 plain text 로 노출.
 * LLM (Claude / GPT 등) 이 *전체 사이트 구조* 를 빠르게 이해하고 *관련 페이지 URL*
 * 직접 fetch 할 수 있게 한다. RAG / context loading 워크플로 표준.
 */

import { getCollection } from 'astro:content';

const SITE = 'https://ohah.github.io/zntc';

export async function GET() {
  const docs = await getCollection('docs');

  // 언어/카테고리별 grouping
  const enDocs = docs.filter((d) => d.id.startsWith('en/'));
  const koDocs = docs.filter((d) => !d.id.startsWith('en/'));

  function fmtSection(items: typeof docs, langPrefix: string) {
    return items
      .filter((d) => d.id !== 'index' && d.id !== 'en/index')
      .map((d) => {
        const slug = d.id.replace(/\.(md|mdx)$/, '');
        const url = `${SITE}/${slug}/`;
        const title = d.data.title ?? slug;
        const desc = d.data.description ?? '';
        return `- [${title}](${url})${desc ? ` — ${desc}` : ''}`;
      })
      .join('\n');
  }

  const body = `# ZNTC

> Zig Native Transpiler & Compiler for JavaScript/TypeScript. JS·TS·JSX·Flow를 네이티브 속도로 transpile + bundle. Vite/Rollup 호환 plugin 시스템.

## 핵심 기능

- TypeScript / JSX / Flow strip (~3 ms / 1K lines)
- ES2015+ 다운레벨링 (target=es5/es2015/es2020/es2022)
- Tree-shake + minify (rolldown/esbuild/rspack 동급 또는 우위)
- Bundle (rollup-style + esbuild-style API)
- React Native (Metro/Hermes 호환)
- C NAPI in-process 호출 (Node/Bun ~50× faster than CLI spawn)
- Vite/Rollup plugin adapter

## 한국어 문서

${fmtSection(koDocs, '')}

## English Documentation

${fmtSection(enDocs, 'en/')}

## 추가 자료

- [전체 문서 (LLM context 직접 주입용 plain text)](${SITE}/llms-full.txt)
- [Claude Code skill 다운로드](${SITE}/zntc-cli.skill.md)
- [GitHub](https://github.com/ohah/zntc)
- [Playground](${SITE}/playground/)
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
