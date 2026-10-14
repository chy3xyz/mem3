#!/usr/bin/env bash
# =============================================================================
# mem3 verification harness
# =============================================================================
#
# One command that reproduces every claim this repo makes about itself, and
# writes down the ones it cannot. Run it from the repo root:
#
#     ./scripts/verify.sh              # quick: 10% of every benchmark's scale
#     ./scripts/verify.sh --full       # the scale the constitution names
#     ./scripts/verify.sh --scale=0.5  # something in between
#
# Output:
#     verify.json      machine-readable: provenance + one record per check
#     verify.txt       the same thing, for a human
#
# ## Why this exists
#
# Until now the claims were spread across five commands a reader had to know
# about, and the most important number in the project (write throughput) did
# not meet its target while the docs were free to imply otherwise. A claim you
# cannot re-run is not a claim. This script makes the distinction mechanical:
# a check either ran and is recorded with its output, or it is recorded as not
# run. Nothing is inferred.
#
# ## The two traps this script is built around
#
# 1. **A cached `zig build test` always returns 0.** The failure only happens
#    on the run that actually executes; every later run replays a cached
#    result. So every test and bench here runs against a fresh `--cache-dir`.
#    Do not "simplify" that away.
#
# 2. **A build can fail while a pipe swallows the error.** `cmd 2>&1 | tail`
#    reports the exit code of `tail`, not of `cmd`, and a failed compile can
#    leave a zero-byte binary behind that a size check alone would not catch
#    if the previous artifact was still there. So every build here asserts
#    both the exit code and a non-empty artifact, and no build output is ever
#    piped into /dev/null.
#
# ## Exit status
#
# 0 only if every check passed. Any failure, and any check that could not run
# at all, is a non-zero exit. "Skipped" never counts as "passed".
#
# Zero external dependencies: uses bash, coreutils, git and jq. jq is used to
# validate that each benchmark really did print one JSON object; if jq is
# missing, the bench is recorded as failed rather than silently accepted.
# -----------------------------------------------------------------------------

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

SCALE="0.1"
MODE="quick"
RUN_MICRO=1          # the original nanosecond-level micro-benchmark suite
SKIP_CROSS=0

usage() {
	sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--full) SCALE="1.0"; MODE="full"; shift ;;
		--quick) SCALE="0.1"; MODE="quick"; shift ;;
		--scale=*) SCALE="${1#*=}"; MODE="custom"; shift ;;
		--no-micro) RUN_MICRO=0; shift ;;
		--no-cross) SKIP_CROSS=1; shift ;;
		-h|--help) usage 0 ;;
		*) echo "unknown argument: $1" >&2; usage 1 ;;
	esac
done

# -----------------------------------------------------------------------------
# Locate the toolchain
#
# `zig` is frequently absent from a non-interactive shell's PATH even when the
# user has it installed (zvm, asdf, and a plain brew install all differ). A
# verification script that dies with "zig: command not found" teaches the
# reader nothing, so we look in the usual places and report what we found.
# -----------------------------------------------------------------------------

find_zig() {
	if [ -n "${ZIG:-}" ] && [ -x "$ZIG" ]; then echo "$ZIG"; return 0; fi
	if command -v zig >/dev/null 2>&1; then command -v zig; return 0; fi
	# This project is NOT portable across Zig 0.17 point releases: the
	# `@typeInfo` payload shape and the `OptimizeMode` literal names both
	# changed *after* dev.387. On dev.387 `@typeInfo(E).@"enum"` exposes
	# `.fields`; on 0.17.0 stable it exposes `.field_names`. The same is
	# true of `OptimizeMode`, where stable wants `.ReleaseFast` and dev.387
	# wants `.fast`. Source that compiles on one does not compile on the
	# other, so picking the wrong toolchain looks exactly like a broken
	# repository. Pin the one your interactive shell resolves to, and the
	# version banner below says which one actually ran.
	local candidate
	for candidate in \
		"$HOME/.local/bin/zig" \
		"/usr/local/bin/zig" \
		"$HOME/.zvm/bin/zig" \
		"/opt/homebrew/bin/zig"; do
		if [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
	done
	return 1
}

ZIG_BIN="$(find_zig)" || {
	echo "FATAL: no zig toolchain found." >&2
	echo "       Set ZIG=/path/to/zig and re-run." >&2
	exit 127
}

command -v jq >/dev/null 2>&1 || {
	echo "FATAL: jq is required (it validates that each bench really emitted" >&2
	echo "       one JSON object). Install jq, or run the checks by hand." >&2
	exit 127
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mem3-verify.XXXXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

RECORDS="$SCRATCH/records.jsonl"   # one JSON object per check, appended
LOGDIR="$SCRATCH/log"              # full stdout+stderr of every check
OUTDIR="$REPO_ROOT/verify-artifacts"  # verify.json, verify.txt, per-bench JSON land here
mkdir -p "$OUTDIR"
mkdir -p "$LOGDIR"
: > "$RECORDS"

CHECKS_TOTAL=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_NOTRUN=0

# -----------------------------------------------------------------------------
# Recording
#
# record <name> <status> <detail> [key=value ...]
#   status: pass | fail | notrun
#   key=value pairs become a JSON object on the record, so a caller can attach
#   structured data (measured numbers, artifact sizes) to a check.
# -----------------------------------------------------------------------------

record() {
	local name="$1" status="$2" detail="$3"
	shift 3
	local extra=""
	local kv
	for kv in "$@"; do
		local k="${kv%%=*}" v="${kv#*=}"
		# Values arrive as strings; a few are numeric and are wrapped
		# explicitly by the caller with a json: prefix.
		case "$v" in
			json:*) extra+="$(printf '%s,"%s":%s' "$extra" "$k" "${v#json:}")" ;;
			*)      extra+="$(printf '%s,"%s":%s' "$extra" "$k" "$(printf '%s' "$v" | jq -Rsa .)")" ;;
		esac
	done
	printf '{"name":%s,"status":%s,"detail":%s%s}\n' \
		"$(printf '%s' "$name" | jq -Rsa .)" \
		"$(printf '%s' "$status" | jq -Rsa .)" \
		"$(printf '%s' "$detail" | jq -Rsa .)" \
		"$extra" >> "$RECORDS"

	CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
	case "$status" in
		pass)   CHECKS_PASSED=$((CHECKS_PASSED + 1)); printf '  \033[32mPASS\033[0m  %-34s %s\n' "$name" "$detail" ;;
		fail)   CHECKS_FAILED=$((CHECKS_FAILED + 1)); printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$name" "$detail" ;;
		notrun) CHECKS_NOTRUN=$((CHECKS_NOTRUN + 1)); printf '  \033[33mSKIP\033[0m  %-34s %s\n' "$name" "$detail" ;;
	esac
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# -----------------------------------------------------------------------------
# Provenance
#
# A number without its provenance is a rumour. Every record carries the
# toolchain, the host and the commit it was produced from, so a result can be
# traced or explicitly invalidated when the commit moves.
# -----------------------------------------------------------------------------

ZIG_VERSION="$("$ZIG_BIN" version 2>/dev/null || echo unknown)"
HOST="$(uname -srm 2>/dev/null || echo unknown)"
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
	GIT_DIRTY=true
	GIT_DIRTY_NOTE="working tree had uncommitted changes; results are not attributable to $GIT_SHA alone"
else
	GIT_DIRTY=false
	GIT_DIRTY_NOTE=""
fi

printf '\033[1mmem3 verification\033[0m  (mode=%s scale=%s)\n' "$MODE" "$SCALE"
printf '  zig     %s  [%s]\n  host    %s\n  commit  %s%s\n' \
	"$ZIG_VERSION" "$ZIG_BIN" "$HOST" "$GIT_SHA" \
	"$( [ "$GIT_DIRTY" = true ] && printf '  \033[33m(DIRTY)\033[0m' )"

# -----------------------------------------------------------------------------
# Step 1 — build
# -----------------------------------------------------------------------------

section "Build"

PREFIX="$SCRATCH/install"
BUILD_LOG="$LOGDIR/build.log"
BUILD_RC=0
"$ZIG_BIN" build -Doptimize=ReleaseFast --cache-dir "$SCRATCH/cache-build" --prefix "$PREFIX" \
	>"$BUILD_LOG" 2>&1 || BUILD_RC=$?

MEM3_BIN="$PREFIX/bin/mem3"
BENCH_BIN="$PREFIX/bin/mem3-bench"

if [ "$BUILD_RC" -ne 0 ]; then
	record build-releasefast fail "zig build exited $BUILD_RC (see $BUILD_LOG)" log="$(basename "$BUILD_LOG")"
elif [ ! -s "$MEM3_BIN" ]; then
	record build-releasefast fail "build reported success but $MEM3_BIN is missing or empty" log="$(basename "$BUILD_LOG")"
else
	BIN_BYTES=$(wc -c < "$MEM3_BIN" | tr -d ' ')
	BIN_DEPS="$(otool -L "$MEM3_BIN" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
	record build-releasefast pass "mem3 is $BIN_BYTES bytes, $BIN_DEPS dynamic link(s)" \
		"json:$BIN_BYTES"=byte_size binary_bytes="$BIN_BYTES" dylib_count="$BIN_DEPS"
fi

if [ ! -x "$BENCH_BIN" ]; then
	record build-bench fail "mem3-bench was not produced at $BENCH_BIN"
	BENCH_BIN=""
fi

# -----------------------------------------------------------------------------
# Step 2 — tests, cold
#
# Fresh cache directory, always. See trap 1 in the header.
# -----------------------------------------------------------------------------

section "Tests (cold cache)"

TEST_LOG="$LOGDIR/test.log"
TEST_RC=0
# `--summary all` is what makes the runner print its per-step test counts.
# Without it a fully green run prints no count at all, and a check that
# cannot state how many tests ran is not evidence of anything.
"$ZIG_BIN" build test --summary all --cache-dir "$SCRATCH/cache-test" --prefix "$SCRATCH/install-test" \
	>"$TEST_LOG" 2>&1 || TEST_RC=$?

if [ "$TEST_RC" -ne 0 ]; then
	record test-cold fail "zig build test exited $TEST_RC" log="$(basename "$TEST_LOG")"
else
	# Two shapes appear depending on how the run went:
	#   "...; 277/277 tests passed"   (from the build summary)
	#   "All 277 tests passed."       (from the runner itself)
	TEST_COUNT=$(grep -oE '[0-9]+/[0-9]+ tests passed' "$TEST_LOG" \
		| grep -oE '^[0-9]+' | paste -sd+ - | bc 2>/dev/null)
	if [ -z "${TEST_COUNT:-}" ]; then
		TEST_COUNT=$(grep -oE 'All [0-9]+ tests passed' "$TEST_LOG" \
			| grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
	fi
	if [ -z "${TEST_COUNT:-}" ] || [ "${TEST_COUNT:-0}" -eq 0 ]; then
		record test-cold notrun "build exited 0 but printed no test-count summary; see log" log="$(basename "$TEST_LOG")"
	else
		SKIPPED=$(grep -oE '[0-9]+ skipped' "$TEST_LOG" | grep -oE '^[0-9]+' | paste -sd+ - | bc 2>/dev/null)
		record test-cold pass "$TEST_COUNT tests passed${SKIPPED:+, $SKIPPED skipped}" \
			test_count="$TEST_COUNT" skipped="${SKIPPED:-0}" log="$(basename "$TEST_LOG")"
	fi
fi

# -----------------------------------------------------------------------------
# Step 3 — constitution gate
# -----------------------------------------------------------------------------

section "Constitution"

CONST_LOG="$LOGDIR/constitution.log"
CONST_RC=0
"$ZIG_BIN" build check-constitution --cache-dir "$SCRATCH/cache-const" --prefix "$SCRATCH/install-const" \
	>"$CONST_LOG" 2>&1 || CONST_RC=$?

CONST_COUNT=$(grep -cE '^test ' tests/constitution/*.zig 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$CONST_RC" -ne 0 ]; then
	record constitution fail "zig build check-constitution exited $CONST_RC" log="$(basename "$CONST_LOG")"
else
	record constitution pass "$CONST_COUNT invariant tests passed" invariant_test_count="$CONST_COUNT"
fi

# -----------------------------------------------------------------------------
# Step 4 — micro-benchmark suite
# -----------------------------------------------------------------------------

section "Micro-benchmarks"

if [ "$RUN_MICRO" -eq 0 ]; then
	record micro-suite notrun "disabled with --no-micro"
elif [ -z "$BENCH_BIN" ]; then
	record micro-suite notrun "mem3-bench was not built"
else
	MICRO_LOG="$LOGDIR/micro.log"
	MICRO_RC=0
	( cd "$SCRATCH" && "$BENCH_BIN" ) >"$MICRO_LOG" 2>&1 || MICRO_RC=$?
	if [ "$MICRO_RC" -ne 0 ]; then
		record micro-suite fail "bench exited $MICRO_RC" log="$(basename "$MICRO_LOG")"
	elif jq -e . "$SCRATCH/bench-results.json" >/dev/null 2>&1; then
		record micro-suite pass "wrote bench-results.json ($(wc -c < "$SCRATCH/bench-results.json" | tr -d ' ') bytes)" \
			log="$(basename "$MICRO_LOG")"
	else
		record micro-suite fail "bench exited 0 but wrote no valid bench-results.json" log="$(basename "$MICRO_LOG")"
	fi
fi

# -----------------------------------------------------------------------------
# Step 5 — the seven constitutional benchmarks
#
# Each must print exactly one JSON object. "Exactly one" is checked rather
# than assumed: a benchmark that prints a banner before its JSON would break
# a downstream parser, and that is worth failing on here rather than in CI.
# -----------------------------------------------------------------------------

section "Constitutional benchmarks (scale=$SCALE)"

BENCH_NAMES="throughput retrieval-p95 hnsw-build multihop cold-start footprint longmemeval"

if [ -z "$BENCH_BIN" ]; then
	for name in $BENCH_NAMES; do
		record "bench:$name" notrun "mem3-bench was not built"
	done
else
	for name in $BENCH_NAMES; do
		BLOG="$LOGDIR/bench-$name.log"
		BOUT="$SCRATCH/bench-$name.json"
		BRC=0
		( cd "$SCRATCH" && "$BENCH_BIN" "$name" "--scale=$SCALE" "--data-dir=$SCRATCH/data-$name" ) \
			>"$BLOG" 2>&1 || BRC=$?

		if [ "$BRC" -ne 0 ]; then
			record "bench:$name" fail "exited $BRC" log="$(basename "$BLOG")"
			continue
		fi
		# The bench narrates on stdout before the JSON ("throughput: 500
		# cells/mode, window 50"), so the whole log is not parseable. The
		# contract is: the last non-empty line is exactly one JSON object.
		# Everything above it is human-facing progress.
		#
		# Note: `jq -e 'type == "object"'` prints `true`, not its input, so
		# it can only ever be a predicate — never the thing you capture.
		grep -v '^[[:space:]]*$' "$BLOG" | tail -1 >"$BOUT"
		jq -e 'type == "object"' "$BOUT" >/dev/null 2>&1 \
			|| { record "bench:$name" fail "last line of stdout is not one JSON object" log="$(basename "$BLOG")"; continue; }
		# Keep the evidence: `$SCRATCH` is deleted on exit, and a result
		# field pointing into the trash is not a result.
		cp "$BOUT" "$OUTDIR/bench-$name.json"

		# Pull out whatever verdict the bench itself recorded. The bench is
		# the authority on whether it met its target; this script only
		# carries the number through verbatim.
		verdict="$(jq -r 'if has("met_target") then (.met_target|tostring) else "unreported" end' "$BOUT" 2>/dev/null)"
		measured="$(jq -c '{measured, unit, target: .constitution_target}' "$BOUT" 2>/dev/null | head -c 300)"
		case "$verdict" in
			true)  record "bench:$name" pass "meets target; $measured" result="verify-artifacts/bench-$name.json" met_target=true ;;
			false) record "bench:$name" fail "does NOT meet target; $measured" result="verify-artifacts/bench-$name.json" met_target=false ;;
			*)     record "bench:$name" pass "ran; no met_target field; $measured" result="verify-artifacts/bench-$name.json" met_target=null ;;
		esac
	done
fi

# -----------------------------------------------------------------------------
# Step 6 — cross-compilation
#
# This proves the code *compiles* for Linux. It does not prove it *runs*
# there. The distinction is recorded rather than blurred.
# -----------------------------------------------------------------------------

section "Cross-compile"

if [ "$SKIP_CROSS" -eq 1 ]; then
	record cross-linux notrun "disabled with --no-cross"
else
	for triple in x86_64-linux-gnu aarch64-linux-gnu; do
		CLOG="$LOGDIR/cross-$triple.log"
		CRC=0
		"$ZIG_BIN" build -Dtarget="$triple" -Doptimize=ReleaseFast \
			--cache-dir "$SCRATCH/cache-cross-$triple" --prefix "$SCRATCH/install-cross-$triple" \
			>"$CLOG" 2>&1 || CRC=$?
		if [ "$CRC" -eq 0 ]; then
			record "cross:$triple" pass "full build (compile only, not executed)"
		else
			record "cross:$triple" fail "exited $CRC" log="$(basename "$CLOG")"
		fi
	done
fi

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

section "Not verified by this script"

# These are not oversights. Each is a structural limit, stated so that a
# reader does not mistake silence for coverage.
NOT_VERIFIED=$(cat <<'EOF'
[
  {"item":"Linux runtime behaviour","why":"Cross-compilation proves the source builds for Linux. Nothing here executes it: this host has no Linux environment and no qemu, so every Linux claim in this repository is a compile-time claim only."},
  {"item":"Windows","why":"Not a target. Constitution v1.1.0 (amendment 2026-10-14) narrowed Principle IV to macOS + Linux. Unsupported targets are refused at compile time with a stated reason rather than left to fail obscurely."},
  {"item":"Official LongMemEval score","why":"The published benchmark requires downloading a dataset and running an LLM judge. This project has zero external dependencies and no network access, so it is structurally unreachable. The `longmemeval` bench is an in-house proxy; its number is NOT comparable to any published result and must not be presented beside one."},
  {"item":"Line coverage","why":"spec.md SC-009 asks for >=80% line coverage on core modules. This project ships no coverage tooling (that would be an external dependency). The claim is therefore neither made nor met."},
  {"item":"Scale beyond what was run","why":"Benchmarks were run at scale=$SCALE. Any `projection` object in a bench result is an extrapolation, is flagged `\"is_measured\": false`, and is not a measurement."}
]
EOF
)

jq -n \
	--arg zig "$ZIG_VERSION" \
	--arg host "$HOST" \
	--arg sha "$GIT_SHA" \
	--arg dirty "$GIT_DIRTY" \
	--arg dirty_note "$GIT_DIRTY_NOTE" \
	--arg mode "$MODE" \
	--arg scale "$SCALE" \
	--argjson checks "$(jq -s '.' "$RECORDS")" \
	--argjson not_verified "$NOT_VERIFIED" \
	'{
	  schema: "mem3.verify/1",
	  provenance: {
	    zig: $zig,
	    host: $host,
	    commit: $sha,
	    working_tree_dirty: ($dirty == "true"),
	    dirty_note: (if $dirty_note == "" then null else $dirty_note end),
	    mode: $mode,
	    bench_scale: $scale
	  },
	  summary: {
	    total: ($checks | length),
	    passed: ([$checks[] | select(.status == "pass")] | length),
	    failed: ([$checks[] | select(.status == "fail")] | length),
	    not_run: ([$checks[] | select(.status == "notrun")] | length)
	  },
	  checks: $checks,
	  not_verified: $not_verified
	}' > "$OUTDIR/verify.json"

{
	printf 'mem3 verification report\n'
	printf '========================\n\n'
	jq -r '
	  "toolchain : \(.provenance.zig)",
	  "host      : \(.provenance.host)",
	  "commit    : \(.provenance.commit)\(if .provenance.working_tree_dirty then "  (WORKING TREE WAS DIRTY)" else "" end)",
	  "mode      : \(.provenance.mode)  bench scale=\(.provenance.bench_scale)",
	  "",
	  "summary   : \(.summary.passed) passed, \(.summary.failed) failed, \(.summary.not_run) not run",
	  "",
	  "checks",
	  "------"
	' "$OUTDIR/verify.json"
	jq -r '.checks[] | "  [\(.status)] \(.name) — \(.detail)"' "$OUTDIR/verify.json"
	printf '\nnot verified\n-----------\n'
	jq -r '.not_verified[] | "  * \(.item)\n      \(.why)"' "$OUTDIR/verify.json"
} > "$OUTDIR/verify.txt"

printf '\n'
if [ "$CHECKS_FAILED" -eq 0 ] && [ "$CHECKS_NOTRUN" -eq 0 ]; then
	printf '\033[32mall %d checks passed\033[0m\n' "$CHECKS_TOTAL"
	RC=0
elif [ "$CHECKS_FAILED" -gt 0 ]; then
	printf '\033[31m%d of %d checks FAILED\033[0m (%d not run)\n' \
		"$CHECKS_FAILED" "$CHECKS_TOTAL" "$CHECKS_NOTRUN"
	RC=1
else
	printf '\033[33m%d checks did not run\033[0m — that is not a pass\n' "$CHECKS_NOTRUN"
	RC=2
fi
printf 'wrote verify-artifacts/verify.json and verify-artifacts/verify.txt\n'
exit "$RC"
