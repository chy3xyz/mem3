---
order: 1
---

# Run

macOS or Linux. Windows and WASM fail at compile time.

```bash
brew tap chy3xyz/tap
brew trust chy3xyz/tap
brew install mem3
```

From source, with Zig 0.17.0:

```bash
git clone https://github.com/chy3xyz/mem3.git
cd mem3
zig build
```

The binary is `mem3` on your `PATH`. A source build leaves it at `zig-out/bin/mem3`.

```bash
D=/tmp/mem3-demo
mkdir -p "$D"

mem3 add --data-dir="$D" --source matter \
  --episode "user asked to refactor the persistence layer" \
  --facts "user|prefers|zig" \
  --goal-ids 1 --relevances 0.8

mem3 query "persistence layer" --data-dir="$D"
```

`--source` is `matter`, `form`, or `spirit`. Facts are `subject|predicate|object`, separated by `;`. A foresight is `description|valid_from|valid_until|confidence`.

A new store already has three goals: `general` (id 1), `research`, and `system`.

`--data-dir` is the folder for `mem3.wal` and `snapshot.bin`. If you omit it, those files land in the current directory.

```bash
mem3 serve --data-dir="$D"
curl -s http://127.0.0.1:7777/healthz
```

`serve` listens on `127.0.0.1:7777`. There is no login and no TLS. `--bind` and `--port` change the address.
