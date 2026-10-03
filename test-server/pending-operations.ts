import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';

// Track handler completion, not socket close: disconnected requests still mutate Core.
export class PendingOperations {
  private readonly pending = new Set<Promise<unknown>>();

  async run<T>(operation: () => Promise<T>): Promise<T> {
    const result = Promise.resolve().then(operation);
    this.pending.add(result);
    try {
      return await result;
    } finally {
      this.pending.delete(result);
    }
  }

  async drain(timeoutMs = 15_000): Promise<void> {
    const deadline = performance.now() + timeoutMs;
    while (this.pending.size > 0) {
      const remaining = deadline - performance.now();
      if (remaining <= 0) {
        throw new Error(`Timed out draining ${this.pending.size} profile operation(s); reset refused`);
      }
      await delay(Math.min(25, remaining));
    }
  }
}
