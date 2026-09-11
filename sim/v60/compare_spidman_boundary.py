#!/usr/bin/env python3
"""Compare the Spider-Man V60 boundary against a pinned MAME tap.

The focused contract is deliberately small: MAME must execute the operand
read at 0x62168 and the following write at 0x6216b, while RTL must decode
0x62168 with length three and next decode 0x6216b without visiting the known
one-byte-skew boundaries first.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


PFTRACE_RE = re.compile(r"\[pftrace\]\s+pc=(?P<pc>[0-9a-f]+)", re.IGNORECASE)
PFRETIRE_RE = re.compile(
    r"\[pfretire\]\s+pc=00062168\s+st=9\b.*\blen=1/0\b.*\bexeclen=3\b",
    re.IGNORECASE,
)
BAD_PCS = {0x6216C, 0x62172, 0x62175}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hash_directory(path: Path) -> dict[str, str]:
    return {
        item.relative_to(path).as_posix(): sha256(item)
        for item in sorted(path.rglob("*"))
        if item.is_file()
    }


def load_mame(path: Path) -> list[dict[str, object]]:
    events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    return [event for event in events if event.get("event") in {"read", "write"}]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mame", type=Path, required=True)
    parser.add_argument("--mame-exe", type=Path, required=True)
    parser.add_argument("--rtl-exe", type=Path, required=True)
    parser.add_argument("--rtl-source", type=Path, required=True)
    parser.add_argument("--rtl-build-manifest", type=Path, required=True)
    parser.add_argument("--img", type=Path, required=True)
    parser.add_argument("--desc", type=Path, required=True)
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("--rtl-log", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()

    mame_events = load_mame(args.mame)
    mame_signature = [
        (event.get("pc"), event.get("event"), event.get("addr"))
        for event in mame_events
    ]
    mame_expected = [
        ("00062168", "read", "00208740"),
        ("0006216b", "write", "00208740"),
    ]

    command = [
        str(args.rtl_exe.resolve()),
        f"+IMG={args.img.resolve().as_posix()}",
        f"+DESC={args.desc.resolve().as_posix()}",
        "+FRAMES=30",
        "+PFTRACE",
        "+STOPPF",
        "+QUIET",
    ]
    args.workdir.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        command,
        cwd=args.workdir,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=args.timeout,
        check=False,
    )
    args.rtl_log.parent.mkdir(parents=True, exist_ok=True)
    args.rtl_log.write_text(result.stdout, encoding="utf-8")

    pcs = [int(match.group("pc"), 16) for match in PFTRACE_RE.finditer(result.stdout)]
    try:
        start = pcs.index(0x62168)
        successor = pcs[start + 1]
    except (ValueError, IndexError):
        successor = None
    checks = {
        "mame_boundary": mame_signature == mame_expected,
        "rtl_exit_code": result.returncode == 0,
        "rtl_length_three": PFRETIRE_RE.search(result.stdout) is not None,
        "rtl_successor_6216b": successor == 0x6216B,
        "rtl_no_skew_boundary_before_successor": not any(
            pc in BAD_PCS for pc in pcs[start + 1 : start + 2]
        ) if 0x62168 in pcs else False,
        "rtl_no_reserved_c2": "reserved opcode c2" not in result.stdout.lower(),
    }
    receipt = {
        "schema": "s32-spidman-v60-boundary-v2",
        "passed": all(checks.values()),
        "checks": checks,
        "contract": {
            "alignment": "first exact work-RAM access at PC 0x62168",
            "last_good_pc": "0x62168",
            "expected_next_pc": "0x6216b",
            "rejected_old_path": ["0x6216c", "0x62172", "0x62175"],
            "missing_event_fatal": True,
            "resync": False,
        },
        "mame": {
            "artifact": str(args.mame.resolve()),
            "sha256": sha256(args.mame),
            "executable": str(args.mame_exe.resolve()),
            "executable_sha256": sha256(args.mame_exe),
            "events": mame_events,
        },
        "rtl": {
            "command": command,
            "exit_code": result.returncode,
            "exe_sha256": sha256(args.rtl_exe),
            "source": str(args.rtl_source.resolve()),
            "source_sha256": sha256(args.rtl_source),
            "build_manifest": str(args.rtl_build_manifest.resolve()),
            "build_manifest_sha256": sha256(args.rtl_build_manifest),
            "image_sha256": hash_directory(args.img),
            "descriptor": str(args.desc.resolve()),
            "descriptor_sha256": sha256(args.desc),
            "log": str(args.rtl_log.resolve()),
            "log_sha256": sha256(args.rtl_log),
            "boundary_pcs": [f"0x{pc:06x}" for pc in pcs if 0x6215F <= pc <= 0x62175],
            "successor": None if successor is None else f"0x{successor:06x}",
        },
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}: {name}")
    print(f"receipt: {args.json}")
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
