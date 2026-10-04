import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { delay, stopChild } from './process';
import { backendStartupTimeoutMs, logDockerDiagnostics } from './startup';
import { collectResourceDiagnostics } from './resource-diagnostics';
import { resultBundleArgs, uiCommandArgs } from './ui-command';
import { resolveSimulatorDestinations } from './simulator-destination';

const harnessPort = Number(process.env.IOS_HARNESS_PORT || 3100);
const apiUrl = `http://127.0.0.1:${harnessPort}`;
const hubPort = Number(process.env.E2E_HUB_PORT || 8788);
const hubUrl = `http://127.0.0.1:${hubPort}`;
const hubHealthUrl = `${hubUrl}/health`;
const localHubRepo = path.resolve(process.env.IOS_LOCAL_HUB_REPO || '../supertokens-rownd-hub');
const environment: NodeJS.ProcessEnv = {
  ...process.env,
  IOS_HARNESS_PORT: String(harnessPort),
  IOS_HUB_BASE_URL: hubUrl,
  IOS_HUB_HEALTH_URL: hubHealthUrl,
  TEST_BACKEND_URL: apiUrl,
};

let harnessProcess: ChildProcess | undefined;
let harnessFailure: Error | undefined;
let hubProcess: ChildProcess | undefined;
let hubFailure: Error | undefined;
let activeCommand: ChildProcess | undefined;
let shutdownPromise: Promise<void> | undefined;

function start(command: string, args: string[], env = environment, cwd = process.cwd()) {
  return spawn(command, args, {
    cwd,
    stdio: 'inherit',
    shell: false,
    detached: process.platform !== 'win32',
    env,
  });
}

async function run(command: string, args: string[], cwd = process.cwd()) {
  const started = Date.now();
  const child = start(command, args, environment, cwd);
  activeCommand = child;

  try {
    await new Promise<void>((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => {
        if (code === 0) {
          resolve();
          return;
        }
        reject(new Error(`${command} ${args.join(' ')} exited with code ${code}, signal ${signal}`));
      });
    });
  } finally {
    console.log(`E2E command duration: ${((Date.now() - started) / 1000).toFixed(1)}s: ${command} ${args.join(' ')}`);
    if (activeCommand === child) {
      activeCommand = undefined;
    }
  }
}

async function runBuiltSuite() {
  const requestedDestination = process.env.IOS_SIMULATOR_DESTINATION || 'platform=iOS Simulator,name=iPhone 17';
  const [simulator, safariSimulator] = await resolveSimulatorDestinations([
    requestedDestination, process.env.IOS_E2E_SAFARI_DESTINATION || requestedDestination,
  ]);
  const destination = simulator.destination;
  const resultsDirectory = process.env.IOS_E2E_UI_RESULTS_DIR || path.join(tmpdir(), 'ios-e2e-results');
  const derivedData = process.env.IOS_E2E_DERIVED_DATA || path.join(tmpdir(), 'ios-e2e-derived-data');
  const packageArgs = process.env.IOS_SWIFTPM_CACHE ? ['-clonedSourcePackagesDirPath', process.env.IOS_SWIFTPM_CACHE] : [];
  // The package workspace pins different dependency versions from the example.
  // Keep that integration coverage instead of silently switching its package graph.
  if (process.env.IOS_E2E_ONLY_UI !== '1') {
    await run('xcodebuild', ['-workspace', 'RowndPackage.xcworkspace', '-scheme', 'RowndIntegration',
      '-derivedDataPath', path.join(derivedData, 'integration'), '-destination', destination,
      '-parallel-testing-enabled', 'NO', ...packageArgs, 'test', ...resultBundleArgs('integration', resultsDirectory)]);
    assertResourcesRunning();
  }
  const args = ['-workspace', 'rownd.xcworkspace', '-scheme', 'RowndE2E',
    '-derivedDataPath', path.join(derivedData, 'example'), '-parallel-testing-enabled', 'NO', ...packageArgs];
  await run('xcodebuild', [...args, '-destination', destination, 'build-for-testing']);
  const safariTest = 'rownd_ios_exampleUITests/RowndManageAccountEmailUITests/testEditingEmailThroughSafariOpensAppAndPersistsVerifiedProfile';
  const phases = [
    ...(process.env.IOS_E2E_ONLY_UI === '1' ? [] : [
      { name: 'example', filters: [
        '-only-testing:rownd_ios_exampleTests/RowndExampleTests/testExampleAppCanUseHarnessBackedSuperTokensSession',
        '-only-testing:rownd_ios_exampleTests/RowndExampleTests/testPostAppleCompletionDismissesRealBottomSheetBeforeRestoringOnboardingTouches',
        '-only-testing:rownd_ios_exampleTests/RowndExampleTests/testHarnessBackedAppleCompletionCreatesUsableSessionAndDismissesRealHub',
      ] },
    ]),
    { name: 'ui', filters: ['-only-testing:rownd_ios_exampleUITests', `-skip-testing:${safariTest}`] },
    { name: 'safari', filters: [`-only-testing:${safariTest}`] },
  ];
  for (const phase of phases) {
    assertResourcesRunning();
    if (phase.name === 'ui' && process.env.IOS_E2E_DIAGNOSTICS_DIR) await collectResourceDiagnostics('ui-start');
    const phaseSimulator = phase.name === 'safari' ? safariSimulator : simulator;
    const phaseDestination = phaseSimulator.destination;
    if (phase.name === 'ui' || phase.name === 'safari') {
      await run('xcrun', phaseSimulator.bootArgs);
    }
    // Each XCTest also terminates the app and resets native/WebKit state before launch.
    // Drain backend operations and remove fault injection between entire test processes.
    const reset = await fetch(`${apiUrl}/reset`, { method: 'POST', signal: AbortSignal.timeout(30_000) });
    if (!reset.ok) throw new Error(`Backend reset before ${phase.name} failed: HTTP ${reset.status}`);
    await run('xcodebuild', [...args, '-destination', phaseDestination,
      'test-without-building', ...phase.filters, ...resultBundleArgs(phase.name, resultsDirectory)]);
  }
}

async function startLocalHub() {
  await run('npm', ['run', 'build'], localHubRepo);

  const hubServerPath = path.join(localHubRepo, 'test/e2e/harness/hub-server.ts');
  hubProcess = start(
    process.execPath,
    ['--import', 'tsx', hubServerPath],
    { ...environment, E2E_HUB_PORT: String(hubPort) },
    localHubRepo,
  );
  const startedHub = hubProcess;
  const handleHubFailure = (error: Error) => {
    if (hubProcess === startedHub) {
      hubFailure = error;
      void stopChild(activeCommand);
    }
  };
  startedHub.once('error', handleHubFailure);
  startedHub.once('exit', (code, signal) => {
    handleHubFailure(new Error(`Local Hub exited unexpectedly (code ${code}, signal ${signal})`));
  });
}

function assertResourcesRunning() {
  if (harnessFailure) {
    throw harnessFailure;
  }
  if (!harnessProcess || harnessProcess.exitCode !== null || harnessProcess.signalCode !== null) {
    throw new Error('The integration harness exited unexpectedly');
  }
  if (hubFailure) {
    throw hubFailure;
  }
  if (!hubProcess || hubProcess.exitCode !== null || hubProcess.signalCode !== null) {
    throw new Error('The local Hub exited unexpectedly');
  }
}

async function waitForHealth(url: string, timeoutMs = 120_000) {
  console.log(`Waiting up to ${timeoutMs / 1000}s for ${url}`);
  let lastStatus = 'no response';
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    assertResourcesRunning();
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(2_000) });
      if (response.ok) {
        console.log(`Ready: ${url}`);
        return;
      }
      lastStatus = `HTTP ${response.status}`;
    } catch {
      // Keep polling while the harness process is alive.
    }
    await delay(500);
  }
  throw new Error(`Timed out after ${timeoutMs / 1000}s waiting for ${url} (last status: ${lastStatus})`);
}

function shutdown() {
  if (shutdownPromise) {
    return shutdownPromise;
  }

  shutdownPromise = (async () => {
    const errors: unknown[] = [];
    const commandToStop = activeCommand;
    const harnessToStop = harnessProcess;
    const hubToStop = hubProcess;
    activeCommand = undefined;
    harnessProcess = undefined;
    hubProcess = undefined;

    await stopResource('active E2E command', errors, () => stopChild(commandToStop));
    await stopResource('integration harness process', errors, () => stopChild(harnessToStop, 30_000));
    await stopResource('local Hub process', errors, () => stopChild(hubToStop));

    if (errors.length > 0) {
      throw new AggregateError(errors, 'Failed to stop one or more iOS E2E resources');
    }
  })();

  return shutdownPromise;
}

async function stopResource(
  name: string,
  errors: unknown[],
  stop: () => Promise<unknown> | undefined,
) {
  try {
    await stop();
  } catch (error) {
    console.error(`Failed to stop ${name}`, error);
    errors.push(error);
  }
}

async function main() {
  const startupTimeoutMs = backendStartupTimeoutMs();
  let failure: unknown;
  let backendReady = false;
  try {
    await startLocalHub();
    harnessProcess = start(process.execPath, ['--import', 'tsx', 'test-server/run-harness.ts']);
    const startedHarness = harnessProcess;
    const handleHarnessFailure = (error: Error) => {
      if (harnessProcess === startedHarness) {
        harnessFailure = error;
        void stopChild(activeCommand);
      }
    };
    startedHarness.once('error', handleHarnessFailure);
    startedHarness.once('exit', (code, signal) => {
      handleHarnessFailure(new Error(`Integration harness exited unexpectedly (code ${code}, signal ${signal})`));
    });

    await Promise.all([waitForHealth(`${apiUrl}/health`, startupTimeoutMs), waitForHealth(hubHealthUrl)]);
    backendReady = true;
    if (process.env.IOS_E2E_DIAGNOSTICS_DIR) await collectResourceDiagnostics('ready');
    if (!process.env.IOS_E2E_UI_SCRIPT) {
      await runBuiltSuite();
    } else {
      if (process.env.IOS_E2E_ONLY_UI !== '1') {
        await run('npm', ['run', 'test:integration']);
        assertResourcesRunning();
        await run('npm', ['run', 'test:e2e:example']);
        assertResourcesRunning();
      }
      if (process.env.IOS_E2E_DIAGNOSTICS_DIR) await collectResourceDiagnostics('ui-start');
      await run('npm', uiCommandArgs(process.env.IOS_E2E_UI_SCRIPT));
    }
    assertResourcesRunning();
  } catch (error) {
    failure = error;
    console.error('iOS E2E failure before cleanup', error);
    if (process.env.IOS_E2E_DIAGNOSTICS_DIR) await collectResourceDiagnostics('failure');
    if (harnessProcess && !backendReady) {
      await logDockerDiagnostics();
    }
  }

  try {
    await shutdown();
  } catch (cleanupError) {
    if (failure) {
      throw new AggregateError([failure, cleanupError], 'E2E run and cleanup failed');
    }
    throw cleanupError;
  }

  if (failure) {
    throw failure;
  }
}

process.once('SIGINT', () => {
  void stopAfterSignal().then(
    () => process.exit(130),
    () => process.exit(1),
  );
});
process.once('SIGTERM', () => {
  void stopAfterSignal().then(
    () => process.exit(143),
    () => process.exit(1),
  );
});

async function stopAfterSignal() {
  // Step timeouts signal the runner before normal error handling can sample the VM.
  if (process.env.IOS_E2E_DIAGNOSTICS_DIR) await collectResourceDiagnostics('failure');
  await shutdown();
}

void main().catch((error) => {
  console.error('iOS E2E run failed', error);
  process.exitCode = 1;
});
