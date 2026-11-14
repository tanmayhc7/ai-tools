"""Tests for keyvault_client.py against a small fake server. Run with:
    python3 -I -m unittest discover -s agent/tests
"""
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import keyvault_client as kv  # noqa: E402


def _short_tempdir():
    """Unix socket paths are limited to ~100 bytes, so use the system temp folder unless it's long."""
    base = tempfile.gettempdir()
    return tempfile.mkdtemp(prefix="kv", dir=base if len(base) <= 60 else "/tmp")


class FakeServer:
    """Answers one connection with whatever `respond(request_bytes)` returns."""

    def __init__(self, respond, mode=0o600, dir_mode=0o700):
        # AF_UNIX paths are limited to ~100 bytes, so keep the folder name short.
        self.dir = _short_tempdir()
        os.chmod(self.dir, dir_mode)
        self.path = os.path.join(self.dir, "a.sock")
        self.respond = respond
        self.received = None
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        os.chmod(self.path, mode)
        self.listener.listen(1)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        try:
            conn, _ = self.listener.accept()
        except OSError:
            return
        with conn:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            self.received = data
            out = self.respond(data)
            if out is not None:
                conn.sendall(out)

    def close(self):
        self.listener.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        os.rmdir(self.dir)


def ok(secret):
    return json.dumps({"ok": True, "secret": secret}).encode() + b"\n"


def err(code):
    return json.dumps({"ok": False, "error": code}).encode() + b"\n"


class ClientTests(unittest.TestCase):
    def serve(self, respond, **kw):
        s = FakeServer(respond, **kw)
        self.addCleanup(s.close)
        return s

    def test_returns_key_and_sends_expected_request(self):
        s = self.serve(lambda _: ok("sk-test-value"))
        self.assertEqual(kv.get_key("My Key", reason="unit test", socket_path=s.path), "sk-test-value")
        sent = json.loads(s.received)
        self.assertEqual(sent, {"v": 1, "op": "get", "key": "My Key", "reason": "unit test"})

    def test_reason_is_truncated(self):
        s = self.serve(lambda _: ok("x"))
        kv.get_key("k", reason="r" * 5000, socket_path=s.path)
        self.assertLessEqual(len(json.loads(s.received)["reason"]), 200)

    def test_error_codes_map_to_exceptions(self):
        for code, exc in [("denied", kv.KeyVaultDenied), ("locked", kv.KeyVaultLocked),
                          ("rate_limited", kv.KeyVaultRateLimited), ("timeout", kv.KeyVaultTimeout),
                          ("bad_request", kv.KeyVaultProtocolError), ("surprise", kv.KeyVaultProtocolError)]:
            s = self.serve(lambda _, c=code: err(c))
            with self.assertRaises(exc):
                kv.get_key("k", socket_path=s.path)

    def test_malformed_replies_are_rejected(self):
        for bad in [b"not json\n", b"[1,2]\n", b'{"ok":true}\n', b'{"ok":true,"secret":5}\n', b"\xff\xfe\n"]:
            s = self.serve(lambda _, b=bad: b)
            with self.assertRaises(kv.KeyVaultProtocolError):
                kv.get_key("k", socket_path=s.path)

    def test_oversized_reply_rejected(self):
        s = self.serve(lambda _: b"a" * (kv._MAX_RESPONSE + 5000))
        with self.assertRaises(kv.KeyVaultProtocolError):
            kv.get_key("k", socket_path=s.path)

    def test_server_closing_without_reply(self):
        s = self.serve(lambda _: None)
        with self.assertRaises(kv.KeyVaultProtocolError):
            kv.get_key("k", socket_path=s.path)

    def test_timeout(self):
        gate = threading.Event()
        self.addCleanup(gate.set)
        s = self.serve(lambda _: gate.wait(5) and None)
        with self.assertRaises(kv.KeyVaultTimeout):
            kv.get_key("k", timeout=0.3, socket_path=s.path)

    def test_missing_socket_explains_how_to_fix(self):
        d = _short_tempdir()
        self.addCleanup(os.rmdir, d)
        os.chmod(d, 0o700)
        with self.assertRaises(kv.KeyVaultUnavailable) as cm:
            kv.get_key("k", socket_path=os.path.join(d, "none.sock"))
        self.assertIn("Agent Access", str(cm.exception))

    def test_refuses_socket_readable_by_others(self):
        s = self.serve(lambda _: ok("leak"), mode=0o666)
        with self.assertRaises(kv.KeyVaultUnavailable):
            kv.get_key("k", socket_path=s.path)

    def test_refuses_folder_readable_by_others(self):
        s = self.serve(lambda _: ok("leak"), dir_mode=0o755)
        with self.assertRaises(kv.KeyVaultUnavailable):
            kv.get_key("k", socket_path=s.path)

    def test_refuses_symlink_to_a_socket(self):
        s = self.serve(lambda _: ok("leak"))
        link = os.path.join(s.dir, "link.sock")
        os.symlink(s.path, link)
        self.addCleanup(os.unlink, link)
        with self.assertRaises(kv.KeyVaultUnavailable):
            kv.get_key("k", socket_path=link)

    def test_refuses_regular_file(self):
        d = _short_tempdir()
        os.chmod(d, 0o700)
        f = os.path.join(d, "a.sock")
        open(f, "w").close()
        os.chmod(f, 0o600)
        self.addCleanup(lambda: (os.unlink(f), os.rmdir(d)))
        with self.assertRaises(kv.KeyVaultUnavailable):
            kv.get_key("k", socket_path=f)

    def test_stale_socket_file_reports_unavailable(self):
        d = _short_tempdir()
        os.chmod(d, 0o700)
        path = os.path.join(d, "a.sock")
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(path)
        sock.close()                      # leaves a socket file with nobody listening
        os.chmod(path, 0o600)
        self.addCleanup(lambda: (os.unlink(path), os.rmdir(d)))
        with self.assertRaises(kv.KeyVaultUnavailable):
            kv.get_key("k", socket_path=path)

    def test_bad_arguments(self):
        for bad in ["", "   ", None, 5]:
            with self.assertRaises(ValueError):
                kv.get_key(bad)

    def test_default_path_ignores_HOME(self):
        old = os.environ.get("HOME")
        os.environ["HOME"] = "/tmp/attacker-home"
        try:
            self.assertNotIn("attacker-home", kv.default_socket_path())
        finally:
            if old is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = old

    def test_secret_never_appears_in_exception_text(self):
        s = self.serve(lambda _: b'{"ok":false,"error":"denied","secret":"sk-leak-me"}\n')
        with self.assertRaises(kv.KeyVaultDenied) as cm:
            kv.get_key("k", socket_path=s.path)
        self.assertNotIn("sk-leak-me", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
