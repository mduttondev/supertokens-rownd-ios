import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { Readable } from 'node:stream';

const execFileAsync = promisify(execFile);

export function backendStartupTimeoutMs(value = process.env.IOS_E2E_BACKEND_STARTUP_TIMEOUT_MS): number {
  return startupTimeoutMs('IOS_E2E_BACKEND_STARTUP_TIMEOUT_MS', value, 120_000);
}

export function containerStartupTimeoutMs(value = process.env.IOS_E2E_CONTAINER_STARTUP_TIMEOUT_MS): number {
  return startupTimeoutMs('IOS_E2E_CONTAINER_STARTUP_TIMEOUT_MS', value, 60_000);
}

function startupTimeoutMs(name: string, value: string | undefined, defaultMs: number): number {
  if (value === undefined) return defaultMs;
  const timeout = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(timeout) || timeout <= 0 || timeout > 2_147_483_647) {
    throw new Error(`${name} must be a positive integer no greater than 2147483647`);
  }
  return timeout;
}

export function containerStartupLogger(name: string) {
  let remaining = 64 * 1024;
  let active = true;
  return {
    consume(stream: Readable) {
      // Testcontainers removes failed containers before start() rejects. Preserve logs now,
      // but stop forwarding once ready so runtime/session data is not included.
      stream.on('data', (chunk: string | Buffer) => {
        if (!active || remaining === 0) return;
        const data = Buffer.from(chunk);
        const output = data.subarray(0, remaining);
        remaining -= output.length;
        console.log(`[iOS harness ${name}] ${output.toString().trimEnd()}`);
        if (remaining === 0) console.log(`[iOS harness ${name}] Startup logs capped at 64 KiB`);
      });
      stream.on('error', () => {
        if (active) console.error(`[iOS harness ${name}] Startup log stream failed`);
      });
    },
    stop() {
      active = false;
    },
  };
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
