import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { resultBundleArgs, uiCommandArgs } from './ui-command';

test('npm UI scripts forward unique result paths, preserve destinations and propagate failures', (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'ios ui arguments '));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const output = path.join(directory, 'args.json');
  writeFileSync(path.join(directory, 'xcodebuild'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(process.env.ARGUMENT_OUTPUT, JSON.stringify(process.argv.slice(2))); process.exit(Number(process.env.TEST_EXIT_CODE));\n`, { mode: 0o755 });
  writeFileSync(path.join(directory, 'xcrun'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const paths: string[] = [];
  for (const script of ['test:e2e:ui', 'test:e2e:safari-handoff', 'test:e2e:ui:native-email-verification', 'test:e2e:ui']) {
    const args = uiCommandArgs(script, path.join(directory, 'results'), '');
    const bundle = args.at(-1)!;
    paths.push(bundle);
    assert.equal(existsSync(bundle), false);
    assert.equal(existsSync(path.dirname(bundle)), true);
    const result = spawnSync('npm', args, {
      encoding: 'utf8', env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, ARGUMENT_OUTPUT: output,
        IOS_SIMULATOR_DESTINATION: 'platform=iOS Simulator,id=normal-id',
        IOS_E2E_SAFARI_DESTINATION: 'platform=iOS Simulator,id=safari-id', TEST_EXIT_CODE: '23' },
    });
    assert.equal(result.status, 23, result.stderr);
    const forwarded: string[] = JSON.parse(readFileSync(output, 'utf8'));
    assert.deepEqual(forwarded.slice(-2), ['-resultBundlePath', bundle]);
    assert.equal(forwarded[forwarded.indexOf('-destination') + 1], `platform=iOS Simulator,id=${script === 'test:e2e:safari-handoff' ? 'safari' : 'normal'}-id`);
    assert.ok(forwarded.includes('test'));
    assert.equal(forwarded.filter((arg) => arg === '-resultBundlePath').length, 1);
  }
  assert.equal(new Set(paths).size, 4);
  assert.deepEqual(uiCommandArgs('test:e2e:ui', '', ''), ['run', 'test:e2e:ui']);
  assert.deepEqual(uiCommandArgs('test:refresh', directory), ['run', 'test:refresh']);
});

test('focused UI scripts receive Swift downloads and distinct result bundles', (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'ios focused ui '));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const packages = path.join(directory, 'swift packages');
  const args = uiCommandArgs('test:e2e:ui:stale-refresh-race', directory, packages);
  assert.deepEqual(args.slice(0, 5), ['run', 'test:e2e:ui:stale-refresh-race', '--', '-clonedSourcePackagesDirPath', packages]);
  assert.equal(args.at(-2), '-resultBundlePath');
  const integration = resultBundleArgs('integration', directory);
  const example = resultBundleArgs('example', directory);
  assert.notEqual(integration[1], example[1]);
  assert.equal(existsSync(integration[1]), false);
  assert.equal(existsSync(path.dirname(integration[1])), true);
  assert.deepEqual(uiCommandArgs('test:refresh', directory), ['run', 'test:refresh']);
});
