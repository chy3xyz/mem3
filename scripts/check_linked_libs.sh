#!/usr/bin/env bash
# =============================================================================
# Constitution IV gate: the mem3 binary may link only the C runtime family.
# =============================================================================
#
#   scripts/check_linked_libs.sh [path/to/binary]   # default zig-out/bin/mem3
#   scripts/check_linked_libs.sh --self-test         # test the allow-list logic
#
# Linux  — `ldd` allow-list (by library file name, not by path):
#            linux-vdso.so, libc.so, libm.so, libpthread.so, libdl.so, librt.so,
#            libgcc_s.so, ld-linux*.so      ("statically linked" is also fine)
# macOS  — `otool -L` allow-list (by exact install name):
#            /usr/lib/libSystem.B.dylib, /usr/lib/libSystem.dylib
#
# Anything else (libssl, libsqlite3, libstdc++, libc++, Foundation, ...) fails.
# So do: a library reported as `not found`, a tool that exits non-zero, a tool
# that prints nothing parseable, and `not a dynamic executable` (mem3 links
# libc dynamically; "no dynamic section" means the artifact is not what we
# think it is — a wrong-architecture binary also prints exactly that).
#
# ## Why this is a script and not inline YAML
#
# The Linux half of this logic shipped inside ci.yml once and was never run, so
# nobody knew whether it worked. As a script it can be exercised with canned
# tool output on any host: `--self-test` feeds fake `ldd` / `otool` executables
# through the real code path (including their exit status) and asserts both the
# good and the bad cases. CI runs the self-test before it trusts the check.
#
# Test seams (used by --self-test, harmless otherwise):
#   MEM3_LINKED_LIBS_OS   force "Linux" or "Darwin" instead of `uname -s`
#   LDD / OTOOL           command to run instead of `ldd` / `otool`
#
# Portable to bash 3.2 (macOS /bin/bash): no mapfile, no associative arrays.
# =============================================================================

set -euo pipefail

# Matched against the *basename* of the first token of each ldd line. The
# `\.so` anchor is what stops `libcrypto.so.3` matching `libc`.
LINUX_ALLOW='^(linux-vdso\.so(\.[0-9]+)?|libc\.so(\.[0-9]+)?|libm\.so(\.[0-9]+)?|libpthread\.so(\.[0-9]+)?|libdl\.so(\.[0-9]+)?|librt\.so(\.[0-9]+)?|libgcc_s\.so(\.[0-9]+)?|ld-linux[A-Za-z0-9_.-]*\.so(\.[0-9]+)?)$'
DARWIN_ALLOW='^(/usr/lib/libSystem\.B\.dylib|/usr/lib/libSystem\.dylib)$'

err() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}

# check_ldd_text <text>: prints offending lines; returns 0 iff there are none.
check_ldd_text() {
	local text="$1" bad="" line first rest name seen=0
	while IFS= read -r line; do
		# shellcheck disable=SC2086
		set -- $line
		[ $# -eq 0 ] && continue
		first="$1"
		rest="${line#*"$first"}"
		case "$line" in
			*"statically linked"*) seen=1; continue ;;
			*"not a dynamic executable"*)
				bad="${bad}${line}  (no dynamic section: wrong architecture, or not linked against libc)"$'\n'
				continue ;;
		esac
		seen=1
		case "$rest" in
			*"not found"*) bad="${bad}${line}  (unresolved)"$'\n'; continue ;;
		esac
		name="${first##*/}"
		if ! printf '%s\n' "$name" | grep -E -q "$LINUX_ALLOW"; then
			bad="${bad}${line}"$'\n'
		fi
	done <<EOF
$text
EOF
	if [ "$seen" -eq 0 ]; then
		bad="${bad}(ldd printed nothing parseable)"$'\n'
	fi
	if [ -n "$bad" ]; then printf '%s' "$bad"; return 1; fi
	return 0
}

# check_otool_text <text>: prints offending lines; returns 0 iff there are none.
check_otool_text() {
	local text="$1" bad="" line path seen=0
	while IFS= read -r line; do
		# Header lines ("bin:" / "bin (architecture arm64):") start in column 0;
		# dependency lines are indented.
		case "$line" in
			[[:space:]]*) ;;
			*) continue ;;
		esac
		# shellcheck disable=SC2086
		set -- $line
		[ $# -eq 0 ] && continue
		path="$1"
		seen=1
		if ! printf '%s\n' "$path" | grep -E -q "$DARWIN_ALLOW"; then
			bad="${bad}${line}"$'\n'
		fi
	done <<EOF
$text
EOF
	if [ "$seen" -eq 0 ]; then
		bad="${bad}(otool printed no dependency lines; libSystem is always present)"$'\n'
	fi
	if [ -n "$bad" ]; then printf '%s' "$bad"; return 1; fi
	return 0
}

check_binary() {
	local bin="$1" os out rc=0 bad
	os="${MEM3_LINKED_LIBS_OS:-$(uname -s)}"
	if [ ! -f "$bin" ]; then err "binary not found: $bin (run \`zig build\` first)"; return 1; fi

	case "$os" in
		Linux)
			out="$("${LDD:-ldd}" "$bin" 2>&1)" || rc=$?
			echo "$out"
			if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "statically linked"; then
				err "ldd exited $rc for $bin"; return 1
			fi
			if ! bad="$(check_ldd_text "$out")"; then
				err "unexpected shared library dependencies in $bin:"; echo "$bad" >&2; return 1
			fi
			;;
		Darwin)
			out="$("${OTOOL:-otool}" -L "$bin" 2>&1)" || rc=$?
			echo "$out"
			if [ "$rc" -ne 0 ]; then err "otool -L exited $rc for $bin"; return 1; fi
			if ! bad="$(check_otool_text "$out")"; then
				err "unexpected dynamic library dependencies in $bin:"; echo "$bad" >&2; return 1
			fi
			;;
		*) err "unsupported OS for the linked-library check: $os"; return 1 ;;
	esac
	echo "linked libraries OK ($os): only the C runtime family"
}

# -----------------------------------------------------------------------------
# --self-test
# -----------------------------------------------------------------------------

self_test() {
	local self dir fails=0 total=0
	self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
	dir="$(mktemp -d "${TMPDIR:-/tmp}/linked-libs-selftest.XXXXXX")"
	# Expanded now, not at exit: `dir` is local and is gone by the time EXIT fires.
	trap "rm -rf '$dir'" EXIT
	: > "$dir/fakebin"

	# expect <name> <os> <tool-exit-code> <expected-script-rc> <<<fixture text
	expect() {
		local name="$1" os="$2" toolrc="$3" want="$4" tool got
		cat > "$dir/fixture"
		tool="$dir/fake-tool"
		printf '#!/bin/sh\ncat "%s"\nexit %s\n' "$dir/fixture" "$toolrc" > "$tool"
		chmod +x "$tool"
		got=0
		if [ "$os" = Linux ]; then
			MEM3_LINKED_LIBS_OS=Linux LDD="$tool" bash "$self" "$dir/fakebin" >"$dir/out" 2>&1 || got=$?
		else
			MEM3_LINKED_LIBS_OS=Darwin OTOOL="$tool" bash "$self" "$dir/fakebin" >"$dir/out" 2>&1 || got=$?
		fi
		total=$((total + 1))
		# Normalise: any non-zero is "fail"; the script only ever returns 0/1.
		[ "$got" -ne 0 ] && got=1
		if [ "$got" -eq "$want" ]; then
			printf '  ok   %-44s (%s, want rc=%s)\n' "$name" "$os" "$want"
		else
			printf '  FAIL %-44s (%s, want rc=%s got rc=%s)\n' "$name" "$os" "$want" "$got"
			sed 's/^/       | /' "$dir/out"
			fails=$((fails + 1))
		fi
	}

	echo "linux / ldd:"
	expect "x86_64 glibc: all allowed" Linux 0 0 <<'F'
	linux-vdso.so.1 (0x00007ffd5d5f1000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f2b1bf00000)
	libpthread.so.0 => /lib/x86_64-linux-gnu/libpthread.so.0 (0x00007f2b1bef0000)
	libdl.so.2 => /lib/x86_64-linux-gnu/libdl.so.2 (0x00007f2b1bee0000)
	librt.so.1 => /lib/x86_64-linux-gnu/librt.so.1 (0x00007f2b1bed0000)
	libgcc_s.so.1 => /lib/x86_64-linux-gnu/libgcc_s.so.1 (0x00007f2b1be00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2b1c200000)
F
	expect "aarch64 glibc: all allowed" Linux 0 0 <<'F'
	linux-vdso.so.1 (0x0000ffff9d0d2000)
	libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x0000ffff9ce20000)
	/lib/ld-linux-aarch64.so.1 (0x0000ffff9d095000)
F
	expect "libc only (modern glibc, no libm/pthread)" Linux 0 0 <<'F'
	linux-vdso.so.1 (0x00007ffc1b9f4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f0f3a600000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f0f3a8f0000)
F
	expect "statically linked" Linux 0 0 <<'F'
	statically linked
F
	expect "BAD libssl" Linux 0 1 <<'F'
	linux-vdso.so.1 (0x00007ffd5d5f1000)
	libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3 (0x00007f2b1c100000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2b1c200000)
F
	expect "BAD libsqlite3 (Constitution IV names it)" Linux 0 1 <<'F'
	linux-vdso.so.1 (0x00007ffd5d5f1000)
	libsqlite3.so.0 => /lib/x86_64-linux-gnu/libsqlite3.so.0 (0x00007f2b1c100000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
F
	expect "BAD libstdc++ next to good libs" Linux 0 1 <<'F'
	linux-vdso.so.1 (0x00007ffd5d5f1000)
	libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6 (0x00007f2b1c100000)
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f2b1bf00000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
F
	expect "BAD prefix trap: libcrypto is not libc" Linux 0 1 <<'F'
	libcrypto.so.3 => /lib/x86_64-linux-gnu/libcrypto.so.3 (0x00007f2b1c100000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
F
	expect "BAD prefix trap: libmysqlclient vs libm" Linux 0 1 <<'F'
	libmysqlclient.so.21 => /lib/x86_64-linux-gnu/libmysqlclient.so.21 (0x00007f2b1c100000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
F
	expect "BAD good name, but not found" Linux 0 1 <<'F'
	libc.so.6 => not found
F
	expect "BAD disallowed lib resolved 'not found'" Linux 0 1 <<'F'
	libfoo.so.1 => not found
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
F
	expect "BAD not a dynamic executable" Linux 1 1 <<'F'
	not a dynamic executable
F
	expect "BAD ldd exits non-zero, output looks fine" Linux 1 1 <<'F'
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2b1c000000)
F
	expect "BAD ldd prints nothing" Linux 0 1 </dev/null

	echo "macOS / otool -L:"
	expect "libSystem.B.dylib only" Darwin 0 0 <<'F'
zig-out/bin/mem3:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "fat binary: libSystem under two headers" Darwin 0 0 <<'F'
mem3 (architecture x86_64):
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
mem3 (architecture arm64):
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "BAD libc++" Darwin 0 1 <<'F'
zig-out/bin/mem3:
	/usr/lib/libc++.1.dylib (compatibility version 1.0.0, current version 1900.180.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "BAD Foundation framework" Darwin 0 1 <<'F'
zig-out/bin/mem3:
	/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation (compatibility version 300.0.0, current version 3000.0.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "BAD homebrew libsqlite3" Darwin 0 1 <<'F'
zig-out/bin/mem3:
	/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 9.6.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "BAD look-alike path outside /usr/lib" Darwin 0 1 <<'F'
zig-out/bin/mem3:
	/tmp/evil/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "BAD otool exits non-zero" Darwin 1 1 <<'F'
zig-out/bin/mem3:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
F
	expect "BAD otool prints header only" Darwin 0 1 <<'F'
zig-out/bin/mem3:
F

	echo "missing binary:"
	total=$((total + 1))
	if MEM3_LINKED_LIBS_OS=Linux bash "$self" "$dir/does-not-exist" >/dev/null 2>&1; then
		echo "  FAIL missing binary was accepted"; fails=$((fails + 1))
	else
		echo "  ok   missing binary rejected"
	fi

	echo
	if [ "$fails" -ne 0 ]; then
		echo "self-test: $fails of $total FAILED"
		return 1
	fi
	echo "self-test: all $total cases passed"
}

# -----------------------------------------------------------------------------

case "${1:-}" in
	--self-test) self_test ;;
	-h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
	*) check_binary "${1:-zig-out/bin/mem3}" ;;
esac
