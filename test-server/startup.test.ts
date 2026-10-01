import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { test } from 'node:test';
import { backendStartupTimeoutMs, containerStartupLogger, containerStartupTimeoutMs } from './startup';

test('container readiness and backend deadlines can be configured independently', () => {
  assert.equal(containerStartupTimeoutMs('180000'), 180_000);
  assert.equal(backendStartupTimeoutMs('600000'), 600_000);
  for (const invalid of ['', '0', '-1', '1.5', 'Infinity', '2147483648', ' 60000']) {
    assert.throws(() => containerStartupTimeoutMs(invalid), /IOS_E2E_CONTAINER_STARTUP_TIMEOUT_MS/);
    assert.throws(() => backendStartupTimeoutMs(invalid), /IOS_E2E_BACKEND_STARTUP_TIMEOUT_MS/);
  }
});

test('container logs are forwarded immediately, but not after readiness', (t) => {
  const log = t.mock.method(console, 'log', () => {});
  const error = t.mock.method(console, 'error', () => {});
  const logger = containerStartupLogger('Core');
  const stream = new PassThrough();
  logger.consume(stream);
  stream.write('startup failure\n');
  assert.equal(log.mock.calls[0].arguments[0], '[iOS harness Core] startup failure');
  stream.emit('error', new Error('private details'));
  assert.equal(error.mock.calls[0].arguments[0], '[iOS harness Core] Startup log stream failed');
  logger.stop();
  stream.write('runtime session data');
  stream.emit('error', new Error('runtime error'));
  assert.equal(log.mock.callCount(), 1);
  assert.equal(error.mock.callCount(), 1);
  stream.end();
});

test('container startup output is bounded even before readiness fails', (t) => {
  const log = t.mock.method(console, 'log', () => {});
  const logger = containerStartupLogger('Postgres');
  const stream = new PassThrough();
  logger.consume(stream);
  stream.write(Buffer.alloc(64 * 1024 + 100, 'x'));
  stream.write('more output');
  assert.equal(log.mock.callCount(), 2);
  assert.equal(log.mock.calls[0].arguments[0], `[iOS harness Postgres] ${'x'.repeat(64 * 1024)}`);
  assert.equal(log.mock.calls[1].arguments[0], '[iOS harness Postgres] Startup logs capped at 64 KiB');
  stream.end();
});
