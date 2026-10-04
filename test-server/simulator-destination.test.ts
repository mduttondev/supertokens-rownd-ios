import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { resolveSimulatorDestinations } from './simulator-destination';

test('boot commands and Xcode destinations honor OS selection and a separate Safari runtime', async (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'ios simulator commands '));
  const previousPath = process.env.PATH;
  t.after(() => {
    process.env.PATH = previousPath;
    rmSync(directory, { recursive: true, force: true });
  });
  const runtime = (version: string) => `com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll('.', '-')}`;
  const inventory = {
    runtimes: ['26.2', '26.3', '26.4'].map((version) => ({
      identifier: runtime(version), version: version === '26.3' ? '26.3.1' : version, isAvailable: version !== '26.4',
    })),
    devices: {
      [runtime('26.2')]: [{ name: 'iPhone 17', udid: 'device-262', isAvailable: true, state: 'Shutdown' }],
      [runtime('26.3')]: [{ name: 'iPhone 17', udid: 'device-263', isAvailable: true, state: 'Booted' }],
      [runtime('26.4')]: [{ name: 'iPhone 17', udid: 'device-264', isAvailable: true, state: 'Shutdown' }],
    },
  };
  const fixture = path.join(directory, 'inventory.json');
  const calls = path.join(directory, 'calls.jsonl');
  writeFileSync(fixture, JSON.stringify(inventory));
  writeFileSync(path.join(directory, 'xcrun'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify(args) + '\\n');
if (args.join(' ') === 'simctl list --json') process.stdout.write(fs.readFileSync(${JSON.stringify(fixture)}));
else if (args[0] !== 'simctl' || args[1] !== 'bootstatus') process.exit(23);
`, { mode: 0o755 });
  process.env.PATH = `${directory}:${previousPath}`;

  const [normal, safari] = await resolveSimulatorDestinations([
    'platform=iOS Simulator,name=iPhone 17,OS=26.2,arch=arm64',
    'platform=iOS Simulator,name=iPhone 17,OS=26.3.1',
  ]);
  for (const simulator of [normal, safari]) execFileSync('xcrun', simulator.bootArgs);
  assert.equal(normal.destination, 'platform=iOS Simulator,arch=arm64,id=device-262');
  assert.equal(safari.destination, 'platform=iOS Simulator,id=device-263');
  assert.deepEqual(readFileSync(calls, 'utf8').trim().split('\n').map((line) => JSON.parse(line)), [
    ['simctl', 'list', '--json'],
    ['simctl', 'bootstatus', 'device-262', '-b'],
    ['simctl', 'bootstatus', 'device-263', '-b'],
  ]);
  const [latest, explicitId] = await resolveSimulatorDestinations([
    'platform=iOS Simulator,name=iPhone 17,OS=latest',
    'platform=iOS Simulator,id=device-262',
  ]);
  assert.equal(latest.destination, 'platform=iOS Simulator,id=device-263');
  assert.equal(explicitId.destination, 'platform=iOS Simulator,id=device-262');
  await assert.rejects(resolveSimulatorDestinations(['platform=iOS Simulator,name=iPhone 17,OS=26.4']), /found 0/);
  await assert.rejects(resolveSimulatorDestinations(['platform=iOS Simulator,name=iPhone 17,OS=26.3']), /found 0/);
  await assert.rejects(resolveSimulatorDestinations(['platform=iOS Simulator,id=device-262,OS=26.3.1']), /found 0/);
  inventory.devices[runtime('26.2')].push({ name: 'iPhone 17', udid: 'duplicate-262', isAvailable: true, state: 'Shutdown' });
  writeFileSync(fixture, JSON.stringify(inventory));
  await assert.rejects(resolveSimulatorDestinations(['platform=iOS Simulator,name=iPhone 17,OS=26.2']), /found 2.*UDID/);
});
