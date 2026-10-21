#!/usr/bin/env bash
# Runs the pre-registered variant matrix of docs/benchmarks/ablation-tri-source.md
# on the official LongMemEval S file and leaves one score file per variant.
#
#   scripts/lme_ablation_run.sh [OUT_DIR] [JOBS]
#
# Needs: zig-out/bin/mem3-bench (zig build) and the dataset at
# $LME_DATA (default /tmp/mem3_lme_data/longmemeval_s_cleaned.json). Nothing is
# written inside the repository. Per run it records <out>/<level>_<variant>.{json,scores.jsonl,err,time}.
# `time` holds wall seconds (the host is shared; treat them as upper bounds).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A copy of the binary can be passed in (BIN=...) so a rebuild or clean of zig-out
# cannot pull it out from under a long matrix.
BIN="${BIN:-$ROOT/zig-out/bin/mem3-bench}"
DATA="${LME_DATA:-/tmp/mem3_lme_data/longmemeval_s_cleaned.json}"
OUT="${1:-/tmp/mem3_abl_$$}"
JOBS="${2:-4}"
mkdir -p "$OUT"
[ -x "$BIN" ] || { echo "missing $BIN (run zig build)" >&2; exit 1; }
[ -f "$DATA" ] || { echo "missing dataset $DATA" >&2; exit 1; }

jobs_file="$OUT/jobs.txt"
: >"$jobs_file"
add() { # level name flags...
  local level="$1" name="$2"; shift 2
  # No trailing blank: BSD xargs -L would join a line ending in a blank to the next one.
  if [ $# -gt 0 ]; then echo "$level $name $*" >>"$jobs_file"; else echo "$level $name" >>"$jobs_file"; fi
}

for level in session turn; do
  add $level A
  add $level A_rerun   # noise floor: the unmodified store is not bit-deterministic deep in a turn ranking
  add $level B --tags=heuristic
  add $level C_form --tags=form
  add $level C_spirit --tags=spirit
  for s in 1 2 3 4 5; do add $level D_s$s --tags=random --tag-seed=$s; done
  add $level E_filter --tags=heuristic --router=filter
  add $level E_boost --tags=heuristic --router=boost
  for s in 1 2 3 4 5; do
    add $level E_filter_rand_s$s --tags=random --tag-seed=$s --router=filter
    add $level E_boost_rand_s$s --tags=random --tag-seed=$s --router=boost
  done
  add $level F_on --goals=per_session
  add $level F_off --goals=per_session --goal-bonus-weight=0
  add $level G_flat --existence-bonus-weight=0
  add $level R_off --recency-bonus-weight=0
  add $level G_heur_on --tags=heuristic --foresight-on-spirit
  add $level G_heur_off --tags=heuristic --foresight-on-spirit --existence-bonus-weight=0
  add $level H_off --graph=off
  [ $level = turn ] && add $level H_edges --session-edges
  add $level I_dense --arm=dense
  add $level I_bm25 --arm=bm25
  add $level J_A --simulate-age
  add $level J_B --simulate-age --tags=heuristic
  add $level J_C_spirit --simulate-age --tags=spirit
  for s in 1 2 3 4 5; do add $level J_D_s$s --simulate-age --tags=random --tag-seed=$s; done
done

run_one() {
  local level="$1" name="$2"; shift 2
  local base="$OUT/${level}_${name}"
  # Resumable: a finished run (rc 0) is kept.
  if [ "$(cat "$base.rc" 2>/dev/null)" = "0" ]; then return 0; fi
  local t0=$SECONDS
  "$BIN" longmemeval-official --data="$DATA" --granularity="$level" \
    --dump-scores="$base.scores.jsonl" "$@" >"$base.json" 2>"$base.err"
  local rc=$?
  echo "$((SECONDS - t0))" >"$base.time"
  echo "$rc" >"$base.rc"
}
export -f run_one
export BIN DATA OUT

# Turn runs are slower; schedule them first so the tail is the cheap session runs.
{ grep '^turn ' "$jobs_file"; grep '^session ' "$jobs_file"; } |
  xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _
echo "done $(date +%s)" >"$OUT/DONE"
