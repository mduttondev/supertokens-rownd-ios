import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
type Inventory = {
  runtimes: Array<{ identifier: string; version: string; isAvailable: boolean }>;
  devices: Record<string, Array<{ name: string; udid: string; isAvailable: boolean }>>;
};

function compareVersions(left: string, right: string) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const difference = (a[index] || 0) - (b[index] || 0);
    if (difference) return difference;
  }
  return 0;
}

export async function resolveSimulatorDestinations(destinations: string[]) {
  const { stdout } = await execute('xcrun', ['simctl', 'list', '--json'], { timeout: 30_000, maxBuffer: 4 * 1024 * 1024 });
  const inventory: Inventory = JSON.parse(stdout);
  return destinations.map((destination) => {
    const fields = new Map(destination.split(',').map((part) => {
      const separator = part.indexOf('=');
      if (separator < 1) throw new Error(`Invalid simulator destination: ${destination}`);
      return [part.slice(0, separator).trim(), part.slice(separator + 1).trim()];
    }));
    const id = fields.get('id');
    const name = fields.get('name');
    const os = fields.get('OS');
    if (fields.get('platform') !== 'iOS Simulator' || (!id && !name)
        || (os && os !== 'latest' && !/^\d+(\.\d+)*$/.test(os))) {
      throw new Error(`Expected an iOS Simulator destination with id or name and a valid OS: ${destination}`);
    }
    let matches = inventory.runtimes
      .filter((runtime) => runtime.isAvailable && runtime.identifier.startsWith('com.apple.CoreSimulator.SimRuntime.iOS-'))
      .filter((runtime) => !os || os === 'latest' || compareVersions(runtime.version, os) === 0)
      .flatMap((runtime) => (inventory.devices[runtime.identifier] || [])
        .filter((device) => device.isAvailable && (!id || device.udid === id) && (!name || device.name === name))
        .map((device) => ({ ...device, version: runtime.version })))
      .sort((left, right) => compareVersions(right.version, left.version));
    if (matches.length && (!os || os === 'latest')) {
      matches = matches.filter((device) => compareVersions(device.version, matches[0].version) === 0);
    }
    if (matches.length !== 1) {
      throw new Error(`Expected one available simulator for "${destination}", found ${matches.length}. Specify an unambiguous simulator UDID.`);
    }
    const udid = matches[0].udid;
    // Pin Xcode and simctl to the same device, including when names span runtimes.
    fields.delete('name');
    fields.delete('OS');
    fields.set('id', udid);
    return {
      destination: [...fields].map(([key, value]) => `${key}=${value}`).join(','),
      bootArgs: ['simctl', 'bootstatus', udid, '-b'],
    };
  });
}
