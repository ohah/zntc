import { createServer, type Server } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname } from 'node:path';

/**
 * 정적 파일을 동적 port(`listen(0)`)로 서빙하는 헬퍼.
 * 매 케이스가 자체 port 를 받아 e2e 테스트 파일 간 port 충돌이 발생할 수 없다.
 *
 * MIME 매핑은 e2e 시나리오에서 실제 쓰이는 확장자만. 사용처가 부족한 확장자를
 * 추가하는 경우만 이 맵을 확장하면 된다.
 */
const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
};

export function serve(dir: string): Promise<{ server: Server; port: number }> {
  return new Promise((res) => {
    const server = createServer(async (req, resp) => {
      const filePath = join(dir, req.url === '/' ? 'index.html' : req.url!);
      try {
        const data = await readFile(filePath);
        resp.writeHead(200, { 'Content-Type': MIME[extname(filePath)] ?? 'text/plain' });
        resp.end(data);
      } catch {
        resp.writeHead(404);
        resp.end('Not Found');
      }
    });
    server.listen(0, () => {
      const addr = server.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      res({ server, port });
    });
  });
}

export function closeServer(server: Server): Promise<void> {
  return new Promise((res) => server.close(() => res()));
}
