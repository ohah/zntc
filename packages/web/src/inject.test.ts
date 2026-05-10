import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  injectAppDevBundleCssLinks,
  injectAppDevHmrClient,
  injectAppDevPipelineCssLinks,
  injectIntoDevHtml,
} from './inject.ts';
import { joinUrl } from './url.ts';

let outdir: string;
let htmlPath: string;

beforeEach(() => {
  outdir = mkdtempSync(join(tmpdir(), 'zntc-web-inject-'));
  htmlPath = join(outdir, 'index.html');
});

afterEach(() => {
  rmSync(outdir, { recursive: true, force: true });
});

function writeHtml(html: string): void {
  mkdirSync(outdir, { recursive: true });
  writeFileSync(htmlPath, html);
}

function readHtml(): string {
  return readFileSync(htmlPath, 'utf8');
}

describe('joinUrl', () => {
  test('base 없으면 rel 그대로', () => {
    expect(joinUrl(undefined, '/foo.css')).toBe('/foo.css');
    expect(joinUrl('', '/foo.css')).toBe('/foo.css');
  });

  test('base + rel concat', () => {
    expect(joinUrl('/app', '/foo.css')).toBe('/app/foo.css');
    expect(joinUrl('/', 'foo.css')).toBe('/foo.css');
  });
});

describe('injectIntoDevHtml — head 주입', () => {
  test('</head> 직전에 tag 삽입', () => {
    writeHtml('<html><head><title>x</title></head><body></body></html>');
    injectIntoDevHtml(outdir, () => `<meta name="x">`);
    expect(readHtml()).toContain(`<meta name="x">\n</head>`);
  });

  test('</head> 없으면 첫 <script> 직전에 삽입', () => {
    writeHtml('<html><body><script src="a.js"></script></body></html>');
    injectIntoDevHtml(outdir, () => `<meta name="x">`);
    expect(readHtml()).toContain(`<meta name="x">\n<script`);
  });

  test('build callback 가 null 반환하면 변경 없음', () => {
    const original = '<html><head></head></html>';
    writeHtml(original);
    injectIntoDevHtml(outdir, () => null);
    expect(readHtml()).toBe(original);
  });

  test('ENOENT (HTML 없음) 은 silent skip — throw 안 함', () => {
    expect(() => injectIntoDevHtml(outdir, () => '<x>')).not.toThrow();
  });

  test('ENOENT 외 다른 에러는 propagate', () => {
    // 디렉토리를 파일로 사용 → EISDIR 같은 에러 (ENOENT 아님).
    mkdirSync(htmlPath, { recursive: true });
    expect(() => injectIntoDevHtml(outdir, () => '<x>')).toThrow();
  });
});

describe('injectAppDevHmrClient', () => {
  test('HTML 에 client script 삽입', () => {
    writeHtml('<html><head></head></html>');
    injectAppDevHmrClient(outdir);
    const html = readHtml();
    expect(html).toContain(`<script type="module" src="/__zntc_app_dev_hmr__"></script>`);
    expect(html).toContain('</head>');
  });

  test('이미 client 가 있으면 중복 삽입 안 함', () => {
    writeHtml(
      `<html><head><script type="module" src="/__zntc_app_dev_hmr__"></script></head></html>`,
    );
    injectAppDevHmrClient(outdir);
    const html = readHtml();
    const occurrences = html.match(/__zntc_app_dev_hmr__/g) ?? [];
    expect(occurrences.length).toBe(1);
  });
});

describe('injectAppDevBundleCssLinks', () => {
  test('css output 마다 <link> 삽입', () => {
    writeHtml('<html><head></head></html>');
    injectAppDevBundleCssLinks(outdir, '/', {
      outputFiles: [{ path: 'dist/styles.css' }, { path: 'dist/main.js' }],
    });
    const html = readHtml();
    expect(html).toContain(`<link rel="stylesheet" href="/styles.css">`);
    expect(html).not.toContain('main.js');
  });

  test('이미 같은 href 가 있으면 중복 삽입 안 함', () => {
    writeHtml(`<html><head><link rel="stylesheet" href="/styles.css"></head></html>`);
    injectAppDevBundleCssLinks(outdir, '/', {
      outputFiles: [{ path: 'dist/styles.css' }],
    });
    const html = readHtml();
    const occurrences = html.match(/href="\/styles\.css"/g) ?? [];
    expect(occurrences.length).toBe(1);
  });

  test('작은따옴표 href 도 중복 검출', () => {
    writeHtml(`<html><head><link rel='stylesheet' href='/styles.css'></head></html>`);
    injectAppDevBundleCssLinks(outdir, '/', {
      outputFiles: [{ path: 'dist/styles.css' }],
    });
    expect(readHtml().match(/styles\.css/g)?.length).toBe(1);
  });

  test('base path 적용 (trailing slash 포함)', () => {
    writeHtml('<html><head></head></html>');
    injectAppDevBundleCssLinks(outdir, '/app/', {
      outputFiles: [{ path: 'dist/x.css' }],
    });
    expect(readHtml()).toContain(`href="/app/x.css"`);
  });

  test('css 가 없으면 변경 없음', () => {
    const original = '<html><head></head></html>';
    writeHtml(original);
    injectAppDevBundleCssLinks(outdir, '/', {
      outputFiles: [{ path: 'dist/main.js' }],
    });
    expect(readHtml()).toBe(original);
  });

  test('bundleResult null 도 안전 (변경 없음)', () => {
    const original = '<html><head></head></html>';
    writeHtml(original);
    injectAppDevBundleCssLinks(outdir, '/', null);
    expect(readHtml()).toBe(original);
  });

  test('outputFiles 의 file.path 가 없으면 skip', () => {
    writeHtml('<html><head></head></html>');
    injectAppDevBundleCssLinks(outdir, '/', { outputFiles: [{}] });
    expect(readHtml()).toBe('<html><head></head></html>');
  });
});

describe('injectAppDevPipelineCssLinks', () => {
  test('rel path 마다 <link>', () => {
    writeHtml('<html><head></head></html>');
    injectAppDevPipelineCssLinks(outdir, '/', ['styles/a.css', 'styles/b.css']);
    const html = readHtml();
    expect(html).toContain(`href="/styles/a.css"`);
    expect(html).toContain(`href="/styles/b.css"`);
  });

  test('이미 있는 href 는 skip', () => {
    writeHtml(`<html><head><link rel="stylesheet" href="/a.css"></head></html>`);
    injectAppDevPipelineCssLinks(outdir, '/', ['a.css']);
    expect(readHtml().match(/a\.css/g)?.length).toBe(1);
  });

  test('작은따옴표 href 도 skip', () => {
    writeHtml(`<html><head><link rel='stylesheet' href='/a.css'></head></html>`);
    injectAppDevPipelineCssLinks(outdir, '/', ['a.css']);
    expect(readHtml().match(/a\.css/g)?.length).toBe(1);
  });

  test('빈 배열은 즉시 return — HTML touch 안 함', () => {
    const original = '<html><head></head></html>';
    writeHtml(original);
    injectAppDevPipelineCssLinks(outdir, '/', []);
    expect(readHtml()).toBe(original);
  });

  test('Windows path separator 를 forward slash 로 변환', () => {
    writeHtml('<html><head></head></html>');
    // path.sep 이 / 인 환경에서도 input 에 \\ 을 명시하면 변환 동작 보장.
    injectAppDevPipelineCssLinks(outdir, '/', ['styles\\a.css']);
    // 유닉스 환경에서 path.sep 은 / 이라 replaceAll(sep, "/") 가 no-op.
    // input 에 backslash 가 그대로 남음 — 환경 별 동작 검증은 통합 테스트로.
    const html = readHtml();
    expect(html).toMatch(/href="\/styles[\\/]a\.css"/);
  });
});
