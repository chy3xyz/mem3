# ADR-0005: Existence-gain forgetting — redundancy, conflict, supersession

**Status**: Accepted (branch `p2/forget`) | **Date**: 2026-10-21 | **Constitution**: Principle III, PCR | **Spec**: FR-010, FR-015 | **Tasks**: T080, T083, T084 (partial)

## Context

The spec defines `net_existence = importance − redundancy − conflict_score`, with
`net_existence < 0` making a cell a forgetting candidate (FR-010), and conflict
resolution that marks the old fact `superseded_at = now` and never deletes it
(FR-015, PCR). The shipped forgetter implemented only
`importance × exp(−decay_rate × age_days) < threshold`. `redundancy` and
`conflict_score` did not exist, `superseded_at` was never set, and the MCP tool
text and the `forgetter.zig` header described the full formula anyway.

The spec gives the formula and does not say what redundancy or conflict *are*.
This ADR is that definition. Everything below is deterministic: no embeddings
in the decision, no randomness, no hash-map order.

## Decision

### 1. `redundancy`

Cells are visited most-dominant first: `importance` descending, then `id`
ascending (arrival). Greedy leader selection: a cell is compared only against
cells *already retained*, and a redundant cell is not retained, so it covers
nobody. Consequently **the first cell of any duplicate group has redundancy 0 —
a group is never forgotten whole**, even when similarity is not transitive.

`d` *covers* `c` iff all of:

- same `source` (物/象/性 are not interchangeable);
- every goal `c` is bound to, `d` is bound to;
- every foresight description of `c` is also one of `d`'s;
- every fact of `c` is also a fact of `d` (normalised: trimmed, ASCII
  case-insensitive), so `c` carries nothing `d` lacks;
- `Jaccard(tokens(c), tokens(d)) ≥ τ` over the **exact** sets of lowercased
  alphanumeric tokens of the episode and of each fact's subject, predicate,
  object (the tokenisation of `cluster_index.forEachToken`, with the full
  64-bit hash; a test pins the two against each other).

```
s(c)          = max over covering d of  clamp((J − τ) / (1 − τ), 0, 1)
redundancy(c) = s(c) · (importance(c) + θ)
```

τ = `redundancy_threshold` (0.7), θ = `forgetting_threshold` (0.1).

Consequences, deliberately:

- An **exact duplicate** has `s = 1`, so `net = −θ < 0` *whatever its
  importance*. Exact copies always collapse to one cell.
- A **near-duplicate** has its net existence lowered but is forgotten only when
  `s > importance / (importance + θ)`. At typical importance (~0.7) that needs
  `J ≳ 0.96`. A 1-token edit of a 13-token cell (J ≈ 0.86) is *lowered, not
  evicted*. This is the conservative reading of "redundant".
- Conflict is checked first: facts are part of the cover test, so two cells that
  say different things about the same subject are never "redundant".

### 2. `conflict_score` and supersession

A **keyed fact** has non-empty trimmed subject, predicate and object. Two facts
*conflict* iff subject and predicate match (normalised) and the object differs.
"Newer" is **arrival order (`id`)**, not `created_at`, which callers can set.

A cell is **superseded** iff *all* of its keyed facts are contradicted by newer
cells (conservative: one contradicted fact out of two does not supersede it).
A cell with no keyed facts is never superseded.

```
conflict_score(c) = importance(superseder(c))   if c is superseded, else 0
```

so a superseded cell is a forgetting candidate only when what replaced it
matters *more* than it does; otherwise it is marked, kept, and hidden from
default recall.

Supersession happens at **write time** (`Store.addRawReporting`, via a
subject+predicate hash index, no scan) and the **sweep re-detects** conflicts
nobody recorded (older data) by replaying cells in id order. A dry run mutates
nothing.

### 3. What a sweep reports

Reason attribution, in priority order when several hold: **decayed**
(`importance × decay < θ`, the original rule, unchanged) → **conflicted**
(`net < 0` because of a supersession) → **redundant** (`net < 0` because of a
duplicate). `importance` in `net_existence` is the *undecayed* score; age is
handled once, by the decay rule. `SweepResult` adds `decayed`, `redundant`,
`conflicted`, `superseded` (cells newly marked by the sweep), `jaccard_evals`;
`fuzzied` remains the total.

### 4. Never deleted

PCR holds: every forgotten cell moves to the fuzzy store (`is_fuzzy`,
`fuzzed_at`), a superseded cell is only *marked* (`superseded_at`,
`superseded_by`). Superseded cells are excluded from default `query` (CLI, HTTP,
MCP) and returned with `--include-superseded` / `"includeSuperseded"` /
`include_superseded`. `inspect` shows `superseded_at`, `superseded_by` and
`supersedes`, and falls back to the fuzzy store; `dump` carries both fields and
`--include-fuzzy` lists forgotten cells.

### 5. Persistence

- **WAL**: a supersession is a `memcell_update (0x02)` record,
  `{"id","superseded_at","superseded_by"}`, journaled *before* the in-memory
  mutation. Builds that predate it ignore the record type, so an older binary
  reading a newer WAL still loads (and simply does not know the stamp).
  I chose this over trailing fields on `memcell_insert` because supersession
  happens *after* the old cell's insert is journaled; there is no insert
  record to append to.
- **Snapshot v3**: each cell ends with `has_superseded_by u8 [+ u64]`. v1 and v2
  files still load (`superseded_by = null`). **A v3 file is refused by a v2
  build**, and a snapshot truncates the WAL, so *downgrading after a sync loses
  the data.* There is no downgrade path; this is the same trade v2 made.
- **A pre-existing PCR bug is fixed on the way**: replaying a `.forget` record
  *freed* the cell instead of moving it to the fuzzy store, and `mem3 forget`
  does not `sync`, so a restart after a CLI sweep lost the forgotten cells
  outright. Replay now moves them to the fuzzy store (and out of HNSW, BM25 and
  goal bindings), keeping the original `fuzzed_at`.

## Complexity: why the sweep is not O(n²)

Candidates for the duplicate pass come from an exact **prefix-filter inverted
index** (Chaudhuri et al., 2006): tokens are ranked by global rarity, a cell is
indexed under the first `k − ⌈t·k⌉ + 1` of its tokens, and two sets with
`J ≥ t` are guaranteed to share one. Verification is the exact Jaccard, so the
result equals an all-pairs scan (a test holds it to an independent oracle at
τ ∈ {0.5, 0.7, 0.85, 0.95}); only the number of evaluations changes. `t` is
lowered by 1e-4 so float rounding cannot admit a pair the filter dropped.

A 512-bucket signature index (the consolidator's) was **not** used for
candidate generation: with 512 posting lists each prefix token hits ~`n·k/512`
retained cells, which is all-pairs with a constant of 1/512. That is an
argument from arithmetic; it was not measured.

Cost is **output-sensitive**, so a corpus where *every* pair is similar and
nothing is redundant (templated text, each cell its own fact) makes every pair
a candidate. To bound that, each cell spends at most
`redundancy_max_candidates` (256) Jaccard evaluations, candidates visited
rarest-token first (a true duplicate shares the cell's rarest tokens, so it is
found first). The cap can only *miss* a covering neighbour — it forgets fewer
cells, never more.

Measured (ReleaseFast, Apple M1 Pro, dry-run `Store.forget`, best of 3,
`mem3-forgetting-eval --mode=scale`):

| corpus | cells | sweep ms | Jaccard evals | all pairs | exponent vs prev |
|---|---:|---:|---:|---:|---:|
| realistic | 1,000 | 7.5 | 1,096 | 499,500 | — |
| realistic | 5,000 | 38.8 | 5,586 | 12,497,500 | 1.02 |
| realistic | 20,000 | 139.9 | 22,967 | 199,990,000 | 0.93 |
| templated, uncapped | 1,000 | 22.2 | 499,500 | 499,500 | — |
| templated, uncapped | 5,000 | 482.3 | 12,497,500 | 12,497,500 | 1.91 |
| templated, uncapped | 20,000 | **18,931** | 199,990,000 | 199,990,000 | 2.65 |
| templated, cap 256 | 1,000 | 11.3 | 223,104 | 499,500 | — |
| templated, cap 256 | 5,000 | 86.8 | 1,247,104 | 12,497,500 | 1.27 |
| templated, cap 256 | 20,000 | 1,131 | 5,087,104 | 199,990,000 | 1.85 |

The cap fixed the evaluation count (linear: ~254 per cell) but wall time at
20,000 templated cells still grew faster than linearly (exponent 1.85 on the
last step). The remainder was **not profiled**; the evaluation counter is not
the whole cost there.

## What was deliberately NOT done

- **No single-/multi-valued predicate classification.** `user|likes|X` and
  `user|likes|Y` are *treated as a conflict*. That is the main false-positive
  risk (see Evaluation). A schema of functional predicates would fix it and
  would be new product surface; it is not in the spec.
- **Partial contradictions do not supersede.** Only a cell whose *every* keyed
  fact is contradicted.
- **`Fact.confidence` is not used** (every ingest path writes 1.0).
- **Redundancy ignores embeddings.** Token sets only.
- **No `mem3 remember` (promote-back).** T084 stays open; `FuzzyStore.promote`
  exists, there is no CLI/HTTP/MCP route.
- **No delete path.** See deviation 1.
- **No snapshot downgrade path** (see §5).
- **No cross-source redundancy** (a 物 cell never covers a 象 cell).
- **Consolidation abstracts** carry no `atomic_facts`, so they take no part in
  conflicts, and they are not duplicates of their sources (different text).

## Deviations from the spec

1. **FR-010's deletion branch does not exist.** The spec implies `net < 0` with
   `spirit_coherence ≤ 0.7` deletes, and `> 0.7` goes to the fuzzy store. PCR and
   the shipped forgetter forbid deletion and no delete path exists, so *every*
   forgotten cell goes to the fuzzy store and the `0.7` clause is vacuous
   (tested: a low-coherence cell is not deleted, a high-coherence one is
   fuzzified). Flagged because it is a deliberate choice between two readings.
2. **Redundancy and conflict are heuristics the spec never defined**, and the
   definitions above are mine. They are conservative where the spec was silent
   (near-duplicates lowered, not evicted; supersession needs all facts
   contradicted), but a different reading is defensible.
3. **"Newer" is arrival order, not `created_at`.**
4. **`conflict_score` is the superseder's importance**, not a similarity.
5. **`net_existence` uses undecayed importance**, with decay as its own rule,
   so age is not charged twice and the original behaviour is unchanged.

## Evaluation

`mem3-forgetting-eval --mode=netex` (seed 42; the same corpus is built twice,
"before" being the decay-only forgetter reproduced by switching the new terms
off). 1,100 cells: 400 unique, 60 duplicate groups of 4, 60 contradiction pairs,
60 subjects × 3 "likes" values, 60 templated ticket pairs, 40 stale.

| measure | before | after |
|---|---:|---:|
| exact-copy pairs reduced to one cell | 0/60 | **60/60** |
| most important member of a duplicate group kept | 60/60 | 60/60 |
| 1-token near-duplicates (J≈0.86) forgotten | 0/60 | 0/60 (by design) |
| unique high-importance cells forgotten | 0/400 | **0/400** |
| stale cells forgotten (decay) | 40/40 | 40/40 |
| contradicted (old) cells superseded | 0/60 | **60/60** |
| contradiction pairs whose top-1 hit is the *current* value | 32/60 (53%) | **60/60 (100%)** |
| **multi-valued** cells wrongly superseded | 0/180 | **120/180** |
| **multi-valued** cells wrongly forgotten | 0/180 | **62/180** |
| duplicate copies in top-5 (mean) | 4.00 | 3.00 |

Across seeds 1, 2, 3 and 42 I re-checked only: exact-copy pairs (60/60 each),
unique cells forgotten (0/400 each), supersession precision (60/180 and 120
multi-valued false marks, each) and the top-1 row (25–32/60, i.e. 42–53%,
before; 60/60 after). The other rows are seed 42 only. Reading it honestly:

- **Benefit that shows:** exact duplicates collapse, contradictions are marked
  and a default query returns the current value every time instead of about half
  the time.
- **No benefit shown for near-duplicates**: by design they are lowered, not
  forgotten, so the duplicate-crowding measure improves only from 4.00 to 3.00.
- **A real cost:** the subject+predicate key is wrong for multi-valued
  predicates. 120 of 180 `likes` cells were marked superseded and 62 of those
  *forgotten* (to the fuzzy store; recoverable, but gone from recall). That is a
  precision of 33% on supersession (60 true of 180 marked), which is what the
  `supersede_on_conflict` switch exists for. A user storing multi-valued
  predicates should turn it off until predicate schemas exist.
- Templated tickets that differ by one token were not forgotten (0/120 on seeds
  1–3; 1/120 on seed 42, which I attribute to the generator drawing the same
  ticket number twice and so producing an exact duplicate — **not verified**).

The evaluation corpus is synthetic and authored by me alongside the code it
tests. It shows the mechanisms work as defined; it says nothing about how often
real memory stores contain these patterns.

## Consequences

- **Positive**: FR-010/FR-015 are implemented as written, with definitions that
  can be argued with because they are stated. `superseded_at` is finally set.
  A restart no longer loses forgotten cells.
- **Negative**: default recall now hides superseded cells, and the heuristic key
  hides *legitimate* earlier values of multi-valued predicates. This is a
  behaviour change visible to users of `memory_query`.
- **Negative**: snapshot v3 is one-way.
- **Open**: functional-predicate schemas; profiling the remaining superlinear
  wall time on a dense templated corpus; a real (non-synthetic) corpus.
