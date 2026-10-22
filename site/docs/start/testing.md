---
order: 3
---

# Tests

```bash
zig build test
zig build check-constitution
python3 scripts/mcp_conformance.py
```

`zig build test` runs two binaries, one rooted at `src/main.zig` and one at `tests/main.zig`. A cached re-run can print a pass without executing. When you need a count you can trust, drive the roots:

```bash
zig test --dep mem3 -Mroot=src/main.zig -Mmem3=src/lib.zig
zig test --dep mem3 -Mroot=tests/main.zig -Mmem3=src/lib.zig
zig test --dep mem3 -Mroot=tests/constitution/main.zig -Mmem3=src/lib.zig
```

The constitution root is also `zig build check-constitution`. It is a separate gate. Twelve invariants.

`scripts/mcp_conformance.py` starts `mem3 mcp` and speaks JSON-RPC at it. Pass `--mem3 zig-out/bin/mem3` to choose the binary. It is not a substitute for a real MCP host. Hosts that have been run are recorded in [MCP hosts](../library/mcp-hosts.md).

## Rules that have already broken the suite

1. Library code must not write to stderr. The test runner talks to the build system on the process pipes. A stray write kills the binary and `zig build test` can still exit 0.
2. A test that cannot run returns `error.SkipZigTest`. A bare `return` was counted as a pass.
3. The test step runs `zig-out/bin/mem3`. Build the install artifact first. `zig build test` does that.
4. Tests write scratch files under `/tmp`, in a directory that includes the process id. They do not write into the checkout.
5. A new test file is imported from `src/main.zig` or `tests/main.zig`. A `test` block in a file nobody imports does not run.
6. After a change to the gate, break a test on purpose and confirm the command exits non-zero.

`zig build bench` is the benchmark harness. It is not part of the pass/fail gate. The GitHub workflow is [`.github/workflows/ci.yml`](https://github.com/chy3xyz/mem3/blob/main/.github/workflows/ci.yml). That file had been linted and its shell snippets run on a developer machine. A GitHub-hosted runner had not executed it when the workflow was added.

See [Contributing](../project/contributing.md).
