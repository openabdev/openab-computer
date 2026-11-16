#!/usr/bin/env python3
"""Generate and verify the pins for the on-demand Playwright install (ADR browser-tiers Q4).

The pins live in release/playwright-pins/ (pins.json, package.json, package-lock.json) and are
rendered into Sources/InstanceMCPCore/Browser/PlaywrightPins.generated.swift, so the app signature
covers them. This script is a release check, not application code.

  generate        download the pinned artifacts, hash them, write the pins (needs the network)
  add-linux       keep every shared and macOS pin, (re)compute the Linux platforms, write schema 2
  verify          check the tracked files: --offline (default, no network) or --online
  render-swift    rewrite the generated Swift file from the three source files

pins.json is schema 2: node and chromium artifacts are keyed by platform id (darwin-arm64,
darwin-x64, linux-x64, linux-arm64). package.json, the lockfile and the version fields are shared.
Each platform's Chromium comes from Chrome for Testing where it hosts the pinned version, else from
the Playwright CDN; the source is recorded per artifact and the check fails if a platform has neither
(ADR linux-browser-tier D1, D2).

Python 3.8+, standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINS_DIR = os.path.join(ROOT, "release", "playwright-pins")
SWIFT_OUT = os.path.join(ROOT, "Sources", "InstanceMCPCore", "Browser", "PlaywrightPins.generated.swift")
CATALOG = os.path.join(ROOT, "Sources", "InstanceMCPCore", "Browser", "BrowserToolCatalog.swift")

NPM_REGISTRY = "https://registry.npmjs.org/"
NODE_HOST = "nodejs.org"
REGISTRY_HOST = "registry.npmjs.org"
DARWIN_PLATFORMS = ("darwin-arm64", "darwin-x64")
LINUX_PLATFORMS = ("linux-x64", "linux-arm64")
PLATFORMS = DARWIN_PLATFORMS + LINUX_PLATFORMS
# Chrome for Testing names its platforms differently from the pin keys.
CFT_DIR = {"darwin-arm64": "mac-arm64", "darwin-x64": "mac-x64", "linux-x64": "linux64", "linux-arm64": "linux-arm64"}
CFT_BASE = "https://storage.googleapis.com/chrome-for-testing-public"
CFT_HOST = "storage.googleapis.com"
CDN_HOST = "cdn.playwright.dev"
CDN_BASE = "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium"
CDN_FILE = {"linux-x64": "chromium-linux.zip", "linux-arm64": "chromium-linux-arm64.zip"}
SOURCES = {"chrome-for-testing": CFT_HOST, "playwright-cdn": CDN_HOST}
CHROMIUM_APP = "Google Chrome for Testing.app"
LINUX_FIELDS = ("minGlibc", "needed", "packageHints")

DEFAULT_MAX_FILE = 400 * 1000 * 1000
DEFAULT_MAX_TOTAL = 1600 * 1000 * 1000

# Tests set this to allow http on loopback. Never set by the CLI.
ALLOW_LOOPBACK_HTTP = False


class PinError(Exception):
    pass


# ---------------------------------------------------------------- downloads

class _NoRedirectToOtherHost(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed):
        self.allowed = allowed

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl, self.allowed)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_url(url, allowed_hosts):
    u = urllib.parse.urlparse(url)
    loopback = ALLOW_LOOPBACK_HTTP and u.scheme == "http" and u.hostname in ("127.0.0.1", "::1")
    if u.scheme != "https" and not loopback:
        raise PinError("not https: %s" % url)
    if u.hostname not in allowed_hosts:
        raise PinError("host not allowed: %s" % u.hostname)
    if ".." in u.path.split("/"):
        raise PinError("path traversal in url: %s" % url)


def _opener(allowed):
    return urllib.request.build_opener(_NoRedirectToOtherHost(allowed))


def http_head(url, allowed):
    check_url(url, allowed)
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "oab-playwright-pins"})
    with _opener(allowed).open(req, timeout=60) as r:
        return dict((k.lower(), v) for k, v in r.getheaders())


def http_json(url, allowed, max_bytes=20 * 1000 * 1000):
    check_url(url, allowed)
    req = urllib.request.Request(url, headers={"User-Agent": "oab-playwright-pins"})
    with _opener(allowed).open(req, timeout=60) as r:
        data = r.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise PinError("response over cap: %s" % url)
    return json.loads(data.decode("utf-8"))


class Budget:
    def __init__(self, per_file, total):
        self.per_file = per_file
        self.total = total
        self.used = 0

    def take(self, n):
        self.used += n
        if self.used > self.total:
            raise PinError("total download cap exceeded")


def download(url, dest, allowed, budget):
    """Stream to dest. Aborts as soon as a cap is crossed. Returns (size, sha256)."""
    check_url(url, allowed)
    req = urllib.request.Request(url, headers={"User-Agent": "oab-playwright-pins"})
    h = hashlib.sha256()
    n = 0
    with _opener(allowed).open(req, timeout=120) as r, open(dest, "wb") as f:
        declared = r.headers.get("Content-Length")
        if declared is not None and int(declared) > budget.per_file:
            raise PinError("Content-Length over cap: %s" % url)
        while True:
            chunk = r.read(1024 * 256)
            if not chunk:
                break
            n += len(chunk)
            if n > budget.per_file:
                raise PinError("file over cap: %s" % url)
            budget.take(len(chunk))
            h.update(chunk)
            f.write(chunk)
        if declared is not None and int(declared) != n:
            raise PinError("Content-Length disagrees with bytes received: %s" % url)
    return n, h.hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


# ---------------------------------------------------------------- archives (read-only inspection)

def _safe_name(name):
    if not name or name.startswith("/") or "\0" in name or len(name.encode("utf-8")) > 1024:
        return False
    return ".." not in name.split("/")


def inspect_tar_gz(path):
    """entryCount, expandedBytes, maxEntryBytes. Nothing is extracted."""
    count = total = biggest = 0
    with tarfile.open(path, "r:gz") as t:
        for m in t:
            if not _safe_name(m.name):
                raise PinError("unsafe archive member name")
            if not (m.isreg() or m.isdir() or m.issym()):
                raise PinError("archive member of a kind the installer rejects: %s" % m.name)
            count += 1
            if m.isreg():
                total += m.size
                biggest = max(biggest, m.size)
    return {"entryCount": count, "expandedBytes": total, "maxEntryBytes": biggest}


def inspect_zip(path):
    count = total = biggest = 0
    execs = []
    linux_execs = []
    with zipfile.ZipFile(path) as z:
        for i in z.infolist():
            if not _safe_name(i.filename):
                raise PinError("unsafe archive member name")
            if i.flag_bits & 0x1:
                raise PinError("encrypted zip entry")
            count += 1
            mode = (i.external_attr >> 16) & 0xFFFF
            if not i.filename.endswith("/") and not stat.S_ISLNK(mode):
                total += i.file_size
                biggest = max(biggest, i.file_size)
            if i.filename.endswith("Contents/MacOS/Google Chrome for Testing"):
                execs.append(i.filename)
            if LINUX_CHROME.match(i.filename):
                linux_execs.append(i.filename)
    return {"entryCount": count, "expandedBytes": total, "maxEntryBytes": biggest, "executables": execs,
            "linuxExecutables": linux_execs}


# ---------------------------------------------------------------- ELF facts (Linux platforms)

LINUX_CHROME = re.compile(r"^chrome-linux[A-Za-z0-9-]*/chrome$")
SONAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
APT_NAME = re.compile(r"^[a-z0-9][a-z0-9+.-]{1,63}$")
GLIBC_VERSION = re.compile(r"^\d+\.\d+(\.\d+)?$")
MAX_ELF_SECTIONS = 4096
MAX_ELF_TABLE = 16 * 1000 * 1000

# Debian package that provides a shared library the pinned binaries ask the host for. The hint is
# advice printed by the installer, never a command it runs. A name that is not here fails generate,
# so a new dependency is noticed by a person. Ubuntu 24.04 renamed some of these (a "t64" suffix) and
# keeps the old name as a provided name, so the same list works with apt there.
APT_HINTS = {
    "libasound.so.2": "libasound2",
    "libatk-1.0.so.0": "libatk1.0-0",
    "libatk-bridge-2.0.so.0": "libatk-bridge2.0-0",
    "libatspi.so.0": "libatspi2.0-0",
    "libcairo.so.2": "libcairo2",
    "libcups.so.2": "libcups2",
    "libdbus-1.so.3": "libdbus-1-3",
    "libdrm.so.2": "libdrm2",
    "libexpat.so.1": "libexpat1",
    "libgbm.so.1": "libgbm1",
    "libgio-2.0.so.0": "libglib2.0-0",
    "libglib-2.0.so.0": "libglib2.0-0",
    "libgobject-2.0.so.0": "libglib2.0-0",
    "libgmodule-2.0.so.0": "libglib2.0-0",
    "libnspr4.so": "libnspr4",
    "libnss3.so": "libnss3",
    "libnssutil3.so": "libnss3",
    "libsmime3.so": "libnss3",
    "libpango-1.0.so.0": "libpango-1.0-0",
    "libudev.so.1": "libudev1",
    "libX11.so.6": "libx11-6",
    "libxcb.so.1": "libxcb1",
    "libXcomposite.so.1": "libxcomposite1",
    "libXdamage.so.1": "libxdamage1",
    "libXext.so.6": "libxext6",
    "libXfixes.so.3": "libxfixes3",
    "libxkbcommon.so.0": "libxkbcommon0",
    "libXrandr.so.2": "libxrandr2",
    "libstdc++.so.6": "libstdc++6",
    "libgcc_s.so.1": "libgcc-s1",
    "libc.so.6": "libc6",
    "libm.so.6": "libc6",
    "libdl.so.2": "libc6",
    "libpthread.so.0": "libc6",
    "librt.so.1": "libc6",
    "libutil.so.1": "libc6",
    "libresolv.so.2": "libc6",
    "ld-linux-x86-64.so.2": "libc6",
    "ld-linux-aarch64.so.1": "libc6",
}


def package_hints(needed):
    """{"apt": sorted package names} for a needed-library list; unknown libraries are an error."""
    missing = [n for n in needed if n not in APT_HINTS]
    if missing:
        raise PinError("no package hint for: %s (add it to APT_HINTS)" % ", ".join(missing))
    return {"apt": sorted(set(APT_HINTS[n] for n in needed))}


def _cstr(table, off):
    if off < 0 or off >= len(table):
        raise PinError("ELF string offset out of range")
    end = table.find(b"\0", off)
    if end < 0 or end - off > 4096:
        raise PinError("ELF string is not terminated")
    return table[off:end].decode("ascii", "strict")


def elf_facts(path):
    """Read a 64-bit little-endian ELF: DT_NEEDED names and the highest GLIBC_x.y version it needs.
    Reads section headers only; never runs the file. Returns {"needed": [...], "glibc": (maj, min, patch)}."""
    import struct
    with open(path, "rb") as f:
        head = f.read(64)
        if len(head) < 64 or head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1:
            raise PinError("not a 64-bit little-endian ELF file")
        (_t, _m, _v, _entry, _phoff, shoff, _fl, _eh, _phes, _phn, shentsize, shnum, _shstr) = struct.unpack("<HHIQQQIHHHHHH", head[16:64])
        if shoff == 0 or shnum == 0 or shnum > MAX_ELF_SECTIONS or shentsize != 64:
            raise PinError("ELF has no usable section header table")
        f.seek(shoff)
        raw = f.read(shnum * 64)
        if len(raw) != shnum * 64:
            raise PinError("ELF section headers are truncated")
        secs = [struct.unpack("<IIQQQQIIQQ", raw[i * 64:(i + 1) * 64]) for i in range(shnum)]

        def blob(sec):
            _n, _ty, _fl, _ad, off, size, _lk, _inf, _al, _es = sec
            if size > MAX_ELF_TABLE:
                raise PinError("ELF table over cap")
            f.seek(off)
            data = f.read(size)
            if len(data) != size:
                raise PinError("ELF table is truncated")
            return data

        needed = []
        glibc = None
        found_dynamic = False
        for sec in secs:
            ty, link, info = sec[1], sec[6], sec[7]
            if ty == 6:  # SHT_DYNAMIC
                found_dynamic = True
                if link >= shnum:
                    raise PinError("ELF dynamic section links nowhere")
                strs = blob(secs[link])
                dyn = blob(sec)
                for i in range(0, len(dyn) - 15, 16):
                    tag, val = struct.unpack("<qQ", dyn[i:i + 16])
                    if tag == 0:
                        break
                    if tag == 1:
                        needed.append(_cstr(strs, val))
            elif ty == 0x6ffffffe:  # SHT_GNU_verneed
                if link >= shnum:
                    raise PinError("ELF verneed section links nowhere")
                strs = blob(secs[link])
                data = blob(sec)
                off = 0
                for _ in range(info):
                    if off + 16 > len(data):
                        raise PinError("ELF verneed is truncated")
                    _ver, cnt, _file, aux, nxt = struct.unpack("<HHIII", data[off:off + 16])
                    a = off + aux
                    for _j in range(cnt):
                        if a + 16 > len(data):
                            raise PinError("ELF vernaux is truncated")
                        _h, _fl, _o, name, anext = struct.unpack("<IHHII", data[a:a + 16])
                        v = _cstr(strs, name)
                        m = re.match(r"^GLIBC_(\d+)\.(\d+)(?:\.(\d+))?$", v)
                        if m:
                            t = (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
                            glibc = t if glibc is None or t > glibc else glibc
                        a += anext
                    if nxt == 0:
                        break
                    off += nxt
        if not found_dynamic:
            raise PinError("ELF has no dynamic section")
    return {"needed": needed, "glibc": glibc}


def glibc_string(t):
    return "%d.%d" % t[:2] if t[2] == 0 else "%d.%d.%d" % t


def _merge_facts(facts_list, bundled):
    needed = set()
    glibc = None
    for fa in facts_list:
        needed.update(fa["needed"])
        if fa["glibc"] and (glibc is None or fa["glibc"] > glibc):
            glibc = fa["glibc"]
    needed -= set(bundled)
    if glibc is None:
        raise PinError("no GLIBC version requirement found")
    return {"minGlibc": glibc_string(glibc), "needed": sorted(needed), "packageHints": package_hints(sorted(needed))}


def _copy_member(src, dest, size_cap):
    n = 0
    with open(dest, "wb") as out:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            n += len(chunk)
            if n > size_cap:
                raise PinError("archive member larger than its declared size")
            out.write(chunk)


def linux_facts_zip(path, work):
    """minGlibc, needed and packageHints for a Chromium zip: the chrome executable plus every bundled
    shared object, minus libraries the zip itself ships."""
    tmp = os.path.join(work, "elf.tmp")
    facts = []
    with zipfile.ZipFile(path) as z:
        infos = [i for i in z.infolist() if not i.filename.endswith("/")]
        bundled = set(i.filename.rsplit("/", 1)[-1] for i in infos)
        for i in infos:
            base = i.filename.rsplit("/", 1)[-1]
            if LINUX_CHROME.match(i.filename) or re.search(r"\.so(\.\d+)*$", base):
                with z.open(i) as src:
                    _copy_member(src, tmp, i.file_size)
                try:
                    facts.append(elf_facts(tmp))
                except PinError:
                    if LINUX_CHROME.match(i.filename):
                        raise
                    # a bundled file that is not a loadable ELF (data named .so) adds no needs
                finally:
                    os.remove(tmp)
    if not facts:
        raise PinError("no ELF files in the Chromium zip")
    return _merge_facts(facts, bundled)


def linux_facts_tar(path, member, work):
    tmp = os.path.join(work, "elf.tmp")
    with tarfile.open(path, "r:gz") as t:
        m = t.getmember(member)
        if not m.isreg():
            raise PinError("%s is not a regular file" % member)
        _copy_member(t.extractfile(m), tmp, m.size)
    try:
        return _merge_facts([elf_facts(tmp)], [])
    finally:
        os.remove(tmp)


def extract_tar_gz_for_generate(path, dest):
    """Extract the Node tarball for `generate` only, with the same refusals as the app's extractor."""
    dest = os.path.realpath(dest)
    with tarfile.open(path, "r:gz") as t:
        for m in t:
            if not _safe_name(m.name):
                raise PinError("unsafe archive member name")
            target = os.path.realpath(os.path.join(dest, m.name))
            if not (target == dest or target.startswith(dest + os.sep)):
                raise PinError("archive member escapes the destination")
            if m.isdir():
                os.makedirs(target, exist_ok=True)
            elif m.isreg():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                src = t.extractfile(m)
                with open(target, "wb") as f:
                    shutil.copyfileobj(src, f)
                os.chmod(target, m.mode & 0o755)
            elif m.issym():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                link_target = os.path.realpath(os.path.join(os.path.dirname(target), m.linkname))
                if m.linkname.startswith("/") or not (link_target == dest or link_target.startswith(dest + os.sep)):
                    raise PinError("symlink escapes the destination")
                os.symlink(m.linkname, target)
            else:
                raise PinError("unsupported archive member")


# ---------------------------------------------------------------- pins files

def read_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def dump_pins(pins):
    return json.dumps(pins, indent=2, sort_keys=False, ensure_ascii=True) + "\n"


def pins_paths(d=None):
    d = d or PINS_DIR
    return (os.path.join(d, "pins.json"), os.path.join(d, "package.json"), os.path.join(d, "package-lock.json"))


def render_swift(pins_bytes, package_bytes, lock_bytes):
    def body(b):
        s = b.decode("utf-8")
        if '"""#' in s or "\\#" in s:
            raise PinError("data contains a Swift raw-string delimiter")
        if not s.endswith("\n"):
            raise PinError("source file must end with a newline")
        return s[:-1]
    return (
        "// GENERATED by scripts/playwright-pins.py generate. Do not edit.\n"
        "// The release check fails if this file differs from release/playwright-pins/.\n"
        "// The constants are part of the signed app: they are the manifest the installer trusts (ADR Q4).\n"
        "enum PlaywrightPins {\n"
        "    /// release/playwright-pins/pins.json, without its final newline.\n"
        '    static let pinsJSONBody = #"""\n' + body(pins_bytes) + '\n"""#\n'
        "    /// release/playwright-pins/package.json, without its final newline.\n"
        '    static let packageJSONBody = #"""\n' + body(package_bytes) + '\n"""#\n'
        "    /// release/playwright-pins/package-lock.json, without its final newline.\n"
        '    static let lockfileJSONBody = #"""\n' + body(lock_bytes) + '\n"""#\n'
        '    static var pinsJSON: String { pinsJSONBody + "\\n" }\n'
        '    static var packageJSON: String { packageJSONBody + "\\n" }\n'
        '    static var lockfileJSON: String { lockfileJSONBody + "\\n" }\n'
        "}\n"
    )


def write_swift(d=None, out=None):
    p, k, l = pins_paths(d)
    text = render_swift(read_bytes(p), read_bytes(k), read_bytes(l))
    out = out or SWIFT_OUT
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# ---------------------------------------------------------------- offline verification

SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def catalog_names():
    text = read_bytes(CATALOG).decode("utf-8")
    return sorted(set(re.findall(r'"(browser_[a-z_]+)"', text)))


def _date_ok(s):
    try:
        time.strptime(s, "%Y-%m-%d")
        return bool(re.match(r"^\d{4}-\d{2}-\d{2}$", s))
    except (TypeError, ValueError):
        return False


def expected_chromium_url(pins, platform, source):
    """The one URL a platform's Chromium may have for its source. A mismatch is drift."""
    bver, rev = pins["chromium"]["browserVersion"], pins["chromium"]["revision"]
    if source == "chrome-for-testing":
        return "%s/%s/%s/chrome-%s.zip" % (CFT_BASE, bver, CFT_DIR[platform], CFT_DIR[platform])
    if source == "playwright-cdn" and platform in CDN_FILE:
        return "%s/%s/%s" % (CDN_BASE, rev, CDN_FILE[platform])
    return None


def expected_node_url(pins, platform):
    v = pins["node"]["version"]
    return "https://%s/dist/v%s/node-v%s-%s.tar.gz" % (NODE_HOST, v, v, platform)


def verify_linux_fields(label, plat, a, need):
    """minGlibc, needed and packageHints exist on Linux artifacts and nowhere else."""
    if plat not in LINUX_PLATFORMS:
        for k in LINUX_FIELDS:
            need(k not in a, "%s/%s must not carry %s" % (label, plat, k))
        return
    g = a.get("minGlibc")
    need(isinstance(g, str) and bool(GLIBC_VERSION.match(g)), "%s/%s minGlibc missing or malformed" % (label, plat))
    nd = a.get("needed")
    ok = isinstance(nd, list) and bool(nd) and all(isinstance(x, str) and SONAME.match(x) for x in nd) \
        and nd == sorted(set(nd))
    need(ok, "%s/%s needed must be a sorted, unique, non-empty list of library names" % (label, plat))
    ph = a.get("packageHints")
    hints_ok = isinstance(ph, dict) and sorted(ph.keys()) == ["apt"] and isinstance(ph["apt"], list) \
        and all(isinstance(x, str) and APT_NAME.match(x) for x in ph["apt"]) and ph["apt"] == sorted(set(ph["apt"]))
    need(hints_ok, "%s/%s packageHints must be {\"apt\": sorted package names}" % (label, plat))
    if ok and hints_ok:
        try:
            need(ph == package_hints(nd), "%s/%s packageHints do not follow from needed" % (label, plat))
        except PinError as e:
            need(False, "%s/%s %s" % (label, plat, e))


def verify_pins_structure(pins, problems):
    def need(cond, msg):
        if not cond:
            problems.append(msg)
    need(pins.get("schema") == 2, "schema must be 2")
    pid = pins.get("id", "")
    need(isinstance(pid, str) and bool(SAFE_ID.match(pid)), "id is not a safe path component")
    mcp = pins.get("mcp", {})
    node = pins.get("node", {})
    chromium = pins.get("chromium", {})
    for key in ("version", "playwrightCoreVersion", "packageJsonSHA256", "lockfileSHA256"):
        need(bool(mcp.get(key)), "mcp.%s missing" % key)
    for key in ("packageJsonSHA256", "lockfileSHA256"):
        need(bool(HEX64.match(str(mcp.get(key, "")))), "mcp.%s is not a sha256" % key)
    need(bool(re.match(r"^[A-Z0-9]{10}$", str(node.get("teamIdentifier", "")))), "node.teamIdentifier missing or malformed")
    need(_date_ok(chromium.get("releasedAt")), "chromium.releasedAt must be YYYY-MM-DD")
    hosts = pins.get("hosts", [])
    chromium_hosts = set()
    for label, section in (("node", node), ("chromium", chromium)):
        arts = section.get("artifacts", {})
        need(sorted(arts.keys()) == sorted(PLATFORMS), "%s artifacts must cover exactly %s" % (label, ", ".join(PLATFORMS)))
        for plat, a in arts.items():
            if plat not in PLATFORMS:
                continue
            url = a.get("url", "")
            u = urllib.parse.urlparse(url)
            need(u.scheme == "https" and u.hostname in hosts and ".." not in u.path.split("/"),
                 "%s/%s url not https on an allowed host" % (label, plat))
            need(bool(HEX64.match(str(a.get("sha256", "")))), "%s/%s sha256 malformed" % (label, plat))
            for k in ("size", "expandedBytes", "entryCount", "maxEntryBytes"):
                need(isinstance(a.get(k), int) and a[k] > 0, "%s/%s %s missing" % (label, plat, k))
            need(a.get("format") == ("tar.gz" if label == "node" else "zip"), "%s/%s format wrong" % (label, plat))
            need(isinstance(a.get("stripComponents"), int) and 0 <= a["stripComponents"] <= 4, "%s/%s stripComponents out of range" % (label, plat))
            if label == "node":
                if node.get("version"):
                    need(url == expected_node_url(pins, plat), "node/%s url does not follow node.version" % plat)
                continue
            if u.hostname:
                chromium_hosts.add(u.hostname)
            src = a.get("source")
            need(src in SOURCES, "chromium/%s source must be one of %s" % (plat, ", ".join(sorted(SOURCES))))
            if src in SOURCES:
                need(u.hostname == SOURCES[src], "chromium/%s url host does not match its source" % plat)
                want = expected_chromium_url(pins, plat, src) if chromium.get("browserVersion") and chromium.get("revision") else None
                need(want is not None and url == want, "chromium/%s url does not follow the pinned version for source %s" % (plat, src))
            ex = a.get("executable")
            if plat in LINUX_PLATFORMS:
                need(isinstance(ex, str) and bool(LINUX_CHROME.match(ex)), "chromium/%s executable path missing or unsafe" % plat)
            else:
                need(isinstance(ex, str) and bool(ex) and ".." not in ex.split("/") and not ex.startswith("/"),
                     "chromium/%s executable path missing or unsafe" % plat)
        for plat, a in arts.items():
            if plat in PLATFORMS:
                verify_linux_fields(label, plat, a, need)
    need(sorted(hosts) == sorted(set([NODE_HOST, REGISTRY_HOST]) | chromium_hosts),
         "hosts must be exactly nodejs.org, registry.npmjs.org and the hosts the chromium urls use")
    need(chromium.get("host") == CFT_HOST, "chromium.host must be the Chrome for Testing host")
    need(isinstance(pins.get("staleAfterDays"), int) and pins["staleAfterDays"] > 0, "staleAfterDays missing")
    need(isinstance(pins.get("freeDiskFactor"), int) and pins["freeDiskFactor"] >= 3, "freeDiskFactor must be at least 3")
    if SAFE_ID.match(str(pid)):
        want = "mcp%s-node%s-cr%s-%s" % (mcp.get("version"), node.get("version"), chromium.get("revision"),
                                        str(mcp.get("lockfileSHA256", ""))[:8])
        need(pid == want, "id should be %s" % want)


def verify_lockfile(lock, package, pins, problems):
    mcp = pins.get("mcp", {})
    if lock.get("lockfileVersion") != 3:
        problems.append("lockfileVersion must be 3")
    deps = package.get("dependencies", {})
    if deps != {"@playwright/mcp": mcp.get("version")}:
        problems.append("package.json must depend on exactly @playwright/mcp at mcp.version")
    if not re.match(r"^\d+\.\d+\.\d+$", str(mcp.get("version", ""))):
        problems.append("mcp.version must be an exact version")
    root = lock.get("packages", {}).get("", {})
    if root.get("dependencies") != {"@playwright/mcp": mcp.get("version")}:
        problems.append("lockfile root dependency is not exactly @playwright/mcp at mcp.version")
    pk = lock.get("packages", {})
    for path, p in pk.items():
        if path == "":
            continue
        if not str(p.get("integrity", "")).startswith("sha512-"):
            problems.append("lockfile package without sha512 integrity: %s" % path)
        if not str(p.get("resolved", "")).startswith(NPM_REGISTRY):
            problems.append("lockfile package not resolved on registry.npmjs.org: %s" % path)
    core = pk.get("node_modules/playwright-core", {})
    if core.get("version") != mcp.get("playwrightCoreVersion"):
        problems.append("lockfile playwright-core version differs from mcp.playwrightCoreVersion")
    mcp_pkg = pk.get("node_modules/@playwright/mcp", {})
    if mcp_pkg.get("version") != mcp.get("version"):
        problems.append("lockfile @playwright/mcp version differs from mcp.version")


def verify_offline(d=None, swift_out=None):
    problems = []
    pp, kp, lp = pins_paths(d)
    for p in (pp, kp, lp):
        if not os.path.isfile(p):
            return ["missing file: %s" % os.path.relpath(p, ROOT)]
    try:
        pins = read_json(pp)
        package = read_json(kp)
        lock = read_json(lp)
    except ValueError as e:
        return ["unreadable JSON: %s" % e]
    if read_bytes(pp).decode("utf-8") != dump_pins(pins):
        problems.append("pins.json is not in canonical form (run generate or render)")
    verify_pins_structure(pins, problems)
    if sha256_bytes(read_bytes(kp)) != pins.get("mcp", {}).get("packageJsonSHA256"):
        problems.append("package.json digest differs from pins.json")
    if sha256_bytes(read_bytes(lp)) != pins.get("mcp", {}).get("lockfileSHA256"):
        problems.append("package-lock.json digest differs from pins.json")
    verify_lockfile(lock, package, pins, problems)
    out = swift_out or SWIFT_OUT
    try:
        want = render_swift(read_bytes(pp), read_bytes(kp), read_bytes(lp))
    except PinError as e:
        problems.append(str(e))
        want = None
    if want is not None:
        if not os.path.isfile(out) or read_bytes(out).decode("utf-8") != want:
            problems.append("PlaywrightPins.generated.swift differs from the pins files (run render-swift)")
    names = catalog_names()
    if len(names) != 32:
        problems.append("BrowserToolCatalog lists %d browser_ names, expected 32" % len(names))
    return problems


# ---------------------------------------------------------------- online verification

def pins_hosts(pins):
    return set(pins["hosts"])


def url_exists(url, allowed):
    """True if a HEAD answers 2xx, False on 403 or 404; any other failure is raised."""
    try:
        http_head(url, allowed)
        return True
    except urllib.error.HTTPError as e:
        if e.code in (403, 404):
            return False
        raise


def choose_chromium_source(bver, rev, platform):
    """Chrome for Testing wherever it hosts the pinned version, else the Playwright CDN, else an error."""
    probe = {CFT_HOST, CDN_HOST}
    cft = "%s/%s/%s/chrome-%s.zip" % (CFT_BASE, bver, CFT_DIR[platform], CFT_DIR[platform])
    if url_exists(cft, probe):
        return "chrome-for-testing", cft
    if platform in CDN_FILE:
        cdn = "%s/%s/%s" % (CDN_BASE, rev, CDN_FILE[platform])
        if url_exists(cdn, probe):
            return "playwright-cdn", cdn
    raise PinError("%s: neither Chrome for Testing nor the Playwright CDN hosts Chromium %s (revision %s)" % (platform, bver, rev))


def verify_online(d=None, per_file=DEFAULT_MAX_FILE, total=DEFAULT_MAX_TOTAL, smoke=False):
    problems = verify_offline(d)
    if problems:
        return problems
    pp, kp, lp = pins_paths(d)
    pins = read_json(pp)
    lock = read_json(lp)
    allowed = pins_hosts(pins)
    work = tempfile.mkdtemp(prefix="oab-pins-verify.")
    budget = Budget(per_file, total)
    try:
        sums = fetch_text(NODE_HOST, "https://%s/dist/v%s/SHASUMS256.txt" % (NODE_HOST, pins["node"]["version"]), allowed)
        for plat, a in pins["node"]["artifacts"].items():
            fname = a["url"].rsplit("/", 1)[1]
            line = [l for l in sums.splitlines() if l.endswith("  " + fname)]
            if not line or line[0].split()[0] != a["sha256"]:
                problems.append("node %s digest differs from nodejs.org SHASUMS256.txt" % plat)
        # Every platform must have a source, and a platform that Chrome for Testing hosts must use it.
        for plat, a in pins["chromium"]["artifacts"].items():
            try:
                src, _url = choose_chromium_source(pins["chromium"]["browserVersion"], pins["chromium"]["revision"], plat)
            except PinError as e:
                problems.append(str(e))
                continue
            except (urllib.error.URLError, OSError) as e:
                problems.append("chromium %s: source probe failed (%s)" % (plat, e.__class__.__name__))
                continue
            if src != a["source"]:
                problems.append("chromium %s: pinned source is %s but %s hosts it" % (plat, a["source"], src))
        for label in ("node", "chromium"):
            for plat, a in pins[label]["artifacts"].items():
                dest = os.path.join(work, "%s-%s" % (label, plat))
                try:
                    n, h = download(a["url"], dest, allowed, budget)
                except (PinError, urllib.error.URLError, OSError) as e:
                    problems.append("%s %s: download failed (%s)" % (label, plat, e.__class__.__name__))
                    continue
                if n != a["size"] or h != a["sha256"]:
                    problems.append("%s %s: upstream bytes differ from the pin" % (label, plat))
                elif plat in LINUX_PLATFORMS:
                    problems.extend(check_linux_artifact(label, plat, a, dest, pins, work))
                os.remove(dest)
        core = lock["packages"]["node_modules/playwright-core"]
        core_tgz = os.path.join(work, "playwright-core.tgz")
        n, h = download(core["resolved"], core_tgz, allowed, budget)
        import base64
        digest = hashlib.sha512(open(core_tgz, "rb").read()).digest()
        if "sha512-" + base64.b64encode(digest).decode() != core["integrity"]:
            problems.append("playwright-core tarball does not match the lockfile integrity")
        else:
            with tarfile.open(core_tgz, "r:gz") as t:
                bj = json.loads(t.extractfile("package/browsers.json").read().decode("utf-8"))
            ch = [b for b in bj["browsers"] if b["name"] == "chromium"][0]
            if ch["revision"] != pins["chromium"]["revision"] or ch["browserVersion"] != pins["chromium"]["browserVersion"]:
                problems.append("chromium revision differs from playwright-core browsers.json")
        for path, p in lock["packages"].items():
            if path == "":
                continue
            name = p.get("name") or path.split("node_modules/")[-1]
            meta = http_json("%s%s/%s" % (NPM_REGISTRY, urllib.parse.quote(name, safe="@").replace("/", "%2f"), p["version"]), allowed)
            if meta.get("dist", {}).get("integrity") != p["integrity"]:
                problems.append("registry integrity differs from lockfile: %s" % path)
        if smoke:
            problems.extend(run_smoke(pins, lock, kp, lp, work))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return problems


def check_linux_artifact(label, plat, a, path, pins, work):
    """Recompute minGlibc, needed and packageHints from the downloaded bytes and compare with the pin."""
    try:
        if label == "node":
            nv = pins["node"]["version"]
            got = linux_facts_tar(path, "node-v%s-%s/bin/node" % (nv, plat), work)
        else:
            if inspect_zip(path)["linuxExecutables"] != [a["executable"]]:
                return ["chromium %s: the zip does not contain exactly the pinned executable" % plat]
            got = linux_facts_zip(path, work)
    except (PinError, OSError, KeyError, zipfile.BadZipFile, tarfile.TarError) as e:
        return ["%s %s: could not read the ELF facts (%s)" % (label, plat, e if isinstance(e, PinError) else e.__class__.__name__)]
    return ["%s %s: %s differs from the downloaded binary" % (label, plat, k) for k in LINUX_FIELDS if got[k] != a.get(k)]


def fetch_text(host, url, allowed):
    check_url(url, allowed | {host})
    req = urllib.request.Request(url, headers={"User-Agent": "oab-playwright-pins"})
    with _opener(allowed | {host}).open(req, timeout=60) as r:
        return r.read(2 * 1000 * 1000).decode("utf-8")


def run_smoke(pins, lock, kp, lp, work):
    """Install the locked package on this machine's node and check tools/list has the 32 names."""
    problems = []
    d = os.path.join(work, "smoke")
    os.makedirs(d)
    shutil.copy(kp, os.path.join(d, "package.json"))
    shutil.copy(lp, os.path.join(d, "package-lock.json"))
    empty, empty_g = os.path.join(work, "user.npmrc"), os.path.join(work, "global.npmrc")
    open(empty, "w").close()
    open(empty_g, "w").close()
    env = {"PATH": os.environ.get("PATH", ""), "HOME": work}
    r = subprocess.run(["npm", "ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund", "--userconfig", empty,
                        "--globalconfig", empty_g, "--registry", NPM_REGISTRY, "--cache", os.path.join(work, "cache")],
                       cwd=d, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    if r.returncode != 0:
        return ["smoke: npm ci failed"]
    cli = os.path.join(d, "node_modules", "@playwright", "mcp", "cli.js")
    p = subprocess.Popen(["node", cli, "--headless", "--caps", "vision,pdf"], cwd=d, env=env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        def send(o):
            p.stdin.write((json.dumps(o) + "\n").encode())
            p.stdin.flush()

        def recv(want_id, timeout=60):
            end = time.time() + timeout
            while time.time() < end:
                line = p.stdout.readline()
                if not line:
                    return None
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get("id") == want_id:
                    return m
            return None
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "pins", "version": "0"}}})
        if recv(1) is None:
            return ["smoke: no initialize reply"]
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        m = recv(2)
        got = sorted(t["name"] for t in (m or {}).get("result", {}).get("tools", []))
        want = catalog_names()
        if got != want:
            problems.append("smoke: tools/list differs from BrowserToolCatalog (missing %s, extra %s)" % (
                sorted(set(want) - set(got)), sorted(set(got) - set(want))))
    finally:
        try:
            p.stdin.close()
        except OSError:
            pass
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
    return problems


# ---------------------------------------------------------------- generate

def verify_node_signature(node_bin, team_id):
    """The downloaded Node must be validly signed by the expected team before the generator runs it."""
    v = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", node_bin],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    if v.returncode != 0:
        raise PinError("downloaded node has no valid code signature")
    d = subprocess.run(["/usr/bin/codesign", "-dvv", node_bin], stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE, timeout=120)
    ids = [l.split("=", 1)[1].strip() for l in d.stderr.decode("utf-8", "replace").splitlines()
           if l.startswith("TeamIdentifier=")]
    if ids != [team_id]:
        raise PinError("downloaded node TeamIdentifier does not match --node-team-id")


def build_node_artifact(nv, plat, sums, work, budget):
    allowed = {NODE_HOST, REGISTRY_HOST}
    fname = "node-v%s-%s.tar.gz" % (nv, plat)
    url = "https://%s/dist/v%s/%s" % (NODE_HOST, nv, fname)
    dest = os.path.join(work, fname)
    size, digest = download(url, dest, allowed, budget)
    line = [l for l in sums.splitlines() if l.endswith("  " + fname)]
    if not line or line[0].split()[0] != digest:
        raise PinError("%s does not match nodejs.org SHASUMS256.txt" % fname)
    info = inspect_tar_gz(dest)
    art = {"url": url, "format": "tar.gz", "size": size, "sha256": digest, "stripComponents": 1,
           "expandedBytes": info["expandedBytes"], "entryCount": info["entryCount"],
           "maxEntryBytes": info["maxEntryBytes"]}
    if plat in LINUX_PLATFORMS:
        art.update(linux_facts_tar(dest, "node-v%s-%s/bin/node" % (nv, plat), work))
    return art, dest


def build_chromium_artifact(bver, rev, plat, work, budget):
    """Download one platform's Chromium from the source choose_chromium_source picks. Returns (artifact, last-modified day)."""
    source, url = choose_chromium_source(bver, rev, plat)
    allowed = {SOURCES[source]}
    dest = os.path.join(work, "chromium-%s.zip" % plat)
    size, digest = download(url, dest, allowed, budget)
    info = inspect_zip(dest)
    if plat in LINUX_PLATFORMS:
        if len(info["linuxExecutables"]) != 1:
            raise PinError("chromium zip for %s has no unique executable" % plat)
        exe = info["linuxExecutables"][0]
    else:
        if len(info["executables"]) != 1 or not info["executables"][0].startswith("chrome-%s/%s/" % (CFT_DIR[plat], CHROMIUM_APP)):
            raise PinError("chromium zip has no unique executable")
        exe = info["executables"][0]
    day = None
    lm = http_head(url, allowed).get("last-modified")
    if lm:
        import email.utils
        day = time.strftime("%Y-%m-%d", email.utils.parsedate(lm))
    art = {"url": url, "format": "zip", "size": size, "sha256": digest, "stripComponents": 0,
           "expandedBytes": info["expandedBytes"], "entryCount": info["entryCount"],
           "maxEntryBytes": info["maxEntryBytes"], "executable": exe, "source": source}
    if plat in LINUX_PLATFORMS:
        art.update(linux_facts_zip(dest, work))
    return art, day


def finish_pins(pins):
    pins["hosts"] = [NODE_HOST, REGISTRY_HOST] + sorted(
        set(SOURCES[a["source"]] for a in pins["chromium"]["artifacts"].values()) - set([NODE_HOST, REGISTRY_HOST]))
    return pins


def write_pins(pins, package_bytes, lock_bytes, args):
    out = args.out or PINS_DIR
    os.makedirs(out, exist_ok=True)
    pp, kp, lp = pins_paths(out)
    old = read_json(pp) if os.path.isfile(pp) else None
    with open(pp, "w", newline="\n") as f:
        f.write(dump_pins(pins))
    if package_bytes is not None:
        with open(kp, "wb") as f:
            f.write(package_bytes)
        with open(lp, "wb") as f:
            f.write(lock_bytes)
    write_swift(out, args.swift_out)
    print_summary(old, pins)


def generate(args):
    if not args.node_team_id:
        raise PinError("--node-team-id is required: record it from a verified Node download (V10)")
    work = os.path.abspath(args.workdir)
    os.makedirs(work, exist_ok=True)
    budget = Budget(args.max_file_bytes, args.max_total_bytes)
    nv, mv = args.node_version, args.mcp_version
    if not re.match(r"^\d+\.\d+\.\d+$", nv) or not re.match(r"^\d+\.\d+\.\d+$", mv):
        raise PinError("versions must be exact x.y.z")
    node_allowed = {NODE_HOST, REGISTRY_HOST}
    sums = fetch_text(NODE_HOST, "https://%s/dist/v%s/SHASUMS256.txt" % (NODE_HOST, nv), node_allowed)
    node_arts = {}
    node_files = {}
    for plat in PLATFORMS:
        node_arts[plat], node_files[plat] = build_node_artifact(nv, plat, sums, work, budget)
    # npm lockfile with the downloaded Node's own npm (no system Node needed).
    host_plat = "darwin-arm64" if os.uname().machine == "arm64" else "darwin-x64"
    node_root = os.path.join(work, "node-host")
    extract_tar_gz_for_generate(node_files[host_plat], node_root)
    node_dir = os.path.join(node_root, "node-v%s-%s" % (nv, host_plat))
    node_bin = os.path.join(node_dir, "bin", "node")
    npm_cli = os.path.join(node_dir, "lib", "node_modules", "npm", "bin", "npm-cli.js")
    verify_node_signature(node_bin, args.node_team_id)   # V10: before this Node runs anything
    pkg = os.path.join(work, "pkg")
    os.makedirs(pkg, exist_ok=True)
    package_json = json.dumps({"name": "oab-playwright-pkg", "private": True, "version": "0.0.0",
                               "dependencies": {"@playwright/mcp": mv}}, indent=2) + "\n"
    with open(os.path.join(pkg, "package.json"), "w") as f:
        f.write(package_json)
    empty, empty_g = os.path.join(work, "user.npmrc"), os.path.join(work, "global.npmrc")
    open(empty, "w").close()
    open(empty_g, "w").close()
    env = {"PATH": "%s:/usr/bin:/bin" % os.path.dirname(node_bin), "HOME": work, "LANG": "en_US.UTF-8"}
    r = subprocess.run([node_bin, npm_cli, "install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund",
                        "--userconfig", empty, "--globalconfig", empty_g, "--registry", NPM_REGISTRY,
                        "--cache", os.path.join(work, "npm-cache")], cwd=pkg, env=env, timeout=600,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        # A release-time tool, not the app: showing the tail of npm's complaint is what the maintainer needs.
        sys.stderr.write(r.stderr.decode("utf-8", "replace")[-2000:])
        raise PinError("npm install --package-lock-only failed")
    lock_bytes = read_bytes(os.path.join(pkg, "package-lock.json"))
    lock = json.loads(lock_bytes.decode("utf-8"))
    package_bytes = package_json.encode("utf-8")
    core = lock["packages"]["node_modules/playwright-core"]
    problems = []
    verify_lockfile(lock, json.loads(package_json), {"mcp": {"version": mv, "playwrightCoreVersion": core["version"]}}, problems)
    if problems:
        raise PinError("lockfile rejected: " + "; ".join(problems))
    # playwright-core: integrity-checked, then browsers.json for the Chromium revision.
    core_tgz = os.path.join(work, "playwright-core.tgz")
    download(core["resolved"], core_tgz, node_allowed, budget)
    import base64
    if "sha512-" + base64.b64encode(hashlib.sha512(open(core_tgz, "rb").read()).digest()).decode() != core["integrity"]:
        raise PinError("playwright-core tarball does not match the lockfile")
    with tarfile.open(core_tgz, "r:gz") as t:
        bj = json.loads(t.extractfile("package/browsers.json").read().decode("utf-8"))
    ch = [b for b in bj["browsers"] if b["name"] == "chromium"][0]
    rev, bver = ch["revision"], ch["browserVersion"]
    cr_arts = {}
    released = None
    for plat in PLATFORMS:
        cr_arts[plat], day = build_chromium_artifact(bver, rev, plat, work, budget)
        if day:
            released = min(released, day) if released else day
    # npm sizes: the tarballs themselves for the download size, registry metadata for the unpacked size.
    dl = unpacked = count = 0
    for path, p in lock["packages"].items():
        if path == "":
            continue
        count += 1
        tgz = os.path.join(work, "npm-%d.tgz" % count)
        dl += download(p["resolved"], tgz, node_allowed, budget)[0]
        os.remove(tgz)
        name = path.split("node_modules/")[-1]
        meta = http_json("%s%s/%s" % (NPM_REGISTRY, name.replace("/", "%2f"), p["version"]), node_allowed)
        unpacked += int(meta.get("dist", {}).get("unpackedSize", 0))
    lock_sha = sha256_bytes(lock_bytes)
    pins = {
        "schema": 2,
        "id": "mcp%s-node%s-cr%s-%s" % (mv, nv, rev, lock_sha[:8]),
        "mcp": {"package": "@playwright/mcp", "version": mv, "playwrightCoreVersion": core["version"],
                "packageJsonSHA256": sha256_bytes(package_bytes), "lockfileSHA256": lock_sha,
                "npmDownloadBytes": dl, "npmInstalledBytes": unpacked, "npmPackageCount": count},
        "node": {"version": nv, "teamIdentifier": args.node_team_id, "artifacts": node_arts},
        "chromium": {"revision": rev, "browserVersion": bver, "releasedAt": released or "1970-01-01",
                     "host": CFT_HOST, "artifacts": cr_arts},
        "hosts": [],
        "staleAfterDays": 180,
        "freeDiskFactor": 3,
    }
    write_pins(finish_pins(pins), package_bytes, lock_bytes, args)


SCHEMA1_KEYS = {"arm64": "darwin-arm64", "x86_64": "darwin-x64"}


def add_linux(args):
    """Schema 1 or 2 in, schema 2 out. Every shared and macOS value is carried over unchanged; only the
    Linux platforms are downloaded and measured. This is how the macOS pins stay byte-identical."""
    out = args.out or PINS_DIR
    pins = read_json(pins_paths(out)[0])
    work = os.path.abspath(args.workdir)
    os.makedirs(work, exist_ok=True)
    budget = Budget(args.max_file_bytes, args.max_total_bytes)
    for label in ("node", "chromium"):
        arts = pins[label]["artifacts"]
        pins[label]["artifacts"] = {SCHEMA1_KEYS.get(k, k): v for k, v in arts.items()}
    for plat, a in pins["chromium"]["artifacts"].items():
        if plat in DARWIN_PLATFORMS and "source" not in a:
            a["source"] = "chrome-for-testing"
    nv = pins["node"]["version"]
    bver, rev = pins["chromium"]["browserVersion"], pins["chromium"]["revision"]
    sums = fetch_text(NODE_HOST, "https://%s/dist/v%s/SHASUMS256.txt" % (NODE_HOST, nv), {NODE_HOST, REGISTRY_HOST})
    for plat in LINUX_PLATFORMS:
        pins["node"]["artifacts"][plat] = build_node_artifact(nv, plat, sums, work, budget)[0]
        pins["chromium"]["artifacts"][plat] = build_chromium_artifact(bver, rev, plat, work, budget)[0]
    for label in ("node", "chromium"):
        arts = pins[label]["artifacts"]
        pins[label]["artifacts"] = {k: arts[k] for k in PLATFORMS}
    pins["schema"] = 2
    write_pins(finish_pins(pins), None, None, args)


def print_summary(old, new):
    def line(k, a, b):
        print("  %-22s %s -> %s" % (k, a if a is not None else "-", b) if a != b else "  %-22s %s (unchanged)" % (k, b))
    print("pins written: id %s" % new["id"])
    line("@playwright/mcp", old and old["mcp"]["version"], new["mcp"]["version"])
    line("playwright-core", old and old["mcp"]["playwrightCoreVersion"], new["mcp"]["playwrightCoreVersion"])
    line("node", old and old["node"]["version"], new["node"]["version"])
    line("chromium", old and old["chromium"]["browserVersion"], new["chromium"]["browserVersion"])
    for label in ("node", "chromium"):
        for plat, a in new[label]["artifacts"].items():
            print("  %s %-12s %12d bytes  %s  sha256 %s" % (label, plat, a["size"], a.get("source", "nodejs.org"), a["sha256"]))


# ---------------------------------------------------------------- cli

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--node-version", required=True)
    g.add_argument("--mcp-version", required=True)
    g.add_argument("--node-team-id")
    g.add_argument("--workdir", required=True)
    g.add_argument("--max-file-bytes", type=int, default=DEFAULT_MAX_FILE)
    g.add_argument("--max-total-bytes", type=int, default=DEFAULT_MAX_TOTAL)
    g.add_argument("--out")
    g.add_argument("--swift-out")
    l = sub.add_parser("add-linux")
    l.add_argument("--workdir", required=True)
    l.add_argument("--max-file-bytes", type=int, default=DEFAULT_MAX_FILE)
    l.add_argument("--max-total-bytes", type=int, default=DEFAULT_MAX_TOTAL)
    l.add_argument("--out")
    l.add_argument("--swift-out")
    v = sub.add_parser("verify")
    mode = v.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true")
    mode.add_argument("--online", action="store_true")
    v.add_argument("--smoke", action="store_true")
    v.add_argument("--max-file-bytes", type=int, default=DEFAULT_MAX_FILE)
    v.add_argument("--max-total-bytes", type=int, default=DEFAULT_MAX_TOTAL)
    v.add_argument("--dir")
    sub.add_parser("render-swift")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "generate":
            generate(a)
        elif a.cmd == "add-linux":
            add_linux(a)
        elif a.cmd == "render-swift":
            write_swift()
        else:
            if a.online:
                problems = verify_online(a.dir, a.max_file_bytes, a.max_total_bytes, a.smoke)
            else:
                problems = verify_offline(a.dir)
            if problems:
                for p in problems:
                    print("FAIL: %s" % p, file=sys.stderr)
                return 1
            print("playwright pins: ok (%s)" % ("online" if a.online else "offline"))
    except (PinError, subprocess.CalledProcessError, urllib.error.URLError, OSError) as e:
        print("error: %s" % (e if isinstance(e, PinError) else e.__class__.__name__), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
