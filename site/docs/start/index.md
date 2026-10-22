---
order: 1
---

# Run

Requires Zig 0.17.0. macOS or Linux. Windows and WASM fail at compile time.

```bash
git clone https://github.com/chy3xyz/mem3.git
cd mem3
zig build
```

The binary is `zig-out/bin/mem3`.

```bash
D=/tmp/mem3-demo
mkdir -p "$D"

./zig-out/bin/mem3 add --data-dir="$D" --source matter \
  --episode "user asked to refactor the persistence layer" \
  --facts "user|prefers|zig" \
  --goal-ids 1 --relevances 0.8

./zig-out/bin/mem3 query "persistence layer" --data-dir="$D"
```

`--source` is `matter`, `form`, or `spirit`. Facts are `subject|predicate|object`, separated by `;`. A foresight is `description|valid_from|valid_until|confidence`.

A new store already has three goals: `general` (id 1), `research`, and `system`.

`--data-dir` is the folder for `mem3.wal` and `snapshot.bin`. If you omit it, those files land in the current directory.

```bash
./zig-out/bin/mem3 serve --data-dir="$D"
curl -s http://127.0.0.1:7777/healthz
```

`serve` listens on `127.0.0.1:7777`. There is no login and no TLS. `--bind` and `--port` change the address.
