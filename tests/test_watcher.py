"""Contract tests for CrystalBall/linux/watcher.py.

Deterministic and GPU-free: a fake Immolate (fake_immolate.py) stands in for the
searcher, so these lock the watcher's handshake behaviour -- request/response
file format, id dedup, error payloads, atomic write -- without any real search.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import cbtest

FAKE = Path(__file__).resolve().parent / "fake_immolate.py"
ID_OK, ID_FAIL, ID_EMPTY, ID_A, ID_B = "ok-1", "fail-1", "empty-1", "dup-A", "dup-B"


def _load_watcher():
    """Import watcher.py as a module (its __main__ guard keeps main() from running)."""
    spec = importlib.util.spec_from_file_location("watcher", cbtest.WATCHER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


watcher = _load_watcher()


def _read_lines(path: Path):
    """returns: (id, payload) parsed from a response file, or None if absent/partial."""
    try:
        head = path.read_text(encoding="utf-8").split("\n")
    except FileNotFoundError:
        return None
    return (head[0].strip(), head[1].strip()) if len(head) >= 2 and head[0].strip() else None


class WatcherTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.req = self.dir / "request.txt"
        self.resp = self.dir / "response.txt"
        self.log = self.dir / "calls.log"

    def _start(self, mode="seed"):
        """Launch the watcher against the fake binary; tear it down on test exit."""
        env = {**os.environ, "FAKE_MODE": mode, "FAKE_LOG": str(self.log)}
        proc = subprocess.Popen(
            [sys.executable, str(cbtest.WATCHER), "--dir", str(self.dir),
             "--immolate", str(FAKE), "--interval", "0.02"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(proc.wait)
        self.addCleanup(proc.terminate)
        # The watcher removes any pre-existing request/response on startup; wait for
        # that pass so our first request isn't deleted out from under it.
        time.sleep(0.2)
        return proc

    def _write_request(self, rid, query='{"any":[{"all":[]}]}'):
        self.req.write_text(f"{rid}\n{query}\n", encoding="utf-8")

    def _await_response(self, rid, timeout=10.0):
        """Poll until response.txt carries `rid`; returns its payload."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            got = _read_lines(self.resp)
            if got and got[0] == rid:
                return got[1]
            time.sleep(0.02)
        self.fail(f"no response for {rid} within {timeout}s")

    def _call_count(self):
        return len(self.log.read_text().splitlines()) if self.log.exists() else 0

    def test_success_returns_seed(self):
        self._start("seed")
        self._write_request(ID_OK)
        self.assertEqual(self._await_response(ID_OK), "FAKESEED")

    def test_failure_returns_error_payload(self):
        self._start("fail")
        self._write_request(ID_FAIL)
        self.assertTrue(self._await_response(ID_FAIL).startswith("ERROR:"))

    def test_no_match_is_error(self):
        self._start("empty")
        self._write_request(ID_EMPTY)
        self.assertEqual(self._await_response(ID_EMPTY), "ERROR: no matching seed")

    def test_query_is_forwarded(self):
        self._start("seed")
        q = '{"any":[{"all":[{"atLeast":1,"minAnte":1,"maxAnte":8,"of":["Blueprint"]}]}]}'
        self._write_request(ID_OK, q)
        self._await_response(ID_OK)
        argv = json.loads(self.log.read_text().splitlines()[0])
        self.assertIn(q, argv)  # the query reaches the searcher verbatim
        # ...and the default filter (find_joker) matches what the mod requests.
        self.assertEqual(argv[argv.index("-f") + 1], "find_joker")

    def test_same_id_runs_once(self):
        self._start("seed")
        self._write_request(ID_A)
        self._await_response(ID_A)
        self._write_request(ID_A)  # identical id: must be ignored
        time.sleep(0.3)
        self.assertEqual(self._call_count(), 1)

    def test_new_id_reprocesses(self):
        self._start("seed")
        self._write_request(ID_A)
        self._await_response(ID_A)
        self._write_request(ID_B)
        self._await_response(ID_B)
        self.assertEqual(self._call_count(), 2)

    def test_no_partial_temp_file_left(self):
        self._start("seed")
        self._write_request(ID_OK)
        self._await_response(ID_OK)
        # Atomic write replaces response.txt.tmp -> response.txt; no stray temp.
        self.assertFalse((self.dir / "response.txt.tmp").exists())


class RunImmolateUnitTest(unittest.TestCase):
    """Direct unit tests of watcher.run_immolate against the fake searcher."""

    def _run(self, mode, env_extra=None):
        prev = dict(os.environ)
        os.environ["FAKE_MODE"] = mode
        os.environ.update(env_extra or {})
        try:
            return watcher.run_immolate(str(FAKE), "find_joker", "{}")
        finally:
            os.environ.clear()
            os.environ.update(prev)

    def test_success(self):
        self.assertEqual(self._run("seed"), ("FAKESEED", None))

    def test_multiline_takes_first(self):
        # The searcher may print more than one seed; the watcher keeps the first.
        seed, err = self._run("multi")
        self.assertEqual((seed, err), ("FAKESEED", None))

    def test_no_match(self):
        self.assertEqual(self._run("empty"), (None, "no matching seed"))

    def test_nonzero_exit_is_error(self):
        seed, err = self._run("fail")
        self.assertIsNone(seed)
        self.assertEqual(err, "simulated search failure")


if __name__ == "__main__":
    unittest.main()
