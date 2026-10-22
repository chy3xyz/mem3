# Contributing

Development is on macOS or Linux, with Zig 0.17.0 from [`.zigversion`](https://github.com/chy3xyz/mem3/blob/main/.zigversion).

```bash
git clone https://github.com/chy3xyz/mem3.git
cd mem3
zig build
zig build test
zig build check-constitution
python3 scripts/mcp_conformance.py --mem3 ./zig-out/bin/mem3
```

`zig build test` prints the pass count. A cached re-run can print a pass without executing. Drive the three roots when the count matters:

```bash
zig test --dep mem3 -Mroot=src/main.zig -Mmem3=src/lib.zig
zig test --dep mem3 -Mroot=tests/main.zig -Mmem3=src/lib.zig
zig test --dep mem3 -Mroot=tests/constitution/main.zig -Mmem3=src/lib.zig
```

The third command is the constitution gate: twelve invariants. `zig build check-constitution` runs the same root.

## Rules

The [constitution](../library/constitution.md) is the constraint. A change that needs to break a principle stops for an amendment. Do not add FAISS, Neo4j, Redis, SQLite, or another runtime dependency to get around it.

- Pass an allocator in. Do not hide one in a global.
- Fallible operations return an error union. `null` means the value is absent.
- Library code does not write to stderr. The test runner uses those pipes.
- A test that cannot run returns `error.SkipZigTest`.
- Tests write under `/tmp`, in a pid-scoped directory. They do not write into the checkout.
- A new test file is imported from `src/main.zig` or `tests/main.zig`. Otherwise its tests never register.
- A cell has a matter, form, or spirit tag, and a spirit dimension (foresight or a goal association).

`AGENTS.md` in the repository root is the longer engineering guide: file map, pitfalls, and the measured performance table.

## Changes

Use a feature branch. Commit subjects look like `feat(hypermem): ...`, `fix(serializer): ...`, `test(constitution): ...`, `docs(site): ...`.

Open a pull request against `main`. The CI workflow builds, runs the tests, runs the constitution gate, checks that the worktree is clean afterwards, checks that a deliberately failing test makes the gate go red, and checks linked libraries. `zig build bench` in that workflow is a smoke step. It is allowed to fail. The workflow file had not been executed by a GitHub-hosted runner when it was added. Treat a green badge as evidence only after you can see a run.

Docs for this site live in `site/docs/`. The build copies `docs/`, the MVP spec, `dev.md`, and the GHW paper into the tree and runs [zdoc](https://github.com/chy3xyz/zdoc):

```bash
bash scripts/build_docs.sh
```

Output is `site/public/`. The default URL prefix is `/mem3/`, which is the project-site path on GitHub Pages. Pass `/` as the second argument when you are serving the folder at a domain root.
