#!/usr/bin/env python3
"""Bound simulator boot and reap the entire command group on timeout."""
import os
import signal
import subprocess
import sys


def run(command, timeout):
    process = subprocess.Popen(command, start_new_session=True)
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


def boot(udid, runner=run):
    # A healthy cold boot on CI has taken over four minutes. Leave it five before retrying.
    for attempt, timeout in enumerate((300, 180)):
        if runner(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout):
            return True
        print(f"::warning::Simulator boot attempt {attempt + 1} failed", flush=True)
        runner(['xcrun', 'simctl', 'list', 'devices'], 10)
        runner(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '2m',
                '--style', 'compact', '--predicate',
                'process == "backboardd" OR process == "SpringBoard"'], 15)
        if attempt == 0:
            if not runner(['xcrun', 'simctl', 'shutdown', udid], 20):
                print('::error::Simulator shutdown failed; refusing an overlapping boot', flush=True)
                return False
    print('::error::Simulator failed both bounded boot attempts', flush=True)
    return False


if __name__ == '__main__':
    def terminate(signum, _frame):
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    sys.exit(0 if boot(sys.argv[1]) else 1)
