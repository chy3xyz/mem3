#!/usr/bin/env python3
"""Turn a scripts/lme_ablation_run.sh output directory into the markdown tables
of docs/benchmarks/ablation-tri-source.md section 5.

    python3 scripts/lme_ablation_report.py RUN_DIR [--resamples N] [--jobs N] > report.md

It shells out to `mem3-bench lme-compare` (the Zig paired bootstrap, unit tested
in src/eval/paired_stats.zig) for every pre-registered comparison, and then
re-derives a handful of deltas with an independent numpy bootstrap as a cross
check on the Zig statistics (means must agree to 1e-6, CI ends to ~0.003; the
two use different RNG streams so the CIs are not expected to match exactly).
"""
import argparse
import json
import math
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("BIN", os.path.join(ROOT, "zig-out", "bin", "mem3-bench"))

SEEDS = [1, 2, 3, 4, 5]
FAM = {
    "D": [f"D_s{s}" for s in SEEDS],
    "E_filter_rand": [f"E_filter_rand_s{s}" for s in SEEDS],
    "E_boost_rand": [f"E_boost_rand_s{s}" for s in SEEDS],
    "J_D": [f"J_D_s{s}" for s in SEEDS],
}

# (n, label, variant, base, only_level)
PRIMARY = [
    (1, "B − A", "B", "A", None),
    (2, "C_form − A", "C_form", "A", None),
    (3, "C_spirit − A", "C_spirit", "A", None),
    (4, "D − A (5 seeds pooled)", "D", "A", None),
    (5, "B − D (5 seeds pooled)", "B", "D", None),
    (6, "E_filter − A", "E_filter", "A", None),
    (7, "E_boost − A", "E_boost", "A", None),
    (8, "E_filter − E_filter_rand", "E_filter", "E_filter_rand", None),
    (9, "E_boost − E_boost_rand", "E_boost", "E_boost_rand", None),
    (10, "F_on − F_off", "F_on", "F_off", None),
    (11, "F_on − A", "F_on", "A", None),
    (12, "G_heur_on − G_heur_off", "G_heur_on", "G_heur_off", None),
    (13, "H_off − A", "H_off", "A", None),
    (14, "H_edges − A", "H_edges", "A", "turn"),
    (15, "I_dense − A", "I_dense", "A", None),
    (16, "I_bm25 − A", "I_bm25", "A", None),
    (17, "J_A − A", "J_A", "A", None),
    (18, "J_B − J_A", "J_B", "J_A", None),
    (19, "J_C_spirit − J_A", "J_C_spirit", "J_A", None),
    (20, "J_B − J_D (5 seeds pooled)", "J_B", "J_D", None),
]
SANITY = [
    ("S1", "F_off − A", "F_off", "A"),
    ("S2", "G_flat − A", "G_flat", "A"),
    ("S3", "R_off − A", "R_off", "A"),
    ("S4", "A_rerun − A (noise floor)", "A_rerun", "A"),
]
METRICS = ["R_any@1", "R_any@5", "R_any@10", "NDCG@10"]


def files(run, level, name):
    names = FAM.get(name, [name])
    return [os.path.join(run, f"{level}_{n}.scores.jsonl") for n in names]


def compare(run, level, variant, base, score_level, resamples, label):
    vf, bf = files(run, level, variant), files(run, level, base)
    for p in vf + bf:
        if not os.path.exists(p):
            return None
    cmd = [BIN, "lme-compare", f"--level={score_level}", f"--resamples={resamples}", f"--label={label}"]
    cmd += [f"--base={p}" for p in bf] + [f"--variant={p}" for p in vf]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return {"error": r.stderr[-400:] + r.stdout[-400:]}
    return json.loads(r.stdout)


def verdict(m):
    lo, hi = m["ci95"]
    la, ha = m["ci_adj"]
    if lo is None:
        return "n/a"
    if lo > 0:
        return "GAIN (survives Bonferroni)" if la > 0 else "gain (does not survive Bonferroni)"
    if hi < 0:
        return "HARM (survives Bonferroni)" if ha < 0 else "harm (does not survive Bonferroni)"
    if lo > -0.01 and hi < 0.01:
        return "bounded null (CI inside ±0.01)"
    return "no detectable effect"


def f(x, d=4):
    return "—" if x is None else f"{x:+.{d}f}"


def row(n, label, res):
    if res is None:
        return f"| {n} | {label} | (missing) | | | | | | |"
    if "error" in res:
        return f"| {n} | {label} | ERROR {res['error'][:60]!r} | | | | | | |"
    o = res["groups"]["overall"]["metrics"]
    nd = o["NDCG@10"]
    cells = [f(o[m]["delta"]) for m in ("R_any@1", "R_any@5", "R_any@10")]
    return (
        f"| {n} | {label} | {f(nd['delta'])} | [{f(nd['ci95'][0])}, {f(nd['ci95'][1])}] "
        f"| [{f(nd['ci_adj'][0])}, {f(nd['ci_adj'][1])}] | {' / '.join(cells)} "
        f"| {nd['improved']}/{nd['worsened']}/{nd['same']} | {res['questions_with_identical_ranking']} | {verdict(nd)} |"
    )


HEADER = (
    "| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 "
    "| improved/worsened/same (NDCG@10) | identical rankings | verdict |\n"
    "|---|---|---|---|---|---|---|---|---|"
)


def numpy_check(run, level, variant, base):
    try:
        import numpy as np
    except ImportError:
        return None

    def load(names):
        acc = None
        for p in files(run, level, names):
            d = {}
            for line in open(p):
                if line.strip():
                    j = json.loads(line)
                    d[j["question_id"]] = j["primary"]["nd"][3]
            acc = d if acc is None else {k: acc[k] + d[k] for k in acc}
        n = len(files(run, level, names))
        return {k: v / n for k, v in acc.items()}

    a, b = load(base), load(variant)
    ids = sorted(a)
    delta = np.array([b[i] - a[i] for i in ids])
    rng = np.random.default_rng(12345)
    idx = rng.integers(0, len(delta), size=(10000, len(delta)))
    means = delta[idx].mean(axis=1)
    return float(delta.mean()), float(np.quantile(means, 0.025)), float(np.quantile(means, 0.975))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--resamples", type=int, default=10000)
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()
    run = args.run

    tasks = []
    for level in ("session", "turn"):
        for (n, label, v, b, only) in PRIMARY:
            if only and only != level:
                continue
            tasks.append((level, "primary", n, label, v, b))
        for (n, label, v, b) in SANITY:
            tasks.append((level, "primary", n, label, v, b))
    # session-derived-from-turn for the turn runs
    for (n, label, v, b, only) in PRIMARY:
        tasks.append(("turn", "derived", n, label, v, b))
    for (n, label, v, b) in SANITY:
        tasks.append(("turn", "derived", n, label, v, b))

    def work(t):
        level, sl, n, label, v, b = t
        return t, compare(run, level, v, b, sl, args.resamples, f"{level}/{sl}/{label}")

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(ex.map(work, tasks))
    by = {(t[0], t[1], t[2]): r for t, r in results}
    json.dump([{"level": t[0], "score_level": t[1], "n": t[2], "label": t[3], "result": r} for t, r in results],
              open(os.path.join(run, "compare_all.json"), "w"))

    out = []
    for level, sl, title in (
        ("session", "primary", "Session granularity (document = session)"),
        ("turn", "primary", "Turn granularity (document = user turn), turn-level metrics"),
        ("turn", "derived", "Turn granularity, session-derived metrics (max over a session's turns)"),
    ):
        out.append(f"#### {title}\n")
        out.append(HEADER)
        for (n, label, v, b, only) in PRIMARY:
            if only and only != level:
                continue
            out.append(row(n, label, by.get((level, sl, n))))
        out.append("")
        out.append("Sanity (expected exactly 0, identical rankings = 419):\n")
        out.append(HEADER)
        for (n, label, v, b) in SANITY:
            out.append(row(n, label, by.get((level, sl, n))))
        out.append("")

    # Per-type NDCG@10 for the comparisons whose overall CI is not inside the null band, exploratory.
    out.append("#### Exploratory: per-`question_type` ΔNDCG@10 (95 % CI, unadjusted)\n")
    for level, sl in (("session", "primary"), ("turn", "primary")):
        out.append(f"**{level}**\n")
        types = None
        lines = []
        for (n, label, v, b, only) in PRIMARY:
            if only and only != level:
                continue
            r = by.get((level, sl, n))
            if not r or "error" in r:
                continue
            gs = r["groups"]
            if types is None:
                types = sorted(k for k in gs if k != "overall")
            cells = []
            for t in types:
                m = gs[t]["metrics"]["NDCG@10"]
                cells.append(f"{f(m['delta'], 3)} [{f(m['ci95'][0], 3)}, {f(m['ci95'][1], 3)}]")
            lines.append(f"| {n} | {label} | " + " | ".join(cells) + " |")
        if types:
            out.append("| # | comparison | " + " | ".join(f"{t} (n={by[(level, sl, 1)]['groups'][t]['n']})" for t in types) + " |")
            out.append("|---|---|" + "---|" * len(types))
            out.extend(lines)
        out.append("")

    # Seed spread: per-seed overall NDCG@10 of each random family, and each seed's
    # difference to the reference arm it is compared with.
    def overall_nd(level, name):
        p = os.path.join(run, f"{level}_{name}.scores.jsonl")
        if not os.path.exists(p):
            return None
        v = [json.loads(l)["primary"]["nd"][3] for l in open(p) if l.strip()]
        return sum(v) / len(v)

    out.append("#### Seed-to-seed spread of the random-tag families (overall NDCG@10 per seed; Δ = seed − reference arm)\n")
    out.append("| level | family | reference | reference NDCG@10 | per-seed NDCG@10 | per-seed Δ | range of Δ |")
    out.append("|---|---|---|---|---|---|---|")
    for level in ("session", "turn"):
        for fam, ref in (("D", "A"), ("E_filter_rand", "E_filter"), ("E_boost_rand", "E_boost"), ("J_D", "J_B")):
            r0 = overall_nd(level, ref)
            vals = [overall_nd(level, n) for n in FAM[fam]]
            if r0 is None or any(v is None for v in vals):
                continue
            ds = [v - r0 for v in vals]
            out.append(
                f"| {level} | {fam} | {ref} | {r0:.4f} | " + ", ".join(f"{v:.4f}" for v in vals)
                + " | " + ", ".join(f"{d:+.4f}" for d in ds) + f" | {min(ds):+.4f} … {max(ds):+.4f} |"
            )
    out.append("")

    # Absolute values + wall times.
    out.append("#### Absolute overall values and wall time per run\n")
    out.append("| level | run | R_any@1 | R_any@5 | R_any@10 | NDCG@10 | wall s |")
    out.append("|---|---|---|---|---|---|---|")
    names = ["A", "A_rerun", "B", "C_form", "C_spirit"] + FAM["D"] + ["E_filter", "E_boost"] + FAM["E_filter_rand"] + FAM["E_boost_rand"] + [
        "F_on", "F_off", "G_flat", "R_off", "G_heur_on", "G_heur_off", "H_off", "H_edges", "I_dense", "I_bm25",
        "J_A", "J_B", "J_C_spirit"] + FAM["J_D"]
    for level in ("session", "turn"):
        for nm in names:
            p = os.path.join(run, f"{level}_{nm}.scores.jsonl")
            if not os.path.exists(p):
                continue
            ra1 = ra5 = ra10 = nd = 0.0
            cnt = 0
            for line in open(p):
                if line.strip():
                    j = json.loads(line)["primary"]
                    ra1 += j["ra"][0]; ra5 += j["ra"][2]; ra10 += j["ra"][3]; nd += j["nd"][3]
                    cnt += 1
            t = "?"
            tp = os.path.join(run, f"{level}_{nm}.time")
            if os.path.exists(tp):
                t = open(tp).read().strip()
            out.append(f"| {level} | {nm} | {ra1/cnt:.4f} | {ra5/cnt:.4f} | {ra10/cnt:.4f} | {nd/cnt:.4f} | {t} |")
    out.append("")

    # Independent numpy check.
    out.append("#### Cross-check of the Zig bootstrap with an independent numpy implementation (primary ΔNDCG@10)\n")
    out.append("| level | comparison | Zig Δ | numpy Δ | Zig CI | numpy CI |")
    out.append("|---|---|---|---|---|---|")
    ok = True
    for level in ("session", "turn"):
        for n in (1, 4, 6, 10, 13, 17):
            r = by.get((level, "primary", n))
            if not r or "error" in r:
                continue
            _, label, v, b, _ = next(p for p in PRIMARY if p[0] == n)
            chk = numpy_check(run, level, v, b)
            if chk is None:
                out.append("| (numpy not available) | | | | | |")
                break
            m = r["groups"]["overall"]["metrics"]["NDCG@10"]
            if abs(chk[0] - m["delta"]) > 1e-5:
                ok = False
            if m["ci95"][0] is not None and (abs(chk[1] - m["ci95"][0]) > 0.003 or abs(chk[2] - m["ci95"][1]) > 0.003):
                ok = False
            out.append(
                f"| {level} | {label} | {m['delta']:+.6f} | {chk[0]:+.6f} | [{m['ci95'][0]:+.5f}, {m['ci95'][1]:+.5f}] "
                f"| [{chk[1]:+.5f}, {chk[2]:+.5f}] |"
            )
    out.append("")
    out.append(f"Cross-check agreement (means 1e-5, CI ends 0.003): **{'OK' if ok else 'MISMATCH'}**\n")

    print("\n".join(out))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
