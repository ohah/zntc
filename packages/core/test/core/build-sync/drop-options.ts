import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';

describe('@zntc/core buildSync - drop options', () => {
  test('dropConsole: bundle 모드에서 console 호출 제거', () => {
    const dropDir = mkdtempSync(join(tmpdir(), 'zntc-bundle-drop-console-'));
    writeFileSync(
      join(dropDir, 'app.ts'),
      'console.log("DROP_CONSOLE_REMOVED"); export const x = "DROP_CONSOLE_KEPT";',
    );
    const result = buildSync({
      entryPoints: [join(dropDir, 'app.ts')],
      dropConsole: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('DROP_CONSOLE_REMOVED');
    expect(result.outputFiles[0].text).toContain('DROP_CONSOLE_KEPT');
    rmSync(dropDir, { recursive: true, force: true });
  });

  test('dropDebugger: bundle 모드에서 debugger 문 제거', () => {
    const dropDir = mkdtempSync(join(tmpdir(), 'zntc-bundle-drop-debugger-'));
    writeFileSync(join(dropDir, 'app.ts'), 'debugger;\nexport const x = "DROP_DEBUGGER_KEPT";');
    const result = buildSync({
      entryPoints: [join(dropDir, 'app.ts')],
      dropDebugger: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('debugger');
    expect(result.outputFiles[0].text).toContain('DROP_DEBUGGER_KEPT');
    rmSync(dropDir, { recursive: true, force: true });
  });

  test('dropConsole 미지정: bundle 모드는 console 호출 보존 (기존 동작)', () => {
    const keepDir = mkdtempSync(join(tmpdir(), 'zntc-bundle-drop-keep-'));
    writeFileSync(join(keepDir, 'app.ts'), 'console.log("KEEP_CONSOLE_VALUE");');
    const result = buildSync({
      entryPoints: [join(keepDir, 'app.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('KEEP_CONSOLE_VALUE');
    rmSync(keepDir, { recursive: true, force: true });
  });
});
