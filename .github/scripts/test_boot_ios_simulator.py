import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('boot', Path(__file__).with_name('boot-ios-simulator.py'))
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)


class BootTests(unittest.TestCase):
    def simulate(self, boot_results, shutdown=True, created_udid='fresh-udid'):
        calls = []

        def runner(command, timeout):
            calls.append((command, timeout))
            if command[2] == 'bootstatus':
                return boot_results.pop(0)
            if command[2] == 'shutdown':
                return shutdown
            return True

        def creator(runtime, device_type):
            self.assertEqual(runtime, 'ios-26-2')
            self.assertEqual(device_type, 'iphone-17')
            calls.append((['xcrun', 'simctl', 'create'], 15))
            return created_udid

        result = boot.boot('test-udid', 'ios-26-2', 'iphone-17', runner, creator)
        return result, calls

    def test_success_does_not_reboot(self):
        result, calls = self.simulate([True])
        self.assertEqual(result, 'test-udid')
        self.assertEqual(len(calls), 1)

    def test_failure_retries_fresh_device_and_returns_its_destination(self):
        result, calls = self.simulate([False, True])
        self.assertEqual(result, 'fresh-udid')
        self.assertEqual([command[2] for command, _ in calls],
                         ['bootstatus', 'list', 'spawn', 'shutdown', 'create', 'bootstatus'])
        self.assertEqual(calls[0][0][3], 'test-udid')
        self.assertEqual(calls[-1][0][3], 'fresh-udid')
        self.assertLessEqual(sum(timeout for _, timeout in calls), 565)

    def test_second_failure_is_terminal_and_bounded(self):
        result, calls = self.simulate([False, False])
        self.assertFalse(result)
        self.assertEqual(sum(command[2] == 'bootstatus' for command, _ in calls), 2)
        self.assertLessEqual(sum(timeout for _, timeout in calls), 565)
        self.assertFalse(any('delete' in command or 'erase' in command for command, _ in calls))

    def test_failed_shutdown_prevents_overlapping_boot(self):
        result, calls = self.simulate([False], shutdown=False)
        self.assertFalse(result)
        self.assertEqual(calls[-1][0][2], 'shutdown')

    def test_failed_creation_does_not_retry_original_device(self):
        result, calls = self.simulate([False], created_udid=None)
        self.assertIsNone(result)
        self.assertEqual(sum(command[2] == 'bootstatus' for command, _ in calls), 1)

    def test_timeout_kills_command_and_child(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / 'pids'
            script = (
                'import os, subprocess, sys, time; '
                'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"]); '
                f'open({str(pid_file)!r}, "w").write(f"{{os.getpid()}} {{child.pid}}"); '
                'time.sleep(60)'
            )
            self.assertFalse(boot.run([sys.executable, '-c', script], 1))
            for pid in pid_file.read_text().split():
                # An orphan may briefly be a zombie; it must not still be running.
                status = subprocess.run(['ps', '-o', 'stat=', '-p', pid], capture_output=True, text=True)
                self.assertTrue(status.returncode != 0 or status.stdout.strip().startswith('Z'))


if __name__ == '__main__':
    unittest.main()
