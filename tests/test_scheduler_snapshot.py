#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Exercise real curl/archive tools against local fixtures and a mock kubectl.

No Kubernetes API, scheduler, credentials, or external network is used.
Run: python3 -m unittest discover -s tests -p 'test_scheduler_snapshot.py' -v
"""

import gzip
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time
import unittest
import warnings
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SCRIPT = Path(__file__).resolve().parents[1] / "scheduler_snapshot.sh"
SNAPSHOT = b'{"config":{},"schedulerParams":{},"rawObjects":{"pods":[]}}'
MOCK_KUBECTL = r'''#!/usr/bin/env python3
import json
import os
import signal
import sys
import time

args = sys.argv[1:]
with open(os.environ["MOCK_COMMANDS"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["get", "deployments"]:
    assert "--request-timeout=30s" in args
    if os.environ.get("MOCK_DISCOVERY_FAIL"):
        print("mock discovery denied", file=sys.stderr)
        sys.exit(1)
    print(os.environ["MOCK_DEPLOYMENTS"])
    sys.exit(0)
if args[0] != "port-forward":
    sys.exit("unexpected mock kubectl command")
assert args[args.index("--address") + 1] == "127.0.0.1"
assert args[-1] == ":8081"
assert any(arg.startswith("--pod-running-timeout=") for arg in args)
deployment = next(arg.split("/", 1)[1] for arg in args if arg.startswith("deployment/"))
with open(os.environ["MOCK_PIDS"], "a") as log:
    log.write(str(os.getpid()) + "\n")
mode = os.environ.get("MOCK_FORWARD_MODE", "ready")
if mode == "fail":
    print("mock port-forward denied", file=sys.stderr)
    sys.exit(1)
def finish(signum, frame):
    sys.exit(0)
signal.signal(signal.SIGTERM, finish)
if mode == "delay":
    time.sleep(0.25)
if mode != "stalled":
    port = json.loads(os.environ["MOCK_PORTS"])[deployment]
    print(f"Forwarding from 127.0.0.1:{port} -> 8081", flush=True)
while True:
    time.sleep(0.1)
'''


def zip_snapshot(payload=SNAPSHOT, name="snapshot.json", duplicate=False, duplicate_payload=None):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(name, payload)
        if duplicate:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr(name, payload if duplicate_payload is None else duplicate_payload)
    return buffer.getvalue()


@unittest.skipUnless(
    all(shutil.which(tool) for tool in ("bash", "curl", "jq", "unzip", "gzip")),
    "bash, curl, jq, unzip and gzip are required",
)
class SchedulerSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        kubectl = self.bin / "kubectl"
        kubectl.write_text(MOCK_KUBECTL)
        kubectl.chmod(0o700)
        self.commands = self.root / "commands.jsonl"
        self.pids = self.root / "pids.txt"
        self.ports = {}
        self.requests = []
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "MOCK_COMMANDS": str(self.commands),
            "MOCK_PIDS": str(self.pids),
            "RUNAI_PORT_FORWARD_TIMEOUT_SECONDS": "2",
            "RUNAI_SNAPSHOT_TIMEOUT_SECONDS": "2",
            # Inherited curl/proxy settings must not redirect the local fixture request.
            "http_proxy": "http://127.0.0.1:1",
            "HTTP_PROXY": "http://127.0.0.1:1",
            "ALL_PROXY": "http://127.0.0.1:1",
            "NO_PROXY": "",
            "no_proxy": "",
        }
        self.addCleanup(self.assert_no_live_forwarders)

    def serve(self, deployment="runai-scheduler-default", payload=None, status=200, delay=0):
        if payload is None:
            payload = zip_snapshot()
        requests = self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(handler):
                requests.append(handler.path)
                time.sleep(delay)
                handler.send_response(status)
                handler.send_header("Content-Length", str(len(payload)))
                handler.end_headers()
                try:
                    handler.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(handler, format, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.ports[deployment] = server.server_port

    def run_script(self, deployments=None, **env):
        if deployments is None:
            deployments = "\n".join(self.ports)
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=self.root,
            env={**self.env, "MOCK_DEPLOYMENTS": deployments, "MOCK_PORTS": json.dumps(self.ports), **env},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assert_no_live_forwarders()
        self.assertEqual(list(self.root.rglob("*.part")), [], result.stderr)
        return result

    def captures(self):
        return list(self.root.glob("scheduler-snapshots-*/*-snapshot.gzip"))

    def assert_no_live_forwarders(self):
        if not self.pids.exists():
            return
        for pid in self.pids.read_text().splitlines():
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                continue
            self.fail(f"mock port-forward {pid} was not reaped")

    def test_zip_and_gzip_snapshots_are_saved_privately_without_overwrite(self):
        payloads = (zip_snapshot(), gzip.compress(SNAPSHOT))
        for payload in payloads:
            self.serve(payload=payload)
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Collected 1 of 1", result.stdout)
        captures = self.captures()
        self.assertEqual(len(captures), 2)
        self.assertEqual({capture.read_bytes() for capture in captures}, set(payloads))
        for capture in captures:
            self.assertEqual(stat.S_IMODE(capture.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(capture.stat().st_mode), 0o600)
        self.assertEqual(self.requests, ["/get-snapshot", "/get-snapshot"])

    def test_discovery_failure_is_distinct_from_empty_discovery(self):
        result = self.run_script(MOCK_DISCOVERY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mock discovery denied", result.stderr)
        self.assertIn("Failed to discover", result.stderr)
        self.assertNotIn("No RunAI", result.stderr)
        self.assertEqual(self.captures(), [])

    def test_no_scheduler_is_not_a_successful_collection(self):
        for deployments in ("", "other-deployment\nrunai-binder"):
            with self.subTest(deployments=deployments):
                result = self.run_script(deployments=deployments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No RunAI scheduler deployments", result.stderr)
        self.assertFalse(self.pids.exists())

    def test_partial_failure_preserves_valid_snapshots_and_counts_them(self):
        self.serve("runai-scheduler-failed", b"unavailable", status=503)
        self.serve("runai-scheduler-good")
        result = self.run_script(deployments="runai-scheduler-failed\nrunai-scheduler-good")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Collected 1 of 2", result.stdout)
        self.assertEqual([capture.name for capture in self.captures()], ["runai-scheduler-good-snapshot.gzip"])

    def test_http_errors_redirects_and_empty_success_are_rejected(self):
        for status in (404, 500, 302, 204):
            with self.subTest(status=status):
                self.serve(payload=zip_snapshot(), status=status)
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Collected 0 of 1", result.stdout)
        self.assertEqual(self.captures(), [])

    def test_invalid_archives_are_not_published(self):
        for payload in (b"", b"<html>not a snapshot</html>", zip_snapshot()[:-20], gzip.compress(SNAPSHOT)[:-5]):
            with self.subTest(payload=payload[:10]):
                self.serve(payload=payload)
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid snapshot", result.stderr)
        self.assertEqual(self.captures(), [])

    def test_zip_requires_snapshot_json(self):
        self.serve(payload=zip_snapshot(name="error.json"))
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.captures(), [])

    def test_json_syntax_and_documented_top_level_shape_are_checked(self):
        for payload in (SNAPSHOT[:-1], b'{}', b'[]', b'null',
                        b'{"config":{},"schedulerParams":{},"rawObjects":null}',
                        b'{"config":null,"schedulerParams":{},"rawObjects":{}}',
                        b'{"config":{},"schedulerParams":[],"rawObjects":{}}'):
            with self.subTest(payload=payload):
                self.serve(payload=zip_snapshot(payload))
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid snapshot", result.stderr)
                self.assertNotIn(payload.decode(), result.stdout)
        self.assertEqual(self.captures(), [])

    def test_extra_snapshot_fields_do_not_require_a_version_specific_schema(self):
        payload = json.dumps({"config": {}, "schedulerParams": {}, "rawObjects": {}, "futureField": {"enabled": True}}).encode()
        self.serve(payload=zip_snapshot(payload))
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.captures()), 1)

    def test_multiple_json_documents_and_duplicate_zip_entries_are_rejected(self):
        for payload in (gzip.compress(SNAPSHOT + b"\n" + SNAPSHOT),
                        gzip.compress(SNAPSHOT) + gzip.compress(SNAPSHOT),
                        zip_snapshot(duplicate=True),
                        zip_snapshot(b"", duplicate=True, duplicate_payload=SNAPSHOT),
                        zip_snapshot(b" \n", duplicate=True, duplicate_payload=SNAPSHOT),
                        zip_snapshot(duplicate=True, duplicate_payload=b"")):
            with self.subTest(payload=payload[:10]):
                self.serve(payload=payload)
                self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.captures(), [])

    def test_snapshot_request_has_a_deadline(self):
        self.serve(delay=3)
        started = time.monotonic()
        result = self.run_script(RUNAI_SNAPSHOT_TIMEOUT_SECONDS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to get snapshot", result.stderr)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(self.captures(), [])

    def test_failed_and_stalled_forwarders_are_not_used(self):
        for mode in ("fail", "stalled"):
            with self.subTest(mode=mode):
                self.serve()
                result = self.run_script(MOCK_FORWARD_MODE=mode, RUNAI_PORT_FORWARD_TIMEOUT_SECONDS="1")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Port-forward failed or timed out", result.stderr)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.captures(), [])

    def test_delayed_forwarder_readiness_is_waited_for(self):
        self.serve()
        result = self.run_script(MOCK_FORWARD_MODE="delay")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.captures()), 1)

    def test_namespace_override_is_used_for_discovery_and_forwarding(self):
        self.serve()
        result = self.run_script(RUNAI_NAMESPACE="diagnostics")
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in self.commands.read_text().splitlines():
            args = json.loads(line)
            self.assertEqual(args[args.index("-n") + 1], "diagnostics")

    def test_invalid_timeout_and_discovery_name_fail_before_forwarding(self):
        for timeout in ("0", "-1", "invalid", "100000"):
            with self.subTest(timeout=timeout):
                result = self.run_script(RUNAI_SNAPSHOT_TIMEOUT_SECONDS=timeout)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Timeouts must be integers", result.stderr)
        result = self.run_script(deployments="runai-scheduler-../../unsafe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid scheduler deployment name", result.stderr)
        self.assertFalse(self.pids.exists())

    def test_termination_cleans_up_the_forwarder(self):
        self.serve()
        process = subprocess.Popen(
            ["bash", str(SCRIPT)], cwd=self.root,
            env={**self.env, "MOCK_DEPLOYMENTS": "runai-scheduler-default", "MOCK_PORTS": json.dumps(self.ports),
                 "MOCK_FORWARD_MODE": "stalled"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            deadline = time.monotonic() + 3
            while not self.pids.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.pids.exists(), "forwarder did not start")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, stdout + stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
