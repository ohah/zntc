import { expect } from '../helpers';

export {
  describe,
  test,
  expect,
  spawn,
  execSync,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  unlinkSync,
  tmpdir,
  join,
  CLI,
  RUNTIME,
  PROJECT_ROOT,
  waitForServer,
  waitForText,
  findFreePort,
  occupyPort,
  runCli,
} from '../helpers';

export function scriptPathFromHtml(html: string): string {
  const match = html.match(/<script[^>]+src="([^"]+)"/);
  expect(match).not.toBeNull();
  return match![1];
}
