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

            def do_HEAD(self):
                outer.hits.append("HEAD " + self.path)
                status, headers, body = outer.routes.get(self.path, (404, {}, b"no"))
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()

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
        pj["node"]["artifacts"]["darwin-arm64"]["url"] = "https://evil.example/node.tar.gz"
        write(os.path.join(self.dir, "pins.json"), pins.dump_pins(pj))
        self.assertTrue(any("url" in p for p in self.check()))

    def test_http_urls_fail(self):
        pj = json.loads(read(os.path.join(self.dir, "pins.json")))
        pj["chromium"]["artifacts"]["darwin-arm64"]["url"] = pj["chromium"]["artifacts"]["darwin-arm64"]["url"].replace("https", "http")
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


def make_elf(needed, glibc, sections=True):
    """A small 64-bit little-endian ELF with a dynamic section and a version-needs section. Never executed."""
    import struct
    dynstr = b"\0"
    offs = {}
    for name in list(needed) + ["libc.so.6"] + ["GLIBC_%s" % v for v in glibc] + ["GLIBC_PRIVATE"]:
        if name not in offs:
            offs[name] = len(dynstr)
            dynstr += name.encode() + b"\0"
    dynamic = b"".join(struct.pack("<qQ", 1, offs[n]) for n in needed) + struct.pack("<qQ", 0, 0)
    vers = ["GLIBC_%s" % v for v in glibc] + ["GLIBC_PRIVATE"]
    verneed = struct.pack("<HHIII", 1, len(vers), offs["libc.so.6"], 16, 0)
    for i, v in enumerate(vers):
        verneed += struct.pack("<IHHII", 0, 0, 2 + i, offs[v], 16 if i < len(vers) - 1 else 0)
    body = dynstr + dynamic + verneed
    base = 64
    o_dynstr, o_dyn, o_ver = base, base + len(dynstr), base + len(dynstr) + len(dynamic)
    shoff = base + len(body)
    shdrs = struct.pack("<IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    shdrs += struct.pack("<IIQQQQIIQQ", 0, 3, 0, 0, o_dynstr, len(dynstr), 0, 0, 1, 0)
    shdrs += struct.pack("<IIQQQQIIQQ", 0, 6, 0, 0, o_dyn, len(dynamic), 1, 0, 8, 16)
    shdrs += struct.pack("<IIQQQQIIQQ", 0, 0x6ffffffe, 0, 0, o_ver, len(verneed), 1, 1, 4, 0)
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    head = ident + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 0, shoff if sections else 0, 0, 64, 56, 0, 64, 4 if sections else 0, 0)
    return head + body + shdrs


class LinuxFacts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="oab-pins-elf.")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def elf(self, name, data):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def test_needed_and_the_highest_glibc_are_read_from_a_generated_elf(self):
        f = pins.elf_facts(self.elf("a", make_elf(["libnss3.so", "libc.so.6"], ["2.17", "2.28", "2.5"])))
        self.assertEqual(f["needed"], ["libnss3.so", "libc.so.6"])
        self.assertEqual(f["glibc"], (2, 28, 0))
        self.assertEqual(pins.glibc_string(f["glibc"]), "2.28")
        self.assertEqual(pins.glibc_string((2, 28, 1)), "2.28.1")

    def test_glibc_private_is_not_a_version(self):
        f = pins.elf_facts(self.elf("a", make_elf(["libc.so.6"], ["2.3"])))
        self.assertEqual(f["glibc"], (2, 3, 0))

    def test_an_elf_without_section_headers_is_refused_not_guessed(self):
        with self.assertRaises(pins.PinError):
            pins.elf_facts(self.elf("a", make_elf(["libc.so.6"], ["2.3"], sections=False)))

    def test_a_non_elf_and_a_truncated_elf_are_refused(self):
        with self.assertRaises(pins.PinError):
            pins.elf_facts(self.elf("a", b"#!/bin/sh\n" + bytes(100)))
        with self.assertRaises(pins.PinError):
            pins.elf_facts(self.elf("b", make_elf(["libc.so.6"], ["2.3"])[:200]))

    def test_zip_facts_drop_libraries_the_zip_ships_and_add_hints(self):
        p = os.path.join(self.tmp, "c.zip")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("chrome-linux64/chrome", make_elf(["libnss3.so", "libvulkan.so.1", "libc.so.6"], ["2.25"]))
            z.writestr("chrome-linux64/libvulkan.so.1", make_elf(["libc.so.6", "libm.so.6"], ["2.17"]))
            z.writestr("chrome-linux64/notes.so", b"not an elf")
        f = pins.linux_facts_zip(p, self.tmp)
        self.assertEqual(f["minGlibc"], "2.25")
        self.assertEqual(f["needed"], ["libc.so.6", "libm.so.6", "libnss3.so"])
        self.assertEqual(f["packageHints"], {"apt": ["libc6", "libnss3"]})

    def test_a_library_with_no_package_hint_stops_the_generator(self):
        p = os.path.join(self.tmp, "c.zip")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("chrome-linux64/chrome", make_elf(["libnew-thing.so.1", "libc.so.6"], ["2.25"]))
        with self.assertRaises(pins.PinError):
            pins.linux_facts_zip(p, self.tmp)

    def test_tar_facts_read_the_named_member(self):
        p = os.path.join(self.tmp, "n.tar.gz")
        data = make_elf(["libstdc++.so.6", "libc.so.6"], ["2.28"])
        with tarfile.open(p, "w:gz") as t:
            ti = tarfile.TarInfo("node-v1.0.0-linux-x64/bin/node")
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
        f = pins.linux_facts_tar(p, "node-v1.0.0-linux-x64/bin/node", self.tmp)
        self.assertEqual(f["minGlibc"], "2.28")
        self.assertEqual(f["packageHints"], {"apt": ["libc6", "libstdc++6"]})

    def test_inspect_zip_finds_the_one_linux_executable(self):
        p = os.path.join(self.tmp, "c.zip")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("chrome-linux-arm64/chrome", b"x")
            z.writestr("chrome-linux-arm64/chrome_sandbox", b"x")
            z.writestr("chrome-linux-arm64/locales/chrome", b"x")
        self.assertEqual(pins.inspect_zip(p)["linuxExecutables"], ["chrome-linux-arm64/chrome"])


class PlatformKeys(unittest.TestCase):
    """Schema 2: four platform ids, one source recorded per Chromium artifact, shared fields that cannot drift."""

    def setUp(self):
        self.pins = json.loads(read(os.path.join(pins.PINS_DIR, "pins.json")))

    def problems(self):
        out = []
        pins.verify_pins_structure(self.pins, out)
        return out

    def test_the_tracked_pins_have_all_four_platforms_with_linux_facts(self):
        self.assertEqual(self.problems(), [])
        for label in ("node", "chromium"):
            self.assertEqual(list(self.pins[label]["artifacts"]), list(pins.PLATFORMS))
        for plat in pins.LINUX_PLATFORMS:
            for label in ("node", "chromium"):
                a = self.pins[label]["artifacts"][plat]
                self.assertTrue(a["minGlibc"] and a["needed"] and a["packageHints"]["apt"])
        for plat in pins.DARWIN_PLATFORMS:
            for a in (self.pins["node"]["artifacts"][plat], self.pins["chromium"]["artifacts"][plat]):
                self.assertFalse(set(pins.LINUX_FIELDS) & set(a))

    def test_a_missing_platform_fails_for_every_platform_and_both_sections(self):
        for label in ("node", "chromium"):
            for plat in pins.PLATFORMS:
                p = json.loads(json.dumps(self.pins))
                del p[label]["artifacts"][plat]
                out = []
                pins.verify_pins_structure(p, out)
                self.assertTrue(any("must cover exactly" in x for x in out), (label, plat, out))

    def test_schema_1_keys_are_not_platform_ids(self):
        p = self.pins
        p["node"]["artifacts"]["arm64"] = p["node"]["artifacts"].pop("darwin-arm64")
        self.assertTrue(any("must cover exactly" in x for x in self.problems()))

    def test_every_chromium_artifact_records_a_known_source_that_matches_its_host(self):
        self.pins["chromium"]["artifacts"]["linux-x64"]["source"] = "mirror"
        self.assertTrue(any("source must be one of" in x for x in self.problems()))
        self.pins["chromium"]["artifacts"]["linux-x64"]["source"] = "playwright-cdn"
        self.assertTrue(any("does not match its source" in x for x in self.problems()))

    def test_the_playwright_cdn_fallback_is_accepted_when_the_url_and_hosts_follow(self):
        a = self.pins["chromium"]["artifacts"]["linux-arm64"]
        a["source"] = "playwright-cdn"
        a["url"] = "%s/%s/chromium-linux-arm64.zip" % (pins.CDN_BASE, self.pins["chromium"]["revision"])
        a["executable"] = "chrome-linux/chrome"
        self.assertTrue(any("hosts must be" in x for x in self.problems()))
        self.pins["hosts"] = self.pins["hosts"] + [pins.CDN_HOST]
        self.assertEqual(self.problems(), [])

    def test_shared_fields_that_drift_between_platforms_fail(self):
        self.pins["chromium"]["artifacts"]["linux-x64"]["url"] = self.pins["chromium"]["artifacts"]["linux-x64"]["url"].replace(
            self.pins["chromium"]["browserVersion"], "1.2.3.4")
        self.assertTrue(any("chromium/linux-x64 url does not follow" in x for x in self.problems()))

    def test_node_version_drift_fails_on_every_platform(self):
        self.pins["node"]["version"] = "1.2.3"
        self.assertEqual(len([x for x in self.problems() if "does not follow node.version" in x]), 4)

    def test_hints_that_do_not_follow_from_needed_fail(self):
        self.pins["chromium"]["artifacts"]["linux-x64"]["packageHints"] = {"apt": ["libfoo"]}
        self.assertTrue(any("do not follow from needed" in x for x in self.problems()))

    def test_linux_fields_on_a_darwin_artifact_fail(self):
        self.pins["node"]["artifacts"]["darwin-x64"]["minGlibc"] = "2.28"
        self.assertTrue(any("must not carry" in x for x in self.problems()))

    def test_the_release_check_has_a_mac_unchanged_id(self):
        self.assertEqual(self.pins["id"], "mcp0.0.82-node24.22.3-cr1246-ae3053ed")

    def test_the_shared_vectors_agree_with_the_python_check_on_valid_or_not(self):
        doc = json.loads(read(os.path.join(ROOT, "conformance", "pins_vectors.json")))
        self.assertGreaterEqual(len(doc["cases"]), 40)
        for c in doc["cases"]:
            p = json.loads(read(os.path.join(ROOT, doc["pins"])))
            for op in c["ops"]:
                apply_op(p, op)
            out = []
            pins.verify_pins_structure(p, out)
            self.assertEqual(not out, c["valid"], (c["name"], out))

    def test_a_lockfile_with_an_os_conditional_optional_dependency_is_still_checked(self):
        lock = json.loads(read(os.path.join(pins.PINS_DIR, "package-lock.json")))
        package = json.loads(read(os.path.join(pins.PINS_DIR, "package.json")))
        lock["packages"]["node_modules/fsevents"] = {
            "version": "2.3.3", "resolved": pins.NPM_REGISTRY + "fsevents/-/fsevents-2.3.3.tgz",
            "integrity": "sha512-AAAA", "optional": True, "os": ["darwin"]}
        out = []
        pins.verify_lockfile(lock, package, self.pins, out)
        self.assertEqual(out, [])
        del lock["packages"]["node_modules/fsevents"]["integrity"]
        pins.verify_lockfile(lock, package, self.pins, out)
        self.assertTrue(any("without sha512 integrity" in x for x in out))


def expand_value(v, p):
    if isinstance(v, str):
        return v.replace("{browserVersion}", p["chromium"]["browserVersion"]).replace(
            "{revision}", p["chromium"]["revision"]).replace("{nodeVersion}", p["node"]["version"])
    return v


def apply_op(p, op):
    path = op["path"]
    if op["op"] == "copy":
        src = p
        for k in op["from"]:
            src = src[k]
        value = json.loads(json.dumps(src))
    parent = p
    for k in path[:-1]:
        parent = parent.setdefault(k, {})
    last = path[-1]
    if op["op"] == "set":
        parent[last] = expand_value(json.loads(json.dumps(op["value"])), p)
    elif op["op"] == "remove":
        del parent[last]
    elif op["op"] == "copy":
        parent[last] = value
    elif op["op"] == "replace":
        a, b = expand_value(op["from"], p), expand_value(op["to"], p)
        assert a in parent[last], op
        parent[last] = parent[last].replace(a, b)
    else:
        raise AssertionError(op)


class SourceChoice(unittest.TestCase):
    """The release check fails a platform that has neither source, and one that uses the wrong one."""

    def setUp(self):
        self.old = (pins.CFT_BASE, pins.CFT_HOST, pins.CDN_BASE, pins.CDN_HOST)

    def tearDown(self):
        pins.CFT_BASE, pins.CFT_HOST, pins.CDN_BASE, pins.CDN_HOST = self.old

    def serve(self, routes):
        s = Server(routes)
        self.addCleanup(s.close)
        base = s.url("")
        pins.CFT_BASE, pins.CDN_BASE = base + "/cft", base + "/cdn"
        pins.CFT_HOST = pins.CDN_HOST = "127.0.0.1"
        return s

    def head_routes(self, paths):
        # The test server answers GET; a HEAD request lands in do_HEAD below.
        return {p: (200, {}, b"") for p in paths}

    def test_cft_wins_when_it_hosts_the_version(self):
        self.serve(self.head_routes(["/cft/9.9/linux64/chrome-linux64.zip", "/cdn/7/chromium-linux.zip"]))
        self.assertEqual(pins.choose_chromium_source("9.9", "7", "linux-x64")[0], "chrome-for-testing")

    def test_the_cdn_is_used_only_when_cft_lacks_the_platform(self):
        self.serve(self.head_routes(["/cdn/7/chromium-linux-arm64.zip"]))
        src, url = pins.choose_chromium_source("9.9", "7", "linux-arm64")
        self.assertEqual(src, "playwright-cdn")
        self.assertTrue(url.endswith("/cdn/7/chromium-linux-arm64.zip"))

    def test_neither_source_is_an_error_for_a_linux_platform(self):
        self.serve({})
        with self.assertRaises(pins.PinError) as cm:
            pins.choose_chromium_source("9.9", "7", "linux-x64")
        self.assertIn("neither", str(cm.exception))

    def test_a_darwin_platform_has_no_cdn_fallback(self):
        self.serve(self.head_routes(["/cdn/7/chromium-linux.zip"]))
        with self.assertRaises(pins.PinError):
            pins.choose_chromium_source("9.9", "7", "darwin-arm64")


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
