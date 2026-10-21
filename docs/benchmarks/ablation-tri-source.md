# Ablation: does the tri-source tag / goal / existence-gain machinery improve retrieval?

> **Status of this file.** Sections 1–4 (inventory, hypotheses, variants,
> analysis plan) are the **pre-registration**. They were written, and committed,
> **before any variant was run**. Section 5 onwards (results) is filled in after
> the runs and is labelled as such. Anything added after seeing a number is
> marked **post-hoc**. No variant parameter below is allowed to change after the
> first run; if one has to, the old definition stays in this file and the new one
> is added as a post-hoc variant.

**Why this exists.** mem3's differentiator is its theory (三源合恰论: every
memory is 物/象/性-tagged; GHW: Goal–Harness–World layers; existence-gain
driven lifecycle). Until now nothing measured whether any of it changes what a
query returns. The official LongMemEval retrieval harness
(`docs/benchmarks/longmemeval-official.md`) gives a fixed, externally defined
yardstick, so the question can finally be asked with a number. A null or
negative answer is a valid outcome and will be reported as such.

**Scope guard.** Product defaults are not touched by this work. Every switch is
in the evaluation harness (`src/eval/`, `bench/`), which writes only to fields
the product already exposes (`store.lc.cfg`, `store.hybrid.cfg`, the arguments
of `addRaw` / `createGoal` / `addHyperedge`, `cell.metadata`).

---

## 1. Inventory — what the query path actually reads

Read from the tree at `d823358` (every line number below is in that tree). The
"query path" is `Store.query` (`src/store/store.zig:1327`), which is what the
MCP `memory_query` tool (`src/mcp/tools.zig:404`) and the LongMemEval harness
call.

```
Store.query(text, {topk, goal_ids})                       store.zig:1327
  1. goal scope  = opts.goal_ids ∪ ghw.retrieve(text)     store.zig:1330-1336
  2. hybrid.recall(text, 3·topk)                          store.zig:1338
       dense : HNSW over embed(cell.episode)              hybrid_retriever.zig:137
       sparse: BM25 over episode + atomic_facts text      hybrid_retriever.zig:149
       graph : multiHop(seeds = top-10 dense ∪ top-10 sparse)  hybrid_retriever.zig:165-189
       base  = 0.5·dense + 0.2·sparse + 0.3·graph         hybrid_retriever.zig:47-52
  3. rerankPairs: base × (1+0.4·goal) × (1+0.3·importance) × (1+0.2·recency)
                                                          reranker.zig:61-69
```

| Mechanism | Does it reach the ranking? | How (file:line) | What the LongMemEval harness feeds it |
|---|---|---|---|
| **Tri-source tag** (`cell.source`) | **Only through `decay_rate`, hence only through the recency factor.** Not read by `Store.query`, `HybridRetriever`, BM25, the embedder, the goal bonus or the importance score. | Tag → `cfg.decayRateFor(source)` (`encoder.zig:109`, `config.zig:93-95`: 0.05 / 0.03 / 0.01 per day) → `exp(-decay_rate·age_days)` inside the recency factor (`reranker.zig:51-58`, weight 0.2 at `config.zig:85`). `QueryOptions` has no source field (`store.zig:1308-1313`); `source_coherence` in the importance formula is the constant `1.0` (`encoder.zig:163`); the tri-source manager only picks one of three hash maps (`tri_source_manager.zig:158-159`) and `get` searches all of them. | Every cell is `.matter` (`longmemeval_official.zig:541`), and cells are microseconds old at query time, so the recency factor is ≈ 1.2 for every cell: **no effect by construction**. |
| **Source filter** | **Exists in exactly one place, and it is not the shipped query path.** `mem3 query --source-filter` is a hard filter on a *dense-only* candidate list. | `cli_commands/query.zig:59-64` (parse), `:90` (HNSW only: no BM25, no graph, no `ghw.retrieve`), `:103` (the filter). `Store.query`, MCP `memory_query` and HTTP `POST /api/query` have no source argument. | n/a (harness uses `Store.query`). |
| **Goal associations** (`goal_associations`) | **Yes, as a multiplicative bonus — but only for a goal that is in the query's goal scope.** The scope is the caller's `goal_ids` ∪ whatever `ghw.retrieve(text)` resolves (best token-substring overlap between the query and each goal's world entity: name + harness id + last cell + goal name/description tokens). Cells associated with that goal get `×(1 + 0.4·relevance)`; a tombstoned or unknown goal gives 0. | `reranker.zig:32-44` (`goalBonus`), `store.zig:1334` (scope), `ghw_io.zig:154-180` + `world_model.zig:183-201`, `:243-251` (`bestMatchFor` / `tokenHits`). **HTTP `POST /api/query` passes `query_goal_ids = &.{}` (`http_server.zig:1350`), so the goal bonus is dead on that path.** The CLI passes only the `--goal-ids` flag (`query.zig:110-116`). | Every cell carries goal 1 ("general") at relevance 0.5, so the bonus is the same constant for every cell of a query: **rank-preserving, no effect**. |
| **Importance** | **Yes, as a multiplicative bonus** `×(1 + 0.3·importance_score)`. | `reranker.zig:46-49`, `:61-69`. `importance = 0.3·1.0 + 0.4·max goal relevance + 0.3·existential` (`encoder.zig:163-190`). `existential` is 1.0 with an unexpired foresight, 0.5 with atomic facts, else 0.2 (`encoder.zig:176-184`). Never updated after encode on the query path (`MemCell.touch`, `memcell.zig:71`, has no non-test caller). | Uniform: 0.3 + 0.4·0.5 + 0.3·0.2 = 0.56 for every cell. **No effect.** |
| **Existence gain / `existenceContribution`** | **Not a retrieval signal.** It is `importance · exp(-decay·age)` and is read only by the forgetting sweep. It can change retrieval only by *deleting* cells. | `forgetter.zig:73-80`, called from `sweep` (`forgetter.zig:86+`). The reranker's "existence bonus" is plain `importance_score`, not this function. | Forgetting is not run. n/a. |
| **Coherence `C_tri`** | **No effect.** `coherence_score` is never read by `Store.query` or the reranker. `CoherenceCalculator.updateCell` (`coherence.zig:130`) has **no non-test caller**; the only writer is the consolidator's abstract cell (`consolidator.zig:320`, fixed at 1.0). | — | Never computed. |
| **Spirit dimension** (`foresight`) | **Only through the `existential` term of importance** (`encoder.zig:176-182`). A foresight entry is never matched against a query or a clock at retrieval time. | Same path as importance above. | The harness stores no foresight. |
| **Hypergraph arm** | **Yes, but not as the theory describes it.** With **no hyperedges**, `multiHop` returns just the seeds (`engine.zig:164-168`), and every returned id gets `graph_score = 0.7` (`hybrid_retriever.zig:210-219`). So today's "graph arm" is a flat `+0.3·0.7 = +0.21` bonus for the union of the top-10 dense and top-10 BM25 hits. Real edges would add their neighbours. Ingestion creates no edges; only `mem3 hyperedge add` does. | `hybrid_retriever.zig:165-189`, `:210-219`; `hypermem/engine.zig:147-204`. | No edges, so the arm is the seed bonus only. |
| **GHW layers** (`encodeAcrossLayers`, `ghw.retrieve`) | **Indirect: they only produce the goal scope above.** `encode` writes one harness and one world entity per *goal* (not per cell), and `retrieve` maps the query back to a goal by token overlap. | `store.zig:1279-1301`, `ghw_io.zig:94-180`. | One goal, so the scope is always {1} or empty. |
| **BM25 / dense arms** | The only mechanisms that actually discriminate between cells in this harness. | `hybrid_retriever.zig:130-190`. | — |

**Reading of the inventory (before any run).**

1. On the shipped query path the tri-source tag is **not a retrieval signal**.
   It is metadata plus a decay-rate lookup. Anything the theory says about
   routing queries by source is, today, implemented only as a CLI flag on a
   different (dense-only) path.
2. The goal machinery is **live code** but can only discriminate if cells are
   bound to **different** goals *and* the query text overlaps the right goal's
   name/description. LongMemEval-as-run-today binds everything to one goal, so
   the whole GHW stack is a constant factor there.
3. Importance is live code but uniform in the harness; "existence gain" and
   `C_tri` do not touch retrieval at all.
4. The "hypergraph" arm without edges is a seed bonus, not a graph.

Consequence for the design: a variant that merely changes the tag (B, C, D)
**cannot** change the ranking except through the recency factor. That is a
*prediction*, written down here before running, and variants J below exist
precisely to give the one real code path (source → decay → recency) something
to act on.

---

## 2. Pre-registered hypotheses and predictions

The theory's retrieval claims, restated as testable statements. "Gain" always
means a paired improvement over the stated baseline on the official metric.

| Id | Claim under test | Baseline → variant |
|---|---|---|
| H-tag | The tri-source tag carries retrieval-relevant signal | B vs D (real heuristic tags vs the same tags shuffled), and B/C vs A |
| H-route | Routing a query to its predicted source helps | E vs A, and E(B tags) vs E(shuffled tags) |
| H-goal | Goal-prioritised rerank helps | F_on vs F_off, F_on vs A |
| H-imp | Importance / existence-gain rerank helps | G_heur_on vs G_heur_off |
| H-graph | The hypergraph arm helps | H_off vs A, H_edges vs A |
| H-decay | Source-dependent decay (the one real tag path) helps | J_B vs J_A, J_B vs J_D |
| Refs | Context for the above | I_dense, I_bm25 vs A |

**Predictions from reading the code (so that a surprise is visible as one):**

* P1. B, C_form, C_spirit, D\_s1..5 rank **identically to A** on (almost) every
  question; the deltas are 0 or a handful of tie flips from float rounding of
  `1 + 0.2·exp(−λ·age)` with age ≈ 0. A 95 % CI of exactly [0, 0] is the
  expected outcome and is **not** a harness bug.
* P2. F_off, G_flat and R_off are **bit-identical to A** (sanity checks of the
  switches, not hypotheses).
* P3. E_filter / E_boost with real tags are not distinguishable from the same
  router over shuffled tags.
* P4. F_on differs from F_off (goal bonus is live once goals differ) but there is
  no reason to expect a gain: the goal is derived from lexical overlap that BM25
  already uses.
* P5. G_heur_on vs G_heur_off: a small, unsystematic change, because the heuristic
  "spirit" label is unrelated to answer-bearing turns.
* P6. J_A vs A: recency is a *prior toward newer sessions*; it can help
  knowledge-update and temporal-reasoning and hurt multi-session. Sign unknown.

---

## 3. Pre-registered variants

Dataset: `longmemeval_s_cleaned.json` (sha256 `d6f21ea9…c3a442`), the 419
evaluable questions of the official protocol (user-turn corpus; abstention and
no-user-evidence questions excluded; all scoring code is the existing,
cross-checked harness). Embedder: built-in `lexical_hash`. Each question gets a
fresh in-memory `Store`. Everything is run at **session** granularity and at
**turn** granularity (turn runs also give the derived session-from-turn metrics).

### 3.1 The tag assigner (defined once, here)

The product has **no** automatic source classifier: `source` is a required
caller-supplied argument (`mcp/tools.zig:336`, `cli_commands/add.zig`). So
"tags assigned by the product's own encoder/heuristic" does not exist, and B uses
a harness-defined **lexical stand-in for an LLM source tagger**. It is fixed now:

On the lower-cased text of a document (a turn, or a whole session at session
granularity), first rule that fires wins:

1. **性 spirit** (intent / goal / preference / plan): contains any of
   `i want`, `i'd like`, `i would like`, `i plan`, `planning to`, `i hope`,
   `i wish`, `my goal`, `i need to`, `going to`, `i prefer`, `my favorite`,
   `my favourite`, `i love`, `i like`, `i enjoy`, `looking for`, `i'm interested`,
   `i am interested`, `i intend`, `thinking of`, `thinking about`, `next week`,
   `next month`, `tomorrow`.
2. **象 form** (procedure / structure / rule): contains any of `how to`, `step by step`,
   `steps`, `recipe`, `always`, `usually`, `routine`, `every day`, `every week`,
   `instructions`, `tutorial`, `template`, `algorithm`, `function`, `script`.
3. **物 matter**: otherwise.

This is deliberately crude. It tests *this tagger*, not the best conceivable one;
that limitation is carried into the verdicts (§8).

Random tags (D): for each question, the multiset of B's tags is **permuted
across that question's documents** (Fisher–Yates with a SplitMix64 stream seeded
by `tag_seed ⊕ hash(question_id)`), so the tag distribution per question is
identical to B and only the tag↔document association is destroyed.
Seeds **1, 2, 3, 4, 5**.

### 3.2 The variants

Baseline **A** = today's harness, unchanged: every cell `.matter`, goal 1,
relevance 0.5, default weights.

| Id | Definition |
|---|---|
| **A** | current default (all 物, goal 1 @ 0.5) |
| **B** | tags from §3.1 |
| **C_form**, **C_spirit** | every cell tagged 象 / 性 (A is the all-物 member of this family) |
| **D_s1…D_s5** | B's tags shuffled, seeds 1–5 |
| **E_filter** (tags B) | router = §3.1 heuristic applied to the **question text** (default 物). Stable partition of the full ranking: cells whose source equals the prediction first, the rest after, each in original order (no recall is lost; the whole corpus is still ranked). |
| **E_boost** (tags B) | same router; `final_score ×= 1.25` for cells whose source equals the prediction, re-sorted stably |
| **E_filter_rand**, **E_boost_rand** | the same routers on D\_s1…s5 tags (control: routing with no tag signal) |
| **F_on** | **goal per session.** One goal per haystack session: name `g<session index>`, description = that session's 12 most frequent content words (lower-case alphabetic, length ≥ 4, a fixed stop-word list, ties broken alphabetically). Every cell is bound to **its own session's goal at relevance 1.0** (the mechanism's maximum strength: if there is no gain at 1.0 there is none below it). Uses only haystack text — **no labels, no `has_answer`, no question type**. The query is routed to a goal by the product's own `ghw.retrieve`. |
| **F_off** | identical store to F_on, `goal_bonus_weight = 0` (isolates the rerank from the presence of goals; expected bit-identical to A) |
| **G_flat** | A with `existence_bonus_weight = 0` (sanity; expected identical to A) |
| **R_off** | A with `recency_bonus_weight = 0` (sanity; expected identical to A) |
| **G_heur_on** | B tags; every cell the heuristic calls 性 also carries one foresight entry (`"intent"`, valid until now+365 d, confidence 0.8), so the product's own encoder gives it `existential = 1.0` instead of 0.2 → higher `importance_score` |
| **G_heur_off** | identical ingest, `existence_bonus_weight = 0` |
| **H_off** | A with `λ_graph = 0` on both live weight copies (`hybrid.cfg`, `lc.cfg`); dense/sparse weights unchanged (the ranking is invariant to the common scale) |
| **H_edges** (turn only) | A plus one `associative` hyperedge per session over that session's ingested turns (confidence 1.0). Natural structure, no labels. Not defined at session granularity (the document *is* the session). |
| **I_dense**, **I_bm25** | the existing `--arm` references |
| **J_A** | A, plus **simulated ages**: after ingestion every cell's `created_at` is set to `t_ref − (question_date − session_date)` from `haystack_dates` / `question_date` (unparseable → age 0, counted), so `exp(-λ·age)` is real |
| **J_B** | J_A with B tags (per-source decay now differs: 0.05 / 0.03 / 0.01 per day) |
| **J_C_spirit** | J_A with every cell 性 (slowest decay) |
| **J_D_s1…s5** | J_A with D tags |

### 3.3 Reporting rules

* **Metrics.** R_any@1, @5, @10 and NDCG@10 overall and per `question_type`
  (R_any@3 and the R_all family are in the JSON but are not part of the
  pre-registered analysis). Levels: session; turn; session-derived-from-turn.
* **Primary outcome** of each comparison: **ΔNDCG@10, overall, at the level the
  variant is defined at** (session for F/G/H/J-session runs, turn for turn runs;
  both levels are run for everything except H_edges). Everything else is
  secondary; per-type rows are exploratory and say so.
* **Paired** deltas per question against the stated baseline. **Percentile
  bootstrap over questions, 10,000 resamples, fixed seed 20261021**, 95 % CI. For
  seed families (D, E_rand, J_D) the per-question metric is first **averaged over
  the 5 seeds**, then differenced; the per-seed overall deltas are also listed so
  the spread is visible.
* **Multiplicity.** There are **m = 20** primary comparisons per level (list in
  §3.4). Besides the plain 95 % CI, the report gives the Bonferroni-adjusted CI
  at level 1 − 0.05/20 for the primary outcome. No other correction is applied
  to the secondary metrics, per-type rows or non-primary comparisons; they are
  exploratory.
* **Verdict rule (fixed now).**
  *gain*: the 95 % CI of the primary ΔNDCG@10 is entirely > 0 (flagged
  "survives Bonferroni" only if the adjusted CI is also > 0).
  *harm*: entirely < 0.
  *no detectable effect*: the CI contains 0; if the CI lies inside (−0.01, +0.01)
  it is reported as *bounded null* (1 NDCG point is the pre-set margin of
  practical relevance). A "no detectable effect" is **not** evidence of a
  mechanism working at some other benchmark.
* Also reported per comparison: the number of questions whose **ranking is
  byte-identical** to the baseline (FNV-1a of the ranking), improved, worsened.
* Wall time per run is recorded. The host is shared and heavily loaded; wall
  times are upper bounds.

### 3.4 The m = 20 primary comparisons (per level)

1 B−A · 2 C_form−A · 3 C_spirit−A · 4 D−A (pooled) · 5 B−D (pooled) ·
6 E_filter−A · 7 E_boost−A · 8 E_filter−E_filter_rand · 9 E_boost−E_boost_rand ·
10 F_on−F_off · 11 F_on−A · 12 G_heur_on−G_heur_off · 13 H_off−A ·
14 H_edges−A (turn only) · 15 I_dense−A · 16 I_bm25−A · 17 J_A−A · 18 J_B−J_A ·
19 J_C_spirit−J_A · 20 J_B−J_D (pooled). Sanity (not primary, expected exactly 0):
F_off−A, G_flat−A, R_off−A.

### 3.5 The synthetic mechanism check (labelled synthetic)

LongMemEval has no notion of goals or sources, so a null there cannot tell
"the machinery is inert" from "the benchmark cannot reward it". A tiny
synthetic task where the machinery **should** help is run to check that the
mechanisms work at all end to end: (a) **goal-conditioned** — 8 goals × 12 cells,
the target phrase is lexically identical across goals, the query names the goal
in its text; (b) **source-routed** — each topic exists as three cells with
identical text and different tags, the query carries an intent marker the §3.1
router recognises. Expectation: chance-level with the mechanism off, near 1.0
with it on. This is a unit check of wiring, not evidence of usefulness on real
data, and it will be described as exactly that.

---

## 4. Implementation notes (fixed before running)

* Switches live in `src/eval/lme_ablation.zig` (variant definition, tag
  assigner, shuffler, goal-topic derivation, router, date parser) and
  `src/eval/paired_stats.zig` (paired bootstrap); `longmemeval_official.zig`
  gains an `Options.variant` whose default reproduces today's behaviour, and
  `mem3-bench longmemeval-official` gains `--variant=…` flags and
  `--dump-scores=PATH`. `mem3-bench lme-compare` computes the paired table.
* **Product defaults unchanged.** Proof obligation: with default options the new
  harness must reproduce, byte for byte, the ranking dumps recorded before this
  work (`/tmp/mem3_lme_data/rank_s_session_hybrid.jsonl` etc.) and the numbers
  in `longmemeval-official.md`.
* Tests come first for: bootstrap math, shuffler determinism, tag assigner,
  router, date parser, goal-topic derivation.

---

## 5. Results

*(to be filled in after the runs — see the sections below once present)*
