#!/usr/bin/env python3
"""N-way interleaved runner: `scripts/hnsw_ab.py` for more than two variants.

`hnsw_ab.py` compares two *builds*. This compares any number of labelled
*commands* — different binaries, or one binary with different flags — which is
what a thread-count sweep or an allocator comparison needs. Same discipline:
round after round every variant runs once, in a rotating order, so each sees
the same background load on average; every run is wrapped in `/usr/bin/time -l`
and reported as it came out, with the median and the range, never the best run.

    scripts/ab_matrix.py --rounds 5 --json-keys build_seconds \\
        --run "t1=/tmp/b/mem3-bench hnsw-build --vectors=100000" \\
        --run "t4=/tmp/b/mem3-bench hnsw-build --vectors=100000 --threads=4"

Per run: wall_s, user_s, sys_s and max_rss_mb come from `/usr/bin/time -l`
(the external reading — the in-process `ru_maxrss` reads low on a host that is
compressing pages); `json:<key>` is any numeric top-level key of the command's
JSON stdout. `user_s` is total CPU across threads, so for a parallel build
`user_s / wall_s` is the parallelism actually obtained, and on a loaded host it
is the number to trust over wall time.

The host's load average is sampled before every run and printed with it, so a
reader can see which runs were taken under what. Scratch is a pid-scoped
directory under /tmp.
"""

import argparse
import json
import os
import re
import shlex
import statistics
import subprocess
import sys
import tempfile


def load1():
    try:
        return os.getloadavg()[0]
    except OSError:
        return float("nan")


def run_once(argv, json_keys):
    p = subprocess.run(["/usr/bin/time", "-l"] + argv, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-2000:])
        raise SystemExit(f"command failed: {' '.join(argv)} rc={p.returncode}")
    out = {}
    m = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", p.stderr)
    if m:
        out["wall_s"], out["user_s"], out["sys_s"] = (float(m.group(i)) for i in (1, 2, 3))
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--run", action="append", required=True, metavar="LABEL=CMD",
                    help="a labelled command (repeatable); CMD is split like a shell would")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--json-keys", default="", help="comma list of numeric JSON keys to collect")
    args = ap.parse_args()

    variants = []
    for spec in args.run:
        label, _, cmd = spec.partition("=")
        if not cmd:
            ap.error(f"--run needs LABEL=CMD, got {spec!r}")
        variants.append((label, shlex.split(cmd)))
    keys = [k for k in args.json_keys.split(",") if k]

    scratch = tempfile.mkdtemp(prefix=f"mem3-ab-matrix-{os.getpid()}-")
    os.chdir(scratch)

    res = {label: [] for label, _ in variants}
    loads = {label: [] for label, _ in variants}
    n = len(variants)
    for r in range(args.rounds):
        # Rotate the starting variant so none always runs first or last.
        order = [variants[(i + r) % n] for i in range(n)]
        for label, argv in order:
            ld = load1()
            one = run_once(argv, keys)
            res[label].append(one)
            loads[label].append(ld)
            print(f"round {r + 1} {label:>10} load1={ld:5.1f}: "
                  + "  ".join(f"{k}={v:.3f}" for k, v in one.items()), flush=True)

    metrics = sorted({k for runs in res.values() for one in runs for k in one})
    print("\nsummary over", args.rounds, "interleaved rounds (median / min / max)")
    for k in metrics:
        print(f"{k}:")
        for label, _ in variants:
            xs = [o[k] for o in res[label] if k in o]
            if xs:
                print(f"  {label:>10}  median {statistics.median(xs):10.3f}  "
                      f"min {min(xs):10.3f}  max {max(xs):10.3f}")
    for label, _ in variants:
        ls = loads[label]
        print(f"load1 at start of {label}'s runs: median {statistics.median(ls):.1f}, "
              f"min {min(ls):.1f}, max {max(ls):.1f}")
    try:
        os.rmdir(scratch)
    except OSError:
        pass


if __name__ == "__main__":
    main()
