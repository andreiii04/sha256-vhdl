#!/usr/bin/env python3
"""Render selected signals of a GHDL .ghw waveform as an SVG timing diagram.

Uses ghwdump (shipped with GHDL) to read the file. Single bits are drawn as
logic traces, vectors and enumerations as bus segments with their value.

    wave_svg.py WAVE.ghw OUT.svg --from 40 --to 1400 --title "..." \
        /tb/start /tb/dut/state:wrapper_state /tb/hash_out:hash ...

Times are in ns. A signal may be given as path:label.
"""
import argparse
import html
import os
import re
import shutil
import subprocess
import sys

FS_PER_NS = 1_000_000


def find_ghwdump() -> str:
    exe = shutil.which("ghwdump")
    if exe:
        return exe
    ghdl = shutil.which("ghdl") or os.path.expanduser("~/.local/opt/ghdl/bin/ghdl")
    cand = os.path.join(os.path.dirname(ghdl), "ghwdump")
    if os.path.exists(cand):
        return cand
    sys.exit("ghwdump not found (it ships with GHDL)")


def read_hierarchy(ghwdump: str, wave: str) -> dict:
    """path -> (kind, [indices]) ; kind is 'bit', 'vec' or 'enum'."""
    out = subprocess.run([ghwdump, "-H", wave], capture_output=True, text=True).stdout
    sigs = {}
    for line in out.splitlines():
        m = re.match(r"signal (\S+): (.+): #(\d+)(?:-#(\d+))?$", line.strip())
        if not m:
            continue
        path, typ, lo, hi = m.group(1), m.group(2), int(m.group(3)), m.group(4)
        idx = list(range(lo, int(hi) + 1)) if hi else [lo]
        if hi:
            kind = "vec"
        elif typ.startswith("std_logic") or typ.startswith("std_ulogic") or typ == "bit":
            kind = "bit"
        else:
            kind = "enum"
        sigs[path.lower()] = (kind, idx)
    return sigs


def read_values(ghwdump: str, wave: str, indices: list) -> list:
    """Return [(time_fs, {index: value})] snapshots."""
    spec = ",".join(str(i) for i in sorted(set(indices)))
    proc = subprocess.Popen([ghwdump, "-s", "-f", spec, wave], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True)
    assert proc.stdout is not None  # always set with stdout=PIPE; narrows the type
    snaps, cur, t = [], None, 0
    for line in proc.stdout:
        if line.startswith("Time is "):
            if cur is not None:
                snaps.append((t, cur))
            t = int(line.split()[2])
            cur = {}
        else:
            m = re.match(r"#(\d+): '?([^' ]+)'? \(", line)
            if m and cur is not None:
                cur[int(m.group(1))] = m.group(2)
    if cur is not None:
        snaps.append((t, cur))
    proc.wait()
    return snaps


def value_of(kind: str, idx: list, snap: dict) -> str:
    if kind == "vec":
        bits = "".join(snap.get(i, "U") for i in idx)
        if set(bits) <= {"0", "1"}:
            width = (len(bits) + 3) // 4
            return f"{int(bits, 2):0{width}x}"
        return "U" if "U" in bits else "X"
    return snap.get(idx[0], "U")


def changes(kind, idx, snaps, t0, t1):
    """List of (time_fs, value) inside [t0, t1], starting with the value at t0."""
    out, last = [], None
    for t, snap in snaps:
        v = value_of(kind, idx, snap)
        if t <= t0:
            last = v
            continue
        if t > t1:
            break
        if not out:
            out.append((t0, last if last is not None else v))
        if v != out[-1][1]:
            out.append((t, v))
    if not out:
        out.append((t0, last if last is not None else "U"))
    return out


def fmt_bus(kind: str, v: str, width_px: float) -> str:
    if kind == "vec" and len(v) > 8 and v not in ("U", "X"):
        v = v[:8] + "…"
    max_chars = int(width_px / 6.5)
    if max_chars < 2:
        return ""
    return v if len(v) <= max_chars else v[: max(1, max_chars - 1)] + "…"


def render(title, rows, t0, t1, out_path):
    label_w, plot_w, row_h, top = 150, 860, 30, 44
    height = top + row_h * len(rows) + 34
    width = label_w + plot_w + 20
    x = lambda t: label_w + (t - t0) / (t1 - t0) * plot_w
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
         f'viewBox="0 0 {width} {height}" font-family="ui-monospace,Menlo,Consolas,monospace" font-size="11">',
         f'<rect width="100%" height="100%" fill="#ffffff"/>',
         f'<text x="12" y="24" font-size="14" font-weight="bold" fill="#1f2328">{html.escape(title)}</text>']
    for r, (label, kind, ch) in enumerate(rows):
        y0 = top + r * row_h
        hi, lo, mid = y0 + 6, y0 + row_h - 8, y0 + row_h / 2 - 1
        s.append(f'<text x="12" y="{mid + 4}" fill="#1f2328">{html.escape(label)}</text>')
        s.append(f'<line x1="{label_w}" y1="{y0 + row_h - 2}" x2="{label_w + plot_w}" y2="{y0 + row_h - 2}" stroke="#d0d7de" stroke-width="0.5"/>')
        segs = ch + [(t1, None)]
        if kind == "bit":
            pts = []
            for (ta, va), (tb, _) in zip(segs, segs[1:]):
                yv = hi if va == "1" else lo if va == "0" else mid
                pts += [(x(ta), yv), (x(tb), yv)]
            s.append('<polyline fill="none" stroke="#0969da" stroke-width="1.4" points="'
                     + " ".join(f"{px:.1f},{py:.1f}" for px, py in pts) + '"/>')
        else:
            for (ta, va), (tb, _) in zip(segs, segs[1:]):
                xa, xb = x(ta), x(tb)
                color = "#bf8700" if va in ("U", "X") else "#1a7f37"
                s.append(f'<path d="M{xa + 2:.1f},{hi} L{xb - 2:.1f},{hi} L{xb:.1f},{mid} L{xb - 2:.1f},{lo} '
                         f'L{xa + 2:.1f},{lo} L{xa:.1f},{mid} Z" fill="#dafbe1" fill-opacity="0.55" stroke="{color}" stroke-width="1"/>')
                txt = fmt_bus(kind, va, xb - xa - 6)
                if txt:
                    s.append(f'<text x="{(xa + xb) / 2:.1f}" y="{mid + 4}" text-anchor="middle" fill="#1f2328">{html.escape(txt)}</text>')
    # time axis
    ya = top + row_h * len(rows) + 6
    s.append(f'<line x1="{label_w}" y1="{ya}" x2="{label_w + plot_w}" y2="{ya}" stroke="#57606a"/>')
    span_ns = (t1 - t0) / FS_PER_NS
    unit, div = ("ms", 1e6) if span_ns > 2e5 else ("µs", 1e3) if span_ns > 2e3 else ("ns", 1)
    for k in range(11):
        t = t0 + (t1 - t0) * k / 10
        px = x(t)
        s.append(f'<line x1="{px:.1f}" y1="{ya}" x2="{px:.1f}" y2="{ya + 4}" stroke="#57606a"/>')
        s.append(f'<text x="{px:.1f}" y="{ya + 16}" text-anchor="middle" fill="#57606a">{t / FS_PER_NS / div:.3g} {unit}</text>')
    s.append("</svg>")
    with open(out_path, "w") as f:
        f.write("\n".join(s) + "\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("wave")
    p.add_argument("out")
    p.add_argument("--from", dest="t0", type=float, required=True, help="start time in ns")
    p.add_argument("--to", dest="t1", type=float, required=True, help="end time in ns")
    p.add_argument("--title", default="")
    p.add_argument("signals", nargs="+")
    a = p.parse_args()

    ghwdump = find_ghwdump()
    hier = read_hierarchy(ghwdump, a.wave)
    wanted = []
    for spec in a.signals:
        path, _, label = spec.partition(":")
        if path.lower() not in hier:
            sys.exit(f"signal not in waveform: {path}")
        kind, idx = hier[path.lower()]
        wanted.append((label or path.rsplit("/", 1)[-1], kind, idx))
    snaps = read_values(ghwdump, a.wave, [i for _, _, idx in wanted for i in idx])
    t0, t1 = int(a.t0 * FS_PER_NS), int(a.t1 * FS_PER_NS)
    rows = [(label, kind, changes(kind, idx, snaps, t0, t1)) for label, kind, idx in wanted]
    render(a.title, rows, t0, t1, a.out)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
