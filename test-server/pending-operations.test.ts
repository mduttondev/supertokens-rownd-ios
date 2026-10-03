import assert from 'node:assert/strict';
import test from 'node:test';
import { once } from 'node:events';
import http from 'node:http';
import express from 'express';
import { PendingOperations } from './pending-operations';

test('reset waits for a delayed profile handler even after its client disconnects', async () => {
  const operations = new PendingOperations();
  let finish!: () => void;
  const completion = new Promise<void>((resolve) => { finish = resolve; });
  let started!: () => void;
  const handlerStarted = new Promise<void>((resolve) => { started = resolve; });
  let resetting!: () => void;
  const resetStarted = new Promise<void>((resolve) => { resetting = resolve; });
  const captures: string[] = [];
  const app = express();
  app.put('/profile', (_req, res, next) => {
    void operations.run(async () => {
      started();
      await completion;
      captures.push('late profile success');
      res.json({ status: 'OK' });
    }).catch(next);
  });
  let resetFinished = false;
  app.post('/reset', async (_req, res) => {
    resetting();
    await operations.drain();
    captures.length = 0;
    resetFinished = true;
    res.json({ status: 'OK' });
  });
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  const url = `http://127.0.0.1:${address.port}`;
  try {
    const request = http.request(`${url}/profile`, { method: 'PUT' });
    request.on('error', () => {});
    request.end();
    await handlerStarted;
    const disconnected = new Promise<void>((resolve) => request.on('close', resolve));
    request.destroy();
    await disconnected;

    const reset = fetch(`${url}/reset`, { method: 'POST' });
    await resetStarted;
    assert.equal(resetFinished, false);
    finish();
    assert.equal((await reset).status, 200);
    captures.push('next test');
    assert.deepEqual(captures, ['next test']);
  } finally {
    finish();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('a stuck profile handler refuses reset without discarding its tracking', async () => {
  const operations = new PendingOperations();
  let finish!: () => void;
  const handler = operations.run(() => new Promise<void>((resolve) => { finish = resolve; }));
  let resetFinished = false;
  await assert.rejects(async () => {
    await operations.drain(10);
    resetFinished = true;
  }, /Timed out draining 1 profile operation\(s\); reset refused/);
  assert.equal(resetFinished, false);
  await assert.rejects(operations.drain(10), /reset refused/);
  finish();
  await handler;
  await operations.drain();
});

test('failed handlers release tracking and preserve the error', async () => {
  const operations = new PendingOperations();
  await assert.rejects(operations.run(async () => { throw new Error('profile failed'); }), /profile failed/);
  await operations.drain();
});
