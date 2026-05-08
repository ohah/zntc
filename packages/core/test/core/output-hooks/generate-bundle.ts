import { describe, test, expect, build, vitePlugin } from '../helpers';
import { useOutputHookFixture } from './fixture';

describe('generateBundle 훅', () => {
  const fixture = useOutputHookFixture();

  test('generateBundle: 번들 완료 콜백', async () => {
    const collected: string[] = [];
    const result = await build({
      entryPoints: [fixture.entryPoint()],
      plugins: [
        {
          name: 'bundle-inspector',
          setup(build) {
            build.onGenerateBundle((outputs) => {
              for (const f of outputs) {
                collected.push(f.path);
              }
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(collected.length).toBeGreaterThan(0);
  });

  test('generateBundle via vitePlugin', async () => {
    let called = false;
    await build({
      entryPoints: [fixture.entryPoint()],
      plugins: [
        vitePlugin({
          name: 'vite-generate',
          generateBundle(outputs) {
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });
});
