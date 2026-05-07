// GET / and /index.html — dev server landing page. 브라우저로 직접 접속 시
// bundle / map / HMR ws endpoint 의 빠른 진입 link 제공.

import type { IncomingMessage, ServerResponse } from 'node:http';

export function isIndexRoute(pathname: string): boolean {
  return pathname === '/' || pathname === '/index.html';
}

export function handleIndexPage(_req: IncomingMessage, res: ServerResponse, port: number): void {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ZNTC RN Dev Server</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; font-size: 14px; line-height: 1.6; color: #333; margin: 0; padding: 30px; background: #fafafa; }
h1 { font-size: 28px; margin-bottom: 8px; font-weight: 600; color: #222; }
h2 { font-size: 18px; margin: 30px 0 15px; font-weight: 600; color: #444; padding-bottom: 8px; border-bottom: 2px solid #e0e0e0; }
p { margin: 8px 0; color: #666; }
a { color: #007aff; text-decoration: none; }
a:hover { text-decoration: underline; }
ul { list-style: none; padding: 0; margin: 15px 0; }
li { margin: 10px 0; padding: 8px 0; }
code { background: #f0f0f0; padding: 4px 8px; border-radius: 4px; font-family: Monaco, Menlo, monospace; font-size: 13px; color: #333; border: 1px solid #e0e0e0; }
a code { background: #e8f4fd; border-color: #007aff; color: #007aff; }
a:hover code { background: #d0e9fc; }
</style>
</head>
<body>
<h1>ZNTC RN Dev Server</h1>
<p>Metro-compatible React Native dev server (port ${port})</p>
<h2>Bundles</h2>
<ul>
<li><a href="/index.bundle?platform=ios&dev=true"><code>/index.bundle?platform=ios&amp;dev=true</code></a></li>
<li><a href="/index.bundle?platform=android&dev=true"><code>/index.bundle?platform=android&amp;dev=true</code></a></li>
</ul>
<h2>Source Maps</h2>
<ul>
<li><a href="/index.bundle.map?platform=ios"><code>/index.bundle.map?platform=ios</code></a></li>
<li><a href="/index.bundle.map?platform=android"><code>/index.bundle.map?platform=android</code></a></li>
</ul>
<h2>HMR</h2>
<ul>
<li><code>ws://localhost:${port}/hot</code></li>
</ul>
</body>
</html>`;
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
  });
  res.end(html);
}
