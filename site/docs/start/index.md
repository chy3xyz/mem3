---
order: 1
---

# Build and run

Zig **0.17.0**, pinned in [`.zigversion`](https://github.com/chy3xyz/mem3/blob/main/.zigversion). macOS or Linux.

```bash
git clone https://github.com/chy3xyz/mem3.git
cd mem3
zig build
./zig-out/bin/mem3 --help
```

`zig build` writes `mem3`, `mem3-bench`, `mem3-longrun`, `mem3-hnsw-recall`, `mem3-forgetting-eval`, `notebook`, and `loadtest` to `zig-out/bin/`.

ReleaseFast, measured 2026-10-22 on this tree, Apple M1 Pro: the `mem3` binary is 1,259,784 bytes and links only `libSystem`. The Debug build is 5,349,720 bytes.

## Add three cells and read them back

Examples write under `/tmp`. A cell needs a foresight or a goal association. Without one, encode returns `SpiritDimMissing` and writes nothing.

```bash
D=/tmp/mem3-demo && mkdir -p "$D"

./zig-out/bin/mem3 add --data-dir="$D" --source matter \
  --episode "user asked to refactor the persistence layer" \
  --facts "user|prefers|zig" \
  --goal-ids 1 --relevances 0.8

./zig-out/bin/mem3 add --data-dir="$D" --source form \
  --episode "tool output showed a snapshot with a stale counter" \
  --facts "snapshot|superseded|counter" \
  --foresight "the WAL will need a rotation policy|0|9999999999|0.7"

./zig-out/bin/mem3 query "persistence layer" --data-dir="$D" --topk 3
./zig-out/bin/mem3 dump --data-dir="$D"
```

`--source` accepts `matter` / `m` / `物`, `form` / `f` / `象`, `spirit` / `s` / `性`. Facts are `subject|predicate|object`, separated by `;`. A foresight is `description|valid_from|valid_until|confidence`.

Three goals exist in a fresh store: `general`, `research`, and `system`. `goal-ids 1` is `general`.

## Daemon

The default listen address is `127.0.0.1:7777`. There is no authentication.

```bash
./zig-out/bin/mem3 serve --data-dir="$D" --bind 127.0.0.1 --port 7777
curl -s http://127.0.0.1:7777/healthz
```

`/healthz` returns `{"status":"ok","version":"0.1.0-alpha"}`. Routes are on the [HTTP](../using/index.md#http) section.

## Next

- [Platforms](platforms.md)
- [Tests](testing.md)
- [Status](status.md)
