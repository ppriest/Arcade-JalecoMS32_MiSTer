#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Draw where a compiled core sits on the FPGA, coloured by high-level block.

    python scripts/floorplan.py                       # build/ database, groups from floorplan.json
    python scripts/floorplan.py --list --depth 3      # hierarchy with resource counts, to write the groups
    python scripts/floorplan.py --rev Name_stp --db . # an in-tree compile

Reads the post-fit netlist through `quartus_cdb -t scripts/floorplan.tcl` (read-only,
seconds, no re-fit), then paints one cell per LAB / M10K / DSP site of the die. Each
site takes the colour of the group owning most of its atoms; brightness is how full
the site is. Writes debug/floorplan/<rev>.png, <rev>_atoms.tsv and <rev>_groups.md
(per group: LUTs, FFs, MLAB, M10K, DSP, bounding box).

Groups come from scripts/floorplan.json, first match wins:

    {"groups": [
        {"name": "Main CPU",   "match": "u_core\\|u_maincpu",    "color": "#e6194b"},
        {"name": "Sprites",    "match": "u_core\\|u_sprites",    "color": "#3cb44b"},
        {"name": "Line buffers","match": "linebuf",              "color": "#ffe119"}
    ]}

`match` is a regex searched in the instance path with Quartus's `entity:` prefixes
removed (`emu|u_core|u_maincpu|...`). Atoms under `emu` that match nothing are grouped
automatically by their path to --depth; atoms outside `emu` (the MiSTer framework:
scaler, HPS bridge, audio out) are one grey "sys (framework)" group (--sys-detail splits it). Unused sites are
drawn dim in their column's kind, so empty space and the M10K and DSP columns show; the
empty block at the top right is the HPS. "LUT" counts combinational cells (two per ALM),
not ALMs, so it does not equal the fit report's ALM figure.

Needs Pillow. Quartus must not be compiling the same project (the database is read).
"""
import argparse
import colorsys
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

# Standalone (copied into cores whose scripts/ predate coretools.py): the few settings
# it needs are resolved here, the same way coretools.py does.
import os
NO_WINDOW = {"creationflags": 0x08000000} if os.name == "nt" else {}
QUARTUS_DEFAULT = r"C:\intelFPGA_lite\17.0\quartus\bin64"
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import hwlock                                                     # noqa: E402
except ImportError:
    hwlock = None


def core_root():
    root = Path(os.environ.get("CORE_ROOT") or Path(__file__).resolve().parent.parent).resolve()
    if not list(root.glob("*.qpf")):
        sys.exit(f"not a core root (no .qpf): {root}")
    return root


def project(root):
    return sorted(root.glob("*.qpf"), key=lambda p: len(p.stem))[0].stem


def revision(root, override=None):
    """--rev, CORE_REV, else the project's own revision (the release one, not _stp)."""
    return override or os.environ.get("CORE_REV") or project(root)


def _env_files(root):
    out = {}
    for f in (os.environ.get("MISTER_CORE_ENV") or Path.home() / ".mister-core.env", root / "mister.env"):
        if Path(f).exists():
            for ln in Path(f).read_text(encoding="utf-8", errors="replace").splitlines():
                if "=" in ln and not ln.lstrip().startswith("#"):
                    k, v = ln.split("=", 1)
                    out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def quartus_bin(root):
    return Path(os.environ.get("QUARTUS_BIN") or _env_files(root).get("QUARTUS_BIN") or QUARTUS_DEFAULT)

LOC_RE = re.compile(r"([A-Z0-9]+?)_X(\d+)_Y(\d+)_N(\d+)$")
SITE_KIND = {"LABCELL": "LAB", "MLABCELL": "MLAB", "FF": None, "M10K": "M10K", "DSP": "DSP"}
# Capacity per site, for the brightness: 10 ALMs = 20 LUT outputs + 40 FFs per LAB.
LAB_CAP = 20 + 40
DIM = {"LAB": (34, 36, 40), "MLAB": (40, 36, 46), "M10K": (30, 40, 58), "DSP": (58, 36, 30)}
UNPLACED = (24, 24, 26)
SMALL = 600          # LUT+FF below which an automatic group folds into "emu other"


def strip_entities(name):
    """'emu:emu|fuuki_core:u_core|x~3' -> 'emu|u_core|x~3' (instance names only)."""
    return "|".join(p.split(":", 1)[-1] for p in name.split("|"))


def inst_path(name):
    """The hierarchical instance an atom belongs to, without the atom's own name."""
    parts = strip_entities(name).split("|")
    return "|".join(parts[:-1]) if len(parts) > 1 else "sys_top"


def dump_atoms(root, db, prj, rev, out_tsv):
    if hwlock:
        hwlock.require_no_jtag("floorplan.tcl (a Quartus process)")
    tcl = Path(__file__).resolve().parent / "floorplan.tcl"
    exe = quartus_bin(root) / "quartus_cdb.exe"
    if not exe.exists():
        exe = quartus_bin(root) / "quartus_cdb"
    r = subprocess.run([str(exe), "-t", str(tcl), prj, rev, out_tsv.as_posix()],
                       cwd=db, capture_output=True, text=True, **NO_WINDOW)
    if "FLOORPLAN_OK" not in r.stdout:
        tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-15:])
        sys.exit(f"quartus_cdb did not dump the atoms (is {db} a compiled database for {rev}?)\n{tail}")


def read_atoms(tsv):
    atoms = []
    for line in tsv.read_text(encoding="utf-8", errors="replace").splitlines():
        f = line.split("\t")
        if len(f) != 3:
            continue
        typ, loc, name = f
        m = LOC_RE.match(loc)
        if not m:
            continue                      # pins, clock control, HPS interface blocks
        site = m.group(1)
        if site not in SITE_KIND:
            continue                      # IO cells, PLLs: not part of the fabric picture
        atoms.append((typ, site, int(m.group(2)), int(m.group(3)), name))
    return atoms


def resource(typ, site):
    if typ == "RAM" and site == "M10K":
        return "M10K"
    if typ == "LUTRAM":
        return "MLAB"
    if typ == "MAC":
        return "DSP"
    if typ == "FF":
        return "FF"
    if typ == "LCELL_COMB":
        return "LUT"
    return None


def load_groups(path):
    if not path.exists():
        return []
    spec = json.loads(path.read_text(encoding="utf-8"))
    return [(g["name"], re.compile(g["match"]), g.get("color")) for g in spec.get("groups", [])]


def classify(name, groups, depth, sys_detail=False):
    path = inst_path(name)
    for gname, rx, _ in groups:
        if rx.search(path):
            return gname
    parts = path.split("|")
    if parts[0] != "emu":
        return "sys/" + parts[0] if sys_detail else "sys (framework)"
    return "|".join(parts[1:1 + depth]) or "emu"


def palette(n):
    """n distinct, bright colours (golden-angle hue walk)."""
    out = []
    for i in range(n):
        h = (i * 0.61803398875) % 1.0
        r, g, b = colorsys.hsv_to_rgb(h, 0.70, 0.95)
        out.append((int(r * 255), int(g * 255), int(b * 255)))
    return out


def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def list_hierarchy(atoms, depth):
    count = defaultdict(Counter)
    for typ, site, x, y, name in atoms:
        parts = inst_path(name).split("|")
        for d in range(1, min(depth, len(parts)) + 1):
            res = resource(typ, site)
            if res:
                count["|".join(parts[:d])][res] += 1
    print(f"{'instance':60} {'LUT':>7} {'FF':>7} {'MLAB':>5} {'M10K':>5} {'DSP':>4}")
    for path in sorted(count, key=lambda p: (p.split("|")[0] != "emu", p)):
        c = count[path]
        print(f"{'  ' * (path.count('|')) + path.split('|')[-1]:60} "
              f"{c['LUT']:7} {c['FF']:7} {c['MLAB']:5} {c['M10K']:5} {c['DSP']:4}")


def render(atoms, groups, depth, out_png, title, scale, sys_detail=False):
    from PIL import Image, ImageDraw, ImageFont

    xs = [a[2] for a in atoms]
    ys = [a[3] for a in atoms]
    W, H = max(xs) + 1, max(ys) + 1

    # Column kind from what the fit placed there; a column never used reads as LAB.
    colkind = {}
    for typ, site, x, y, name in atoms:
        k = SITE_KIND[site]
        if k in ("M10K", "DSP", "MLAB") or x not in colkind:
            colkind[x] = k or colkind.get(x, "LAB")

    per_site = defaultdict(Counter)          # (x, y) -> group -> atoms
    fill = Counter()                         # (x, y) -> occupancy units
    stats = defaultdict(Counter)
    box = {}
    for typ, site, x, y, name in atoms:
        g = classify(name, groups, depth, sys_detail)
        res = resource(typ, site)
        if res:
            stats[g][res] += 1
        per_site[(x, y)][g] += 1
        fill[(x, y)] += 1
        bx = box.get(g, (x, y, x, y))
        box[g] = (min(bx[0], x), min(bx[1], y), max(bx[2], x), max(bx[3], y))

    # Automatic groups too small to see on the die fold into one entry.
    named = {n for n, _, _ in groups}
    small = [g for g in stats if g not in named and not g.startswith("sys")
             and stats[g]["LUT"] + stats[g]["FF"] < SMALL and not stats[g]["M10K"] and not stats[g]["DSP"]]
    if len(small) > 1:
        for g in small:
            stats["emu other (small)"].update(stats.pop(g))
            b, bo = box.pop(g), box.get("emu other (small)")
            box["emu other (small)"] = b if bo is None else (min(b[0], bo[0]), min(b[1], bo[1]),
                                                            max(b[2], bo[2]), max(b[3], bo[3]))
        for site in per_site.values():
            for g in small:
                if g in site:
                    site["emu other (small)"] += site.pop(g)

    order = sorted(stats, key=lambda g: (g.startswith("sys"),
                                         -(stats[g]["LUT"] + stats[g]["FF"] + 50 * stats[g]["M10K"])))
    fixed = {n: hex_rgb(c) for n, _, c in groups if c}
    auto = iter(palette(len(order)))
    colour = {}
    for g in order:
        colour[g] = fixed.get(g) or ((110, 110, 116) if g.startswith("sys") else next(auto))

    legend_w = 360
    img = Image.new("RGB", (W * scale + legend_w, max(H * scale, 40 + 18 * len(order)) + 30),
                    (16, 16, 18))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("consola.ttf", 13)
    except OSError:
        font = ImageFont.load_default()

    def cell(x, y):
        # Quartus Y grows upward (Chip Planner view); the image's grows down.
        top = (H - 1 - y) * scale + 24
        return (x * scale, top, x * scale + scale - 1, top + scale - 1)

    for x in range(W):
        for y in range(H):
            d.rectangle(cell(x, y), fill=DIM.get(colkind.get(x), UNPLACED))
    for (x, y), groups_here in per_site.items():
        g, n = groups_here.most_common(1)[0]
        kind = colkind.get(x, "LAB")
        cap = 1 if kind in ("M10K", "DSP") else LAB_CAP
        level = min(1.0, fill[(x, y)] / cap)
        k = 0.35 + 0.65 * level
        r, gg, b = colour[g]
        d.rectangle(cell(x, y), fill=(int(r * k), int(gg * k), int(b * k)))

    d.text((4, 4), title, fill=(230, 230, 230), font=font)
    lx = W * scale + 12
    d.text((lx, 4), f"{'group':22} {'LUT':>6} {'FF':>6} {'M10K':>4} {'DSP':>3}",
           fill=(200, 200, 200), font=font)
    for i, g in enumerate(order):
        yy = 24 + 18 * i
        d.rectangle((lx, yy + 2, lx + 11, yy + 13), fill=colour[g])
        s = stats[g]
        label = g if len(g) <= 20 else "…" + g[-19:]
        d.text((lx + 16, yy), f"{label:20} {s['LUT']:6} {s['FF']:6} {s['M10K']:4} {s['DSP']:3}",
               fill=(220, 220, 220), font=font)
    img.save(out_png)
    return order, stats, box


def build_tag(db, rev):
    """'fitted <date>', plus the commit when build/ last compiled this revision.

    build/ holds every revision's database, but BUILT_COMMIT names only the last
    compile, so the commit is shown only when q_staged.log says it was this one.
    """
    tag = ""
    summ = db / "output_files" / f"{rev}.fit.summary"
    if summ.exists():
        first = summ.read_text(encoding="utf-8", errors="replace").splitlines()[0]
        m = re.search(r"- \w+ (\w+ +\d+) [\d:]+ (\d{4})", first)
        if m:
            tag = f"fitted {m.group(1)} {m.group(2)}"
    log, commit = db / "q_staged.log", db / "BUILT_COMMIT"
    if log.exists() and commit.exists():
        if re.search(rf"Revision Name = {re.escape(rev)}\s*$",
                     log.read_text(encoding="utf-8", errors="replace"), re.M):
            tag = (commit.read_text(encoding="utf-8").split()[0][:10] + " " + tag).strip()
    return tag


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--rev", help="Quartus revision (default: CORE_REV, else the project's own)")
    ap.add_argument("--db", help="directory holding the compiled database (default: build/)")
    ap.add_argument("--groups", help="group file (default: scripts/floorplan.json)")
    ap.add_argument("--depth", type=int, default=2,
                    help="instance depth below emu for automatic groups (default 2)")
    ap.add_argument("--scale", type=int, default=8, help="pixels per site (default 8)")
    ap.add_argument("--sys-detail", action="store_true",
                    help="one group per framework instance instead of one grey 'sys' group")
    ap.add_argument("--list", action="store_true", help="print the hierarchy with counts, draw nothing")
    ap.add_argument("--reuse", action="store_true", help="use the last atom dump, do not run Quartus")
    a = ap.parse_args()

    root = core_root()
    rev = revision(root, a.rev)
    db = Path(a.db).resolve() if a.db else root / "build"
    out = root / "debug" / "floorplan"
    out.mkdir(parents=True, exist_ok=True)
    tsv = out / f"{rev}_atoms.tsv"
    if not (a.reuse and tsv.exists()):
        dump_atoms(root, db, project(root), rev, tsv)
    atoms = read_atoms(tsv)
    if not atoms:
        sys.exit(f"no placed fabric atoms in {tsv}")

    if a.list:
        list_hierarchy(atoms, a.depth + 1)
        return 0

    groups = load_groups(Path(a.groups) if a.groups else root / "scripts" / "floorplan.json")
    tag = build_tag(db, rev)
    png = out / f"{rev}.png"
    order, stats, box = render(atoms, groups, a.depth, png, f"{rev} {tag}".strip(), a.scale,
                               a.sys_detail)

    lines = [f"# Floorplan: {rev} {tag}".rstrip(), "",
             "| group | LUT | FF | MLAB | M10K | DSP | X | Y |", "|---|---|---|---|---|---|---|---|"]
    for g in order:
        s, b = stats[g], box[g]
        lines.append(f"| {g} | {s['LUT']} | {s['FF']} | {s['MLAB']} | {s['M10K']} | {s['DSP']} "
                     f"| {b[0]}-{b[2]} | {b[1]}-{b[3]} |")
    (out / f"{rev}_groups.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{png}\n{out / (rev + '_groups.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
