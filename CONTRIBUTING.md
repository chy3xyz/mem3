# Contributing

macOS or Linux. Zig 0.17.0, pinned in `.zigversion`.

```bash
git clone https://github.com/chy3xyz/mem3.git
cd mem3
zig build
zig build test
zig build check-constitution
python3 scripts/mcp_conformance.py --mem3 ./zig-out/bin/mem3
```

`zig build test` can reprint a cached pass. To force a run:

```bash
zig test --dep mem3 -Mroot=src/main.zig -Mmem3=src/lib.zig
zig test --dep mem3 -Mroot=tests/main.zig -Mmem3=src/lib.zig
zig test --dep mem3 -Mroot=tests/constitution/main.zig -Mmem3=src/lib.zig
```

The last command is the constitution gate in `.specify/memory/constitution.md`. Twelve checks.

- Tests write under `/tmp`, in a directory named with the process id.
- Library code does not write to stderr.
- A test that cannot run returns `error.Skip ZigTest`.
- Import a new test file from `src/main.zig` or `tests/main.zig`.
- Pass an allocator in. Return an error for failure.
- Do not add a database, FAISS, or another runtime dependency.

`AGENTS.md` has the file map and the measured numbers.

Use a branch. Subjects look like `fix(store): ...`. Open a pull request against `main`.

The public manual is `site/docs/`. Build it with `bash scripts/build_docs.sh`. The same pages are at <https://chy3xyz.github.io/mem3/>.
