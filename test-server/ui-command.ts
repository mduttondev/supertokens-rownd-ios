import { mkdirSync, mkdtempSync } from 'node:fs';
import path from 'node:path';

export function uiCommandArgs(script: string, resultsDirectory = process.env.IOS_E2E_UI_RESULTS_DIR) {
  const args = ['run', script];
  if (!resultsDirectory || !['test:e2e:ui', 'test:e2e:safari-handoff'].includes(script)) return args;
  const directory = path.resolve(resultsDirectory);
  mkdirSync(directory, { recursive: true });
  // xcodebuild requires a nonexistent bundle; reserve a unique parent even for repeated runs.
  const runDirectory = mkdtempSync(path.join(directory, script === 'test:e2e:ui' ? 'ui-' : 'safari-'));
  return [...args, '--', '-resultBundlePath', path.join(runDirectory, 'tests.xcresult')];
}
