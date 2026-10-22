---
order: 3
---

# Develop

```bash
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

The last command is the constitution gate. Twelve checks.

## Rules

- Tests write under `/tmp`, in a directory named with the process id.
- Library code does not write to stderr. The test runner uses that pipe.
- A test that cannot run returns `error.Skip ZigTest`.
- Import a new test file from `src/main.zig` or `tests/main.zig`, or it never runs.
- Pass an allocator in. Return an error for failure. `null` means the value is absent.
- Do not add a database, FAISS, or another runtime dependency. The constraint is `.specify/memory/constitution.md`.

Use a branch. Commit subjects look like `fix(store): ...`. Open a pull request against `main`.

## Security

The daemon has no authentication and no TLS. `mem3.wal` and `snapshot.bin` are plaintext. Do not bind a public address unless you mean to.

Report a vulnerability with a [private advisory](https://github.com/chy3xyz/mem3/security/advisories/new).

## License

MIT. See `LICENSE` in the repository.

Design notes, measurements, and decision records stay in the repository: `README.md`, `docs/roadmap.md`, `docs/adr/`, `AGENTS.md`. This site is the short manual.
