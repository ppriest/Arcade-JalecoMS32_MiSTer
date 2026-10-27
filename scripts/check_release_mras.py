#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Refuse a push whose published .mra files would break on the published cores.

    python scripts/check_release_mras.py                    # HEAD against its upstream
    python scripts/check_release_mras.py --base origin/master --head HEAD
    (run by scripts/hooks/pre-push for every ref pushed; installed with
     git config core.hooksPath scripts/hooks)

WHY
---
The Downloader database publishes whatever is pushed in releases/ (not
unsupported/ or _dev/). An .mra that adds control bytes (a mod byte, a
board-config byte, a padded button slot) shifts the bytes an older core reads,
and an .mra whose <rbf> names an unreleased core does not load.

Checked on the trees being pushed, not on the working tree, for every .mra under
releases/ and releases/_alternatives/ (releases/_dev/ and unsupported/ are not
published and are skipped):

  1. RELEASED CORE. The .mra's <rbf>NAME</rbf> has a released bitstream in the
     same tree: releases/Arcade-NAME_YYYYMMDD.rbf (or releases/NAME_YYYYMMDD.rbf).
  2. LAYOUT NEEDS A NEW CORE. If the part of an .mra that the core depends on
     changed against what is already pushed -- the <rom> structure (index,
     address, interleave, part offsets/lengths/repeats/maps/CRCs, inline bytes,
     patches), the bits of a DIP that exists in both, or the number of button
     slots -- the push
     must also add a new releases/*NAME_*.rbf. Names, comments, zip names,
     descriptions, DIP labels and defaults do not count.

An .mra new to the published tree passes check 2 (a new game or alternative on a
released core), but must still pass check 1. Bypassing with `git push
--no-verify` defeats the point; fix the push instead: move the .mra to
releases/_dev/ until its core is released, or release the core with it.
"""
import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

PUBLISHED = re.compile(r"^releases/(?!_dev/)(?:_alternatives/.*/)?[^/]+\.mra$|^releases/_alternatives/[^/]+\.mra$")
RBF = re.compile(r"^releases/(?:Arcade-)?(.+)_(\d{8})\.rbf$")
ZERO = "0" * 40


def git(*args, ok=False):
    r = subprocess.run(["git", *args], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode and not ok:
        sys.exit(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout if r.returncode == 0 else None


_TREES = {}


def tree(rev):
    """{path: blob id} under releases/ at rev. Blob ids, not `git show rev:path`, which
    fails on Windows with "Filename too long" for long paths; -z avoids path quoting."""
    if not rev:
        return {}
    if rev not in _TREES:
        out = subprocess.run(["git", "ls-tree", "-r", "-z", rev, "--", "releases"],
                             capture_output=True).stdout.decode("utf-8", "replace")
        t = {}
        for rec in out.split("\0"):
            if "\t" in rec:
                meta, path = rec.split("\t", 1)
                t[path] = meta.split()[2]
        _TREES[rev] = t
    return _TREES[rev]


def tree_files(rev):
    return list(tree(rev))


def show(rev, path):
    blob = tree(rev).get(path)
    if not blob:
        return None
    r = subprocess.run(["git", "cat-file", "blob", blob], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def parse(blob):
    if blob is None:
        return None
    try:
        return ET.fromstring(blob)
    except ET.ParseError:
        return None


def rbf_name(root):
    """<rbf>, without the Arcade- prefix MiSTer also accepts (<rbf>Arcade-X</rbf> loads Arcade-X_*.rbf)."""
    name = (root.findtext("rbf") or "").strip()
    return name[len("Arcade-"):] if name.startswith("Arcade-") else name


def layout(root):
    """What the core depends on: (ROM structure, button-slot count, DIP name -> bits)."""
    roms = []
    for rom in root.iter("rom"):
        roms.append("rom " + " ".join(f"{k}={rom.get(k)}" for k in ("index", "address", "type") if rom.get(k)))
        for el in rom.iter():
            if el is rom:
                continue
            attrs = {k: v.lower() for k, v in el.attrib.items() if k not in ("name", "zip", "md5")}
            text = " ".join((el.text or "").split()).lower() if el.tag in ("part", "patch") else ""
            roms.append(f"  {el.tag} {sorted(attrs.items())} {text}")
    buttons = [len([x for x in (b.get("names") or "").split(",") if x != ""]) for b in root.iter("buttons")]
    sw = root.find("switches")
    dips = {} if sw is None else {d.get("name"): d.get("bits") for d in sw.findall("dip")}
    return "\n".join(roms), buttons, (sw.get("base") if sw is not None else None), dips


def layout_change(old, new):
    """Why the new .mra needs a different core than the old one, or None.

    A DIP added, removed or relabelled does not; the same DIP on different bits does."""
    (r0, b0, s0, d0), (r1, b1, s1, d1) = layout(old), layout(new)
    if r0 != r1:
        return "the ROM layout changed"
    if b0 != b1:
        return "the number of button slots changed (Start/Coin move)"
    if s0 != s1:
        return "the DIP base changed"
    moved = [n for n in d0.keys() & d1.keys() if d0[n] != d1[n]]
    if moved:
        return "DIP %s moved to other bits" % ", ".join(f"'{n}'" for n in sorted(moved))
    return None


def released(files):
    names = {}
    for f in files:
        m = RBF.match(f)
        if m:
            names.setdefault(m.group(1), set()).add(f)
    return names


def check(base, head):
    head_files = tree_files(head)
    base_files = set(tree_files(base))
    rel_head = released(head_files)
    rel_base = released(base_files)
    added_rbf = {n for n, fs in rel_head.items() if fs - rel_base.get(n, set())}
    problems = []
    for path in head_files:
        if not PUBLISHED.match(path):
            continue
        root = parse(show(head, path))
        if root is None:
            problems.append(f"{path}: not well-formed XML")
            continue
        name = rbf_name(root)
        if not name:
            problems.append(f"{path}: no <rbf>")
            continue
        if name not in rel_head:
            problems.append(f"{path}: <rbf>{name}</rbf> has no released bitstream "
                            f"(releases/Arcade-{name}_YYYYMMDD.rbf) in this push. Release the core "
                            f"with it, or keep the .mra in releases/_dev/ until then.")
            continue
        if path not in base_files:
            continue
        old = parse(show(base, path))
        why = layout_change(old, root) if old is not None else None
        if why and name not in added_rbf:
            problems.append(f"{path}: {why}, but this push adds no new releases/Arcade-{name}_*.rbf. "
                            f"The released core reads the old layout; release the core that matches "
                            f"in the same push.")
    return problems


def upstream_of(head):
    up = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", ok=True)
    if up:
        return git("rev-parse", up.strip()).strip()
    for cand in ("origin/master", "origin/main"):
        r = git("rev-parse", "--verify", "-q", cand, ok=True)
        if r:
            return r.strip()
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="what is already published (default: the upstream)")
    ap.add_argument("--head", default="HEAD", help="what is being pushed (default: HEAD)")
    ap.add_argument("--pre-push", action="store_true", help="read git's pre-push lines from stdin")
    a = ap.parse_args()

    jobs = []
    if a.pre_push:
        for line in sys.stdin:
            f = line.split()
            if len(f) != 4 or f[1] == ZERO:
                continue                                   # malformed, or a branch deletion
            local, remote = f[1], f[3]
            if remote == ZERO:                             # new remote branch: compare with its fork point
                fork = upstream_of(local)
                remote = git("merge-base", fork, local).strip() if fork else None
            jobs.append((f[2], remote, local))
    else:
        base = a.base or upstream_of(a.head)
        base = git("rev-parse", "--verify", "-q", base, ok=True) if base else None
        jobs.append((a.head, base.strip() if base else None, git("rev-parse", a.head).strip()))

    failed = False
    for ref, base, head in jobs:
        problems = check(base, head)
        if problems:
            failed = True
            print(f"check_release_mras: {ref} would publish broken .mra files:", file=sys.stderr)
            for p in problems:
                print("  " + p, file=sys.stderr)
    if failed:
        print("Push refused. Nothing was sent.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
