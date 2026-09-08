"""Exercise the real CLI and persistence with a test-only platform adapter."""

import json
import os
import fcntl
from contextlib import closing
from pathlib import Path
import subprocess
import sqlite3
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = None
BINARY = None
A = "11111111-1111-1111-1111-111111111111"
B = "22222222-2222-2222-2222-222222222222"


def setUpModule():
    global BUILD, BINARY
    # Moon does not track C #include dependencies for the platform wrappers.
    # A fresh target directory guarantees tests exercise the current sources.
    BUILD = tempfile.TemporaryDirectory(prefix="ankerscale-cli-build-")
    release = os.environ.get("ANKERSCALE_TEST_RELEASE") == "1"
    subprocess.run(
        [
            "moon",
            "build",
            "--deny-warn",
            "--target-dir",
            BUILD.name,
            *(["--release"] if release else []),
            "tests/cli",
        ],
        cwd=ROOT,
        check=True,
    )
    BINARY = (
        Path(BUILD.name)
        / "native"
        / ("release" if release else "debug")
        / "build/tests/cli/cli.exe"
    )


def tearDownModule():
    BUILD.cleanup()


class CliTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ankerscale-cli-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.data = self.root / "Library/Application Support/AnkerScale"
        self.data.mkdir(parents=True)
        self.registry = self.data / "devices.json"
        self.env = {**os.environ, "ANKERSCALE_TEST_HOME": str(self.root)}

    def run_cli(self, *args, input="", code=0):
        result = subprocess.run(
            [str(BINARY), *args],
            input=input,
            text=True,
            capture_output=True,
            env=self.env,
            timeout=15,
        )
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def write_registry(self, devices):
        temporary = self.registry.with_suffix(".tmp")
        temporary.write_text(json.dumps({"version": 1, "devices": devices}))
        temporary.replace(self.registry)

    def scenario(self, devices, **options):
        path = self.root / "scenario.json"
        path.write_text(json.dumps({"devices": devices, **options}))
        self.env["ANKERSCALE_TEST_SCENARIO"] = str(path)

    def commands(self):
        return [
            json.loads(line)
            for line in (self.data / "ble-commands.jsonl").read_text().splitlines()
        ]

    def start_collector(self):
        output = self.root / "collector.stdout"
        errors = self.root / "collector.stderr"
        with output.open("w") as stdout, errors.open("w") as stderr:
            process = subprocess.Popen(
                [str(BINARY), "collect"], stdout=stdout, stderr=stderr, env=self.env
            )

        def cleanup():
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=8)

        self.addCleanup(cleanup)
        return process

    def rows(self, sql):
        with closing(
            sqlite3.connect(f"file:{self.data / 'records.sqlite3'}?mode=ro", uri=True)
        ) as connection:
            return connection.execute(sql).fetchall()

    def await_condition(self, process, condition, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.assertIsNone(
                process.poll(), (self.root / "collector.stderr").read_text()
            )
            try:
                if condition():
                    return
            except (sqlite3.OperationalError, FileNotFoundError):
                pass  # The collector may not have initialized its outputs yet.
            time.sleep(0.05)
        self.fail(
            "collector did not reach the expected state: "
            + (self.root / "collector.stderr").read_text()
        )

    def stop_collector(self, process, code=0):
        process.terminate()
        self.assertEqual(
            process.wait(timeout=8), code, (self.root / "collector.stderr").read_text()
        )

    def test_devices_empty_without_bluetooth_or_file_creation(self):
        self.assertEqual(json.loads(self.run_cli("devices", "--json").stdout), [])
        self.assertEqual(list(self.data.iterdir()), [])

    def test_devices_lists_registration_not_observation_history(self):
        devices = [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        self.write_registry(devices)
        self.assertEqual(json.loads(self.run_cli("devices", "--json").stdout), devices)

    def test_unregister_removes_selection_and_keeps_other_devices(self):
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.run_cli("unregister", input="1\n")
        self.assertEqual(
            json.loads(self.registry.read_text())["devices"],
            [{"id": B, "name": "eufy T9120"}],
        )

    def test_legacy_setting_is_read_without_migrating(self):
        (self.data / "service.json").write_text(json.dumps({"device": A}))
        devices = json.loads(self.run_cli("devices", "--json").stdout)
        self.assertEqual([device["id"] for device in devices], [A])
        self.assertFalse(self.registry.exists())

    def test_empty_registry_does_not_resurrect_legacy_device(self):
        (self.data / "service.json").write_text(json.dumps({"device": A}))
        self.write_registry([])
        self.assertEqual(json.loads(self.run_cli("devices", "--json").stdout), [])

    def test_unregistered_start_has_actionable_error_before_os_registration(self):
        result = self.run_cli("service", "start", code=2)
        self.assertIn("register", result.stderr)
        self.assertNotIn("unexpected service operation", result.stderr)

    def test_service_start_migrates_legacy_without_device_argument(self):
        (self.data / "service.json").write_text(json.dumps({"device": A}))
        result = self.run_cli("service", "start")
        self.assertIn("Migrated", result.stderr)
        self.assertEqual(json.loads(result.stdout)["registration"], "enabled")
        self.assertEqual(
            [d["id"] for d in json.loads(self.registry.read_text())["devices"]], [A]
        )
        self.run_cli("service", "stop")
        self.assertEqual(
            [d["id"] for d in json.loads(self.registry.read_text())["devices"]], [A]
        )

    def test_unregister_last_legacy_device_creates_authoritative_empty_registry(self):
        (self.data / "service.json").write_text(json.dumps({"device": A}))
        result = self.run_cli("unregister", input="1\n")
        self.assertIn("Migrated", result.stderr)
        self.assertEqual(json.loads(self.run_cli("devices", "--json").stdout), [])

    def test_invalid_registry_is_an_error_not_an_empty_allowlist(self):
        for contents in (
            "{",
            '{"version":2,"devices":[]}',
            '{"version":1,"devices":[{"id":"bad","name":"scale"}]}',
        ):
            with self.subTest(contents=contents):
                self.registry.write_text(contents)
                self.run_cli("devices", "--json", code=1)
                self.assertEqual(self.registry.read_text(), contents)

    def test_duplicate_registry_uuid_is_rejected(self):
        self.write_registry([{"id": A, "name": "first"}, {"id": A, "name": "second"}])
        self.assertIn("duplicate", self.run_cli("devices", "--json", code=1).stderr)

    def test_invalid_selection_and_cancellation_do_not_modify_registration(self):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        original = self.registry.read_bytes()
        for selection, code in (
            ("0\n", 2),
            ("2\n", 2),
            ("1,x\n", 2),
            ("\n", 0),
            ("", 0),
        ):
            with self.subTest(selection=selection):
                self.run_cli("unregister", input=selection, code=code)
                self.assertEqual(self.registry.read_bytes(), original)

    def test_failed_atomic_write_preserves_original_registration(self):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        original = self.registry.read_bytes()
        (self.data / "devices.lock").touch(mode=0o600)
        self.data.chmod(0o500)
        self.addCleanup(self.data.chmod, 0o700)
        self.run_cli("unregister", input="1\n", code=1)
        self.assertEqual(self.registry.read_bytes(), original)

    def test_obsolete_device_and_scan_options_are_rejected(self):
        self.run_cli("service", "start", "--device", A, code=2)
        self.run_cli("collect", "--device", A, code=2)
        self.run_cli("devices", "--seconds", "1", code=2)
        for seconds in ("0", "301", "abc"):
            self.run_cli("register", "--seconds", seconds, code=2)

    def test_register_filters_duplicates_and_verifies_before_saving(self):
        self.scenario(
            [
                {"device": A, "name": "eufy T9120", "services": []},
                {"device": A, "name": "eufy T9120", "services": ["FFF0"]},
                {"device": B, "name": "eufy T9148", "services": ["FFF0"]},
            ]
        )
        result = self.run_cli("register", "--seconds", "1", input="1,1\n")
        self.assertNotIn("eufy T9148", result.stdout)
        self.assertEqual(
            json.loads(self.registry.read_text())["devices"],
            [{"id": A, "name": "eufy T9120"}],
        )
        operations = [command["op"] for command in self.commands()]
        self.assertEqual(operations.count("ble_connect"), 1)
        self.assertIn("ble_discover", operations)
        self.assertIn("ble_disconnect", operations)
        self.assertNotIn("ble_subscribe", operations)
        self.assertNotIn("ble_write", operations)
        self.assertEqual(self.registry.stat().st_mode & 0o777, 0o600)

    def test_register_multiple_devices_including_unknown_advertised_name(self):
        self.scenario(
            [
                {"device": A, "name": "eufy T9120", "services": []},
                {
                    "device": B,
                    "name": "",
                    "services": ["FFF0"],
                    "profile_name": "eufy T9120",
                },
            ]
        )
        self.run_cli("register", "--seconds", "1", input="1,2\n")
        self.assertEqual(
            [d["id"] for d in json.loads(self.registry.read_text())["devices"]], [A, B]
        )

    def test_register_profile_failure_does_not_partially_save(self):
        self.write_registry([])
        original = self.registry.read_bytes()
        self.scenario(
            [
                {"device": A, "name": "eufy T9120", "services": []},
                {
                    "device": B,
                    "name": "eufy T9120",
                    "services": [],
                    "failure": "profile",
                },
            ]
        )
        self.run_cli("register", "--seconds", "1", input="1,2\n", code=1)
        self.assertEqual(self.registry.read_bytes(), original)

    def test_register_single_candidate_still_requires_selection(self):
        self.scenario([{"device": A, "name": "eufy T9120", "services": []}])
        self.run_cli("register", "--seconds", "1")
        self.assertFalse(self.registry.exists())
        self.assertNotIn("ble_connect", [command["op"] for command in self.commands()])

    def test_register_without_candidates_does_not_create_registration(self):
        self.scenario([{"device": A, "name": "unrelated", "services": ["FFF0"]}])
        self.assertIn(
            "No matching scales", self.run_cli("register", "--seconds", "1").stdout
        )
        self.assertFalse(self.registry.exists())

    def test_register_existing_device_does_not_reconnect_or_duplicate_it(self):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario([{"device": A, "name": "eufy T9120", "services": []}])
        self.assertIn(
            "[registered]",
            self.run_cli("register", "--seconds", "1", input="1\n").stdout,
        )
        self.assertEqual(len(json.loads(self.registry.read_text())["devices"]), 1)
        self.assertNotIn("ble_connect", [command["op"] for command in self.commands()])

    def test_register_permission_denial_does_not_change_registration(self):
        self.write_registry([])
        original = self.registry.read_bytes()
        self.scenario([], power=3)
        self.assertIn(
            "permission denied",
            self.run_cli("register", "--seconds", "1", code=1).stderr,
        )
        self.assertEqual(self.registry.read_bytes(), original)

    def test_register_does_not_drop_fatal_events_in_a_successful_callback_batch(self):
        for failure in ("fatal_after_profile", "fatal_after_disconnect"):
            with self.subTest(failure=failure):
                self.registry.unlink(missing_ok=True)
                self.scenario(
                    [
                        {
                            "device": A,
                            "name": "eufy T9120",
                            "services": [],
                            "failure": failure,
                        }
                    ]
                )
                result = self.run_cli("register", "--seconds", "1", input="1\n", code=1)
                self.assertIn("transport failure", result.stderr)
                self.assertFalse(self.registry.exists())

    def test_registration_lock_rejects_concurrent_changes_and_interrupt_releases_it(
        self,
    ):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        original = self.registry.read_bytes()
        self.scenario([{"device": A, "name": "eufy T9120", "services": []}])
        with (
            (self.root / "register.stdout").open("w") as output,
            (self.root / "register.stderr").open("w") as errors,
        ):
            process = subprocess.Popen(
                [str(BINARY), "register", "--seconds", "1"],
                stdin=subprocess.PIPE,
                stdout=output,
                stderr=errors,
                env=self.env,
            )
        try:
            deadline = time.monotonic() + 5
            while (
                "Select device numbers"
                not in (self.root / "register.stderr").read_text()
            ):
                self.assertIsNone(process.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            self.assertIn(
                "registration lock",
                self.run_cli("unregister", input="1\n", code=1).stderr,
            )
            process.terminate()
            self.assertEqual(process.wait(timeout=6), 1)
            self.assertEqual(self.registry.read_bytes(), original)
            self.run_cli("unregister", input="\n")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=6)
            process.stdin.close()

    def test_registration_disconnect_timeout_does_not_save_or_retry_cancellation(self):
        self.scenario(
            [
                {
                    "device": A,
                    "name": "eufy T9120",
                    "services": [],
                    "failure": "disconnect_timeout",
                }
            ]
        )
        result = self.run_cli("register", "--seconds", "1", input="1\n", code=1)
        self.assertIn("cancellation timed out", result.stderr)
        self.assertFalse(self.registry.exists())
        self.assertEqual([c["op"] for c in self.commands()].count("ble_disconnect"), 1)

    def test_collect_saves_equal_measurements_from_two_devices_separately(self):
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.scenario(
            [{"device": id, "name": "eufy T9120", "services": []} for id in (A, B)]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 2
        )
        self.stop_collector(process)
        self.assertEqual(
            self.rows("SELECT DISTINCT device_id FROM raw_packets ORDER BY device_id"),
            [(A,), (B,)],
        )
        self.assertEqual(
            self.rows("SELECT count(DISTINCT session) FROM raw_packets")[0][0], 2
        )
        output = (self.root / "collector.stdout").read_text()
        self.assertIn(A, output)
        self.assertIn(B, output)

    def test_collect_applies_addition_and_removal_without_reconnecting_other_scale(
        self,
    ):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario(
            [{"device": id, "name": "eufy T9120", "services": []} for id in (A, B)]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 2
        )
        self.run_cli("unregister", input="1\n")
        self.await_condition(
            process,
            lambda: any(
                c["op"] == "ble_disconnect" and c["device"] == A
                for c in self.commands()
            ),
        )
        self.assertEqual(
            [c["device"] for c in self.commands() if c["op"] == "ble_connect"], [A, B]
        )
        self.assertFalse(
            any(
                c["op"] == "ble_disconnect" and c["device"] == B
                for c in self.commands()
            )
        )
        self.stop_collector(process)
        self.assertEqual(self.rows("SELECT count(*) FROM measurements")[0][0], 2)

    def test_collect_reports_states_and_isolates_a_failed_device(self):
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.scenario(
            [
                {
                    "device": A,
                    "name": "eufy T9120",
                    "services": [],
                    "failure": "profile",
                },
                {"device": B, "name": "eufy T9120", "services": []},
            ]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        status = json.loads(self.run_cli("service", "status").stdout)
        devices = {device["id"]: device for device in status["devices"]}
        self.assertEqual(devices[A]["phase"], "Stopped")
        self.assertIn("unsupported", devices[A]["last_error"]["detail"]["message"])
        self.assertEqual(devices[B]["phase"], "Measuring")
        self.assertIsNone(devices[B]["last_error"])
        self.stop_collector(process)
        status = json.loads(self.run_cli("service", "status").stdout)
        self.assertTrue(all(d["phase"] == "Inactive" for d in status["devices"]))

    def test_status_does_not_treat_an_unrelated_writer_as_the_last_collector(self):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario([{"device": A, "name": "eufy T9120", "services": []}])
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        process.kill()
        process.wait(timeout=5)
        with (self.data / "records.sqlite3.lock").open("r+") as lock:
            fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            status = json.loads(self.run_cli("service", "status").stdout)
        self.assertTrue(status["writer_active"])
        self.assertEqual(status["devices"][0]["phase"], "Unknown")

    def test_corrupted_registry_stops_all_connections_without_losing_saved_measurements(
        self,
    ):
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.scenario(
            [{"device": id, "name": "eufy T9120", "services": []} for id in (A, B)]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 2
        )
        self.registry.write_text("{")
        self.assertEqual(process.wait(timeout=8), 1)
        self.assertIn(
            "cannot reload device registrations",
            (self.root / "collector.stderr").read_text(),
        )
        disconnected = {
            c["device"] for c in self.commands() if c["op"] == "ble_disconnect"
        }
        self.assertEqual(disconnected, {A, B})
        self.assertEqual(self.rows("SELECT count(*) FROM measurements")[0][0], 2)

    def test_deleted_registry_does_not_reload_legacy_while_collecting(self):
        (self.data / "service.json").write_text(json.dumps({"device": B}))
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario(
            [{"device": id, "name": "eufy T9120", "services": []} for id in (A, B)]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        self.registry.unlink()
        self.assertEqual(process.wait(timeout=8), 1)
        self.assertIn(
            "registration file disappeared",
            (self.root / "collector.stderr").read_text(),
        )
        self.assertNotIn(
            B, [c["device"] for c in self.commands() if c["op"] == "ble_connect"]
        )

    def test_shutdown_saves_notifications_delivered_during_cancellation(self):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario(
            [
                {
                    "device": A,
                    "name": "eufy T9120",
                    "services": [],
                    "packet_on_disconnect": True,
                }
            ]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        self.stop_collector(process)
        self.assertEqual(
            self.rows("SELECT count(*) FROM raw_packets WHERE direction='rx'")[0][0], 2
        )
        self.assertEqual([c["op"] for c in self.commands()].count("ble_write"), 3)

    def test_storage_failure_reports_uncommitted_packet_and_keeps_prior_measurements(
        self,
    ):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario(
            [{"device": id, "name": "eufy T9120", "services": []} for id in (A, B)]
        )
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        with closing(sqlite3.connect(self.data / "records.sqlite3")) as connection:
            connection.execute(
                "CREATE TRIGGER reject_rx BEFORE INSERT ON raw_packets "
                "WHEN NEW.direction='rx' BEGIN SELECT RAISE(ABORT,'test storage failure'); END"
            )
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.assertEqual(process.wait(timeout=8), 1)
        errors = (self.root / "collector.stderr").read_text()
        self.assertIn("test storage failure", errors)
        pending = next(
            json.loads(line)["uncommitted_events"]
            for line in errors.splitlines()
            if line.startswith('{"uncommitted_events"')
        )
        self.assertEqual(
            [event["device"] for event in pending if event["event"] == "packet"], [B]
        )
        self.assertEqual(self.rows("SELECT count(*) FROM measurements")[0][0], 1)
        self.assertEqual(self.commands()[-1]["op"], "ble_close")

    def test_shared_transport_failure_stops_every_device_before_initialization(self):
        self.write_registry(
            [{"id": A, "name": "eufy T9120"}, {"id": B, "name": "eufy T9120"}]
        )
        self.scenario(
            [
                {
                    "device": A,
                    "name": "eufy T9120",
                    "services": [],
                    "failure": "fatal_after_profile",
                },
                {"device": B, "name": "eufy T9120", "services": []},
            ]
        )
        process = self.start_collector()
        self.assertEqual(process.wait(timeout=8), 1)
        self.assertIn(
            "shared transport failure", (self.root / "collector.stderr").read_text()
        )
        self.assertEqual(
            {c["device"] for c in self.commands() if c["op"] == "ble_disconnect"},
            {A, B},
        )
        self.assertNotIn("ble_write", [c["op"] for c in self.commands()])

    def test_unregister_all_waits_and_register_reactivates_collection(self):
        self.write_registry([{"id": A, "name": "eufy T9120"}])
        self.scenario([{"device": A, "name": "eufy T9120", "services": []}])
        process = self.start_collector()
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 1
        )
        self.run_cli("unregister", input="1\n")
        self.await_condition(
            process, lambda: any(c["op"] == "ble_disconnect" for c in self.commands())
        )
        self.run_cli("register", "--seconds", "1", input="1\n")
        self.await_condition(
            process, lambda: self.rows("SELECT count(*) FROM measurements")[0][0] == 2
        )
        self.stop_collector(process)
        self.assertEqual(
            self.rows("SELECT count(DISTINCT session) FROM raw_packets")[0][0], 2
        )


if __name__ == "__main__":
    unittest.main()
