import { describe, expect, test } from '../../helpers';
import { loadBuildRnDevServerInput } from '../helpers';

describe('buildRnDevServerInput — runtime bundle option config 추출 (#2605)', () => {
  test('config.watchFolders → bundle.extra.watchFolders', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { watchFolders: ['../shared', '../tokens'] },
    );
    expect(input?.bundle.extra?.watchFolders).toEqual(['../shared', '../tokens']);
  });

  test('config.transformer.babelTransformerPath 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { transformer: { babelTransformerPath: 'react-native-svg-transformer' } },
    );
    expect(input?.bundle.extra?.babelTransformerPath).toBe('react-native-svg-transformer');
  });

  test('dev 우선순위: CLI devMode > config.dev > default true', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const defaultInput = buildRnDevServerInput({ entryPoints: ['i.js'] }, {});
    expect(defaultInput?.bundle.dev).toBe(true);

    const configOff = buildRnDevServerInput({ entryPoints: ['i.js'] }, { dev: false });
    expect(configOff?.bundle.dev).toBe(false);

    const cliOff = buildRnDevServerInput({ entryPoints: ['i.js'], devMode: false }, { dev: true });
    expect(cliOff?.bundle.dev).toBe(false);

    const cliOn = buildRnDevServerInput({ entryPoints: ['i.js'], devMode: true }, { dev: false });
    expect(cliOn?.bundle.dev).toBe(true);
  });

  test('config.minify → bundle.minify', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, { minify: true });
    expect(input?.bundle.minify).toBe(true);
  });

  test('config.root → projectRoot (resolve 적용)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, { root: '/abs/path' });
    expect(input?.bundle.projectRoot).toBe('/abs/path');
  });

  test('rnPlatform=android override', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'], rnPlatform: 'android' }, {});
    expect(input?.bundle.rnPlatform).toBe('android');
  });
});
