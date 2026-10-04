import { mkdirSync, mkdtempSync } from 'node:fs';
import path from 'node:path';

export function uiCommandArgs(
  script: string,
  resultsDirectory = process.env.IOS_E2E_UI_RESULTS_DIR,
  swiftPackagesDirectory = process.env.IOS_SWIFTPM_CACHE,
) {
  const args = ['run', script];
  if (script !== 'test:e2e:ui' && !script.startsWith('test:e2e:ui:') && script !== 'test:e2e:safari-handoff') return args;
  const xcodeArgs: string[] = [];
  if (swiftPackagesDirectory) xcodeArgs.push('-clonedSourcePackagesDirPath', swiftPackagesDirectory);
  if (resultsDirectory) xcodeArgs.push(...resultBundleArgs(script === 'test:e2e:safari-handoff' ? 'safari' : 'ui', resultsDirectory));
  return xcodeArgs.length ? [...args, '--', ...xcodeArgs] : args;
}

export function resultBundleArgs(phase: string, resultsDirectory: string) {
  const directory = path.resolve(resultsDirectory);
  mkdirSync(directory, { recursive: true });
  // xcodebuild requires a nonexistent bundle; reserve a unique parent even for repeated runs.
  const runDirectory = mkdtempSync(path.join(directory, `${phase}-`));
  return ['-resultBundlePath', path.join(runDirectory, 'tests.xcresult')];
}
