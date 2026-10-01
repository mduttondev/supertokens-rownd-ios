import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export function backendStartupTimeoutMs(value = process.env.IOS_E2E_BACKEND_STARTUP_TIMEOUT_MS): number {
  if (value === undefined) {
    return 120_000;
  }
  const timeout = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(timeout) || timeout <= 0 || timeout > 2_147_483_647) {
    throw new Error('IOS_E2E_BACKEND_STARTUP_TIMEOUT_MS must be a positive integer no greater than 2147483647');
  }
  return timeout;
}

export async function logDockerDiagnostics() {
  // Restrict output to runtime/status fields: full inspect and container logs can contain credentials.
  const commands = [
    ['version', '--format', 'Client: {{.Client.Version}} Server: {{if .Server}}{{.Server.Version}}{{end}}'],
    ['ps', '-a', '--filter', 'label=org.testcontainers=true', '--format', 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'],
  ];
  await Promise.all(commands.map(async (args) => {
    try {
      const { stdout } = await execFileAsync('docker', args, { timeout: 10_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024 });
      console.error(`[iOS harness diagnostics] docker ${args[0]}\n${stdout.trim()}`);
    } catch {
      console.error(`[iOS harness diagnostics] docker ${args[0]} failed or timed out`);
    }
  }));
}
