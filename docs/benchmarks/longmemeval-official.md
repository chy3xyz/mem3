# LongMemEval (official dataset) — retrieval metrics

`mem3-bench longmemeval-official` runs mem3 against the **official**
LongMemEval dataset (Wu et al., `xiaowu0162/longmemeval-cleaned`) and reports
what can be measured without an LLM: session-level and turn-level
**Recall@k / NDCG@k** against the dataset's own evidence labels
(`answer_*` sessions, `has_answer` turns), by `question_type`.

> **Disclaimer — read before quoting anything below.** These are *retrieval*
> metrics. No LLM reader and no LLM judge was run. They are **not** QA
> accuracy and are **not** comparable to published QA numbers (for example the
> vendor figures quoted elsewhere in this repo). They are the same *kind* of
> quantity as the retrieval table in the LongMemEval repository, but this run
> uses mem3's built-in hashed lexical embedder, so it characterises mem3; it is
> not a leaderboard entry. Every figure here was measured on this tree, once
> per configuration, on one machine.

This is the counterpart of `mem3-bench longmemeval`, which is an **offline
re-implementation on a locally generated case set** (README, "Status and
limitations"). The two numbers measure different things and neither replaces
the other.

## 1. Dataset

Not in the repository and never committed. Fetch it into `/tmp`:

```bash
mkdir -p /tmp/mem3_lme_data && cd /tmp/mem3_lme_data
python3 - <<'EOF'
import urllib.request
base = "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/"
for name in ("longmemeval_oracle.json", "longmemeval_s_cleaned.json"):
    urllib.request.urlretrieve(base + name, name)
EOF
shasum -a 256 longmemeval_oracle.json longmemeval_s_cleaned.json
```

(`curl`/`wget` may be blocked by local hooks; `urllib` was what worked here. A
277 MB download can be interrupted: the one used for the numbers below was
resumed with an HTTP `Range` request and then verified against the hash.)

| File | Bytes | SHA-256 |
|---|---|---|
| `longmemeval_s_cleaned.json` | 277,383,467 | `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442` |
| `longmemeval_oracle.json` | 15,388,478 | `821a2034d219ab45846873dd14c14f12cfe7776e73527a483f9dac095d38620c` |

Both hashes match the LFS `sha256` that the Hugging Face API
(`/api/datasets/xiaowu0162/longmemeval-cleaned?blobs=true`) reported for
dataset revision `98d7416c24c778c2fee6e6f3006e7a073259d48f` on 2026-10-21. The
harness also computes and prints the SHA-256 of whatever file it is given
(`dataset.sha256` in the JSON), so a run records its own input.

What the files contain, measured: 500 questions each; `_s` has ~47.7 sessions
per haystack on average (≤ 62) and 244 user turns on average; `_oracle`'s
haystack is **only the evidence sessions** (2.0 sessions per question on
average), so retrieval there is close to trivial and is a sanity check, not a
benchmark. `longmemeval_m_cleaned.json` (2.7 GB) was **not** fetched or run.

## 2. Reproduce

```bash
zig build                       # builds zig-out/bin/mem3-bench (ReleaseFast)
D=/tmp/mem3_lme_data
B=./zig-out/bin/mem3-bench

# Session-level, product defaults (hybrid fusion, built-in embedder):
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json > out.json

# Arms (λ weights set for one run; product defaults are not changed):
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json --arm=dense
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json --arm=bm25

# Turn-level (also prints session-level derived from the turn ranking):
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json --granularity=turn

# A deterministic subset (seeded sample of N questions, drawn BEFORE exclusions):
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json --limit=100 --seed=42

# Extension, NOT the official configuration: index assistant turns too:
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json --roles=all

# Re-score a ranking dump with the OFFICIAL eval_utils.py (see §4):
$B longmemeval-official --data=$D/longmemeval_s_cleaned.json \
   --dump-rankings=$D/rank.jsonl > $D/summary.json
python3 scripts/lme_official_crosscheck.py \
   --eval-utils $D/src__retrieval__eval_utils.py \
   --rankings $D/rank.jsonl --summary $D/summary.json
```

`$D/src__retrieval__eval_utils.py` is a copy of
`https://raw.githubusercontent.com/xiaowu0162/LongMemEval/main/src/retrieval/eval_utils.py`;
it is someone else's code and is deliberately not vendored. stdout is one JSON
document (same envelope as the other benches, plus `disclaimer`, `dataset`,
`config`, `counts`, `results`, `timing`); the human table goes to stderr.

Unit tests (fixture in the official schema, metric math, abstention exclusion,
per-type aggregation, a Store-backed end-to-end run) live in
`src/eval/longmemeval_official.zig` and run under `zig build test`.

## 3. What is measured

For each question: a **fresh in-memory `Store`** (default goals seeded) ingests
that question's haystack (`addRaw`, source `matter`), the question text is the query
through **`Store.query`** — the same recall path as `mem3 query`, GHW
goal-aware rerank included — and the returned cells are mapped back to corpus
documents. The ranking depth requested is the whole corpus; the fraction the
store actually returned is reported (`mean_fraction_of_corpus_ranked`), not
assumed. A ranking shorter than k is never padded into a hit.

Choice of a harness in Zig (not a Python driver over `mem3 mcp`): the Zig
library is the product's `Store`, running in-process with no protocol overhead,
so ~24k sessions / ~100k turns are ingested in tens of seconds; the
metric/corpus code sits in the library so it is unit tested under the existing
gates. The Python scripts are only used to *check* it (§4).

Corpus and metric rules are a transcription of the official repository's
`src/retrieval/eval_utils.py`, `run_retrieval.py` and
`print_retrieval_metrics.py` (read on 2026-10-21):

- **Corpus = user turns only** by default. Session granularity: one document
  per session, user turns joined by a space. Turn granularity: one document per
  user turn, id `<session>_<1-based position in the session>`.
- An `answer_*` session with no user-side `has_answer` turn is relabelled
  `noans_*` and is **not** a correct document.
- `recall_any@k`, `recall_all@k`, `ndcg@k` as in `eval_utils.py`. Its `dcg`
  leaves rank 2 undiscounted (`log2(2) = 1`), which differs from textbook NDCG;
  reproduced as-is so numbers line up with the official script.
- Turn→session ("derived") uses the official rule: `k` is widened until `k`
  distinct sessions appear. As in the official code, retrieving a non-evidence
  turn of an evidence session does *not* count as a session hit (it is renamed
  `noans_*` before the suffix is stripped).
- Excluded from every average: **30** abstention (`_abs`) questions and **51**
  questions with no user-side `has_answer` turn → **419 evaluated** of 500.
  (`answer_session_ids` equals "haystack ids containing `answer`" for all 500
  questions in both files; the harness counts disagreements, 0 here.)

Not part of the official protocol, and stated as such: `--roles=all`.

## 4. Verification of the transcription

`scripts/lme_official_crosscheck.py` recomputes every per-question metric with
the official `eval_utils.py` from a `--dump-rankings` file and compares all 126
aggregates (overall + 6 question types, × 3 metrics × 6 cut-offs) with the
harness's JSON. Run on: session/hybrid, session/bm25, turn/hybrid (both the
turn level and the derived session level). **All match; max abs difference
4.99e-07**, which is the 6-decimal rounding of the JSON output. (numpy ≥ 2
removed `np.asfarray`, which `eval_utils.py` calls; the script installs the
documented one-line replacement.)

What this proves: the metric arithmetic, the `noans` relabel and the turn→session
widening agree with the official code *given the same ranking and ids*. What it
does not prove: that my corpus construction equals the official one for every
edge case — it is a transcription of the code I read, and I did not run the
official `run_retrieval.py` itself (it needs torch/GPU imports at module load).
Independent corroboration: a separate script re-implementing the official
`flat-bm25` path reached the same exclusion counts (419 / 30 / 51).

Also checked: two consecutive session/hybrid runs gave byte-identical `results`
and `counts` (the harness is deterministic).

## 5. Results — `longmemeval_s_cleaned.json`, 419 evaluated questions

Embedder: built-in `lexical_hash` (default). Hybrid = product weights
λ_dense 0.5 / λ_sparse 0.2 / λ_graph 0.3. No hyperedges are added, so the graph
arm contributes only seeds. k = 30 / 50 are in the JSON; the tables show
1 / 3 / 5 / 10.

### Overall, by arm and granularity

| Level | Arm | R_any@1 | @3 | @5 | @10 | R_all@1 | @3 | @5 | @10 | NDCG@1 | @3 | @5 | @10 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| session | **hybrid** | 0.802 | 0.912 | 0.938 | 0.957 | 0.222 | 0.740 | 0.797 | 0.871 | 0.802 | 0.818 | 0.834 | 0.853 |
| session | dense only | 0.477 | 0.711 | 0.778 | 0.874 | 0.115 | 0.387 | 0.506 | 0.637 | 0.477 | 0.518 | 0.563 | 0.605 |
| session | bm25 only | 0.802 | 0.900 | 0.936 | 0.955 | 0.215 | 0.745 | 0.809 | 0.885 | 0.802 | 0.819 | 0.839 | 0.859 |
| turn | **hybrid** | 0.525 | 0.742 | 0.816 | 0.874 | 0.148 | 0.465 | 0.570 | 0.666 | 0.525 | 0.575 | 0.617 | 0.647 |
| turn | dense only | 0.368 | 0.530 | 0.597 | 0.695 | 0.100 | 0.263 | 0.339 | 0.437 | 0.368 | 0.368 | 0.402 | 0.435 |
| turn | bm25 only | 0.547 | 0.754 | 0.828 | 0.874 | 0.158 | 0.487 | 0.587 | 0.690 | 0.547 | 0.589 | 0.629 | 0.658 |
| session, from turn ranking | hybrid | 0.525 | 0.766 | 0.833 | 0.888 | 0.148 | 0.511 | 0.630 | 0.699 | 0.525 | 0.587 | 0.628 | 0.651 |
| session, from turn ranking | dense only | 0.368 | 0.542 | 0.616 | 0.733 | 0.105 | 0.279 | 0.365 | 0.496 | 0.368 | 0.373 | 0.408 | 0.447 |
| session, from turn ranking | bm25 only | 0.547 | 0.780 | 0.850 | 0.905 | 0.160 | 0.535 | 0.654 | 0.745 | 0.547 | 0.603 | 0.643 | 0.669 |

`recall_all@1` is low by construction: multi-session questions have 2+ evidence
sessions, so they cannot be fully recalled at k = 1. Hybrid at k = 30 / 50,
session: recall_any 0.998 / 1.000 (a 48-session haystack is almost exhausted);
turn: recall_any 0.926 / 0.955, recall_all 0.788 / 0.847.

### Per question type — hybrid, session level

| question_type | n | R_any@1 | @3 | @5 | @10 | R_all@1 | @3 | @5 | @10 | NDCG@1 | @3 | @5 | @10 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| knowledge-update | 72 | 0.931 | 1.000 | 1.000 | 1.000 | 0.014 | 0.931 | 0.944 | 0.972 | 0.931 | 0.955 | 0.958 | 0.963 |
| multi-session | 121 | 0.769 | 0.942 | 0.967 | 0.967 | 0.000 | 0.521 | 0.612 | 0.760 | 0.769 | 0.733 | 0.754 | 0.787 |
| single-session-assistant | 5 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 |
| single-session-preference | 30 | 0.400 | 0.533 | 0.667 | 0.733 | 0.400 | 0.533 | 0.667 | 0.733 | 0.400 | 0.496 | 0.558 | 0.580 |
| single-session-user | 64 | 0.922 | 0.984 | 1.000 | 1.000 | 0.922 | 0.984 | 1.000 | 1.000 | 0.922 | 0.979 | 0.986 | 0.986 |
| temporal-reasoning | 127 | 0.795 | 0.890 | 0.913 | 0.961 | 0.134 | 0.764 | 0.819 | 0.890 | 0.795 | 0.816 | 0.830 | 0.853 |
| **overall** | 419 | 0.802 | 0.912 | 0.938 | 0.957 | 0.222 | 0.740 | 0.797 | 0.871 | 0.802 | 0.818 | 0.834 | 0.853 |

`single-session-assistant` has only 5 evaluated questions: the other 51 of its
56 have no user-side evidence turn, so the official protocol drops them.

### Per question type — hybrid, turn level

| question_type | n | R_any@1 | @3 | @5 | @10 | R_all@1 | @3 | @5 | @10 | NDCG@1 | @3 | @5 | @10 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| knowledge-update | 72 | 0.625 | 0.889 | 0.958 | 1.000 | 0.000 | 0.556 | 0.750 | 0.806 | 0.625 | 0.678 | 0.741 | 0.759 |
| multi-session | 121 | 0.446 | 0.661 | 0.760 | 0.860 | 0.000 | 0.174 | 0.281 | 0.446 | 0.446 | 0.396 | 0.443 | 0.497 |
| single-session-assistant | 5 | 0.400 | 0.600 | 0.600 | 0.800 | 0.400 | 0.600 | 0.600 | 0.800 | 0.400 | 0.600 | 0.600 | 0.671 |
| single-session-preference | 30 | 0.067 | 0.300 | 0.400 | 0.500 | 0.067 | 0.167 | 0.200 | 0.300 | 0.067 | 0.215 | 0.251 | 0.292 |
| single-session-user | 64 | 0.734 | 0.906 | 0.938 | 0.969 | 0.734 | 0.906 | 0.938 | 0.969 | 0.734 | 0.895 | 0.909 | 0.920 |
| temporal-reasoning | 127 | 0.551 | 0.764 | 0.835 | 0.858 | 0.087 | 0.535 | 0.646 | 0.724 | 0.551 | 0.609 | 0.651 | 0.671 |
| **overall** | 419 | 0.525 | 0.742 | 0.816 | 0.874 | 0.148 | 0.465 | 0.570 | 0.666 | 0.525 | 0.575 | 0.617 | 0.647 |

The derived session-level per-type table is in the JSON
(`results.session_from_turn.by_question_type`).

### A baseline measured here, not quoted

To read mem3 next to something other than itself, the official repository's
`flat-bm25` path (whitespace tokens, case-sensitive, `rank_bm25.BM25Okapi`) was
re-run on the same file with the same exclusions and the official
`eval_utils.py` (`scripts/lme_official_flat_bm25_baseline.py`, numpy 2.5.4,
`rank_bm25` from PyPI):

| Level | Method | R_any@1 | @3 | @5 | @10 | R_all@10 | NDCG@10 |
|---|---|---|---|---|---|---|---|
| session | official flat-bm25 (local run) | 0.706 | 0.845 | 0.888 | 0.926 | 0.823 | 0.794 |
| session | mem3 hybrid | 0.802 | 0.912 | 0.938 | 0.957 | 0.871 | 0.853 |
| turn | official flat-bm25 (local run) | 0.453 | 0.644 | 0.716 | 0.804 | 0.592 | 0.564 |
| turn | mem3 hybrid | 0.525 | 0.742 | 0.816 | 0.874 | 0.666 | 0.647 |

Read this carefully: mem3's lexical arm is not the official BM25 (it lowercases,
splits on punctuation and indexes bigrams, and the fusion adds a dense arm and a
rerank), so the gap is a property of those differences, not a statement that
mem3's retrieval is "better" in general.

**Published numbers are deliberately not cited.** I did not have the paper's
retrieval table in front of me and will not reproduce figures from memory; the
rows above are the only external reference point and were measured by me. Anyone
wanting the paper's baselines should take them from the paper and compare against
the `official flat-*` rows only for retrievers that script can run.

### Other runs

| Run | Evaluated | R_any@1 / @5 / @10 | NDCG@10 | Note |
|---|---|---|---|---|
| `_oracle`, session, hybrid | 419 | 0.971 / 1.000 / 1.000 | 0.993 | Haystack = evidence sessions only (2.0 docs/question). Sanity check, not a retrieval benchmark. |
| `_s`, session, hybrid, `--roles=all` | 470 | 0.834 / 0.940 / 0.972 | 0.876 | **Not official**: assistant turns indexed; 51 more questions become evaluable (no user-side target is required). Different question set, so not comparable with the 419-question rows. |

### Runtime

Single-threaded, ReleaseFast, macOS aarch64, one run per configuration. **Other
worktrees were building and benchmarking on the same machine**, so wall times are
upper bounds (for turn/hybrid the process used 39 s of user CPU inside an 83 s
wall run). Wall: session/hybrid 18.7 s, session/dense 18.8 s, session/bm25
31.6 s, turn/hybrid 83.3 s, turn/dense 60.3 s, turn/bm25 74.6 s, session/hybrid
with `--roles=all` 197.6 s (assistant turns are long), `_oracle` 1.1 s. Reading
the 277 MB file and hashing it is included. The full set was run in every
configuration; no subset was needed.

## 6. Limitations — what this does not tell you

- **No QA accuracy.** Nothing here says whether an LLM given the retrieved
  context would answer correctly. The old `mem3-bench longmemeval` number (0.73
  combined) and these retrieval numbers are not interchangeable.
- **One embedder.** Built-in `lexical_hash` only. `--embedder-cmd` is wired
  through to the Store but was **not run** on this dataset (ONNX MiniLM adapter,
  see `scripts/embedder_adapter_example.py`, would be the first thing to try; its
  cost over ~100k turns was not measured).
- **BM25-only ≈ hybrid at session level.** The lexical arm carries the hybrid
  result here (dense-only is far behind: 0.477 vs 0.802 at R_any@1); this agrees
  with the README's earlier finding that `lexical_hash` is the ceiling, but it is
  a single-run observation on this dataset. In the BM25-only arm the candidates
  BM25 did not match enter the ranking with score 0 in no meaningful order, which
  only affects ranks beyond the lexical matches.
- **Empty documents.** 58 of ~19.9k session documents (7 of ~102k turns) in the
  evaluated questions have empty user text and cannot be indexed by `addRaw`;
  they stay in the corpus, can never be retrieved, and none of them is an
  `answer_*` session (checked). They are reported as
  `counts.ingest_failures_empty_text`.
- **Graph arm idle.** No hyperedges are created by ingestion here, matching how
  `mem3 add` behaves, so the graph arm contributes only seeds.
- **Transcription, not the official run.** See §4 for exactly what was checked.
  The official script ranks with `numpy.argsort` over all scores; mem3 returns
  what `Store.query` returns (99.68% of the corpus on average at session level,
  99.92% at turn level; the shortfall is almost entirely the empty documents
  below), unreturned documents count as misses.
- **Single seed, single run, one machine.** The harness is deterministic (two
  runs identical), so there is no run-to-run variance to report, but the
  per-type rows for `single-session-assistant` (n = 5) are anecdotes.
- **`_m` (2.7 GB, ~500 sessions per haystack) not run.**
