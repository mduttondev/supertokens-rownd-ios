import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';

// Run against a dedicated harness, not concurrently with the simulator suite:
// TEST_BACKEND_URL=http://127.0.0.1:3100 node --import tsx --test test-server/expiring-session.integration.test.ts
test('overlapping expiry fixtures preserve their requested Core token lifetimes', {
  skip: !process.env.TEST_BACKEND_URL,
}, async () => {
  const lifetimes = await Promise.all([5, 30, 5, 30, 5].map(async (validity, index) => {
    await delay(index * 100);
    const response = await fetch(`${process.env.TEST_BACKEND_URL}/test/expiring-session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'st-auth-mode': 'header' },
      body: JSON.stringify({ accessTokenValidity: validity }),
    });
    await response.json();
    assert.equal(response.status, 200);
    const accessToken = response.headers.get('st-access-token');
    assert.ok(accessToken);
    const payload = JSON.parse(Buffer.from(accessToken.split('.')[1], 'base64url').toString());
    return { requested: validity, issued: payload.exp - payload.iat };
  }));
  for (const { requested, issued } of lifetimes) {
    assert.equal(issued, requested);
  }
});
