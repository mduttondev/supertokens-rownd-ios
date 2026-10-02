# E2E failure diagnostics

Release E2E jobs upload `ios-e2e-diagnostics-<run>-<attempt>` on failure (7-day retention).
The runner writes snapshots before testing and **before failure cleanup**, while Core/Postgres
are still running. A workflow fallback also samples resources after a failed step.

To enable locally:

```sh
IOS_E2E_DIAGNOSTICS_DIR=/absolute/path/to/diagnostics npm run test:e2e
```

Files are separated by process ID and capped at 1 MiB each:

- `requests-*.ndjson`: fixed endpoints, request IDs, timestamps, elapsed milliseconds,
  response status/completion, client abort/close, and capture state. No headers, tokens,
  bodies, query strings, exception details, or user/session identifiers.
- `resources-*.ndjson`: host capacity/swap/VM counters, 30 largest processes by RSS
  (executable names, not arguments), Colima status and guest memory/pressure counters,
  Docker capacity and one-shot usage. Eight concurrent probes, each with a 5-second
  timeout and 64 KiB output limit; unavailable probes do not fail the tests.

Test output and failure details remain in the GitHub Actions console. Child processes
inherit stdio; the runner does not capture output through pipes or create test-summary
artifacts. This avoids introducing a pipe-drain dependency on surviving descendants.

## Reading the five outstanding failures from run 36980665092

- **Expiry fixture timeouts:** group `/test/expiring-session` events by `requestId`.
  Phases are `queue`, `config`, `user`, `session`, `session-info`, and `restore`.
  Each has a start and an end/error with `phaseDurationMs`. A phase start without
  an end identifies the outstanding operation. `response_close` with `completed:false`
  distinguishes a disconnected client; subsequent restore logs show server work continuing.
  Reset snapshots cover open responses only: a disconnected handler drops out of those
  snapshots even if its work continues. Follow later phase events with the same
  `requestId` to determine whether that handler completed/restored configuration.
- **Profile PUT waits:** arrivals are recorded before JSON parsing. `not-captured`
  means plugin capture middleware has not run; `pending` means it has run but its
  response has not finished. `completed` matches the captured status the Swift helper
  waits for. `superseded` means another request or reset replaced that capture entry.
  A 2-second pending event and reset snapshots expose operations still in flight when
  the helper's short polling budget runs out. If no PUT arrival exists, investigate
  SDK dispatch/transport rather than a slow plugin response.

Compare `ready` and pre-cleanup `failure` resource snapshots for swap, VM pressure,
guest pressure, and container CPU/memory. These are snapshots, not proof that no
transient pressure occurred between samples. No resource allocations or timeouts
were changed by this instrumentation.

The Docker setup action v1.1.0 reads host `hw.ncpu` and `hw.memsize` and passes both
directly to Colima. In run 36980665092, the resulting arguments were `--cpu 4 --memory 14`
(log line 829): the host had 4 CPUs/14 GiB and the VM received all of both, not 14 GiB
out of a 16-GiB host. This establishes no configured RAM reserve, not measured swapping.
Source: https://github.com/douglascamata/setup-docker-macos-action/blob/v1.1.0/action.yml

Checks:

```sh
node --import tsx --test test-server/diagnostics.test.ts test-server/serial-task-queue.test.ts test-server/startup.test.ts
```

Full xcresult bundles and container logs are intentionally not uploaded: they can
contain authentication data and add substantial artifact volume.
