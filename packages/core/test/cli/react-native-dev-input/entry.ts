import { describe, test, expect } from '../helpers';
import { loadBuildRnDevServerInput } from './helpers';

describe('buildRnDevServerInput — entry config 추출 (#2605)', () => {
  test('entry 없음 → null', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    expect(buildRnDevServerInput({ entryPoints: [] }, {})).toBeNull();
    expect(buildRnDevServerInput({}, {})).toBeNull();
  });

  test('config.entry 만 있어도 entry 채워짐', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({}, { entry: 'src/index.ts' });
    expect(input?.bundle.entry).toBe('src/index.ts');
  });

  test('CLI flag 우선 — config.entry override', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['cli.js'] }, { entry: 'config.js' });
    expect(input?.bundle.entry).toBe('cli.js');
  });
});
