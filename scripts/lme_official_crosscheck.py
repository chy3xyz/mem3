#!/usr/bin/env python3
"""Re-score a `mem3-bench longmemeval-official --dump-rankings=...` file with
the OFFICIAL LongMemEval `eval_utils.py`, and compare with the harness's own
JSON summary.

The Zig harness transcribes the official metric functions. A transcription is
only as good as its check, so this script recomputes every per-question metric
with the original Python and fails loudly on any disagreement.

Usage:
  python3 scripts/lme_official_crosscheck.py \
      --eval-utils /tmp/mem3_lme_data/src__retrieval__eval_utils.py \
      --rankings   /tmp/mem3_lme_data/rank_s_session_hybrid.jsonl \
      --summary    /tmp/mem3_lme_data/s_session_hybrid.json

`--eval-utils` is a copy of
https://raw.githubusercontent.com/xiaowu0162/LongMemEval/main/src/retrieval/eval_utils.py
(not vendored here: it is someone else's code, fetch it yourself). It needs
numpy; numpy >= 2 removed `np.asfarray`, which that file calls, so a shim is
installed below. The shim is the documented replacement and does not change
the arithmetic.
"""
import argparse
import importlib.util
import json
import sys
from collections import defaultdict

import numpy as np

if not hasattr(np, "asfarray"):  # numpy >= 2.0
    np.asfarray = lambda a, dtype=float: np.asarray(a, dtype=dtype)

KS = [1, 3, 5, 10, 30, 50]
TOL = 1e-6


def load_eval_utils(path):
    spec = importlib.util.spec_from_file_location("eval_utils", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval-utils", required=True)
    ap.add_argument("--rankings", required=True)
    ap.add_argument("--summary", required=True)
    args = ap.parse_args()

    eu = load_eval_utils(args.eval_utils)
    summary = json.load(open(args.summary))
    gran = summary["config"]["granularity"]

    prim = defaultdict(list)     # (qtype, name@k) -> [values]
    derived = defaultdict(list)
    n = 0
    for line in open(args.rankings):
        e = json.loads(line)
        ids = e["corpus_ids"]
        ranking = e["ranking"]
        # Official: correct_docs = list(set(ids containing "answer")).
        correct = list(set(i for i in ids if "answer" in i))
        # The official script ranks the whole corpus; mem3 may return fewer
        # docs. Unreturned docs are simply absent, which is what the Zig side
        # does too (a short ranking is not padded).
        for k in KS:
            a, b, c = eu.evaluate_retrieval(ranking, correct, ids, k=k)
            for name, v in (("recall_any", a), ("recall_all", b), ("ndcg", c)):
                prim[(e["question_type"], f"{name}@{k}")].append(v)
                prim[("overall", f"{name}@{k}")].append(v)
            if gran == "turn":
                a, b, c = eu.evaluate_retrieval_turn2session(ranking, correct, ids, k=k)
                for name, v in (("recall_any", a), ("recall_all", b), ("ndcg", c)):
                    derived[(e["question_type"], f"{name}@{k}")].append(v)
                    derived[("overall", f"{name}@{k}")].append(v)
        n += 1

    def compare(label, py, zig_level):
        worst = 0.0
        checked = 0
        for (qtype, key), vals in py.items():
            name, k = key.split("@")
            grp = (zig_level["overall"] if qtype == "overall"
                   else zig_level["by_question_type"][qtype])
            zig_v = grp["metrics"][name][f"@{k}"]
            py_v = float(np.mean(vals))
            d = abs(zig_v - py_v)
            worst = max(worst, d)
            checked += 1
            if d > TOL:
                print(f"MISMATCH {label} {qtype} {key}: zig={zig_v:.9f} official={py_v:.9f}")
                sys.exit(1)
        print(f"{label}: {checked} aggregates match the official eval_utils "
              f"(max abs diff {worst:.2e}, tol {TOL:g}) over {n} questions")

    compare(gran, prim, summary["results"]["primary"])
    if gran == "turn":
        compare("session_from_turn", derived, summary["results"]["session_from_turn"])


if __name__ == "__main__":
    main()
