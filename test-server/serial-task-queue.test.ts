import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SerialTaskQueue } from './serial-task-queue';

test('configuration restoration finishes before another fixture or reset begins', async () => {
  const queue = new SerialTaskQueue();
  const events: string[] = [];
  let release!: () => void;
  const blocked = new Promise<void>((resolve) => { release = resolve; });
  const first = queue.run(async () => {
    events.push('configure');
    await blocked;
    events.push('restore');
  });
  const second = queue.run(() => { events.push('next fixture'); });
  const reset = queue.run(() => { events.push('reset'); });
  await Promise.resolve();
  assert.deepEqual(events, ['configure']);
  release();
  await Promise.all([first, second, reset]);
  assert.deepEqual(events, ['configure', 'restore', 'next fixture', 'reset']);
});

test('failed fixtures release the queue without hiding their error', async () => {
  const queue = new SerialTaskQueue();
  const failure = new Error('fixture failed');
  const first = queue.run(async () => { throw failure; });
  const second = queue.run(() => 'next fixture');
  await assert.rejects(first, (error) => error === failure);
  assert.equal(await second, 'next fixture');
});
