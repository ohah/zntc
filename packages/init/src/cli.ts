import {
  initReactNativeProject,
  PACKAGE_MANAGERS,
  type InitReactNativeOptions,
  type PackageManager,
} from './index.ts';

function printHelp(): void {
  console.log(`Usage: zntc-init [react-native] [options]

Overlay ZNTC onto an existing React Native CLI project.

Options:
  --root <dir>               Project root (default: cwd)
  --platform <ios|android>   Default platform for the start script (default: ios)
  --zntc-version <range>     Version range for @zntc packages (default: latest)
  --package-manager <pm>     Install command hint: bun, npm, pnpm, or yarn
  --no-metro-fallback        Do not add Metro fallback scripts
  --force                    Overwrite an existing zntc.config.ts
  --dry-run                  Print planned changes without writing files
  --help, -h                 Show this help message
`);
}

function readValue(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith('-')) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function parseArgs(argv: string[]): InitReactNativeOptions & { help?: boolean } {
  const args = [...argv];
  if (args[0] === 'react-native') args.shift();

  const options: InitReactNativeOptions & { help?: boolean } = {};
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!;
    switch (arg) {
      case '--help':
      case '-h':
        options.help = true;
        break;
      case '--root':
        options.root = readValue(args, i, arg);
        i += 1;
        break;
      case '--platform': {
        const value = readValue(args, i, arg);
        if (value !== 'ios' && value !== 'android') {
          throw new Error(`--platform must be "ios" or "android"`);
        }
        options.defaultPlatform = value;
        i += 1;
        break;
      }
      case '--zntc-version':
        options.zntcVersion = readValue(args, i, arg);
        i += 1;
        break;
      case '--package-manager': {
        const value = readValue(args, i, arg) as PackageManager;
        if (!PACKAGE_MANAGERS.includes(value)) {
          throw new Error(`--package-manager must be one of ${PACKAGE_MANAGERS.join(', ')}`);
        }
        options.packageManager = value;
        i += 1;
        break;
      }
      case '--no-metro-fallback':
        options.metroFallback = false;
        break;
      case '--force':
        options.force = true;
        break;
      case '--dry-run':
        options.dryRun = true;
        break;
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }
  return options;
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    process.exit(0);
  }

  const result = initReactNativeProject(options);
  const verb = result.dryRun ? 'Would update' : 'Updated';
  console.log(`${verb} ${result.root}`);
  for (const change of result.changes) {
    console.log(`  ${change.action.padEnd(9)} ${change.path}`);
  }
  if (!result.dryRun) {
    console.log(`\nRun ${result.installCommand} to install dependencies.`);
  }
} catch (error) {
  console.error(`zntc-init: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
