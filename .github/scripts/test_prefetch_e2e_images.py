import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prefetch-e2e-images.sh")
DEFAULT_CORE = "supertokens/supertokens-postgresql:12.0.10"
RYUK = "testcontainers/ryuk:0.14.0"


class PrefetchImagesTests(unittest.TestCase):
    def run_prefetch(self, core="", cached=False, fail_image=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text("""#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ['DOCKER_CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['image', 'inspect']:
    sys.exit(0 if os.environ['IMAGES_CACHED'] == '1' else 1)
if sys.argv[1] == 'pull':
    sys.exit(23 if sys.argv[2] == os.environ['FAIL_IMAGE'] else 0)
sys.exit(99)
""")
            docker.chmod(0o755)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       DOCKER_CALLS=str(log), E2E_CORE_IMAGE=core,
                       RYUK_CONTAINER_IMAGE="", IMAGES_CACHED="1" if cached else "0",
                       FAIL_IMAGE=fail_image)
            result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result.returncode, calls

    def test_defaults_and_configured_core_tag_or_digest(self):
        for core in ("", "example/core:custom", "example/core@sha256:" + "a" * 64):
            with self.subTest(core=core):
                status, calls = self.run_prefetch(core=core)
                self.assertEqual(status, 0)
                self.assertEqual(calls, [
                    call for image in ("postgres:14", core or DEFAULT_CORE, RYUK)
                    for call in (["image", "inspect", image], ["pull", image])
                ])

    def test_warm_images_do_not_pull(self):
        status, calls = self.run_prefetch(cached=True)
        self.assertEqual(status, 0)
        self.assertEqual(calls, [["image", "inspect", image]
                                 for image in ("postgres:14", DEFAULT_CORE, RYUK)])

    def test_pull_failure_propagates_and_stops_prefetch(self):
        status, calls = self.run_prefetch(fail_image=DEFAULT_CORE)
        self.assertEqual(status, 23)
        self.assertEqual(calls[-1], ["pull", DEFAULT_CORE])
        self.assertFalse(any(RYUK in call for call in calls))


if __name__ == "__main__":
    unittest.main()
