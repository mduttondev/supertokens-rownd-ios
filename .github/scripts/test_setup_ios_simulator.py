import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('setup-ios-simulator.sh')
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
PRIMARY = '00000000-0000-0000-0000-000000000001'
FALLBACK = '00000000-0000-0000-0000-000000000002'


def runtime(version, available=True, supported=True):
    return {
        'identifier': f'com.apple.CoreSimulator.SimRuntime.iOS-{version.replace(".", "-")}',
        'version': version,
        'isAvailable': available,
        'supportedDeviceTypes': [{'identifier': DEVICE_TYPE}] if supported else [],
    }


# Exercise the real shell selector and Python CLI without touching CoreSimulator.
FAKE_XCRUN = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
fixture = json.loads(Path(os.environ['SIM_FIXTURE']).read_text())
with open(os.environ['SIM_CALLS'], 'a') as calls:
    calls.write(json.dumps(args) + '\\n')
if args == ['--sdk', 'iphonesimulator', '--show-sdk-version']:
    print('26.0')
elif args[:3] == ['simctl', 'list', 'runtimes']:
    print(json.dumps({'runtimes': fixture['runtimes']}))
elif args[:3] == ['simctl', 'list', 'devices']:
    print(json.dumps({'devices': fixture['devices']}))
elif args[:2] == ['simctl', 'bootstatus']:
    sys.exit(fixture.get('boot_exit', {}).get(args[2], 0))
elif args[:2] == ['simctl', 'shutdown']:
    sys.exit(fixture.get('shutdown_exit', 0))
elif args[:2] == ['simctl', 'create']:
    print(fixture['created_udid'])
    sys.exit(fixture.get('create_exit', 0))
elif args[:2] != ['simctl', 'spawn']:
    raise AssertionError(args)
'''


class ProvisioningTests(unittest.TestCase):
    def provision(self, runtimes=None, **overrides):
        primary_runtime = runtime('26.0')['identifier']
        fixture = {
            'runtimes': runtimes if runtimes is not None else [runtime('26.0'), runtime('26.2')],
            'devices': {primary_runtime: [{
                'udid': PRIMARY, 'deviceTypeIdentifier': DEVICE_TYPE,
                'isAvailable': True, 'state': 'Booted',
            }]},
            'created_udid': FALLBACK,
            **overrides,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, script in [('xcrun', FAKE_XCRUN), ('xcodebuild', '#!/bin/sh\necho Xcode 26.0.1\n'),
                                 ('sleep', '#!/bin/sh\nexit 0\n')]:
                path = root / name
                path.write_text(script)
                path.chmod(0o755)
            (root / 'fixture.json').write_text(json.dumps(fixture))
            result = subprocess.run(['bash', str(SCRIPT)], capture_output=True, text=True, timeout=15,
                                    env={**os.environ, 'PATH': f'{root}:{os.environ["PATH"]}',
                                         'SIM_FIXTURE': str(root / 'fixture.json'),
                                         'SIM_CALLS': str(root / 'calls.jsonl'),
                                         'GITHUB_ENV': str(root / 'env')})
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
            environment = (root / 'env').read_text() if (root / 'env').exists() else ''
            self.assertFalse(any('erase' in call or 'delete' in call or 'all' in call for call in calls))
            return result, calls, environment

    def test_healthy_sdk_matching_device_is_reused_without_creation(self):
        result, calls, environment = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'IOS_SIMULATOR_UDID={PRIMARY}\n', environment)
        self.assertFalse(any(call[1] in ('create', 'shutdown') for call in calls))

    def test_failed_readiness_uses_newest_supported_alternate_and_exports_new_udid(self):
        result, calls, environment = self.provision(
            runtimes=[runtime('26.2'), runtime('27.0', available=False),
                      runtime('26.0'), runtime('28.0', supported=False), runtime('26.1')],
            boot_exit={PRIMARY: 1})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'create', 'Rownd CI fallback', DEVICE_TYPE,
                       runtime('26.2')['identifier']], calls)
        self.assertEqual([call for call in calls if call[1] == 'bootstatus'],
                         [['simctl', 'bootstatus', PRIMARY, '-b'],
                          ['simctl', 'bootstatus', FALLBACK, '-b']])
        self.assertIn(f'IOS_SIMULATOR_DESTINATION=platform=iOS Simulator,id={FALLBACK}\n', environment)
        self.assertNotIn(PRIMARY, environment)

    def test_versions_are_sorted_numerically_for_fallback(self):
        result, calls, _ = self.provision(runtimes=[runtime('26.0'), runtime('26.10'), runtime('26.2')],
                                          boot_exit={PRIMARY: 1})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(call[-1] for call in calls if call[1] == 'create'),
                         runtime('26.10')['identifier'])

    def test_single_runtime_still_retries_a_fresh_device(self):
        result, calls, environment = self.provision(runtimes=[runtime('26.0')], boot_exit={PRIMARY: 1})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(call[-1] for call in calls if call[1] == 'create'),
                         runtime('26.0')['identifier'])
        self.assertIn(FALLBACK, environment)

    def test_no_sdk_matching_runtime_uses_newest_supported_runtime(self):
        result, calls, environment = self.provision(runtimes=[runtime('26.1'), runtime('26.2')])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(call[-1] for call in calls if call[1] == 'create'),
                         runtime('26.2')['identifier'])
        self.assertIn(FALLBACK, environment)

    def test_no_supported_runtime_fails_without_booting(self):
        result, calls, environment = self.provision(runtimes=[runtime('26.0', supported=False)])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[1] == 'bootstatus' for call in calls))
        self.assertEqual(environment, '')

    def test_failures_never_export_an_unready_destination(self):
        for overrides in [
            {'boot_exit': {PRIMARY: 1, FALLBACK: 1}},
            {'boot_exit': {PRIMARY: 1}, 'shutdown_exit': 1},
            {'boot_exit': {PRIMARY: 1}, 'create_exit': 1},
            {'boot_exit': {PRIMARY: 1}, 'created_udid': 'invalid'},
        ]:
            with self.subTest(overrides=overrides):
                result, calls, environment = self.provision(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(environment, '')
                self.assertLessEqual(sum(call[1] == 'bootstatus' for call in calls), 2)


if __name__ == '__main__':
    unittest.main()
