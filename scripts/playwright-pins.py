#!/usr/bin/env python3
"""Generate and verify the pins for the on-demand Playwright install (ADR browser-tiers Q4).

The pins live in release/playwright-pins/ (pins.json, package.json, package-lock.json) and are
rendered into Sources/InstanceMCPCore/Browser/PlaywrightPins.generated.swift, so the app signature
covers them. This script is a release check, not application code.

  generate        download the pinned artifacts, hash them, write the pins (needs the network)
  verify          check the tracked files: --offline (default, no network) or --online
  render-swift    rewrite the generated Swift file from the three source files

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
ARCHS = ("arm64", "x86_64")
NODE_ARCH = {"arm64": "arm64", "x86_64": "x64"}
CFT_ARCH = {"arm64": "mac-arm64", "x86_64": "mac-x64"}
CFT_BASE = "https://storage.googleapis.com/chrome-for-testing-public"
CFT_HOST = "storage.googleapis.com"
CHROMIUM_APP = "Google Chrome for Testing.app"

DEFAULT_MAX_FILE = 400 * 1000 * 1000
DEFAULT_MAX_TOTAL = 1000 * 1000 * 1000

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
    return {"entryCount": count, "expandedBytes": total, "maxEntryBytes": biggest, "executables": execs}


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


def verify_pins_structure(pins, problems):
    def need(cond, msg):
        if not cond:
            problems.append(msg)
    need(pins.get("schema") == 1, "schema must be 1")
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
    hosts = pins.get("hosts", [])
    need(sorted(hosts) == sorted([NODE_HOST, REGISTRY_HOST, chromium.get("host", "?")]),
         "hosts must be exactly nodejs.org, registry.npmjs.org and the chromium host")
    for label, section in (("node", node), ("chromium", chromium)):
        arts = section.get("artifacts", {})
        need(sorted(arts.keys()) == sorted(ARCHS), "%s artifacts must cover %s" % (label, ", ".join(ARCHS)))
        for arch, a in arts.items():
            url = a.get("url", "")
            u = urllib.parse.urlparse(url)
            need(u.scheme == "https" and u.hostname in hosts and ".." not in u.path.split("/"),
                 "%s/%s url not https on an allowed host" % (label, arch))
            need(bool(HEX64.match(str(a.get("sha256", "")))), "%s/%s sha256 malformed" % (label, arch))
            for k in ("size", "expandedBytes", "entryCount", "maxEntryBytes"):
                need(isinstance(a.get(k), int) and a[k] > 0, "%s/%s %s missing" % (label, arch, k))
            need(a.get("format") == ("tar.gz" if label == "node" else "zip"), "%s/%s format wrong" % (label, arch))
        if label == "chromium":
            for arch, a in arts.items():
                need(bool(a.get("executable")) and ".." not in a["executable"].split("/") and not a["executable"].startswith("/"),
                     "chromium/%s executable path missing or unsafe" % arch)
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
        for arch, a in pins["node"]["artifacts"].items():
            fname = a["url"].rsplit("/", 1)[1]
            line = [l for l in sums.splitlines() if l.endswith("  " + fname)]
            if not line or line[0].split()[0] != a["sha256"]:
                problems.append("node %s digest differs from nodejs.org SHASUMS256.txt" % arch)
        for label in ("node", "chromium"):
            for arch, a in pins[label]["artifacts"].items():
                dest = os.path.join(work, "%s-%s" % (label, arch))
                try:
                    n, h = download(a["url"], dest, allowed, budget)
                except (PinError, urllib.error.URLError, OSError) as e:
                    problems.append("%s %s: download failed (%s)" % (label, arch, e.__class__.__name__))
                    continue
                if n != a["size"] or h != a["sha256"]:
                    problems.append("%s %s: upstream bytes differ from the pin" % (label, arch))
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
    for arch in ARCHS:
        fname = "node-v%s-darwin-%s.tar.gz" % (nv, NODE_ARCH[arch])
        url = "https://%s/dist/v%s/%s" % (NODE_HOST, nv, fname)
        dest = os.path.join(work, fname)
        size, digest = download(url, dest, node_allowed, budget)
        line = [l for l in sums.splitlines() if l.endswith("  " + fname)]
        if not line or line[0].split()[0] != digest:
            raise PinError("%s does not match nodejs.org SHASUMS256.txt" % fname)
        info = inspect_tar_gz(dest)
        node_arts[arch] = {"url": url, "format": "tar.gz", "size": size, "sha256": digest, "stripComponents": 1,
                           "expandedBytes": info["expandedBytes"], "entryCount": info["entryCount"],
                           "maxEntryBytes": info["maxEntryBytes"]}
    # npm lockfile with the downloaded Node's own npm (no system Node needed).
    host_arch = "arm64" if os.uname().machine == "arm64" else "x86_64"
    node_root = os.path.join(work, "node-host")
    extract_tar_gz_for_generate(os.path.join(work, "node-v%s-darwin-%s.tar.gz" % (nv, NODE_ARCH[host_arch])), node_root)
    node_dir = os.path.join(node_root, "node-v%s-darwin-%s" % (nv, NODE_ARCH[host_arch]))
    node_bin = os.path.join(node_dir, "bin", "node")
    npm_cli = os.path.join(node_dir, "lib", "node_modules", "npm", "bin", "npm-cli.js")
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
    cr_allowed = {CFT_HOST}
    cr_arts = {}
    released = None
    for arch in ARCHS:
        url = "%s/%s/%s/chrome-%s.zip" % (CFT_BASE, bver, CFT_ARCH[arch], CFT_ARCH[arch])
        dest = os.path.join(work, "chromium-%s.zip" % arch)
        size, digest = download(url, dest, cr_allowed, budget)
        info = inspect_zip(dest)
        if len(info["executables"]) != 1 or not info["executables"][0].startswith("chrome-%s/%s/" % (CFT_ARCH[arch], CHROMIUM_APP)):
            raise PinError("chromium zip has no unique executable")
        lm = http_head(url, cr_allowed).get("last-modified")
        if lm:
            import email.utils
            day = time.strftime("%Y-%m-%d", email.utils.parsedate(lm))
            released = min(released, day) if released else day
        cr_arts[arch] = {"url": url, "format": "zip", "size": size, "sha256": digest, "stripComponents": 0,
                         "expandedBytes": info["expandedBytes"], "entryCount": info["entryCount"],
                         "maxEntryBytes": info["maxEntryBytes"], "executable": info["executables"][0]}
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
        "schema": 1,
        "id": "mcp%s-node%s-cr%s-%s" % (mv, nv, rev, lock_sha[:8]),
        "mcp": {"package": "@playwright/mcp", "version": mv, "playwrightCoreVersion": core["version"],
                "packageJsonSHA256": sha256_bytes(package_bytes), "lockfileSHA256": lock_sha,
                "npmDownloadBytes": dl, "npmInstalledBytes": unpacked, "npmPackageCount": count},
        "node": {"version": nv, "teamIdentifier": args.node_team_id, "artifacts": node_arts},
        "chromium": {"revision": rev, "browserVersion": bver, "releasedAt": released or "1970-01-01",
                     "host": CFT_HOST, "artifacts": cr_arts},
        "hosts": [NODE_HOST, REGISTRY_HOST, CFT_HOST],
        "staleAfterDays": 180,
        "freeDiskFactor": 3,
    }
    out = args.out or PINS_DIR
    os.makedirs(out, exist_ok=True)
    pp, kp, lp = pins_paths(out)
    old = read_json(pp) if os.path.isfile(pp) else None
    with open(pp, "w", newline="\n") as f:
        f.write(dump_pins(pins))
    with open(kp, "wb") as f:
        f.write(package_bytes)
    with open(lp, "wb") as f:
        f.write(lock_bytes)
    write_swift(out, args.swift_out)
    print_summary(old, pins)


def print_summary(old, new):
    def line(k, a, b):
        print("  %-22s %s -> %s" % (k, a if a is not None else "-", b) if a != b else "  %-22s %s (unchanged)" % (k, b))
    print("pins written: id %s" % new["id"])
    line("@playwright/mcp", old and old["mcp"]["version"], new["mcp"]["version"])
    line("playwright-core", old and old["mcp"]["playwrightCoreVersion"], new["mcp"]["playwrightCoreVersion"])
    line("node", old and old["node"]["version"], new["node"]["version"])
    line("chromium", old and old["chromium"]["browserVersion"], new["chromium"]["browserVersion"])
    for label in ("node", "chromium"):
        for arch, a in new[label]["artifacts"].items():
            print("  %s %-6s %12d bytes  sha256 %s" % (label, arch, a["size"], a["sha256"]))


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
