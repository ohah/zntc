import {
  PACKAGE_MANAGERS,
  WEB_FRAMEWORKS,
  initReactNativeProject,
  initRspackProject,
  initViteProject,
  initWebProject,
  type FileChange,
  type InitReactNativeOptions,
  type InitRspackOptions,
  type InitViteOptions,
  type InitWebOptions,
  type PackageManager,
  type RspackBundler,
  type WebFramework,
} from './index.ts';

const MODES = ['react-native', 'vite', 'rspack', 'web'] as const;
type Mode = (typeof MODES)[number];

function printHelp(): void {
  console.log(`Usage: zntc-init <mode> [options]

Modes:
  react-native    Overlay ZNTC onto an existing React Native CLI project
  vite            Overlay ZNTC onto an existing Vite project (@zntc/vite-plugin)
  rspack          Overlay ZNTC onto an existing Rspack/Webpack project (@zntc/rspack-loader)
  web             Scaffold a standalone ZNTC web project (no Vite/Rspack)

Common options:
  --root <dir>                Project root (default: cwd)
  --zntc-version <range>      Version range for @zntc packages (default: latest)
  --package-manager <pm>      Install command hint: bun, npm, pnpm, or yarn
  --force                     Overwrite existing files where the mode allows
  --dry-run                   Print planned changes without writing files
  --help, -h                  Show this help message

react-native options:
  --platform <ios|android>    Default platform for the start script (default: ios)
  --no-metro-fallback         Do not add Metro fallback scripts

rspack options:
  --bundler <rspack|webpack>  Force bundler choice (default: auto-detect)

web options:
  --name <pkg-name>           package.json name field (default: directory name)
  --framework <react|vanilla> Starter template (default: react)
`);
}

function readValue(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith('-')) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

type ParsedArgs =
  | { help: true }
  | { help?: false; mode: 'react-native'; options: InitReactNativeOptions }
  | { help?: false; mode: 'vite'; options: InitViteOptions }
  | { help?: false; mode: 'rspack'; options: InitRspackOptions }
  | { help?: false; mode: 'web'; options: InitWebOptions };

function pickMode(argv: string[]): { mode: Mode; rest: string[] } | { help: true } {
  if (argv.length === 0) return { help: true };
  const first = argv[0]!;
  if (first === '--help' || first === '-h') return { help: true };
  if (first.startsWith('-')) {
    // 모드 생략 시 기본은 react-native (기존 동작 호환).
    return { mode: 'react-native', rest: argv };
  }
  if (!MODES.includes(first as Mode)) {
    throw new Error(`unknown mode: ${first} (expected one of ${MODES.join(', ')})`);
  }
  return { mode: first as Mode, rest: argv.slice(1) };
}

function parseArgs(argv: string[]): ParsedArgs {
  const picked = pickMode(argv);
  if ('help' in picked) return { help: true };

  const { mode, rest } = picked;
  const opts: Record<string, unknown> = {};
  let help = false;

  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i]!;
    switch (arg) {
      case '--help':
      case '-h':
        help = true;
        break;
      case '--root':
        opts.root = readValue(rest, i, arg);
        i += 1;
        break;
      case '--zntc-version':
        opts.zntcVersion = readValue(rest, i, arg);
        i += 1;
        break;
      case '--package-manager': {
        const value = readValue(rest, i, arg) as PackageManager;
        if (!PACKAGE_MANAGERS.includes(value)) {
          throw new Error(`--package-manager must be one of ${PACKAGE_MANAGERS.join(', ')}`);
        }
        opts.packageManager = value;
        i += 1;
        break;
      }
      case '--force':
        opts.force = true;
        break;
      case '--dry-run':
        opts.dryRun = true;
        break;
      case '--platform': {
        if (mode !== 'react-native')
          throw new Error(`--platform is only valid for react-native mode`);
        const value = readValue(rest, i, arg);
        if (value !== 'ios' && value !== 'android') {
          throw new Error(`--platform must be "ios" or "android"`);
        }
        opts.defaultPlatform = value;
        i += 1;
        break;
      }
      case '--no-metro-fallback':
        if (mode !== 'react-native') {
          throw new Error(`--no-metro-fallback is only valid for react-native mode`);
        }
        opts.metroFallback = false;
        break;
      case '--bundler': {
        if (mode !== 'rspack') throw new Error(`--bundler is only valid for rspack mode`);
        const value = readValue(rest, i, arg);
        if (value !== 'rspack' && value !== 'webpack') {
          throw new Error(`--bundler must be "rspack" or "webpack"`);
        }
        opts.bundler = value as RspackBundler;
        i += 1;
        break;
      }
      case '--name':
        if (mode !== 'web') throw new Error(`--name is only valid for web mode`);
        opts.name = readValue(rest, i, arg);
        i += 1;
        break;
      case '--framework': {
        if (mode !== 'web') throw new Error(`--framework is only valid for web mode`);
        const value = readValue(rest, i, arg) as WebFramework;
        if (!WEB_FRAMEWORKS.includes(value)) {
          throw new Error(`--framework must be one of ${WEB_FRAMEWORKS.join(', ')}`);
        }
        opts.framework = value;
        i += 1;
        break;
      }
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }

  if (help) return { help: true };
  // mode 별로 옵션 shape 이 다르지만 parser 가 mode-guard 로 키를 분기했으므로 안전한 cast.
  switch (mode) {
    case 'react-native':
      return { mode, options: opts as InitReactNativeOptions };
    case 'vite':
      return { mode, options: opts as InitViteOptions };
    case 'rspack':
      return { mode, options: opts as InitRspackOptions };
    case 'web':
      return { mode, options: opts as InitWebOptions };
  }
}

interface RunResult {
  root: string;
  changes: FileChange[];
  dryRun: boolean;
  installCommand: string;
}

interface PrintConfig {
  verb: { dry: string; live: string };
  suffix?: string;
  postHint?: (result: RunResult) => string;
}

function printChanges(changes: FileChange[]): void {
  for (const change of changes) {
    console.log(`  ${change.action.padEnd(9)} ${change.path}`);
    if (change.manualInstructions) {
      const indented = change.manualInstructions
        .split('\n')
        .map((line) => (line ? `    ${line}` : ''))
        .join('\n');
      console.log(indented);
    }
  }
}

function printResult(result: RunResult, config: PrintConfig): void {
  const verb = result.dryRun ? config.verb.dry : config.verb.live;
  const suffix = config.suffix ? ` (${config.suffix})` : '';
  console.log(`${verb} ${result.root}${suffix}`);
  printChanges(result.changes);
  if (!result.dryRun) {
    const hint = config.postHint?.(result);
    console.log(`\nRun ${result.installCommand} to install dependencies.${hint ? ` ${hint}` : ''}`);
  }
}

const OVERLAY_VERB = { dry: 'Would update', live: 'Updated' };
const SCAFFOLD_VERB = { dry: 'Would scaffold', live: 'Scaffolded' };

try {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    printHelp();
    process.exit(0);
  }
  switch (parsed.mode) {
    case 'react-native':
      printResult(initReactNativeProject(parsed.options), { verb: OVERLAY_VERB });
      break;
    case 'vite':
      printResult(initViteProject(parsed.options), { verb: OVERLAY_VERB });
      break;
    case 'rspack': {
      const result = initRspackProject(parsed.options);
      printResult(result, { verb: OVERLAY_VERB, suffix: result.bundler });
      break;
    }
    case 'web': {
      const result = initWebProject(parsed.options);
      printResult(result, {
        verb: SCAFFOLD_VERB,
        suffix: result.framework,
        postHint: (r) => `Then ${r.installCommand.split(' ')[0]} run dev.`,
      });
      break;
    }
  }
} catch (error) {
  console.error(`zntc-init: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
