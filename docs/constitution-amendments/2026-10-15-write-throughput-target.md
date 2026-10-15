# Constitution Amendment — Write-Throughput Target

**Date**: 2026-10-15
**Bump**: 1.1.0 → **1.2.0**
**Scope**: one row of §Performance Standards, plus the measurement rule attached to it
**Status**: ratified by the repository owner

---

## 1. Rationale

The release-blocking target was **≥ 10,000 MemCells/sec sustained**. Measured on
the durable path — every write encoded, WAL-journalled with an `fsync` per
record, and indexed — it has never been close:

| Run | Overall mean | Worst window |
|---|---|---|
| 1 | 3,898 | — |
| 2 | 3,800 | — |
| 3 | 3,028 | — |
| 4 | 2,779 | — |
| 5 | 3,243 | 2,047 |
| 6 | 3,298 | 1,863 |
| 7 | 3,116 | 2,216 |
| 8 | 3,322 | 2,438 |

Two things are true here and both matter. The **mean** spread is nearly 40% run
to run, so a mean is not a number worth quoting on its own. And the **worst
window sits 30–45% below the mean in the same run** — that gap was invisible
until the verdict was switched from mean to worst window, and it is the reason
§2.2 exists.

**The original target missed by roughly 3× on the mean and by roughly 5× on the
worst window, and the gap is not a missing micro-optimisation.** A phase profile of the write pipeline attributes it as:

| Phase | Share |
|---|---|
| `hnsw.insert` | ~55% |
| `embedder.embed` | ~42% |
| `Store`'s own code | <3% |

Two of those three have already been worked, and the results are on record:

- **`hnsw.insert`** was optimised 14.3× in commit `91f70c8` (2,016 µs → 141 µs)
  with recall@10 bit-identical at every `ef`. It is the largest single item in
  the pipeline and it is already an order of magnitude faster than it was.
- **`Store`'s own code** is under 3%. There is nothing left there to take.
- **`embedder.embed`** looked like the next lever: it builds a fresh `XxHash3`
  — deriving a 192-byte secret — once per *character position*, not once per
  input. Hoisting the seed is provably bit-identical (verified: the embedding
  fingerprint `5cc300af6482e4a4` is unchanged across nine inputs × 64
  dimensions) and strictly less work. **It measured 13–40% slower at realistic
  episode lengths** and was reverted. The reason is that at 94–384 bytes — the
  lengths this product actually stores — about 97% of `embed` is the 384-dim
  `f32` allocation and the `memset`, not hashing. The 39× figure quoted for
  that loop was measured on a 4 KB input the product never produces.

So the remaining distance is not in the code that is slow; it is in the shape of
the architecture. Closing a 3× gap on the two hot phases would mean buffer reuse
or an arena for the embedding output, and an index whose insert cost does not
grow with corpus size — design changes, not tuning.

**A target nobody can meet teaches nothing.** A release gate that is known to
fail is worse than no gate: it trains the reader to ignore the table, and the
one row that is failing drowns out the six that are passing.

### 1.1 This is a target correction, not a claim of compliance

Nothing here says the 10K figure was achieved, or that 3K is as good. It says
the published number was aspirational in a way that had stopped being useful,
and the amendment replaces it with a floor the system reliably clears, plus a
stated path for the rest.

### 1.2 What the old target was already saying

The same section already records a **v0.2.0-mvp gate of 1K/sec**, which the
system clears today with roughly 3× headroom. The 10K figure was the release
target layered on top. Lowering it does not weaken the MVP gate, which is
unchanged.

---

## 2. The change

### 2.1 §Performance Standards — the row

| | Before | After |
|---|---|---|
| Target | ≥ 10,000 MemCells/sec (sustained) | **≥ 1,750 MemCells/sec (sustained, durable path, worst window)** |

1,750 is set **below every worst window ever measured** (minimum 1,863), so the
gate is a floor rather than a restatement of the best observation.

This number was originally drafted as 2,500, set below the worst of the mean
rates. That was wrong, and wrong in exactly the way this amendment exists to
prevent: the mean is the statistic §2.2 rejects. Corrected to the worst-window
series before ratification. The v0.2.0-mvp gate of 1K/sec is untouched and is
still cleared with headroom — the worst window observed is 1,863.

### 2.2 The measurement rule attached to it

The target is only meaningful if it says what "sustained" means. The rule:

> Measured on the **durable** path: every write encoded, WAL-journalled with an
> `fsync` per record, and indexed. The verdict is the **worst window**, not the
> mean and not the best run. `bench/throughput.zig` reports both; a release
> passes when the worst window clears the target.

This is not new machinery — the benchmark already emits `worst_window_rate`
alongside the mean. The amendment makes it normative, because the mean across
the four runs above (3,376) would have cleared a 3,000 target that the slowest
run fails.

### 2.3 What is explicitly *not* being claimed

- That 10K is unreachable forever. It is a design change away (§4), not a
  physical limit.
- That the MVP gate of 1K/sec has been relaxed. It has not.
- That any other row in the table changed. They did not, and six of the seven
  benchmarks pass at the scale run.

---

## 3. Sync-impact report

Every document that states or depends on the old target, and what was done to
each:

| File | Change applied |
|---|---|
| `.specify/memory/constitution.md` | Table row → 1,750; new measurement rule paragraph; version → 1.2.0 |
| `README.md` | "Known misses" restated against the new target, with the measured range and the phase attribution |
| `AGENTS.md` | Performance-gates table row; the write-path paragraph |
| `docs/roadmap.md` | Release-performance table and the write-path paragraph |
| `bench/throughput.zig` | `target_value` 10000 → 1750, and `measured` switched from overall mean to worst window, target string, doc comments; `met_target` now evaluates against the amended target |
| `bench/main.zig` | Bench listing text |
| `specs/001-trisource-everos-mvp/plan.md` | Performance-goals line |
| `specs/001-trisource-everos-mvp/analyze-report.md` | Left as a point-in-time record of the v0.1.0 analysis; it describes what was consistent *at that time*, and rewriting it would falsify the record |
| `specs/001-trisource-everos-mvp/spec.md` | Checked; states SC-002 in terms of the constitution, carries no independent number |
| `.opencode/node_modules/**` | Not project content |

No API, on-disk format, or public interface changes. `SNAPSHOT_VERSION` is
untouched by this amendment (it was separately moved 1 → 2 by the durability
work, which carries its own compatibility rule).

---

## 4. What is deferred, and the cost

**Deferred**: the path back to 10K. It needs, in rough order of leverage:

1. **Reuse the embedding output buffer.** ~97% of `embed`'s cost at real input
   lengths is one allocation and one `memset` of 384 `f32`. A caller-owned
   scratch buffer, or an arena per batch, is a contained change with an obvious
   ceiling — roughly the 42% share, most of it.
2. **Index insert cost that does not grow with corpus.** `hnsw.insert` is
   ~55% and still scales gently with N. A flat-cost structure would change the
   shape rather than the constant.

**The cost of this amendment** is stated plainly: the release target is now one
the system meets, so it no longer exerts pressure on the two phases that
actually need it. That pressure is replaced by a written path rather than a
failing gate, which is weaker. If the project later needs the gate to push, this
amendment is the thing to revisit — and it should be revisited with numbers from
`./scripts/verify.sh`, not with intent.

---

## 5. Compliance

- `./scripts/verify.sh` prints the toolchain, host and commit it ran against, and
  records this benchmark's measured value and `met_target` verdict per run.
- The benchmark's own `target_value` is amended alongside the constitution, so
  `met_target` cannot drift back to the old number silently.
- Amendment procedure followed: written rationale (§1), sync-impact report
  (§3), version bump (§2, this header) — constitution §Governance.
- Related: the platform-scope amendment of 2026-10-14 corrected a *capability*
  claim; this one corrects a *target* claim. Both follow the same rule — a
  document that declares itself supreme must not carry statements that the code
  cannot back.
