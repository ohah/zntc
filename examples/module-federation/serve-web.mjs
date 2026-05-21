// MF 브라우저 데모 정적 서버 — host (index.html + dist/host-web.js) 와
// remote(remote/dist/*) 를 한 origin 에서 서빙한다. host 의 loadRemote 가
// `/remote/dist/index.js` 를 같은 origin 에서 가져온다 (CORS 불필요).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, dirname, extname, sep } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};

const port = Number(process.env.PORT) || 12308;
const host = process.env.HOST || "0.0.0.0";

const server = createServer(async (req, res) => {
  const urlPath = (req.url || "/").split("?")[0];
  const rel = urlPath === "/" ? "/index.html" : urlPath;
  const file = join(here, rel);
  // 0.0.0.0 바인드라 LAN 노출 — `/../` 디렉토리 탈출 차단 (here 밖 파일 거부).
  if (file !== here && !file.startsWith(here + sep)) {
    res.writeHead(403).end("403");
    return;
  }
  try {
    const data = await readFile(file);
    res.writeHead(200, { "content-type": MIME[extname(rel)] || "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404).end("404");
  }
});

server.listen(port, host, () => {
  console.log(`\n  zntc module-federation (browser)\n`);
  console.log(`  Local:   http://localhost:${port}/`);
  console.log(`  Network: http://${host}:${port}/\n`);
});
