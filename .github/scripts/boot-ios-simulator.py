#!/usr/bin/env python3
"""Bound simulator boot and reap the entire command group on timeout."""
import os
import signal
import subprocess
import sys
import tempfile
import uuid


def run(command, timeout, stdout=None):
    process = subprocess.Popen(command, start_new_session=True, stdout=stdout)
    try:
        return process.wait(timeout=timeout) == 0
    except subprocess.TimeoutExpired:
        print(f"Timed out after {timeout}s: {' '.join(command)}", flush=True)
        return False
    finally:
        # simctl can leave children behind; don't wait on an unbounded cleanup command.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def create_device(runtime, device_type):
    with tempfile.TemporaryFile(mode='w+') as output:
        if not run(['xcrun', 'simctl', 'create', 'Rownd CI fallback', device_type, runtime],
                   15, stdout=output):
            return None
        output.seek(0)
        try:
            return str(uuid.UUID(output.read().strip())).upper()
        except ValueError:
            print('::error::Simulator creation returned an invalid UDID', flush=True)
            return None


def boot(udid, fallback_runtime, device_type, runner=run, creator=create_device):
    # A healthy cold boot on CI has taken over four minutes. Leave it five before retrying.
    for attempt, timeout in enumerate((300, 180)):
        if runner(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout):
            return udid
        print(f"::warning::Simulator boot attempt {attempt + 1} failed", flush=True)
        runner(['xcrun', 'simctl', 'list', 'devices'], 10)
        runner(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '2m',
                '--style', 'compact', '--predicate',
                'process == "backboardd" OR process == "SpringBoard"'], 15)
        if attempt == 0:
            if not runner(['xcrun', 'simctl', 'shutdown', udid], 20):
                print('::error::Simulator shutdown failed; refusing an overlapping boot', flush=True)
                return None
            print(f'Creating fresh fallback device on {fallback_runtime}; '
                  'the original device did not become ready', flush=True)
            udid = creator(fallback_runtime, device_type)
            if not udid:
                print('::error::Could not create fallback simulator', flush=True)
                return None
            print(f'Fallback simulator: {udid} ({fallback_runtime})', flush=True)
    print('::error::Simulator failed both bounded boot attempts', flush=True)
    return None


if __name__ == '__main__':
    def terminate(signum, _frame):
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    ready_udid = boot(*sys.argv[1:])
    if not ready_udid:
        sys.exit(1)
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        environment.write(f'IOS_SIMULATOR_UDID={ready_udid}\n'
                          f'IOS_SIMULATOR_DESTINATION=platform=iOS Simulator,id={ready_udid}\n')
