#!/usr/bin/env python3
"""Unit tests for scripts/playwright-pins.py. No real network: downloads go to a local server.

Run: python3 scripts/test-playwright-pins.py
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import tarfile
import tempfile
import threading
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("playwright_pins", os.path.join(HERE, "playwright-pins.py"))
pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pins)
pins.ALLOW_LOOPBACK_HTTP = True


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class Server:
    """A loopback HTTP server whose routes are (status, headers, body) tuples; counts requests."""

    def __init__(self, routes):
        self.routes = routes
        self.hits = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                outer.hits.append(self.path)
                status, headers, body = outer.routes.get(self.path, (404, {}, b"no"))
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                if "Content-Length" not in headers:
                    self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

        self.httpd = HTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def make_tar_gz(path, members):
    with tarfile.open(path, "w:gz") as t:
        for name, kind, data in members:
            ti = tarfile.TarInfo(name)
            if kind == "file":
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
            elif kind == "dir":
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            elif kind == "symlink":
                ti.type = tarfile.SYMTYPE
                ti.linkname = data
                t.addfile(ti)
            elif kind == "hardlink":
                ti.type = tarfile.LNKTYPE
                ti.linkname = data
                t.addfile(ti)


class OfflineVerify(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="oab-pins-test.")
        self.dir = os.path.join(self.tmp, "pins")
        shutil.copytree(pins.PINS_DIR, self.dir)
        self.swift = os.path.join(self.tmp, "PlaywrightPins.generated.swift")
        shutil.copy(pins.SWIFT_OUT, self.swift)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self):
        return pins.verify_offline(self.dir, self.swift)

    def edit(self, name, fn, binary=False):
        p = os.path.join(self.dir, name)
        with open(p, "rb") as f:
            data = f.read()
        with open(p, "wb") as f:
            f.write(fn(data))

    def test_the_tracked_files_pass(self):
        self.assertEqual(self.check(), [])

    def test_the_real_cli_passes(self):
        self.assertEqual(pins.main(["verify", "--offline"]), 0)

    def test_one_changed_byte_in_the_lockfile_fails(self):
        self.edit("package-lock.json", lambda d: d.replace(b"sha512-", b"sha512-A", 1))
        self.assertTrue(any("digest" in p for p in self.check()))

    def test_a_package_resolved_on_another_host_fails(self):
        def f(d):
            return d.replace(b"https://registry.npmjs.org/", b"https://evil.example/", 1)
        self.edit("package-lock.json", f)
        problems = self.check()
        self.assertTrue(any("not resolved on registry.npmjs.org" in p for p in problems), problems)

    def test_a_package_without_integrity_fails(self):
        lock = json.loads(read(os.path.join(self.dir, "package-lock.json")))
        for k, v in lock["packages"].items():
            if k:
                v.pop("integrity")
                break
        text = json.dumps(lock, indent=2) + "\n"
        write(os.path.join(self.dir, "package-lock.json"), text)
        pj = json.loads(read(os.path.join(self.dir, "pins.json")))
        pj["mcp"]["lockfileSHA256"] = pins.sha256_bytes(text.encode())
        write(os.path.join(self.dir, "pins.json"), pins.dump_pins(pj))
        self.assertTrue(any("integrity" in p for p in self.check()))

    def test_a_version_range_in_package_json_fails(self):
        self.edit("package.json", lambda d: d.replace(b'"0.0.82"', b'"^0.0.82"'))
        self.assertTrue(any("package.json" in p for p in self.check()))

    def test_the_generated_swift_must_match_by_one_character(self):
        text = read(self.swift)
        write(self.swift, text.replace("sha256", "sha257", 1))
        self.assertTrue(any("generated.swift" in p for p in self.check()))

    def test_a_missing_swift_file_fails(self):
        os.remove(self.swift)
        self.assertTrue(any("generated.swift" in p for p in self.check()))

    def test_pins_must_use_the_allowed_hosts(self):
        pj = json.loads(read(os.path.join(self.dir, "pins.json")))
        pj["node"]["artifacts"]["arm64"]["url"] = "https://evil.example/node.tar.gz"
        write(os.path.join(self.dir, "pins.json"), pins.dump_pins(pj))
        self.assertTrue(any("url" in p for p in self.check()))

    def test_http_urls_fail(self):
        pj = json.loads(read(os.path.join(self.dir, "pins.json")))
        pj["chromium"]["artifacts"]["arm64"]["url"] = pj["chromium"]["artifacts"]["arm64"]["url"].replace("https", "http")
        write(os.path.join(self.dir, "pins.json"), pins.dump_pins(pj))
        self.assertTrue(any("url" in p for p in self.check()))

    def test_the_id_must_follow_the_versions(self):
        pj = json.loads(read(os.path.join(self.dir, "pins.json")))
        pj["id"] = "something-else"
        write(os.path.join(self.dir, "pins.json"), pins.dump_pins(pj))
        self.assertTrue(any("id should be" in p for p in self.check()))

    def test_render_is_deterministic_and_refuses_a_raw_string_delimiter(self):
        a = pins.render_swift(b"{}\n", b"{}\n", b"{}\n")
        self.assertEqual(a, pins.render_swift(b"{}\n", b"{}\n", b"{}\n"))
        with self.assertRaises(pins.PinError):
            pins.render_swift(b'x"""#y\n', b"{}\n", b"{}\n")
        with self.assertRaises(pins.PinError):
            pins.render_swift(b"{}", b"{}\n", b"{}\n")


class Downloads(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="oab-pins-test.")
        self.allowed = {"127.0.0.1"}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def dest(self):
        return os.path.join(self.tmp, "f")

    def test_ok_returns_size_and_digest(self):
        s = Server({"/a": (200, {}, b"hello")})
        self.addCleanup(s.close)
        n, h = pins.download(s.url("/a"), self.dest(), self.allowed, pins.Budget(100, 100))
        self.assertEqual((n, h), (5, pins.sha256_bytes(b"hello")))

    def test_a_file_over_the_cap_aborts(self):
        s = Server({"/a": (200, {}, b"x" * 5000)})
        self.addCleanup(s.close)
        with self.assertRaises(pins.PinError):
            pins.download(s.url("/a"), self.dest(), self.allowed, pins.Budget(1000, 10000))

    def test_the_total_cap_aborts(self):
        s = Server({"/a": (200, {}, b"x" * 600)})
        self.addCleanup(s.close)
        b = pins.Budget(1000, 1000)
        pins.download(s.url("/a"), self.dest(), self.allowed, b)
        with self.assertRaises(pins.PinError):
            pins.download(s.url("/a"), self.dest(), self.allowed, b)

    def test_a_redirect_to_another_host_is_refused_and_never_followed(self):
        target = Server({"/x": (200, {}, b"should not be fetched")})
        self.addCleanup(target.close)
        origin = Server({"/a": (302, {"Location": "http://localhost:%d/x" % target.port}, b"")})
        self.addCleanup(origin.close)
        with self.assertRaises(Exception):
            pins.download(origin.url("/a"), self.dest(), self.allowed, pins.Budget(100, 100))
        self.assertEqual(target.hits, [])

    def test_a_redirect_inside_the_allowed_host_is_followed(self):
        s = Server({"/a": (302, {"Location": "/b"}, b""), "/b": (200, {}, b"ok")})
        self.addCleanup(s.close)
        n, _ = pins.download(s.url("/a"), self.dest(), self.allowed, pins.Budget(100, 100))
        self.assertEqual(n, 2)

    def test_a_host_outside_the_list_is_refused_before_any_request(self):
        s = Server({"/a": (200, {}, b"x")})
        self.addCleanup(s.close)
        with self.assertRaises(pins.PinError):
            pins.download(s.url("/a"), self.dest(), {"nodejs.org"}, pins.Budget(100, 100))
        self.assertEqual(s.hits, [])

    def test_plain_http_is_refused_unless_the_test_switch_is_on(self):
        pins.ALLOW_LOOPBACK_HTTP = False
        try:
            with self.assertRaises(pins.PinError):
                pins.check_url("http://127.0.0.1:1/a", {"127.0.0.1"})
        finally:
            pins.ALLOW_LOOPBACK_HTTP = True

    def test_path_traversal_in_a_url_is_refused(self):
        with self.assertRaises(pins.PinError):
            pins.check_url("http://127.0.0.1:1/a/../b", {"127.0.0.1"})


class Archives(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="oab-pins-test.")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_inspect_tar_counts_entries_and_sizes(self):
        p = os.path.join(self.tmp, "a.tgz")
        make_tar_gz(p, [("d", "dir", None), ("d/f", "file", b"12345"), ("d/g", "file", b"123"), ("d/l", "symlink", "f")])
        info = pins.inspect_tar_gz(p)
        self.assertEqual(info, {"entryCount": 4, "expandedBytes": 8, "maxEntryBytes": 5})

    def test_inspect_tar_rejects_traversal_and_hardlinks(self):
        p = os.path.join(self.tmp, "a.tgz")
        make_tar_gz(p, [("../x", "file", b"1")])
        with self.assertRaises(pins.PinError):
            pins.inspect_tar_gz(p)
        make_tar_gz(p, [("a", "file", b"1"), ("b", "hardlink", "a")])
        with self.assertRaises(pins.PinError):
            pins.inspect_tar_gz(p)

    def test_inspect_zip_finds_the_single_executable(self):
        p = os.path.join(self.tmp, "c.zip")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", b"bin")
            z.writestr("chrome-mac-arm64/other", b"12")
        info = pins.inspect_zip(p)
        self.assertEqual(len(info["executables"]), 1)
        self.assertEqual((info["entryCount"], info["expandedBytes"]), (2, 5))

    def test_inspect_zip_rejects_traversal(self):
        p = os.path.join(self.tmp, "c.zip")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("../evil", b"x")
        with self.assertRaises(pins.PinError):
            pins.inspect_zip(p)

    def test_extract_for_generate_refuses_a_link_that_leaves_the_folder(self):
        p = os.path.join(self.tmp, "a.tgz")
        make_tar_gz(p, [("d", "dir", None), ("d/l", "symlink", "../../outside")])
        with self.assertRaises(pins.PinError):
            pins.extract_tar_gz_for_generate(p, os.path.join(self.tmp, "out"))

    def test_extract_for_generate_extracts_a_clean_tree(self):
        p = os.path.join(self.tmp, "a.tgz")
        make_tar_gz(p, [("d", "dir", None), ("d/f", "file", b"x"), ("d/l", "symlink", "f")])
        out = os.path.join(self.tmp, "out")
        os.makedirs(out)
        pins.extract_tar_gz_for_generate(p, out)
        self.assertEqual(read(os.path.join(out, "d/l")), "x")


class Generate(unittest.TestCase):
    def test_generate_refuses_to_run_without_a_node_team_id(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = pins.main(["generate", "--node-version", "1.2.3", "--mcp-version", "0.0.1", "--workdir", tempfile.mkdtemp()])
        self.assertEqual(rc, 2)
        self.assertIn("--node-team-id", err.getvalue())

    def test_versions_must_be_exact(self):
        rc = pins.main(["generate", "--node-version", "24", "--mcp-version", "^0.0.1", "--node-team-id", "ABCDE12345",
                        "--workdir", tempfile.mkdtemp()])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
