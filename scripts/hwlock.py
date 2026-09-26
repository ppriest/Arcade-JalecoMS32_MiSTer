#!/usr/bin/env python3
"""Keep JTAG and Quartus off this machine at the same time, and give JTAG priority.

Shared by every MiSTer core on this PC -- one USB-Blaster, one Quartus, and
markers outside any of the repos so all of them see each other.

Running a JTAG session (read_issp.tcl, a memory dump) while a Quartus
compile is in flight has bugchecked this PC (0x139, KERNEL_SECURITY_CHECK_FAILURE)
three times. Enforced here rather than remembered. Three rules:

  * a JTAG tool refuses to start while Quartus OR ModelSim is running;
  * a build, or a simulation, refuses to start while a JTAG tool holds the
    marker;
  * **a build or simulation refuses to start while a JTAG tool is WAITING**,
    even though the build itself would be legal. Without this, a JTAG session
    can wait indefinitely on a machine that always has one more compile
    starting: each build is individually fine and the probe read never runs.
    A waiting session publishes a reservation, new builds stand off, the
    in-flight ones finish, and the probe goes first.

Quartus and ModelSim are NOT a hazard to each other: builds and simulations
may run side by side, and several of either at once.

The markers are files rather than lock objects because the JTAG side is a
mix of Python and quartus_stp Tcl, and a file is the only thing both can
agree on. Each carries the pid and what the session was for, and a stale one
(whose pid is gone) is cleared automatically -- a crashed tool must not
wedge every later build.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# MACHINE-WIDE, not per-repo: every core on this PC shares one USB-Blaster
# and one Quartus install, and the bugcheck does not care which repo started
# which half. Do not make these paths per-repo and do not move them under
# build/; the point is that every copy of this file names the same files.
_BASE = Path(os.environ.get("LOCALAPPDATA") or Path.home())
MARKER = _BASE / "mister_jtag_running"
# One reservation per waiting session, so several may queue without racing on
# a single file: mister_jtag_wanted.<pid>
WANT_GLOB = "mister_jtag_wanted.*"


def _want_path(pid=None):
    return _BASE / ("mister_jtag_wanted.%d" % (pid if pid is not None else os.getpid()))


def quartus_processes():
    """Names of running Quartus AND ModelSim processes, empty if none.

    Both are a hazard to a concurrent JTAG session; they are not a hazard
    to each other, and several builds or simulations may run side by side.
    """
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-Process quartus*,vsim*,vlog,vcom,vlib -ErrorAction SilentlyContinue | "
             "Select-Object -ExpandProperty ProcessName"],
            capture_output=True, text=True, timeout=30)
        return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    except Exception:
        # If the check itself cannot run, do not block the tool -- an
        # unavailable guard is not a reason to stop working.
        return []


def _pid_alive(pid):
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "if (Get-Process -Id %d -ErrorAction SilentlyContinue) "
             "{ 'yes' } else { 'no' }" % pid],
            capture_output=True, text=True, timeout=30)
        return r.stdout.strip() == "yes"
    except Exception:
        return False


def read_marker():
    """(pid, what) if a live JTAG session holds the marker, else None.

    A marker whose process has gone is stale and is removed here.
    """
    if not MARKER.exists():
        return None
    try:
        pid_s, what = MARKER.read_text(encoding="utf-8").split("\n", 1)
        pid = int(pid_s.strip())
    except Exception:
        MARKER.unlink(missing_ok=True)
        return None
    if not _pid_alive(pid):
        MARKER.unlink(missing_ok=True)
        return None
    return pid, what.strip()


def waiting_sessions():
    """[(pid, what)] for JTAG sessions queued for the Blaster, stale ones removed."""
    out = []
    for p in sorted(_BASE.glob(WANT_GLOB)):
        try:
            pid = int(p.name.rsplit(".", 1)[1])
            what = p.read_text(encoding="utf-8").strip()
        except Exception:
            p.unlink(missing_ok=True)
            continue
        if _pid_alive(pid):
            out.append((pid, what))
        else:
            p.unlink(missing_ok=True)
    return out


def reserve_jtag(what="this JTAG session"):
    """Publish that a JTAG session is waiting: new builds stand off from here."""
    _BASE.mkdir(parents=True, exist_ok=True)
    _want_path().write_text("%s: %s, waiting since %s"
                            % (REPO.name, what, time.strftime("%H:%M:%S")), encoding="utf-8")


def release_reservation():
    _want_path().unlink(missing_ok=True)


def require_no_quartus(what="this JTAG session"):
    """Refuse to run a JTAG tool while Quartus is compiling."""
    procs = quartus_processes()
    if procs:
        sys.exit(
            "REFUSING %s: Quartus/ModelSim is running (%s).\n"
            "JTAG concurrent with either has bugchecked this PC (0x139). "
            "Wait for it (--wait), or stop it deliberately."
            % (what, ", ".join(sorted(set(procs)))))


def wait_for_quartus(what="this JTAG session", timeout=3600, poll=10, log=print):
    """Reserve the Blaster, then wait for in-flight Quartus/ModelSim to finish.

    The reservation is what makes this terminate: while it stands, no NEW build
    or simulation may start, so the set of processes to wait for only shrinks.
    """
    reserve_jtag(what)
    deadline = time.time() + timeout
    announced = False
    while True:
        procs = sorted(set(quartus_processes()))
        if not procs:
            return True
        if not announced:
            log("waiting for %s to finish before %s; new builds are blocked "
                "while this reservation stands" % (", ".join(procs), what))
            announced = True
        if time.time() > deadline:
            release_reservation()
            sys.exit("REFUSING %s: %s still running after %d s. Reservation dropped so "
                     "builds can proceed; try again later." % (what, ", ".join(procs), timeout))
        time.sleep(poll)


def require_no_jtag(what="this build"):
    """Refuse to start a build while a JTAG tool holds the marker OR is waiting."""
    held = read_marker()
    if held:
        pid, why = held
        sys.exit(
            "REFUSING %s: a JTAG session is running (pid %d, %s).\n"
            "JTAG concurrent with a compile has bugchecked this PC three "
            "times (0x139). Wait for it, or kill it deliberately and delete\n"
            "  %s" % (what, pid, why, MARKER))
    queued = waiting_sessions()
    if queued:
        lines = "\n".join("  pid %d: %s" % (p, w) for p, w in queued)
        sys.exit(
            "REFUSING %s: a JTAG session is WAITING for the Blaster:\n%s\n"
            "JTAG has priority: a probe read cannot get in edgeways on a machine that "
            "always has one more compile starting. Let it take the Blaster first; it "
            "releases as soon as it is done. Its reservation is in\n"
            "  %s" % (what, lines, _BASE / WANT_GLOB))


if __name__ == "__main__":
    # command-line forms for shell scripts
    if len(sys.argv) >= 2 and sys.argv[1] == "--require-no-jtag":
        require_no_jtag(sys.argv[2] if len(sys.argv) > 2 else "this build")
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--status":
        held = read_marker()
        print("jtag holder :", "%d (%s)" % held if held else "none")
        for pid, what in waiting_sessions():
            print("jtag waiting:", pid, what)
        procs = sorted(set(quartus_processes()))
        print("quartus/msim:", ", ".join(procs) if procs else "none")
        sys.exit(0)


class jtag_session:
    """Context manager: reserve, guard, take the marker, release on the way out.

    wait=True (the default) reserves the Blaster and waits for an in-flight
    build or simulation instead of refusing; the reservation stops new ones
    starting. wait=False keeps the old behaviour: refuse immediately.
    """

    def __init__(self, what="jtag", wait=True, timeout=3600):
        self.what = what
        self.wait = wait
        self.timeout = timeout

    def __enter__(self):
        if self.wait:
            wait_for_quartus(self.what, timeout=self.timeout)
        else:
            require_no_quartus(self.what)
        MARKER.parent.mkdir(parents=True, exist_ok=True)
        MARKER.write_text("%d\n%s at %s\n"
                          % (os.getpid(), REPO.name + ": " + self.what, time.strftime("%H:%M:%S")),
                          encoding="utf-8")
        release_reservation()      # holding the marker supersedes the reservation
        return self

    def __exit__(self, *exc):
        MARKER.unlink(missing_ok=True)
        release_reservation()
        return False
