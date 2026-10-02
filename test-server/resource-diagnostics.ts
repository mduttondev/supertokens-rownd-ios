import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { appendBoundedLine } from './request-diagnostics';

const execFileAsync = promisify(execFile);
const probes = [
  ['host-capacity-swap', 'sysctl', ['hw.ncpu', 'hw.memsize', 'vm.swapusage']],
  ['host-vm', 'vm_stat', []],
  ['host-load', 'uptime', []],
  // comm, not command: process arguments may contain credentials.
  ['host-processes', 'sh', ['-c', 'ps -axo pid,ppid,%cpu,rss,comm | sort -k4,4nr | head -n 30']],
  ['colima-status', 'colima', ['status', '--json']],
  ['guest-pressure', 'colima', ['ssh', '--', 'sh', '-c', 'free -m; cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io']],
  ['docker-capacity', 'docker', ['info', '--format', 'CPUs={{.NCPU}} MemoryBytes={{.MemTotal}}']],
  ['docker-usage', 'docker', ['stats', '--no-stream', '--format', '{{.Name}} CPU={{.CPUPerc}} Memory={{.MemUsage}} PIDs={{.PIDs}}']],
] as const;

type ProbeRunner = (command: string, args: readonly string[]) => Promise<string>;
const runProbe: ProbeRunner = async (command, args) => {
  const { stdout } = await execFileAsync(command, [...args], {
    timeout: 5_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024,
  });
  return stdout;
};

export async function collectResourceDiagnostics(stage: 'ready' | 'failure' | 'workflow-failure', run: ProbeRunner = runProbe) {
  const time = new Date().toISOString();
  // Parallel, one-shot probes: bounded to ~5s total even if Colima is wedged.
  const records = await Promise.all(probes.map(async ([probe, command, args]) => {
    try { return { time, stage, probe, output: (await run(command, args)).slice(0, 64 * 1024) }; }
    catch { return { time, stage, probe, output: 'unavailable (failed, timed out, or exceeded output limit)' }; }
  }));
  for (const record of records) {
    const line = JSON.stringify(record);
    console.log(`[iOS E2E resources] ${line}`);
    const directory = process.env.IOS_E2E_DIAGNOSTICS_DIR;
    if (directory) {
      try { appendBoundedLine(path.join(directory, `resources-${process.pid}.ndjson`), `${line}\n`); }
      catch { console.error('[iOS E2E diagnostics] Could not write resource snapshot'); }
    }
  }
}

if (process.argv[1]?.endsWith('/resource-diagnostics.ts')) {
  void collectResourceDiagnostics('workflow-failure');
}
