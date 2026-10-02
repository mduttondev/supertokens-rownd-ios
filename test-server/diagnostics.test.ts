import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer, request, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { appendBoundedLine, requestDiagnostics, snapshotPendingRequests, startRequestDiagnostics } from './request-diagnostics';
import { collectResourceDiagnostics } from './resource-diagnostics';

async function listen(server: Server) {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  return `http://127.0.0.1:${address.port}`;
}

test('profile diagnostics distinguish pending and completed captures without request secrets', async (t) => {
  const log = t.mock.method(console, 'log', () => {});
  const server = createServer(async (req, res) => {
    startRequestDiagnostics(req, res, '/auth/plugin/rownd/user');
    const trace = requestDiagnostics(res)!;
    trace.captured(false);
    snapshotPendingRequests();
    await delay(2_050);
    res.once('finish', () => trace.captured(true));
    res.statusCode = 200;
    res.end('private-response');
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = await listen(server);
  const response = await fetch(`${url}/auth/plugin/rownd/user?token=private-query`, {
    method: 'PUT', headers: { authorization: 'Bearer private-token' }, body: 'private-body',
  });
  await response.text();
  const output = log.mock.calls.map((call) => String(call.arguments[0])).join('\n');
  assert.match(output, /"event":"request_pending"/);
  assert.match(output, /"event":"reset_with_request_pending"/);
  assert.match(output, /"captureState":"pending"/);
  assert.match(output, /"captureState":"completed"/);
  assert.match(output, /"completed":true,"statusCode":200/);
  assert.doesNotMatch(output, /private-|authorization|Bearer/);
});

test('disconnected expiry clients still log session completion and restore errors', async (t) => {
  const log = t.mock.method(console, 'log', () => {});
  let ready!: () => void;
  let finished!: () => void;
  const started = new Promise<void>((resolve) => { ready = resolve; });
  const done = new Promise<void>((resolve) => { finished = resolve; });
  const server = createServer(async (req, res) => {
    startRequestDiagnostics(req, res, '/test/expiring-session');
    const trace = requestDiagnostics(res)!;
    trace.startPhase('queue')();
    await trace.phase('session', () => new Promise<void>((resolve) => {
      res.once('close', resolve);
      ready();
    }));
    await assert.rejects(
      trace.phase('restore', async () => { throw new Error('private-error-token'); }),
      /private-error-token/,
    );
    finished();
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = await listen(server);
  const client = request(url, { method: 'POST' });
  client.on('error', () => {});
  client.end();
  await started;
  client.destroy();
  await done;
  const records = log.mock.calls.map((call) => JSON.parse(String(call.arguments[0]).replace('[iOS harness request] ', '')));
  assert.ok(records.some((record) => record.event === 'response_close' && !record.completed));
  assert.ok(records.some((record) => record.event === 'phase_end' && record.phase === 'session' && record.clientClosed));
  assert.ok(records.some((record) => record.event === 'phase_error' && record.phase === 'restore' && record.phaseDurationMs >= 0));
  assert.equal(new Set(records.map((record) => record.requestId)).size, 1);
  assert.doesNotMatch(JSON.stringify(records), /private-error-token/);
});

test('artifact lines are bounded without writing partial records', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'ios-diagnostics-'));
  try {
    const file = path.join(directory, 'diagnostics.log');
    appendBoundedLine(file, 'first\n', 10);
    appendBoundedLine(file, 'too large\n', 10);
    appendBoundedLine(file, 'end\n', 10);
    assert.equal(readFileSync(file, 'utf8'), 'first\nend\n');
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('an interrupted request body is logged as aborted before plugin capture', async (t) => {
  const log = t.mock.method(console, 'log', () => {});
  let ready!: () => void;
  let closed!: () => void;
  const started = new Promise<void>((resolve) => { ready = resolve; });
  const done = new Promise<void>((resolve) => { closed = resolve; });
  const server = createServer((req, res) => {
    startRequestDiagnostics(req, res, '/auth/plugin/rownd/user');
    res.once('close', closed);
    req.resume();
    ready();
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = await listen(server);
  const client = request(url, { method: 'PUT', headers: { 'content-length': '1000' } });
  client.on('error', () => {});
  client.write('private-partial-body');
  await started;
  client.destroy();
  await done;
  const output = log.mock.calls.map((call) => String(call.arguments[0])).join('\n');
  assert.match(output, /"event":"request_aborted"/);
  assert.match(output, /"captureState":"not-captured"/);
  assert.doesNotMatch(output, /private-partial-body/);
});

test('resource probes continue after failures and never log command error details', async (t) => {
  const log = t.mock.method(console, 'log', () => {});
  const commands: string[] = [];
  await collectResourceDiagnostics('failure', async (command, args) => {
    commands.push([command, ...args].join(' '));
    if (command === 'colima') throw new Error('private-error-token');
    return 'safe resource counters';
  });
  assert.equal(commands.length, 8);
  assert.ok(commands.includes('sysctl hw.ncpu hw.memsize vm.swapusage'));
  assert.ok(commands.includes('sh -c ps -axo pid,ppid,%cpu,rss,comm | sort -k4,4nr | head -n 30'));
  assert.ok(commands.some((command) => command.includes('/proc/pressure/memory')));
  const output = log.mock.calls.map((call) => String(call.arguments[0])).join('\n');
  assert.match(output, /unavailable/);
  assert.match(output, /safe resource counters/);
  assert.doesNotMatch(output, /private-error-token/);
});
