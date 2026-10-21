#!/usr/bin/env python3
"""Interleaved A/B runner for mem3 benchmarks on a noisy host.

Why this exists: on a machine with a load average of 40+ a number taken once,
or taken for A and then for B, mostly measures what else was running. This
runs the baseline binary (A) and the candidate binary (B) alternately, round
after round, so both sides see the same background load on average, and it
reports the median and the range of every metric — not the best run.

    scripts/hnsw_ab.py --a /tmp/base/zig-out/bin --b zig-out/bin \
        --rounds 5 -- mem3-bench hnsw-build --vectors=10000

Everything after `--` is the command; its first word is looked up in each
side's bin directory. It is wrapped in `/usr/bin/time -l` (the README's
RSS method, not the in-process `ru_maxrss`). Reported per side:

  wall_s, user_s       from `/usr/bin/time -l`; user CPU is much less
                       sensitive to load than wall time and is the number to
                       compare, though cache and SMT contention still leak in
  max_rss_mb           "maximum resident set size" (bytes on macOS)
  json:<key>           any top-level numeric key of the command's JSON stdout
                       (`--json-keys build_seconds,peak_rss_kb`)

The order within a round alternates (ABAB..., BABA..., ...) so neither side
always runs first. Raw per-run values are printed so nothing is hidden by the
summary. Scratch output goes to a pid-scoped directory under /tmp.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile


def run_once(exe_dir, cmd, json_keys):
    argv = ["/usr/bin/time", "-l", os.path.join(exe_dir, cmd[0])] + cmd[1:]
    p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-2000:])
        raise SystemExit(f"command failed in {exe_dir}: rc={p.returncode}")
    out = {}
    m = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", p.stderr)
    if m:
        out["wall_s"] = float(m.group(1))
        out["user_s"] = float(m.group(2))
    m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
    if m:
        out["max_rss_mb"] = int(m.group(1)) / (1024 * 1024)
    if json_keys:
        try:
            doc = json.loads(p.stdout)
        except json.JSONDecodeError:
            doc = {}
        for k in json_keys:
            v = doc
            for part in k.split("."):
                v = v.get(part) if isinstance(v, dict) else None
            if isinstance(v, (int, float)):
                out["json:" + k] = float(v)
    return out


def fmt(xs):
    return f"median {statistics.median(xs):9.3f}  min {min(xs):9.3f}  max {max(xs):9.3f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--a", required=True, help="bin dir of the baseline build")
    ap.add_argument("--b", required=True, help="bin dir of the candidate build")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--json-keys", default="", help="comma list of numeric JSON keys to collect")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
    if not cmd:
        ap.error("no command given")
    keys = [k for k in args.json_keys.split(",") if k]

    # Pid-scoped scratch: commands that write files get a private cwd.
    scratch = tempfile.mkdtemp(prefix=f"mem3-hnsw-ab-{os.getpid()}-")
    os.chdir(scratch)

    res = {"A": [], "B": []}
    sides = {"A": os.path.abspath(args.a) if not os.path.isabs(args.a) else args.a,
             "B": os.path.abspath(args.b) if not os.path.isabs(args.b) else args.b}
    for r in range(args.rounds):
        order = ["A", "B"] if r % 2 == 0 else ["B", "A"]
        for s in order:
            one = run_once(sides[s], cmd, keys)
            res[s].append(one)
            print(f"round {r + 1} {s}: " + "  ".join(f"{k}={v:.3f}" for k, v in one.items()), flush=True)

    metrics = sorted({k for s in res.values() for one in s for k in one})
    print("\nsummary over", args.rounds, "interleaved rounds")
    for k in metrics:
        a = [o[k] for o in res["A"] if k in o]
        b = [o[k] for o in res["B"] if k in o]
        if not a or not b:
            continue
        ratio = statistics.median(b) / statistics.median(a)
        per_round = [y / x for x, y in zip(a, b) if x]
        print(f"{k}:")
        print(f"  A  {fmt(a)}")
        print(f"  B  {fmt(b)}")
        print(f"  B/A of medians {ratio:.3f}   per-round B/A: " + " ".join(f"{x:.3f}" for x in per_round))
    try:
        os.rmdir(scratch)
    except OSError:
        pass


if __name__ == "__main__":
    main()
