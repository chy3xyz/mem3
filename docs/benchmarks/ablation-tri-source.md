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

> Everything from here on was written **after** the runs. Where a number or a
> definition differs from §1–§4, it is listed in §5.9 as **post-hoc**.

### 5.1 Verdict in one table

Primary outcome = ΔNDCG@10 (variant − base), 419 evaluable questions, paired
percentile bootstrap (10,000 resamples, seed 20261021). "Survives Bonferroni"
means the CI at level 1 − 0.05/20 also excludes 0. Session and turn are the two
granularities of the official harness; "derived" is the session-level metric
computed from the turn-level ranking.

| Mechanism (hypothesis) | Comparison | Session | Turn | Verdict |
|---|---|---|---|---|
| **Tri-source tag as a ranking signal** (H-tag) | B, C_form, C_spirit, D vs A | Δ = 0.0000, CI [0, 0]; 416–418 of 419 rankings identical (noise floor: 417) | Δ = 0.0000, CI [0, 0]; 415–419 identical (noise floor: 419) | **No effect, exactly zero, as predicted (P1).** The tag is not an input to ranking on this path; this says nothing about whether a tag *could* help. |
| **Source-aware routing** (H-route) | E_filter / E_boost vs A, and vs the same router on shuffled tags | filter −0.754 [−0.785, −0.720]; boost −0.053 [−0.062, −0.044]. Real tags vs shuffled: filter **−0.219** [−0.242, −0.195], boost −0.009 [−0.019, +0.001] | filter −0.386 [−0.424, −0.347]; boost −0.077 [−0.093, −0.061]. Real vs shuffled: filter **−0.126** [−0.162, −0.090], boost **−0.022** [−0.036, −0.008] | **Harm.** Routing with this tagger loses to routing with *random* tags. No evidence the tag locates the answer. (Crude tagger, see §5.6.) |
| **Goal-prioritised rerank** (H-goal) | F_on vs F_off (= A) | **−0.0138** [−0.0209, −0.0070] | **−0.0225** [−0.0354, −0.0095] | **Harm** (small), survives Bonferroni at both levels. With goals derived from haystack text and routed by the product's own `ghw.retrieve`, switching the goal bonus on makes retrieval slightly worse. |
| **Importance / existence-gain rerank** (H-imp) | G_heur_on vs G_heur_off | +0.0046 [+0.0012, +0.0082] (adjusted CI [−0.0008, +0.0103]) | −0.0010 [−0.0085, +0.0060] | **No reliable effect.** One nominally positive session number that does not survive the correction and has the opposite sign at turn level. Existence-gain proper and `C_tri` are not on the query path at all (§1). |
| **Hypergraph arm, no edges** (H-graph) | H_off vs A | −0.00002 [−0.0001, 0.0000] | +0.0013 [−0.0022, +0.0049] | **No effect.** Removing the flat seed bonus changes nothing measurable. |
| **Hypergraph arm, session edges** (H-graph) | H_edges vs A (turn only) | n/a | primary: +0.0020 [−0.0009, +0.0053]; secondary, session-derived: **+0.0076** [+0.0043, +0.0115] (adjusted [+0.0028, +0.0137]) | **Null on the pre-registered primary; a small positive on a secondary metric.** One edge per session is dataset structure, not a theory-derived graph; see §5.4. |
| **Source-dependent decay** (H-decay) | J_B vs J_A; J_B vs J_D | J_B−J_A +0.0006 [−0.0030, +0.0039]; J_B−J_D +0.0044 [+0.0015, +0.0075] (adjusted [−0.0001, +0.0091]) | J_B−J_A +0.0006 [−0.0039, +0.0052]; J_B−J_D +0.0006 [−0.0035, +0.0049] | **Bounded null** at turn level and for J_B vs J_A at session level; J_B vs J_D at session level is nominally positive and does not survive the correction. |
| Recency prior with real ages (context for H-decay) | J_A vs A | +0.0035 [−0.0006, +0.0080] | **−0.0060** [−0.0112, −0.0014] (adjusted [−0.0144, +0.0005]) | No reliable effect; sign differs by level. |
| Reference arms | I_dense, I_bm25 vs A | I_dense **−0.248**; I_bm25 +0.0055 [−0.0053, +0.0160] | I_dense **−0.212**; I_bm25 +0.0116 [+0.0008, +0.0217] (adjusted [−0.0054, +0.0267]); session-derived +0.0178 [+0.0073, +0.0277], survives | The dense arm (`lexical_hash`) alone is far worse than the hybrid; BM25 alone is **not** worse than the hybrid and is nominally better at turn level. Outside the theory but worth knowing. |

**Plain reading.** On the official LongMemEval S retrieval task, with the
product's query path as it ships and with the pre-registered harness-side
switches, **none of the theory-specific mechanisms produced a measurable
retrieval gain**: the tag is inert by construction, routing by tag and the
goal bonus made things worse, importance and source-dependent decay are
indistinguishable from zero or from noise, and the only *positive* result that survives the
multiplicity correction on a theory-adjacent variant is a small effect from
adding one hyperedge per session on a *secondary* metric. The result does not
show that the ideas are wrong; it shows that this benchmark, this
implementation and these variants give them no measurable credit (§5.6, §5.7).

### 5.2 What was run

* Data: `longmemeval_s_cleaned.json` (sha256 prefix `d6f21ea9d60a`), 500
  questions, 419 evaluable under the official protocol (30 abstention + 51
  with no user-side evidence excluded; 58 empty-text turns fail to ingest, as
  in the baseline). Store: fresh in-memory `Store` per question, built-in
  `lexical_hash` embedder, product default weights unless a variant says
  otherwise.
* Matrix (39 variants at session level, 40 at turn level): `A` plus an `A_rerun`
  noise-floor run; `B`; `C_form`, `C_spirit`; `D_s1–5`; `E_filter`, `E_boost`; the same two
  routers on `D_s1–5`; `F_on`, `F_off`; `G_flat`; `R_off`; `G_heur_on`,
  `G_heur_off`; `H_off`; `H_edges` (turn only); `I_dense`, `I_bm25`; `J_A`,
  `J_B`, `J_C_spirit`, `J_D_s1–5` = 79 runs. Driver:
  `scripts/lme_ablation_run.sh` (4 in parallel); tables: `scripts/lme_ablation_report.py`
  → `mem3-bench lme-compare` (bootstrap in `src/eval/paired_stats.zig`, tested).
* Wall time: the sum of per-run wall times is **7,709 s** (session 3,779 s,
  turn 3,930 s, i.e. roughly 60–150 s per run) on a host whose load average was
  50–140 on 10 cores, so these are upper bounds. The same default session run
  took **17.9 s** on a quieter moment (`time`, user 16.75 s) and the default
  turn run about 90 s.
* **Default parity with `main` (verified, byte for byte where it can be).**
  `main` (`61aa2fc`, after the HNSW and translation merges) was exported with
  `git archive main` into a clean directory, built there, and run with the same
  data and arguments as this branch's default variant A
  (`longmemeval-official --granularity=… --dump-rankings=…`, 419 questions):

  | Comparison | Result |
  |---|---|
  | session, main vs branch A | `cmp`: **byte-identical** whole-ranking dumps; identical `counts`/`results` |
  | turn, main vs branch A, default (both runs of each) | whole rankings differ in 11 of 419 questions, **first difference at rank 105–180**; first 100 ranks identical in all 6 pairs; `results` identical |
  | turn, main vs main (two runs of the same binary) | differ in 15 of 419, first difference at rank 106: **the same binary does not reproduce itself** |
  | turn, branch vs branch (two runs) | differ in 11 of 419, first difference at rank 105 |
  | turn, recency disabled in both (scratch copy of `main` with one line `store.lc.cfg.recency_bonus_weight = 0` added to its harness, vs the branch's `--recency-bonus-weight=0`), 2 × 2 pairs | **`cmp`: byte-identical** whole-ranking dumps for all four pairs |
  | the earlier recorded turn dump (`rank_s_turn_hybrid.jsonl`, pre-HNSW-merge) vs branch default | 12 of 419 differ, first difference at rank 186 |

  The turn-level dumps differ from run to run in **every** pairing, including
  main against itself, so that is not a change the branch introduced.
* **Cause of the run-to-run difference (found).** The recency factor
  `1 + 0.2·exp(−λ·age)` reads the wall clock: cells ingested in different
  milliseconds get ages that differ by milliseconds, and where the fused base
  score is exactly tied (the deep tail of a 244-document turn corpus) that
  sub-millisecond-scale difference orders the tied cells, with the order
  depending on where millisecond boundaries fall in each run. Evidence: with the
  recency weight 0, two runs are byte-identical across all 419 questions; with
  simulated, fixed `created_at` (variant J_A), two runs are also byte-identical;
  and the four recency-off `main`/branch dumps are mutually byte-identical. The
  effect is confined to float-near-ties beyond rank ~100 here; metrics `@1…@50`
  and the `results` blocks were identical in every pair. Consequence for this
  study: the `identical rankings` column hashes only the first 50 ranked ids
  (post-hoc, §5.9), and its noise floor is `A_rerun` vs `A`: 417/419 identical
  at session level and 419/419 at turn level, with all metric deltas exactly 0.
  I did not change the product: removing the wall-clock dependence (e.g. by
  tie-breaking on cell id) would be a behaviour change and is out of scope.
* **Sanity switches behave:** `F_off`, `G_flat`, `R_off`, `A_rerun` have Δ
  exactly 0 on every metric at every level (P2 confirmed). `F_off` differs from
  `A` in the order of float-near-tied ranks for 68 session questions without
  moving any metric; the same wall-clock effect (goal creation makes ingestion
  slower, so millisecond boundaries fall elsewhere) is the likely cause, but I
  did not test it for this pair.
* Cross-check: the Zig bootstrap agrees with an independent numpy
  implementation to 1e-6 on every mean and to < 0.003 on every CI end for the
  12 comparisons tested (table at the end of §5.3). Metric implementations are
  the existing, officially cross-checked ones (`scripts/lme_official_crosscheck.py`).

### 5.3 Full tables (generated by `scripts/lme_ablation_report.py`)

Columns: `improved/worsened/same` counts questions whose NDCG@10 moved by more
than 5e-9; `identical rankings` counts questions whose first 50 ranked ids
are byte-identical across the compared files (all files, for pooled arms).
Per-type rows are exploratory and uncorrected.

#### 5.3a Session granularity (document = session)

| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 | improved/worsened/same (NDCG@10) | identical rankings | verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | B − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| 2 | C_form − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 417 | bounded null (CI inside ±0.01) |
| 3 | C_spirit − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 417 | bounded null (CI inside ±0.01) |
| 4 | D − A (5 seeds pooled) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 416 | bounded null (CI inside ±0.01) |
| 5 | B − D (5 seeds pooled) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 416 | bounded null (CI inside ±0.01) |
| 6 | E_filter − A | -0.7538 | [-0.7850, -0.7199] | [-0.8013, -0.7011] | -0.7351 / -0.8425 / -0.7566 | 3/377/39 | 0 | HARM (survives Bonferroni) |
| 7 | E_boost − A | -0.0525 | [-0.0622, -0.0435] | [-0.0675, -0.0392] | -0.0811 / -0.0167 / -0.0048 | 1/132/286 | 0 | HARM (survives Bonferroni) |
| 8 | E_filter − E_filter_rand | -0.2187 | [-0.2416, -0.1947] | [-0.2550, -0.1801] | -0.3241 / -0.3709 / -0.3566 | 31/353/35 | 0 | HARM (survives Bonferroni) |
| 9 | E_boost − E_boost_rand | -0.0093 | [-0.0191, +0.0006] | [-0.0254, +0.0064] | -0.0363 / +0.0010 / -0.0095 | 111/134/174 | 0 | no detectable effect |
| 10 | F_on − F_off | -0.0138 | [-0.0209, -0.0070] | [-0.0246, -0.0035] | -0.0692 / -0.0024 / +0.0000 | 14/48/357 | 222 | HARM (survives Bonferroni) |
| 11 | F_on − A | -0.0138 | [-0.0209, -0.0070] | [-0.0246, -0.0035] | -0.0692 / -0.0024 / +0.0000 | 14/48/357 | 186 | HARM (survives Bonferroni) |
| 12 | G_heur_on − G_heur_off | +0.0046 | [+0.0012, +0.0082] | [-0.0008, +0.0103] | +0.0072 / +0.0024 / +0.0000 | 39/3/377 | 0 | gain (does not survive Bonferroni) |
| 13 | H_off − A | -0.0000 | [-0.0001, +0.0000] | [-0.0001, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/1/418 | 21 | bounded null (CI inside ±0.01) |
| 15 | I_dense − A | -0.2483 | [-0.2756, -0.2205] | [-0.2905, -0.2067] | -0.3246 / -0.1599 / -0.0835 | 13/255/151 | 0 | HARM (survives Bonferroni) |
| 16 | I_bm25 − A | +0.0055 | [-0.0053, +0.0160] | [-0.0117, +0.0215] | +0.0000 / -0.0024 / -0.0024 | 61/41/317 | 0 | no detectable effect |
| 17 | J_A − A | +0.0035 | [-0.0006, +0.0080] | [-0.0029, +0.0105] | +0.0024 / +0.0000 / +0.0048 | 28/20/371 | 30 | bounded null (CI inside ±0.01) |
| 18 | J_B − J_A | +0.0006 | [-0.0030, +0.0039] | [-0.0050, +0.0055] | +0.0048 / +0.0048 / -0.0024 | 32/16/371 | 33 | bounded null (CI inside ±0.01) |
| 19 | J_C_spirit − J_A | -0.0023 | [-0.0056, +0.0007] | [-0.0077, +0.0020] | +0.0000 / +0.0000 / -0.0024 | 16/21/382 | 37 | bounded null (CI inside ±0.01) |
| 20 | J_B − J_D (5 seeds pooled) | +0.0044 | [+0.0015, +0.0075] | [-0.0001, +0.0091] | +0.0076 / +0.0038 / +0.0000 | 58/29/332 | 25 | gain (does not survive Bonferroni) |

Sanity (expected exactly 0, identical rankings = 419):

| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 | improved/worsened/same (NDCG@10) | identical rankings | verdict |
|---|---|---|---|---|---|---|---|---|
| S1 | F_off − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 351 | bounded null (CI inside ±0.01) |
| S2 | G_flat − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| S3 | R_off − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 417 | bounded null (CI inside ±0.01) |
| S4 | A_rerun − A (noise floor) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 417 | bounded null (CI inside ±0.01) |

#### 5.3b Turn granularity (document = user turn), turn-level metrics

| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 | improved/worsened/same (NDCG@10) | identical rankings | verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | B − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 419 | bounded null (CI inside ±0.01) |
| 2 | C_form − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| 3 | C_spirit − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| 4 | D − A (5 seeds pooled) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 415 | bounded null (CI inside ±0.01) |
| 5 | B − D (5 seeds pooled) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 415 | bounded null (CI inside ±0.01) |
| 6 | E_filter − A | -0.3856 | [-0.4238, -0.3472] | [-0.4413, -0.3217] | -0.2530 / -0.4153 / -0.4368 | 38/274/107 | 0 | HARM (survives Bonferroni) |
| 7 | E_boost − A | -0.0766 | [-0.0927, -0.0609] | [-0.1020, -0.0526] | -0.0907 / -0.0597 / -0.0191 | 44/174/201 | 0 | HARM (survives Bonferroni) |
| 8 | E_filter − E_filter_rand | -0.1264 | [-0.1616, -0.0900] | [-0.1802, -0.0696] | -0.1212 / -0.1909 / -0.1957 | 126/247/46 | 0 | HARM (survives Bonferroni) |
| 9 | E_boost − E_boost_rand | -0.0217 | [-0.0362, -0.0075] | [-0.0440, -0.0004] | -0.0372 / -0.0267 / +0.0010 | 131/161/127 | 0 | HARM (survives Bonferroni) |
| 10 | F_on − F_off | -0.0225 | [-0.0354, -0.0095] | [-0.0420, -0.0024] | -0.0358 / +0.0119 / +0.0048 | 46/132/241 | 56 | HARM (survives Bonferroni) |
| 11 | F_on − A | -0.0225 | [-0.0354, -0.0095] | [-0.0420, -0.0024] | -0.0358 / +0.0119 / +0.0048 | 46/132/241 | 55 | HARM (survives Bonferroni) |
| 12 | G_heur_on − G_heur_off | -0.0010 | [-0.0085, +0.0060] | [-0.0132, +0.0097] | +0.0095 / -0.0024 / +0.0000 | 64/45/310 | 0 | bounded null (CI inside ±0.01) |
| 13 | H_off − A | +0.0013 | [-0.0022, +0.0049] | [-0.0041, +0.0073] | +0.0000 / +0.0000 / +0.0024 | 8/6/405 | 3 | bounded null (CI inside ±0.01) |
| 14 | H_edges − A | +0.0020 | [-0.0009, +0.0053] | [-0.0025, +0.0076] | +0.0000 / +0.0000 / +0.0024 | 7/5/407 | 0 | bounded null (CI inside ±0.01) |
| 15 | I_dense − A | -0.2115 | [-0.2380, -0.1851] | [-0.2549, -0.1709] | -0.1575 / -0.2196 / -0.1790 | 18/239/162 | 0 | HARM (survives Bonferroni) |
| 16 | I_bm25 − A | +0.0116 | [+0.0008, +0.0217] | [-0.0054, +0.0267] | +0.0215 / +0.0119 / +0.0000 | 92/55/272 | 0 | gain (does not survive Bonferroni) |
| 17 | J_A − A | -0.0060 | [-0.0112, -0.0014] | [-0.0144, +0.0005] | -0.0024 / -0.0095 / -0.0048 | 22/41/356 | 14 | harm (does not survive Bonferroni) |
| 18 | J_B − J_A | +0.0006 | [-0.0039, +0.0052] | [-0.0069, +0.0078] | +0.0024 / +0.0000 / +0.0000 | 36/28/355 | 19 | bounded null (CI inside ±0.01) |
| 19 | J_C_spirit − J_A | +0.0028 | [-0.0012, +0.0074] | [-0.0034, +0.0105] | -0.0072 / +0.0024 / +0.0048 | 33/19/367 | 11 | bounded null (CI inside ±0.01) |
| 20 | J_B − J_D (5 seeds pooled) | +0.0006 | [-0.0035, +0.0049] | [-0.0059, +0.0068] | +0.0067 / -0.0000 / -0.0010 | 64/57/298 | 12 | bounded null (CI inside ±0.01) |

Sanity (expected exactly 0, identical rankings = 419):

| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 | improved/worsened/same (NDCG@10) | identical rankings | verdict |
|---|---|---|---|---|---|---|---|---|
| S1 | F_off − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 406 | bounded null (CI inside ±0.01) |
| S2 | G_flat − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 419 | bounded null (CI inside ±0.01) |
| S3 | R_off − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| S4 | A_rerun − A (noise floor) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 419 | bounded null (CI inside ±0.01) |

#### 5.3c Turn granularity, session-derived metrics (max over a session's turns)

| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 | improved/worsened/same (NDCG@10) | identical rankings | verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | B − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 419 | bounded null (CI inside ±0.01) |
| 2 | C_form − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| 3 | C_spirit − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| 4 | D − A (5 seeds pooled) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 415 | bounded null (CI inside ±0.01) |
| 5 | B − D (5 seeds pooled) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 415 | bounded null (CI inside ±0.01) |
| 6 | E_filter − A | -0.3879 | [-0.4260, -0.3495] | [-0.4435, -0.3236] | -0.2530 / -0.4248 / -0.4415 | 39/278/102 | 0 | HARM (survives Bonferroni) |
| 7 | E_boost − A | -0.0724 | [-0.0883, -0.0572] | [-0.0967, -0.0488] | -0.0907 / -0.0597 / -0.0191 | 45/175/199 | 0 | HARM (survives Bonferroni) |
| 8 | E_filter − E_filter_rand | -0.1277 | [-0.1629, -0.0909] | [-0.1812, -0.0712] | -0.1212 / -0.1943 / -0.2005 | 128/247/44 | 0 | HARM (survives Bonferroni) |
| 9 | E_boost − E_boost_rand | -0.0243 | [-0.0380, -0.0107] | [-0.0451, -0.0038] | -0.0372 / -0.0248 / -0.0095 | 126/169/124 | 0 | HARM (survives Bonferroni) |
| 10 | F_on − F_off | -0.0224 | [-0.0352, -0.0094] | [-0.0419, -0.0022] | -0.0358 / +0.0215 / +0.0024 | 46/132/241 | 56 | HARM (survives Bonferroni) |
| 11 | F_on − A | -0.0224 | [-0.0352, -0.0094] | [-0.0419, -0.0022] | -0.0358 / +0.0215 / +0.0024 | 46/132/241 | 55 | HARM (survives Bonferroni) |
| 12 | G_heur_on − G_heur_off | +0.0002 | [-0.0072, +0.0070] | [-0.0119, +0.0105] | +0.0095 / -0.0024 / +0.0024 | 69/49/301 | 0 | bounded null (CI inside ±0.01) |
| 13 | H_off − A | +0.0054 | [+0.0017, +0.0095] | [-0.0003, +0.0118] | +0.0000 / -0.0024 / +0.0095 | 22/17/380 | 3 | gain (does not survive Bonferroni) |
| 14 | H_edges − A | +0.0076 | [+0.0043, +0.0115] | [+0.0028, +0.0137] | +0.0000 / +0.0000 / +0.0119 | 23/14/382 | 0 | GAIN (survives Bonferroni) |
| 15 | I_dense − A | -0.2036 | [-0.2309, -0.1774] | [-0.2446, -0.1635] | -0.1575 / -0.2172 / -0.1551 | 21/246/152 | 0 | HARM (survives Bonferroni) |
| 16 | I_bm25 − A | +0.0178 | [+0.0073, +0.0277] | [+0.0019, +0.0325] | +0.0215 / +0.0167 / +0.0167 | 110/53/256 | 0 | GAIN (survives Bonferroni) |
| 17 | J_A − A | -0.0042 | [-0.0090, -0.0000] | [-0.0120, +0.0020] | -0.0024 / +0.0000 / +0.0000 | 23/41/355 | 14 | harm (does not survive Bonferroni) |
| 18 | J_B − J_A | +0.0002 | [-0.0040, +0.0045] | [-0.0060, +0.0069] | +0.0024 / -0.0024 / +0.0024 | 39/31/349 | 19 | bounded null (CI inside ±0.01) |
| 19 | J_C_spirit − J_A | +0.0007 | [-0.0029, +0.0049] | [-0.0048, +0.0074] | -0.0072 / -0.0024 / +0.0000 | 32/21/366 | 11 | bounded null (CI inside ±0.01) |
| 20 | J_B − J_D (5 seeds pooled) | +0.0007 | [-0.0031, +0.0047] | [-0.0053, +0.0067] | +0.0067 / +0.0014 / +0.0029 | 65/59/295 | 12 | bounded null (CI inside ±0.01) |

Sanity (expected exactly 0, identical rankings = 419):

| # | comparison (variant − base) | ΔNDCG@10 | 95 % CI | Bonferroni CI (m=20) | ΔR_any@1 / @5 / @10 | improved/worsened/same (NDCG@10) | identical rankings | verdict |
|---|---|---|---|---|---|---|---|---|
| S1 | F_off − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 406 | bounded null (CI inside ±0.01) |
| S2 | G_flat − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 419 | bounded null (CI inside ±0.01) |
| S3 | R_off − A | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 418 | bounded null (CI inside ±0.01) |
| S4 | A_rerun − A (noise floor) | +0.0000 | [+0.0000, +0.0000] | [+0.0000, +0.0000] | +0.0000 / +0.0000 / +0.0000 | 0/0/419 | 419 | bounded null (CI inside ±0.01) |

#### 5.3d Exploratory: per-`question_type` ΔNDCG@10 (95 % CI, unadjusted)

**session**

| # | comparison | knowledge-update (n=72) | multi-session (n=121) | single-session-assistant (n=5) | single-session-preference (n=30) | single-session-user (n=64) | temporal-reasoning (n=127) |
|---|---|---|---|---|---|---|---|
| 1 | B − A | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 2 | C_form − A | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 3 | C_spirit − A | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 4 | D − A (5 seeds pooled) | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 5 | B − D (5 seeds pooled) | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 6 | E_filter − A | -0.861 [-0.915, -0.796] | -0.699 [-0.753, -0.642] | -0.400 [-0.800, +0.000] | -0.422 [-0.598, -0.244] | -0.863 [-0.929, -0.791] | -0.783 [-0.835, -0.727] |
| 7 | E_boost − A | -0.032 [-0.049, -0.017] | -0.086 [-0.103, -0.069] | +0.000 [+0.000, +0.000] | -0.011 [-0.024, -0.001] | -0.024 [-0.050, -0.004] | -0.059 [-0.080, -0.039] |
| 8 | E_filter − E_filter_rand | -0.237 [-0.286, -0.184] | -0.228 [-0.267, -0.186] | -0.043 [-0.450, +0.368] | -0.122 [-0.231, -0.005] | -0.165 [-0.238, -0.090] | -0.256 [-0.291, -0.219] |
| 9 | E_boost − E_boost_rand | +0.005 [-0.011, +0.020] | -0.030 [-0.048, -0.012] | -0.073 [-0.263, +0.044] | +0.023 [-0.021, +0.067] | +0.010 [-0.009, +0.031] | -0.012 [-0.032, +0.009] |
| 10 | F_on − F_off | -0.010 [-0.023, +0.000] | -0.012 [-0.026, +0.003] | +0.000 [+0.000, +0.000] | -0.001 [-0.004, +0.000] | -0.006 [-0.017, +0.000] | -0.025 [-0.041, -0.010] |
| 11 | F_on − A | -0.010 [-0.023, +0.000] | -0.012 [-0.026, +0.003] | +0.000 [+0.000, +0.000] | -0.001 [-0.004, +0.000] | -0.006 [-0.017, +0.000] | -0.025 [-0.041, -0.010] |
| 12 | G_heur_on − G_heur_off | +0.003 [+0.000, +0.008] | +0.008 [+0.001, +0.014] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.006 [-0.003, +0.016] |
| 13 | H_off − A | +0.000 [+0.000, +0.000] | -0.000 [-0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 15 | I_dense − A | -0.201 [-0.252, -0.152] | -0.244 [-0.285, -0.204] | -0.314 [-0.714, +0.000] | -0.193 [-0.313, -0.074] | -0.264 [-0.353, -0.180] | -0.282 [-0.338, -0.225] |
| 16 | I_bm25 − A | +0.007 [-0.003, +0.020] | +0.013 [-0.004, +0.029] | +0.100 [+0.000, +0.300] | +0.030 [-0.036, +0.094] | -0.009 [-0.029, +0.004] | -0.004 [-0.030, +0.018] |
| 17 | J_A − A | -0.003 [-0.016, +0.008] | +0.002 [-0.005, +0.010] | +0.063 [+0.000, +0.189] | +0.002 [-0.003, +0.008] | -0.001 [-0.003, +0.000] | +0.009 [+0.001, +0.019] |
| 18 | J_B − J_A | +0.000 [-0.006, +0.006] | +0.004 [-0.002, +0.011] | -0.063 [-0.189, +0.000] | -0.002 [-0.008, +0.003] | +0.001 [+0.000, +0.003] | -0.000 [-0.008, +0.006] |
| 19 | J_C_spirit − J_A | -0.003 [-0.011, +0.003] | -0.000 [-0.006, +0.006] | -0.063 [-0.189, +0.000] | -0.002 [-0.008, +0.003] | +0.001 [+0.000, +0.003] | -0.003 [-0.011, +0.001] |
| 20 | J_B − J_D (5 seeds pooled) | -0.001 [-0.007, +0.003] | +0.005 [+0.000, +0.010] | -0.036 [-0.108, +0.000] | +0.008 [-0.004, +0.024] | +0.000 [+0.000, +0.001] | +0.010 [+0.003, +0.017] |

**turn**

| # | comparison | knowledge-update (n=72) | multi-session (n=121) | single-session-assistant (n=5) | single-session-preference (n=30) | single-session-user (n=64) | temporal-reasoning (n=127) |
|---|---|---|---|---|---|---|---|
| 1 | B − A | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 2 | C_form − A | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 3 | C_spirit − A | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 4 | D − A (5 seeds pooled) | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 5 | B − D (5 seeds pooled) | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |
| 6 | E_filter − A | -0.440 [-0.524, -0.358] | -0.277 [-0.337, -0.221] | -0.185 [-0.600, +0.045] | -0.119 [-0.230, -0.029] | -0.484 [-0.607, -0.362] | -0.479 [-0.552, -0.406] |
| 7 | E_boost − A | -0.039 [-0.071, -0.011] | -0.073 [-0.097, -0.049] | +0.015 [+0.000, +0.045] | -0.057 [-0.124, -0.006] | -0.069 [-0.126, -0.020] | -0.113 [-0.146, -0.081] |
| 8 | E_filter − E_filter_rand | -0.139 [-0.222, -0.056] | -0.093 [-0.142, -0.044] | +0.120 [-0.200, +0.480] | +0.022 [-0.073, +0.130] | -0.082 [-0.225, +0.060] | -0.219 [-0.278, -0.159] |
| 9 | E_boost − E_boost_rand | -0.003 [-0.032, +0.026] | -0.014 [-0.037, +0.009] | +0.080 [+0.000, +0.218] | +0.029 [-0.020, +0.084] | -0.036 [-0.086, +0.010] | -0.048 [-0.075, -0.021] |
| 10 | F_on − F_off | -0.042 [-0.069, -0.012] | -0.014 [-0.038, +0.009] | +0.055 [+0.000, +0.165] | +0.010 [-0.048, +0.065] | -0.003 [-0.018, +0.008] | -0.040 [-0.067, -0.011] |
| 11 | F_on − A | -0.042 [-0.069, -0.012] | -0.014 [-0.038, +0.009] | +0.055 [+0.000, +0.165] | +0.010 [-0.048, +0.065] | -0.003 [-0.018, +0.008] | -0.040 [-0.067, -0.011] |
| 12 | G_heur_on − G_heur_off | -0.002 [-0.011, +0.005] | +0.004 [-0.006, +0.015] | -0.111 [-0.311, +0.000] | -0.005 [-0.037, +0.019] | -0.015 [-0.044, +0.008] | +0.007 [-0.007, +0.020] |
| 13 | H_off − A | +0.000 [+0.000, +0.000] | +0.001 [-0.004, +0.007] | +0.000 [+0.000, +0.000] | +0.027 [+0.000, +0.062] | -0.005 [-0.014, +0.000] | -0.001 [-0.008, +0.004] |
| 14 | H_edges − A | +0.000 [+0.000, +0.000] | +0.003 [-0.002, +0.008] | +0.000 [+0.000, +0.000] | +0.027 [+0.000, +0.062] | -0.005 [-0.014, +0.000] | -0.000 [-0.000, +0.000] |
| 15 | I_dense − A | -0.159 [-0.210, -0.111] | -0.186 [-0.224, -0.151] | -0.271 [-0.671, +0.000] | -0.162 [-0.286, -0.052] | -0.204 [-0.293, -0.123] | -0.278 [-0.331, -0.224] |
| 16 | I_bm25 − A | +0.009 [-0.007, +0.026] | +0.030 [+0.013, +0.048] | +0.000 [+0.000, +0.000] | +0.004 [-0.019, +0.028] | -0.020 [-0.062, +0.012] | +0.014 [-0.006, +0.034] |
| 17 | J_A − A | -0.006 [-0.016, +0.003] | -0.005 [-0.013, +0.002] | -0.074 [-0.221, +0.000] | -0.003 [-0.035, +0.022] | -0.013 [-0.034, +0.000] | -0.001 [-0.006, +0.003] |
| 18 | J_B − J_A | -0.002 [-0.014, +0.010] | +0.006 [-0.001, +0.013] | -0.011 [-0.033, +0.000] | -0.009 [-0.022, +0.001] | +0.003 [-0.015, +0.019] | -0.001 [-0.009, +0.006] |
| 19 | J_C_spirit − J_A | -0.004 [-0.013, +0.002] | +0.005 [-0.002, +0.013] | +0.000 [+0.000, +0.000] | +0.009 [-0.011, +0.038] | +0.013 [+0.000, +0.034] | -0.002 [-0.007, +0.001] |
| 20 | J_B − J_D (5 seeds pooled) | +0.000 [-0.011, +0.012] | +0.001 [-0.005, +0.007] | -0.007 [-0.021, +0.000] | -0.003 [-0.009, +0.001] | -0.003 [-0.018, +0.010] | +0.004 [-0.005, +0.011] |

#### 5.3e Seed-to-seed spread of the random-tag families (overall NDCG@10 per seed; Δ = seed − reference arm)

| level | family | reference | reference NDCG@10 | per-seed NDCG@10 | per-seed Δ | range of Δ |
|---|---|---|---|---|---|---|
| session | D | A | 0.8531 | 0.8531, 0.8531, 0.8531, 0.8531, 0.8531 | +0.0000, +0.0000, +0.0000, +0.0000, +0.0000 | +0.0000 … +0.0000 |
| session | E_filter_rand | E_filter | 0.0993 | 0.3100, 0.3244, 0.3083, 0.3213, 0.3261 | +0.2107, +0.2251, +0.2090, +0.2219, +0.2268 | +0.2090 … +0.2268 |
| session | E_boost_rand | E_boost | 0.8006 | 0.8080, 0.8140, 0.8085, 0.8048, 0.8141 | +0.0074, +0.0134, +0.0079, +0.0042, +0.0135 | +0.0042 … +0.0135 |
| session | J_D | J_B | 0.8573 | 0.8560, 0.8514, 0.8525, 0.8502, 0.8539 | -0.0012, -0.0058, -0.0047, -0.0071, -0.0033 | -0.0071 … -0.0012 |
| turn | D | A | 0.6466 | 0.6466, 0.6466, 0.6466, 0.6466, 0.6466 | +0.0000, +0.0000, +0.0000, +0.0000, +0.0000 | +0.0000 … +0.0000 |
| turn | E_filter_rand | E_filter | 0.2610 | 0.3772, 0.3924, 0.3646, 0.4002, 0.4027 | +0.1162, +0.1314, +0.1036, +0.1392, +0.1417 | +0.1036 … +0.1417 |
| turn | E_boost_rand | E_boost | 0.5701 | 0.5919, 0.5944, 0.5806, 0.5940, 0.5980 | +0.0219, +0.0243, +0.0106, +0.0240, +0.0279 | +0.0106 … +0.0279 |
| turn | J_D | J_B | 0.6412 | 0.6396, 0.6431, 0.6394, 0.6394, 0.6416 | -0.0016, +0.0018, -0.0019, -0.0019, +0.0003 | -0.0019 … +0.0018 |

#### 5.3f Absolute overall values and wall time per run

| level | run | R_any@1 | R_any@5 | R_any@10 | NDCG@10 | wall s |
|---|---|---|---|---|---|---|
| session | A | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 83 |
| session | A_rerun | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 80 |
| session | B | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 83 |
| session | C_form | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 81 |
| session | C_spirit | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 69 |
| session | D_s1 | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 70 |
| session | D_s2 | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 71 |
| session | D_s3 | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 70 |
| session | D_s4 | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 81 |
| session | D_s5 | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 81 |
| session | E_filter | 0.0668 | 0.0955 | 0.2005 | 0.0993 | 79 |
| session | E_boost | 0.7208 | 0.9212 | 0.9523 | 0.8006 | 79 |
| session | E_filter_rand_s1 | 0.3890 | 0.4726 | 0.5680 | 0.3100 | 64 |
| session | E_filter_rand_s2 | 0.3771 | 0.4726 | 0.5465 | 0.3244 | 66 |
| session | E_filter_rand_s3 | 0.3866 | 0.4487 | 0.5394 | 0.3083 | 110 |
| session | E_filter_rand_s4 | 0.4010 | 0.4702 | 0.5632 | 0.3213 | 108 |
| session | E_filter_rand_s5 | 0.4010 | 0.4678 | 0.5680 | 0.3261 | 105 |
| session | E_boost_rand_s1 | 0.7613 | 0.9284 | 0.9594 | 0.8080 | 67 |
| session | E_boost_rand_s2 | 0.7542 | 0.9284 | 0.9642 | 0.8140 | 69 |
| session | E_boost_rand_s3 | 0.7589 | 0.9165 | 0.9594 | 0.8085 | 110 |
| session | E_boost_rand_s4 | 0.7518 | 0.9165 | 0.9594 | 0.8048 | 110 |
| session | E_boost_rand_s5 | 0.7589 | 0.9117 | 0.9666 | 0.8141 | 105 |
| session | F_on | 0.7327 | 0.9356 | 0.9570 | 0.8393 | 109 |
| session | F_off | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 107 |
| session | G_flat | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 101 |
| session | R_off | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 97 |
| session | G_heur_on | 0.8091 | 0.9403 | 0.9570 | 0.8578 | 104 |
| session | G_heur_off | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 105 |
| session | H_off | 0.8019 | 0.9379 | 0.9570 | 0.8531 | 107 |
| session | I_dense | 0.4773 | 0.7780 | 0.8735 | 0.6049 | 108 |
| session | I_bm25 | 0.8019 | 0.9356 | 0.9547 | 0.8586 | 106 |
| session | J_A | 0.8043 | 0.9379 | 0.9618 | 0.8567 | 108 |
| session | J_B | 0.8091 | 0.9427 | 0.9594 | 0.8573 | 118 |
| session | J_C_spirit | 0.8043 | 0.9379 | 0.9594 | 0.8544 | 115 |
| session | J_D_s1 | 0.8019 | 0.9403 | 0.9618 | 0.8560 | 126 |
| session | J_D_s2 | 0.8019 | 0.9379 | 0.9618 | 0.8514 | 122 |
| session | J_D_s3 | 0.8019 | 0.9356 | 0.9594 | 0.8525 | 135 |
| session | J_D_s4 | 0.7995 | 0.9379 | 0.9570 | 0.8502 | 139 |
| session | J_D_s5 | 0.8019 | 0.9427 | 0.9570 | 0.8539 | 131 |
| turn | A | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 82 |
| turn | A_rerun | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 82 |
| turn | B | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 83 |
| turn | C_form | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 82 |
| turn | C_spirit | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 64 |
| turn | D_s1 | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 66 |
| turn | D_s2 | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 65 |
| turn | D_s3 | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 62 |
| turn | D_s4 | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 96 |
| turn | D_s5 | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 95 |
| turn | E_filter | 0.2721 | 0.4010 | 0.4368 | 0.2610 | 95 |
| turn | E_boost | 0.4344 | 0.7566 | 0.8544 | 0.5701 | 94 |
| turn | E_filter_rand_s1 | 0.3652 | 0.5800 | 0.6229 | 0.3772 | 103 |
| turn | E_filter_rand_s2 | 0.3819 | 0.5967 | 0.6301 | 0.3924 | 103 |
| turn | E_filter_rand_s3 | 0.3962 | 0.5704 | 0.6134 | 0.3646 | 61 |
| turn | E_filter_rand_s4 | 0.4272 | 0.5990 | 0.6372 | 0.4002 | 61 |
| turn | E_filter_rand_s5 | 0.3962 | 0.6134 | 0.6587 | 0.4027 | 78 |
| turn | E_boost_rand_s1 | 0.4606 | 0.7852 | 0.8640 | 0.5919 | 103 |
| turn | E_boost_rand_s2 | 0.4630 | 0.7804 | 0.8425 | 0.5944 | 102 |
| turn | E_boost_rand_s3 | 0.4869 | 0.7637 | 0.8425 | 0.5806 | 61 |
| turn | E_boost_rand_s4 | 0.4940 | 0.7995 | 0.8568 | 0.5940 | 61 |
| turn | E_boost_rand_s5 | 0.4535 | 0.7876 | 0.8616 | 0.5980 | 78 |
| turn | F_on | 0.4893 | 0.8282 | 0.8783 | 0.6242 | 77 |
| turn | F_off | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 77 |
| turn | G_flat | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 78 |
| turn | R_off | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 78 |
| turn | G_heur_on | 0.5346 | 0.8138 | 0.8735 | 0.6457 | 80 |
| turn | G_heur_off | 0.5251 | 0.8162 | 0.8735 | 0.6466 | 79 |
| turn | H_off | 0.5251 | 0.8162 | 0.8759 | 0.6479 | 120 |
| turn | H_edges | 0.5251 | 0.8162 | 0.8759 | 0.6487 | 120 |
| turn | I_dense | 0.3675 | 0.5967 | 0.6945 | 0.4352 | 119 |
| turn | I_bm25 | 0.5465 | 0.8282 | 0.8735 | 0.6582 | 120 |
| turn | J_A | 0.5227 | 0.8067 | 0.8687 | 0.6406 | 148 |
| turn | J_B | 0.5251 | 0.8067 | 0.8687 | 0.6412 | 152 |
| turn | J_C_spirit | 0.5155 | 0.8091 | 0.8735 | 0.6434 | 148 |
| turn | J_D_s1 | 0.5155 | 0.8019 | 0.8687 | 0.6396 | 152 |
| turn | J_D_s2 | 0.5203 | 0.8115 | 0.8687 | 0.6431 | 152 |
| turn | J_D_s3 | 0.5179 | 0.8115 | 0.8735 | 0.6394 | 151 |
| turn | J_D_s4 | 0.5227 | 0.8019 | 0.8711 | 0.6394 | 151 |
| turn | J_D_s5 | 0.5155 | 0.8067 | 0.8663 | 0.6416 | 151 |

#### 5.3g Cross-check of the Zig bootstrap with an independent numpy implementation (primary ΔNDCG@10)

| level | comparison | Zig Δ | numpy Δ | Zig CI | numpy CI |
|---|---|---|---|---|---|
| session | B − A | +0.000000 | +0.000000 | [+0.00000, +0.00000] | [+0.00000, +0.00000] |
| session | D − A (5 seeds pooled) | +0.000000 | -0.000000 | [+0.00000, +0.00000] | [-0.00000, -0.00000] |
| session | E_filter − A | -0.753803 | -0.753803 | [-0.78502, -0.71985] | [-0.78506, -0.72021] |
| session | F_on − F_off | -0.013807 | -0.013807 | [-0.02093, -0.00705] | [-0.02066, -0.00686] |
| session | H_off − A | -0.000017 | -0.000017 | [-0.00005, +0.00000] | [-0.00005, +0.00000] |
| session | J_A − A | +0.003547 | +0.003547 | [-0.00057, +0.00802] | [-0.00066, +0.00802] |
| turn | B − A | +0.000000 | +0.000000 | [+0.00000, +0.00000] | [+0.00000, +0.00000] |
| turn | D − A (5 seeds pooled) | +0.000000 | -0.000000 | [+0.00000, +0.00000] | [-0.00000, -0.00000] |
| turn | E_filter − A | -0.385647 | -0.385647 | [-0.42381, -0.34722] | [-0.42514, -0.34732] |
| turn | F_on − F_off | -0.022487 | -0.022487 | [-0.03536, -0.00948] | [-0.03538, -0.00935] |
| turn | H_off − A | +0.001297 | +0.001297 | [-0.00220, +0.00491] | [-0.00224, +0.00491] |
| turn | J_A − A | -0.006011 | -0.006011 | [-0.01119, -0.00143] | [-0.01099, -0.00162] |

Cross-check agreement (means 1e-5, CI ends 0.003): **OK**



### 5.4 Reading the numbers, mechanism by mechanism

**Tag (B, C, D).** Exactly zero, and 415–418 identical rankings out of 419 is
the same as re-running the baseline. This is not a discovery about memory; it
confirms the inventory: the tag only reaches ranking through the recency
factor, and the factor is the same for every cell when all cells are
microseconds old. P1 held.

**Routing (E).** The heuristic tagger labels 61 % of session documents 性
(12,070 of 19,875; 29 % 物, 10 % 象; turn level: 57 % 物, 33 % 性, 10 % 象)
while the router predicts 物 for 383 of 419 questions (14 象, 22 性). A hard
partition therefore pushes most answer-bearing sessions below non-answer ones:
NDCG@10 falls from 0.853 to 0.099 at session level. The boost variant is
gentler but still negative. The more informative comparison is against the
**same router on shuffled tags** (`E_*_rand`, 5 seeds): real tags are worse
than random ones for the filter at both levels and for the boost at turn
level, so the tagger's labels carry *anti*-signal for this router. Why, I did
not test. A plausible mechanism (not verified) is that "physical" turns, as
this tagger defines them, are short and chatty while the answers live in
longer first-person statements.

**Goals (F).** Switching the bonus on for goals derived from each session's own
top-12 content words (relevance 1.0, the strongest setting) costs 1.4 NDCG
points at session level and 2.3 at turn level, with the loss concentrated in
`temporal-reasoning` (−0.025, −0.040) and `knowledge-update` at turn level
(−0.042). Mechanism, **hypothesis only**: `ghw.retrieve` picks one goal by
substring overlap and multiplies *all* of that session's cells by 1.4; when it
picks the wrong session, a distractor is boosted past the answer. I did not
measure how often the routed goal is an evidence session. This variant is the
most favourable derivation I could define without labels; a goal derivation
that used the answer would be circular.

**Importance (G).** The one nominal gain, +0.0046 at session level, comes from
giving documents the heuristic calls 性 an unexpired foresight (existential
term 0.2 → 1.0), i.e. a prior toward documents containing first-person intent
phrases. It does not replicate at turn level (−0.0010) or on the derived
metric (+0.0002), it fails the Bonferroni correction, and it needs a
harness-supplied foresight (the product never creates one from text). It is
not evidence for existence-gain.

**Hypergraph (H).** With no edges the graph arm is a flat bonus for the top
seeds and removing it is a no-op (session −0.00002; turn +0.0013, CI spans 0).
Adding one `associative` hyperedge per session (so a hit on one turn lifts its
siblings) gives +0.0020 on the pre-registered turn-level primary (not
distinguishable from zero) and +0.0076 on the secondary session-derived metric
(R_any@10 +0.0119). That is the expected direction of a session-grouping prior
for a session-level question, it is small, and the edges encode the benchmark's
own session boundaries rather than anything the theory would have to infer;
treat it as a modest, plausible, secondary result. Note that H_off is *also*
nominally positive at the session-derived level (+0.0054, adjusted CI
[−0.0003, +0.0118]), so the shipped no-edge graph arm is, if anything, not
helping.

**Decay (J).** Giving every cell a real age moves results by at most 0.6 points
and the sign depends on the level (J_A − A: +0.0035 session, −0.0060 turn). Making
that decay source-dependent (J_B vs J_A, J_C_spirit vs J_A, J_B vs J_D) is a
bounded null at turn level and at session level for J_B vs J_A and
J_C_spirit vs J_A; J_B vs J_D at session level is nominally +0.0044
(unadjusted CI excludes 0, adjusted CI does not).

**Reference arms.** `lexical_hash` alone (I_dense) is 21–25 NDCG points below
the hybrid; BM25 alone (I_bm25) is level with it at session level and slightly
ahead at turn level (+0.0116, session-derived +0.0178 surviving the correction).
On this benchmark the default fusion is not better than its sparse arm. That
is a statement about `lexical_hash` and the fusion weights, not about the
theory, and it was not what this study set out to test.

**Question types.** Nothing in the per-type tables contradicts the overall
reading except where it is already noted (goals hurt `temporal-reasoning`;
`single-session-assistant` has 5 questions and its intervals are meaningless).

### 5.5 Mechanisms with no effect on the ranking (checked, not assumed)

Confirmed by the inventory (§1) and by the sanity runs:

| Mechanism | Evidence |
|---|---|
| Tri-source tag, as a ranking input | B/C/D rank like A (§5.4) |
| `existenceContribution` / existence gain, as a retrieval signal | read only by the forgetting sweep; not run here; the reranker's "existence bonus" is plain `importance_score` (`G_flat` ≡ A) |
| Coherence `C_tri` | never read by the query path; its updater has no non-test caller |
| Spirit-dimension foresight as content | only reaches ranking through the importance term; never matched against queries |
| GHW layers | only produce the goal scope; with one goal, constant |
| Recency factor with microsecond-old cells | `R_off` ≡ A |
| Goal bonus with a single shared goal | `F_off` ≡ A (metrics) |

### 5.6 Threats to validity

1. **The benchmark has no notion of goals or sources.** LongMemEval asks
   "which session holds the evidence for this question". There are no
   labelled goals, no source types, no forgetting pressure, no multi-hop
   dependency between memories. A null here cannot distinguish *inert
   machinery* from *a yardstick that cannot reward it*. The tag is inert
   for a code reason (§1), but the verdicts on routing, goals and importance
   are verdicts on **my stand-ins**.
2. **The tagger is a crude lexical stand-in** for an LLM source tagger
   (§3.1), fixed before running. Its labels are not a gold standard; a better
   tagger might give a different E. D (shuffled tags) controls for the
   association, not for tagger quality.
3. **Goal derivation is lexical** and routed by the product's own substring
   matcher, in a store with one goal per haystack session (≈ 48 per question at session level, ≈ 5 000 sessions' worth of turns overall). Real goals would be
   fewer, semantically distinct and user-declared.
4. **The embedder is `lexical_hash`.** A semantic embedder changes the dense arm
   and everything fused with it; none of these numbers describe the external
   embedder path. The hybrid's own ceiling (0.853 NDCG@10 at session level) is
   an upper bound on what any rerank variant can add.
5. **Retrieval only.** No reader, no judge; nothing here says anything about
   answer accuracy. The reranker also only reorders the top `3·topk` fused
   candidates (found while building the synthetic check, §5.8), so a rerank
   cannot rescue an answer the fusion put deeper.
6. **Multiplicity and exploration.** 20 primary comparisons per level (adjusted
   CIs reported) but 3 levels, ~10 metric/type cuts per comparison; per-type
   rows are exploratory. A comparison that is nominally significant and does
   not survive the correction (G_heur session, J_B−J_D session, H_off derived,
   I_bm25 turn) should be read as noise-compatible.
7. **Dependence between variants.** All variants share the same 419 questions,
   so CIs for different comparisons are not independent; the correction is
   conservative for that, not exact.
8. **Wall-clock-dependent tie order in the unmodified store** (§5.2): the runs
   are not bit-reproducible deep in a turn-level ranking. Metrics up to @50 were
   identical across repeated baseline runs, but I have only two repeats at turn
   level for the dumps and one `A_rerun` per level for the scores.
9. **One host, one dataset variant** (S, cleaned). Not run on `oracle` or `M`,
   not run on Linux, not run through the HTTP/MCP surfaces (HTTP passes no goal
   ids, so the goal bonus would be dead there, §1).

### 5.7 What a benchmark that *would* reward these mechanisms looks like

Sketch only, not built; every item needs a gold label that LongMemEval lacks.

* **Goal-conditioned recall.** A multi-goal agent trace in which the *same
  surface fact* (same words) is relevant to different goals, and the query
  carries an explicit goal scope (not text-derived). Gold: the cell bound to the
  active goal. Metric: R_any@k vs the same store with goal bonus off, paired
  per query. Control: queries with the wrong goal scope must *lose* accuracy.
* **Source-conditioned recall.** Questions that are explicitly "what happened"
  (物), "how do I" (象), "what do I want" (性), with independently labelled
  gold sources and an unbalanced mix. Control: shuffled tags (D), as here.
* **Existence-gain forgetting under pressure.** A stream longer than a fixed
  capacity, followed by queries about items of known value; compare recall of
  high-value items after forgetting against LRU/TTL at equal capacity.
  This is the only place existence gain is a meaningful quantity.
* **Multi-hop over hyperedges.** Questions whose evidence is split across cells
  that only a hyperedge connects; compare with the no-edge store.
* **Protocol:** pre-registered variants, paired per-question deltas, bootstrap
  CIs, noise-floor re-runs, shuffled-label controls, all as in this study.

### 5.8 Small labelled-synthetic check (SYNTHETIC)

`mem3-bench lme-synthetic`. These two tasks are **constructed so the machinery
should win**; they check wiring end to end, not usefulness on real data.

| Check | Setup | Without | With | Chance |
|---|---|---|---|---|
| Goal-conditioned | 8 goals × 12 cells; the target phrase is identical across goals; the query names the goal | goal bonus off: **1/8** top-1 | goal bonus on: **8/8** | 1/8 |
| Source-routed | 10 topics × 3 cells with identical text and tags 物/象/性; the query carries an intent marker | no router: **2/10** top-1 | router on: **10/10** | ≈ 1/3 |

So the goal bonus and the tag do what they are coded to do. The real-data
runs show that doing it does not help LongMemEval. One by-product: queried at
`topk = 1`, the goal-conditioned check only reached **3/8**, because the
reranker sees only the `3·topk` best fused candidates and, among 96 cells with
identical text, the target was often outside them. The check is run at
`topk = 10`.

### 5.9 Post-hoc changes, deviations, and what was not verified

Post-hoc (all decided after seeing a number; none changes a variant
definition):

1. **`rank_hash` covers the first 50 ids**, not the whole ranking (§5.2:
   the unmodified store reorders ties beyond rank 100 between runs). A first
   partial pass (~49 runs) that used a whole-ranking hash was discarded and
   everything was rerun with the 50-id hash.
2. **`A_rerun`** (a second default run per level) and sanity row S4 were added
   as the noise floor.
3. **Delta snapping:** per-question deltas below 5e-9 are treated as 0 in
   `lme-compare`. Without it, averaging 5 equal 9-decimal values produced
   float-ulp "improved/worsened" counts in the pooled rows (D vs A showed
   5/32/382). Means and CIs are unaffected at the displayed precision.
4. **Phrase matching:** the apostrophe in the §3.1 phrases matches both `'` and
   U+2019 (`i'd like`, `i'm interested`).
5. **Flag names** are `--tags=`, `--goals=`, `--router=` … rather than the
   `--variant=…` spelling in §4.
6. **Numpy cross-check** and the per-seed spread table were added to the report.
7. **The synthetic goal check is run at `topk = 10`** (see §5.8).
8. **Verdict wording:** for CIs that exclude 0 only before the correction the
   report says "gain/harm (does not survive Bonferroni)"; the §3.3 rule is
   otherwise unchanged.
9. Two operational incidents: a run-script bug (`xargs -L 1` joined the line
   `turn A` to the next because of a trailing blank; fixed, output deleted) and
   `zig-out/bin` disappearing mid-matrix (not caused by any command of this
   task as far as I could tell; 51 runs failed with exit 127). The matrix was
   resumed from a copied binary (`BIN=`; finished runs are kept). The final
   tables therefore combine 28 turn runs from the pass that lost its binary
   with 51 runs from the resumed pass; both used the same harness source
   (the later rebuild changed only `lme-compare`'s delta snapping, which the
   runs do not use).

Not verified:

* Whether the `F_off`-vs-`A` rank-order differences are the same wall-clock effect (probable; not isolated).
* Why the goal bonus hurts (hypothesis in §5.4 untested), and why real tags
  route worse than shuffled ones.
* Any behaviour with an LLM tagger, a semantic embedder, user-declared goals,
  the HTTP/MCP surfaces, `oracle`/`M` data, or Linux.
* Reproducibility of wall times (host load was 50–140).

### 5.9a Addendum: `main` moved after the inventory (§1) was written

§1 was written against `d823358`. `main` has since merged write-time
**supersession** (`Config.supersede_mode`, default `.functional`,
`src/core/config.zig:107`): a new cell with the same subject+predicate as an
older live cell marks the older one `superseded_at`, and `Store.query` skips
such cells unless `include_superseded` is set (`src/store/store.zig:1555`,
`:1582`, `:1593`). That is a lifecycle mechanism **on the query path** that §1
does not list. It was **not ablated**: it keys on `atomic_facts` triples, and
the LongMemEval harness ingests every turn with empty facts, so no cell is ever
superseded (`superseded_live` stays 0) and it cannot move a ranking there. What
was re-checked on the merged tree: build, the three test roots, and the default
session ranking dump, which is byte-identical to the `main` export's. The 79
ablation runs themselves were produced by the pre-merge branch binary; the
merge changed neither the harness path nor (per the parity table in §5.2) its
rankings.

### 5.10 How to reproduce

```sh
zig build
LME_DATA=/tmp/mem3_lme_data/longmemeval_s_cleaned.json \
  scripts/lme_ablation_run.sh /tmp/mem3_abl_run 4        # 79 runs; ~35 min on a loaded 10-core host
python3 scripts/lme_ablation_report.py /tmp/mem3_abl_run > /tmp/mem3_abl_run/report.md
./zig-out/bin/mem3-bench lme-synthetic
```

Data and run output stay under `/tmp`; nothing is written in the repository.
