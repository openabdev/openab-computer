#!/usr/bin/env bash
# Release smoke for the Linux managed browser tier (docs/requirements/linux-browser-tier.md,
# section 3.3, and docs/releasing.md "Linux release gates"). One cell of the matrix runs this once.
#
#   release-smoke-linux.sh --bin BIN --harness TESTBIN        real cell: user manager required
#   release-smoke-linux.sh --bin BIN --container              Debian 12 container job, as the user
#   release-smoke-linux.sh --bin BIN --in-container           container entry, as root (see below)
#
# BIN       the release-profile oab-computer binary.
# TESTBIN   the `cargo test --release --no-run` binary of poc/reverse-attach-linux, which holds the
#           ignored end-to-end harness (`e2e_daemon_harness`, OAB_L2_E2E=1).
#
# A real cell does, in a temporary HOME under /tmp: browser plan, preflight, a real `browser install`
# (which runs the headless health check), the harness as the main process of a transient unit named
# oab-l5-test-harness-<pid> (the production Supervisor, Systemd containment, tools/list, navigate,
# snapshot), `browser status --json` while the tree runs, `kill -9` of the harness, and a survivor
# check on the install directory. Nothing outside the temporary HOME and that unit is touched; the
# unit is stopped on exit.
#
# Output: one `GATE <id> pass|fail|info ...` line per gate, so the per-release record can quote them.
# The exit status is the first failing gate's code (below); every gate still runs and prints.
#   12 install (the pinned source, install and the headless health check)
#   13 no systemd user manager (a real cell FAILS without one, section 3.3)
#   14 the harness never became ready
#   20 V2  a TCP or UDP listener, a Unix listener outside the private TMPDIR, a TMPDIR that is not
#          0700 or not the daemon's, or listeners that cannot be read
#   24 V4  containment is not `systemd` or `systemd+mount`
#   30 R1.3 something from the install directory survived `kill -9` of the harness
#   64 usage
# V3 (Chromium exit timing after SIGKILL) and V9, V11 are informational and never fail the cell.
#
# V2 (decided): no TCP or UDP listener, and any Unix listener must be inside the child's private
# per-run 0700 TMPDIR owned by the daemon's uid (the Playwright browser socket and Chromium's
# SingletonSocket). The gate has no other allow-list.

set -u

# ---------------------------------------------------------------- pure helpers (tested)

# json_field JSON KEY: the string value of a top-level key of the flat object `browser status --json`
# prints (fixed keys, values from a fixed vocabulary, no escapes).
json_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"
}

# list_field LISTENERS KEY: the value of `KEY=` in the `listeners` word, or empty.
list_field() {
  printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# gate_v2 STATUS_JSON: the decided V2 rule (R1.1). Passes when the managed tree holds no listener at
# all, or when it holds no TCP or UDP listener and every Unix listener is inside the child's private
# per-run TMPDIR, which `status` has checked to be a real directory of the daemon's uid with mode
# exactly 0700. The word is `tcp=N udp=N unix=N unix_outside=N tmpdir=S result=pass|fail`. This
# gate trusts no `result=` alone: it recomputes the rule from the counts, and a missing or unknown
# field fails. There is no path allow-list here; "inside" is decided by `status`.
gate_v2() {
  local l tcp udp unix out tmp res
  l=$(json_field "$1" listeners)
  if [ "$l" = none ]; then
    echo "GATE V2 pass listeners=none"
    return 0
  fi
  tcp=$(list_field "$l" tcp)
  udp=$(list_field "$l" udp)
  unix=$(list_field "$l" unix)
  out=$(list_field "$l" unix_outside)
  tmp=$(list_field "$l" tmpdir)
  # tmpdir is judged only when a Unix listener exists (unix>0); with none, a bad TMPDIR cannot hold a
  # socket, and the real cell separately requires NAVIGATE ok and SNAPSHOT_HAS_TEXT true.
  res=$(list_field "$l" result)
  local f
  for f in "$tcp" "$udp" "$unix" "$out"; do
    case "$f" in
      '' | *[!0-9]*) echo "GATE V2 fail listeners=${l:-missing}"; return 1 ;;
    esac
  done
  if [ "$tcp" = 0 ] && [ "$udp" = 0 ] && [ "$out" = 0 ] \
    && [ "$res" = pass ] && { [ "$unix" = 0 ] || [ "$tmp" = ok ]; }; then
    echo "GATE V2 pass listeners=$l"
    return 0
  fi
  echo "GATE V2 fail listeners=$l"
  return 1
}

# gate_v4 CONTAINMENT: the self-test must have reached a systemd mode (BindsTo fires, V4).
gate_v4() {
  case "$1" in
    systemd | systemd+mount)
      echo "GATE V4 pass containment=$1"
      return 0
      ;;
  esac
  echo "GATE V4 fail containment=${1:-missing}"
  return 1
}

# survivors_under DIR: the pids of this user's processes whose executable is below DIR.
survivors_under() {
  local dir=$1 p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$exe" in
      "$dir"/*) echo "${p#/proc/}" ;;
    esac
  done
}

# ---------------------------------------------------------------- the cell

# Milliseconds since the epoch (V3 is a measurement, a whole second is too coarse).
now_ms() {
  local t=${EPOCHREALTIME:-}
  if [ -n "$t" ]; then
    echo $((${t//[.,]/} / 1000))
  else
    echo $(($(date +%s) * 1000))
  fi
}

die() {
  echo "release-smoke: $*" >&2
  exit "${2:-64}"
}

first_fail=0
note_fail() { [ "$first_fail" -ne 0 ] || first_fail=$1; }

cleanup() {
  if [ -n "${UNIT:-}" ]; then
    systemctl --user stop "$UNIT.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$UNIT.service" >/dev/null 2>&1 || true
  fi
}

# Runs on exit: the transient unit, then the temporary HOME (about 900 MB with the browser) unless
# OAB_SMOKE_KEEP=1 asks to keep it for a look.
cleanup_all() {
  cleanup
  if [ -n "${TMP:-}" ] && [ "${OAB_SMOKE_KEEP:-0}" != 1 ]; then
    rm -rf "$TMP"
  fi
}

# The common part: plan, preflight, install, status. Sets BASE and INSTALL_DIR.
prepare() {
  local bin=$1
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/oab-l5-smoke.XXXXXX") || die "mktemp failed" 64
  trap cleanup_all EXIT
  export HOME="$TMP/home"
  export XDG_DATA_HOME="$HOME/.local/share"
  mkdir -p "$HOME" "$XDG_DATA_HOME"
  BASE=$XDG_DATA_HOME
  INSTALL_DIR=$BASE/oab-computer/playwright

  echo "== browser plan"
  "$bin" browser plan || true
  echo "== browser preflight"
  "$bin" browser preflight
  pre=$?
  echo "== browser install (downloads the pinned Node.js and Chromium, runs the headless health check)"
  if "$bin" browser install; then
    echo "GATE V1 pass pinned source downloaded and installed"
    echo "GATE health pass headless health check"
  else
    echo "GATE health fail install or headless health check failed"
    note_fail 12
    return 1
  fi
  # V9: the preflight's library list against what the health check then did. Informational: the
  # health check is the final test (docs/requirements/linux-browser-tier.md, V9).
  echo "GATE V9 info preflight_exit=$pre health=ok"
  return 0
}

real_cell() {
  local bin=$1 harness=$2 state log out status contain
  prepare "$bin" || return "$first_fail"

  state=$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" systemctl --user is-system-running 2>/dev/null || true)
  case "$state" in
    running | degraded) echo "user manager: $state" ;;
    *)
      echo "GATE manager fail systemctl --user is-system-running=${state:-none}"
      return 13
      ;;
  esac

  UNIT="oab-l5-test-harness-$$"
  log=$TMP/e2e.log
  : >"$log"
  echo "== harness as the main process of $UNIT.service"
  systemd-run --user --quiet --collect --unit "$UNIT" \
    -E HOME="$HOME" -E XDG_DATA_HOME="$XDG_DATA_HOME" \
    -E OAB_L2_E2E=1 -E OAB_L2_E2E_BASE="$BASE" -E OAB_L2_E2E_OUT="$log" \
    "$harness" --ignored --test-threads=1 e2e_daemon_harness || die "systemd-run failed" 14
  for _ in $(seq 1 240); do
    grep -q '^READY \|^TOOLS_LIST_FAILED ' "$log" && break
    sleep 1
  done
  grep -q '^READY ' "$log" || {
    echo "GATE harness fail never ready"
    sed 's/^/e2e.log: /' "$log"
    return 14
  }
  sed 's/^/e2e.log: /' "$log"
  # V2 is only measured with a browser running: the harness prints READY whatever the navigation did.
  if ! { grep -q '^NAVIGATE ok$' "$log" && grep -q '^SNAPSHOT_HAS_TEXT true$' "$log"; }; then
    echo "GATE harness fail no browser page was loaded (need NAVIGATE ok and SNAPSHOT_HAS_TEXT true)"
    return 14
  fi

  contain=$(sed -n 's/^CONTAINMENT //p' "$log" | head -n 1)
  gate_v4 "$contain" || note_fail 24

  # The listener self-check on the live tree: the status command reads it from /proc.
  status=$("$bin" browser status --json)
  echo "status: $status"
  gate_v2 "$status" || note_fail 20
  case "$(json_field "$status" listeners)" in
    none | "")
      echo "GATE V2 fail no listener seen in the real cell: the browser tree was not measured"
      note_fail 20
      ;;
  esac
  # V11: the mount tier's answer. `--retry` runs the containment self-test in this process, which
  # uses the production unit names, so only the CI job sets this (a throwaway runner).
  if [ "${OAB_SMOKE_STATUS_RETRY:-0}" = 1 ]; then
    out=$("$bin" browser status --json --retry)
    echo "GATE V11 info hardening_mount=$(json_field "$out" hardening_mount)"
  else
    echo "GATE V11 info hardening_mount=$(json_field "$status" hardening_mount) (no --retry in this run)"
  fi

  # R1.3 and V3: kill -9 the harness, then wait for the tree to go.
  echo "== kill -9 the harness main process"
  local t0 t1 left=1
  t0=$(now_ms)
  systemctl --user kill --kill-who=main --signal=KILL "$UNIT.service" || true
  for _ in $(seq 1 300); do
    if [ -z "$(survivors_under "$INSTALL_DIR")" ]; then
      left=0
      break
    fi
    sleep 0.2
  done
  t1=$(now_ms)
  if [ "$left" -eq 0 ]; then
    echo "GATE survivors pass nothing from the install directory remains"
  else
    echo "GATE survivors fail still running: $(survivors_under "$INSTALL_DIR" | tr '\n' ' ')"
    note_fail 30
  fi
  echo "GATE V3 info ms_until_tree_gone=$((t1 - t0)) (informational; the stop guarantee does not depend on it)"
  cleanup
  UNIT=
  left=$(systemctl --user list-units 'oab-l5-test-*' --all --no-legend 2>/dev/null | wc -l)
  echo "units left with the oab-l5-test- prefix: $left"
  return "$first_fail"
}

container_cell() {
  local bin=$1 status
  prepare "$bin" || return "$first_fail"
  status=$("$bin" browser status --json)
  echo "status: $status"
  echo "GATE V2 info not measured in a container job (no user manager, no running tree); the real cells measure it"
  echo "GATE V4 info not measured in a container job; the real cells measure it"
  return "$first_fail"
}

# As root inside the Debian 12 container: the packages a fresh image lacks, a non-root user (euid 0
# is not realistic and `browser install` does not refuse it), then the cell as that user.
in_container() {
  local bin=$1 self line
  self=$(readlink -f "$0")
  [ "$(id -u)" -eq 0 ] || die "--in-container runs as root inside the container" 64
  if ! { apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates util-linux >/dev/null; }; then
    die "apt-get failed" 12
  fi
  useradd -m smoke
  # The root actions the host-side preflight itself prints (missing libraries). The container is
  # throwaway, so running them here is the same as a person following the hint.
  runuser -u smoke -- env HOME=/home/smoke "$bin" browser preflight --root-actions >/tmp/root-actions.tsv || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "root action: ${line%%$'\t'*}"
    act=${line%%$'\t'*}
    act=${act#sudo }   # already root in the throwaway container, which has no sudo
    sh -c "$act" || echo "(that action failed; the health check decides)"
  done </tmp/root-actions.tsv
  runuser -u smoke -- env TMPDIR=/tmp bash "$self" --bin "$bin" --container
}

main() {
  local bin='' harness='' mode=''
  while [ $# -gt 0 ]; do
    case $1 in
      --bin) bin=${2:-}; shift 2 ;;
      --harness) harness=${2:-}; shift 2 ;;
      --container | --in-container) mode=${1#--}; shift ;;
      *) die "unknown argument: $1" 64 ;;
    esac
  done
  [ -x "$bin" ] || die "--bin must be an executable file" 64
  case "$mode" in
    in-container) in_container "$bin" ;;
    container) container_cell "$bin" ;;
    *)
      [ -x "$harness" ] || die "--harness must be the test binary" 64
      real_cell "$bin" "$harness"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
