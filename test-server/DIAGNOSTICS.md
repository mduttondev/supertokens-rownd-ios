# E2E failure diagnostics

Release E2E jobs upload `ios-e2e-diagnostics-<run>-<attempt>` on failure or cancellation (7-day retention).
The runner writes snapshots before testing and **before failure cleanup**, while Core/Postgres
are still running, including on SIGINT/SIGTERM. A workflow fallback also samples resources
after a failed or cancelled step. Abrupt runner termination can still prevent uploads.

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
   the helper's 15-second monotonic polling budget runs out. If no PUT arrival exists, investigate
   SDK dispatch/transport rather than a slow plugin response.

Integration preparation releases harness holds and drains profile handlers, then waits
for SDK profile loading to finish before resetting shared state. `/reset` also drains
handlers, including disconnected requests, and refuses to clear captures if they remain
pending after 15 seconds. This protects tracked operations from being reset underneath
their completion; it does not block unrelated requests arriving later. A stuck operation
fails subsequent preparation explicitly.

Compare `ready` and pre-cleanup `failure` resource snapshots for swap, VM pressure,
guest pressure, and container CPU/memory. These are snapshots, not proof that no
transient pressure occurred between samples.

The Docker setup action v1.1.0 reads host `hw.ncpu` and `hw.memsize` and passes both
directly to Colima. In run 36980665092, the resulting arguments were `--cpu 4 --memory 14`
(log line 829): the host had 4 CPUs/14 GiB and the VM received all of both, not 14 GiB
out of a 16-GiB host. This establishes no configured RAM reserve, not measured swapping.
Source: https://github.com/douglascamata/setup-docker-macos-action/blob/v1.1.0/action.yml

## Infrastructure correction after run 37029409758

The job hit its 60-minute hard deadline. Docker setup consumed 19m04s: Homebrew
update took ~83s, the Docker/Compose/Buildx install ~12m12s (including building Go
and Docker from source), and Colima startup ~5m25s. The action has extra Colima
options, but no input to skip Homebrew or install only a binary Docker client.

Both Docker-backed workflows now use `.github/scripts/setup-docker-macos.sh`:
checksum-pinned Lima 1.2.1, Colima 0.9.1, and Docker CLI 28.3.3 binaries, without
Homebrew, Compose, or Buildx. Colima uses 2 CPUs/4 GiB instead of 4 CPUs/14 GiB.
This limits guest contention; it does not dedicate or reserve physical host CPUs.
At readiness, the old guest used 851 MiB with 13,123 MiB available and no swap;
host load was 15.62 on four CPUs. These samples support reducing contention,
**not** a diagnosis of OOM. The smaller VM may slow cold pulls/Core startup;
compare startup times and existing resource snapshots on the next CI run.

Release E2E has a 50-minute step limit inside a 75-minute job (previously an
unbounded step inside 60 minutes). Setup has individual limits; the target is
20 minutes or less, leaving cancellation/diagnostic headroom. This raises the
worst-case billed job ceiling by 15 minutes, but removes the measured source-build
overhead. Safari still runs, now with `IOS_E2E_ONLY_UI=1` so integration and example
tests are not repeated. No test or HTTP request timeout was relaxed.

The integration suite recorded one issue across 22 tests: the `waitForExpiry=true`
refresh-outage fixture timed out before the job cancellation. Its configuration
phase took 89.631s; its queue wait was only 1ms. Restoration later failed with
`No SuperTokens core available to query`. A subsequent fixture succeeded, so
this is not evidence of a permanently dead Core. The infrastructure changes
mitigate the observed slow environment; resolving that failure still requires
a CI rerun. Example/UI/Safari coverage was not reached in this failed run.

Checks:

```sh
node --import tsx --test test-server/diagnostics.test.ts test-server/serial-task-queue.test.ts test-server/startup.test.ts
```

Full xcresult bundles and container logs are intentionally not uploaded: they can
contain authentication data and add substantial artifact volume.
