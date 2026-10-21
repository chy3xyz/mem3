#!/usr/bin/env python3
"""Reference baseline: the official repository's `flat-bm25` retriever, run
by us on the same file, scored by the official `eval_utils.py` with the same
exclusion rules. Lets mem3's retrieval numbers be read next to a baseline that
was MEASURED HERE, instead of next to numbers recalled from a paper.

It reproduces, from `src/retrieval/run_retrieval.py` (read 2026-10-21):
  * corpus construction (`process_item_flat_index`): user turns only; session
    text = user turns joined by ' '; `noans_` relabel of evidence sessions
    with no user-side has_answer turn;
  * flat-bm25: `BM25Okapi(doc.split(" "))`, `get_scores(query.split(" "))`,
    ranking = `np.argsort(scores)[::-1]` (whitespace tokens, case-sensitive,
    no stemming, no stop-word removal);
  * exclusion of `_abs` questions and of questions with no user-side target.

Requires: numpy, rank_bm25 (the official code's own dependency).

  python3 scripts/lme_official_flat_bm25_baseline.py \
      --eval-utils /tmp/mem3_lme_data/src__retrieval__eval_utils.py \
      --data /tmp/mem3_lme_data/longmemeval_s_cleaned.json \
      --granularity session            # or turn
"""
import argparse
import importlib.util
import json
import time
from collections import defaultdict

import numpy as np
from rank_bm25 import BM25Okapi

if not hasattr(np, "asfarray"):  # numpy >= 2.0 (eval_utils.py calls it)
    np.asfarray = lambda a, dtype=float: np.asarray(a, dtype=dtype)

KS = [1, 3, 5, 10, 30, 50]


def build_corpus(entry, granularity):
    corpus, ids = [], []
    for sess_id, data in zip(entry["haystack_session_ids"], entry["haystack_sessions"]):
        if granularity == "session":
            corpus.append(" ".join(t["content"] for t in data if t["role"] == "user"))
            sid = sess_id
            if "answer" in sess_id and all(not t["has_answer"] for t in data if t["role"] == "user"):
                sid = sess_id.replace("answer", "noans")
            ids.append(sid)
        else:
            for i_turn, turn in enumerate(data):
                if turn["role"] != "user":
                    continue
                corpus.append(turn["content"])
                if "answer" not in sess_id:
                    ids.append(sess_id + "_" + str(i_turn + 1))
                elif turn["has_answer"]:
                    ids.append(sess_id + "_" + str(i_turn + 1))
                else:
                    ids.append((sess_id + "_" + str(i_turn + 1)).replace("answer", "noans"))
    return corpus, ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval-utils", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--granularity", choices=["session", "turn"], default="session")
    ap.add_argument("--out", help="write the summary JSON here")
    args = ap.parse_args()

    spec = importlib.util.spec_from_file_location("eval_utils", args.eval_utils)
    eu = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(eu)

    data = json.load(open(args.data))
    t0 = time.time()
    prim, derived = defaultdict(list), defaultdict(list)
    n_eval = n_abs = n_notarget = 0
    for e in data:
        if "_abs" in e["question_id"]:
            n_abs += 1
            continue
        if not any(t.get("has_answer") and t["role"] == "user"
                   for s in e["haystack_sessions"] for t in s):
            n_notarget += 1
            continue
        corpus, ids = build_corpus(e, args.granularity)
        correct = list(set(i for i in ids if "answer" in i))
        bm25 = BM25Okapi([d.split(" ") for d in corpus])
        scores = bm25.get_scores(e["question"].split(" "))
        ranking = np.argsort(scores)[::-1]
        for k in KS:
            res = [("primary", eu.evaluate_retrieval(ranking, correct, ids, k=k))]
            if args.granularity == "turn":
                res.append(("derived", eu.evaluate_retrieval_turn2session(ranking, correct, ids, k=k)))
            for lvl, (a, b, c) in res:
                store = prim if lvl == "primary" else derived
                for name, v in (("recall_any", a), ("recall_all", b), ("ndcg", c)):
                    store[(e["question_type"], f"{name}@{k}")].append(v)
                    store[("overall", f"{name}@{k}")].append(v)
        n_eval += 1

    def collapse(store):
        out = defaultdict(lambda: defaultdict(dict))
        for (qt, key), vals in store.items():
            name, k = key.split("@")
            out[qt][name]["@" + k] = float(np.mean(vals))
        return {qt: dict(v) for qt, v in out.items()}

    summary = {
        "what": "official flat-bm25 baseline, measured locally",
        "granularity": args.granularity,
        "evaluated": n_eval, "excluded_abstention": n_abs, "excluded_no_user_side_target": n_notarget,
        "wall_seconds": time.time() - t0,
        "primary": collapse(prim),
    }
    if args.granularity == "turn":
        summary["session_from_turn"] = collapse(derived)
    text = json.dumps(summary, indent=1)
    if args.out:
        open(args.out, "w").write(text)
    o = summary["primary"]["overall"]
    print(f"{args.granularity}: evaluated {n_eval}, excluded abs={n_abs} no-target={n_notarget}, "
          f"wall {summary['wall_seconds']:.1f}s")
    for name in ("recall_any", "recall_all", "ndcg"):
        print(f"  {name:<10}", " ".join(f"{o[name]['@' + str(k)]:.3f}" for k in (1, 3, 5, 10)))
    if args.granularity == "turn":
        o = summary["session_from_turn"]["overall"]
        print("  session-from-turn:")
        for name in ("recall_any", "recall_all", "ndcg"):
            print(f"  {name:<10}", " ".join(f"{o[name]['@' + str(k)]:.3f}" for k in (1, 3, 5, 10)))


if __name__ == "__main__":
    main()
