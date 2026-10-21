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

- same `source` (matter, form and spirit are not interchangeable);
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

**Only single-valued predicates can conflict** (see "Single-valued predicates"
below). A fact whose predicate is not on the single-valued list is treated as
multi-valued: a second value is an addition, not a correction, so it supersedes
nothing and contributes nothing to `conflict_score`.

A cell is **superseded** iff *every* fact it asserts is on the single-valued
list *and* contradicted by a newer cell (conservative: one contradicted fact out
of two does not supersede it, and a cell that also asserts a multi-valued fact
is never hidden by a change to the single-valued one, because that fact is still
true). A cell with no keyed facts is never superseded. A cell restored with
`unsupersede` (`supersede_pinned`) is never superseded again.

### Single-valued predicates

`Config.supersede_mode` (CLI `--supersede=off|functional|all`, default
`functional`; `--no-supersede` = `off`):

| mode | which predicates can supersede |
|---|---|
| `functional` (default) | the list below, or the operator's own list |
| `all` | every predicate: the first cut of this ADR, an explicit opt-in |
| `off` | none |

`--functional-predicates=a,b,c` **replaces** the built-in list; a leading `+`
(`+is,role`) extends it; a trailing `*` is a prefix (`current_*`). Matching is on
the normalised predicate (trimmed, lower-case, space/hyphen → `_`), so
`Lives In` is `lives_in`. The list is process configuration (CLI flags on `add`,
`forget`, `serve`, `mcp`), not per-call, and an unknown mode or a flag without a
value is an error rather than a silent fallback.

Built-in list (`memory/conflict.zig: default_functional`), with the reason for
each entry and the case where it is wrong:

| predicate | why it is on the list | known failure |
|---|---|---|
| `lives_in`, `resides_in` | one residence at a time | a person with two homes |
| `located_in` | a thing is in one place | hierarchical use: `Paris located_in France` then `Paris located_in Europe` |
| `works_at`, `employed_by` | one primary employer | a person with two jobs |
| `has_status`, `status` | one current state | none known |
| `version` | one current version of a thing | a thing with several maintained versions |
| `name` | one primary name | aliases and nicknames |
| `email` | one primary address | several addresses |
| `owner` | one owner of a resource | co-ownership |
| `born_in`, `birthday` | one value, ever; a different one is a correction | none known |
| `current_*` | "the current X" is single-valued by construction | none known |

Deliberately **not** on the list, although the request that asked for this
suggested `is`: `is`, `has`, `owns`, `likes`, `prefers`, `uses`, `knows`,
`role`, `title`. "Alice is a doctor" and "Alice is tall" are both true; `is`
is the most multi-valued predicate there is. Every entry above has a failure
case, so the list is a bet that those cases are rarer than the plain
single-valued ones, not a proof; that is why it is configurable and why a
wrong supersession is reversible (`unsupersede`).

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
`include_superseded`. `inspect` shows `superseded_at`, `superseded_by`,
`supersede_pinned` and `supersedes`, and falls back to the fuzzy store; `dump`
carries `superseded_at` / `superseded_by` / `supersede_pinned` on every line by
default (and `--include-fuzzy` lists forgotten cells).

**Audit.** A supersession is never silent: the `add` result (CLI `--json`, HTTP
`POST /api/memcells`, MCP `memory_add`) carries
`"superseded":[{"id":4,"subject":"user","predicate":"lives_in"}]`, naming each
older cell and the predicate that justified it, and the human CLI line ends
with `undo with mem3 unsupersede <id>`.

**Reversal.** `mem3 unsupersede <id>` (MCP `memory_unsupersede {id}`) restores a
superseded cell, including one already forgotten into the fuzzy store: clears
`superseded_at` / `superseded_by` and sets `supersede_pinned`, which
write-time detection and the sweep both honour, so the next sweep does not
re-supersede it. It is journaled before it takes effect. An unknown id or a cell
that is not superseded is an error, not a no-op. It does not un-forget a cell
(there is still no `mem3 remember`, T084).

### 5. Persistence

- **WAL**: a supersession is a `memcell_update (0x02)` record,
  `{"id","superseded_at","superseded_by"}`, and its reversal is
  `{"id","unsuperseded":true}`; both are journaled *before* the in-memory
  mutation. Replay applies them in file order, so a WAL holding stamp then
  reversal ends restored, and a reversal on top of a snapshot that still holds
  the stamp wins. Builds that predate it ignore the record type, so an older binary
  reading a newer WAL still loads (and simply does not know the stamp).
  I chose this over trailing fields on `memcell_insert` because supersession
  happens *after* the old cell's insert is journaled; there is no insert
  record to append to.
- **Snapshot v3**: each cell ends with a `flags u8 [+ superseded_by u64]`
  (bit 0 = has `superseded_by`, bit 1 = `supersede_pinned`; the first v3 writer
  stored 0/1 there, which reads unchanged). v1 and v2
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

- **No learned or schema-driven predicate classification.** Single-valued-ness
  comes from a short built-in list or the operator's list. A predicate the list
  does not name is treated as multi-valued even when it is really
  single-valued (`shoe_size`): **those contradictions are no longer
  superseded automatically.** That recall was given up on purpose (see
  Evaluation, row (c)).
- **Partial contradictions do not supersede.** Only a cell whose *every* keyed
  fact is contradicted.
- **`Fact.confidence` is not used** (every ingest path writes 1.0).
- **Redundancy ignores embeddings.** Token sets only.
- **No `mem3 remember` (promote-back).** T084 stays open; `FuzzyStore.promote`
  exists, there is no CLI/HTTP/MCP route.
- **No delete path.** See deviation 1.
- **No snapshot downgrade path** (see §5).
- **No cross-source redundancy** (a matter cell never covers a form cell).
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
6. **The spec's "two MemCells with conflicting atomic_facts" is narrowed to
   single-valued predicates.** The first cut applied it to every predicate and
   measured 120 of 180 multi-valued cells wrongly superseded (below). The
   shipped default supersedes only listed predicates; `--supersede=all`
   restores the literal reading.

## Evaluation

`mem3-forgetting-eval --mode=netex` (seed 42, 1,220 cells). The same corpus is
built three times: **decay_only** (the forgetter before net_existence, the new
terms switched off), **all** (the first cut: every predicate single-valued,
`--supersede=all`) and **functional** (the shipped default). Corpus: 400 unique,
60 duplicate groups of 4, 60 `status` contradiction pairs (single-valued, on the
list), 60 `shoe_size` contradiction pairs (single-valued in reality, **not** on
the list), 60 subjects x 3 values of a rotating multi-valued predicate
(`likes`/`knows`/`uses`/`prefers`/`speaks`/`visited`), 60 templated ticket pairs,
40 stale.

| measure | decay_only | all | **functional (default)** |
|---|---:|---:|---:|
| (a) `status` cells contradicted and superseded | 0/60 | 60/60 | **60/60** |
| (a) pairs whose top-1 hit is the *current* value | 32/60 (53%) | 60/60 | **60/60 (100%)** |
| (b) multi-valued cells wrongly superseded | 0/180 | 120/180 | **0/180** |
| (b) multi-valued cells wrongly forgotten | 0/180 | 68/180 | **0/180** |
| (c) `shoe_size` contradictions superseded | 0/60 | 60/60 | **0/60** |
| (c) pairs whose top-1 hit is the *current* value | 21/60 (35%) | 60/60 | **21/60 (35%)** |
| exact-copy pairs reduced to one cell | 0/60 | 60/60 | 60/60 |
| most important member of a duplicate group kept | 60/60 | 60/60 | 60/60 |
| unique cells forgotten | 0/400 | 0/400 | 0/400 |
| stale cells forgotten (decay) | 40/40 | 40/40 | 40/40 |

Rows (a), (b) and (c) are asserted, not just printed: the harness exits non-zero
if the default arm supersedes or forgets a multi-valued or unknown-predicate
cell, fails to supersede a contradicted `status` cell, or forgets a unique one.
The same properties are tests (`tests/integration/supersede_e2e.zig`,
`tests/unit/supersede_policy.zig`). Seeds 1, 2 and 3 give the same (a), (b) and
(c) supersession numbers (60/60, 0/180, 0/60 for functional; 120/180 false marks
for `all`); the top-1 figures vary by seed (decay_only 40-53% for (a), 35-58% for
(c)); `all` forgets 55, 64, 58 multi-valued cells on seeds 1, 2, 3.

What the numbers say, honestly:

- **The cost of the first cut is gone**: 0 wrongly superseded and 0 wrongly
  forgotten multi-valued cells, down from 120 and 68.
- **The recall given up is real.** Row (c): 60 genuine contradictions that the
  first cut superseded are now left alone, so a query for `shoe_size` returns
  both values and the old one ranks first in 39 of 60 queries on seed 42 (top-1
  current 21/60 = the same as with no supersession at all). This is the chosen
  trade: a stale value shown beside its correction is recoverable by the reader;
  a true value hidden from recall is not visible to anyone. If you know your
  single-valued predicates, name them with `--functional-predicates`.
- **Row (a) is unchanged** by the narrowing: listed predicates still supersede
  60/60 and the current value is the top hit every time.
- Near-duplicates are still lowered, not forgotten, so duplicate crowding in the
  top 5 improves only from 4.00 to 3.00.
- A superseded cell can still be *forgotten* (31 of 60 `status` old cells here):
  that happens only when its superseder is more important, it goes to the fuzzy
  store (not deleted), and `unsupersede` still works on it.

The corpus is synthetic and authored by me alongside the code it tests. The
`shoe_size` and `likes` families were chosen to be the cases the design is
about; the evaluation says nothing about how often real memory stores contain
them, nor how often a *listed* predicate is in fact multi-valued (the table
above lists a failure case for each).

## Consequences

- **Positive**: FR-010/FR-015 are implemented as written, with definitions that
  can be argued with because they are stated. `superseded_at` is finally set.
  A restart no longer loses forgotten cells.
- **Negative**: default recall hides superseded cells (a behaviour change visible
  to users of `memory_query`), and a *listed* predicate that is multi-valued in
  someone's data (two jobs, two emails) will still hide an earlier value. It is
  reported on the add that caused it and reversible with `unsupersede`.
- **Negative**: unlisted single-valued predicates are no longer superseded
  automatically; stale values stay visible until the operator names the
  predicate.
- **Negative**: snapshot v3 is one-way.
- **Open**: predicate schemas beyond a flat list; a way to see all pins; profiling the remaining superlinear
  wall time on a dense templated corpus; a real (non-synthetic) corpus.
