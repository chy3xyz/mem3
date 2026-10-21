# ADR-0004: WAL-First Persistence (No RocksDB / SQLite)

**Status**: Accepted | **Date**: 2026-06-07 | **Authors**: Mavis (drafted from `dev.md` §2.4 + Constitution IV)

## Context

The system needs a persistent store for ~1M MemCells, each ~1KB, with crash recovery and snapshot support. Candidate storage engines:

- **RocksDB / LevelDB / LMDB**: C++ LSM implementations, ~10MB shared lib each, complex C++ ABIs.
- **SQLite (libsqlite3)**: C, simpler ABI, but we have a hard constitutional ban on external deps.
- **WAL + periodic snapshot, in-tree**: ~300 LOC for the WAL, ~150 LOC for the snapshot writer/reader, ~200 LOC for the LSM memtable + SSTable. Total ~650 LOC of pure Zig.
- **Memory-mapped flat files**: fast but no crash recovery; recovery requires rebuilding indexes on every startup.

## Decision

Implement a WAL + snapshot architecture in-tree:
- `src/storage/wal.zig` — append-only log with record types (MemcellInsert, MemcellUpdate, HyperedgeAdd, GoalCreate, GoalUpdate, Forget, SnapshotMarker, ChecksumMarker). Each record has a 4-byte length prefix + payload + CRC.
- `src/storage/snapshot.zig` — full state dump at `snapshot_every_n_writes` (default 10K). Atomic rename on completion. Recovery bootstrap: load latest snapshot, then replay WAL records after the snapshot marker.
- `src/storage/lsm_store.zig` — memtable (in-memory hashmap) + SSTable (sorted on-disk run files) for the MemCell store. Memtable flushes to SSTable when it exceeds `memtable_size` (default 64MB).
- `src/storage/sstable.zig` — block-based SSTable with sparse index, binary search within a block.

## Consequences

- **Positive**: Zero external runtime dependency. `ldd` clean.
- **Positive**: Full control over the format; we can add tri-source-specific optimizations (e.g., column-grouped storage by source_tag).
- **Positive**: Cross-compiles cleanly. No `librocksdb-sys` build chain.
- **Negative**: ~650 LOC of storage code we own. Compaction logic, block cache, bloom filters, etc. must be implemented and tested.
- **Note (2026-10-21)**: durability is now selectable (`--wal-sync=always|group|interval:N`). `always`, the default, is the behaviour described here. `group` acknowledges only after an fsync covering the record; `interval:N` deliberately does not and can lose ~N ms to an OS crash. Record bytes and replay are identical in every mode.
- **Negative**: No battle-tested "this won't lose your data" guarantee. We rely on the OS filesystem durability (fsync of the WAL record before acknowledging a write).
- **Mitigation**: Property tests for WAL replay correctness, snapshot roundtrip, partial-corruption recovery. The dev.md lessons-learned also note: "WAL is append-only. Crash recovery is best-effort within a single session; long-term durability relies on filesystem durability."

## Alternatives Considered

1. **Use libsqlite3 (the only C dep that would still be acceptable)**. Rejected for the constitutional reason (no external runtime deps). Also: SQLite's binary serialization for our 7-tuple struct is awkward; we'd still need a custom schema.
2. **Memory-only, no persistence**. Rejected: researcher's notebook use case (US1) requires durability across restarts.
3. **Use LMDB (mdb)**. Rejected: still an external dep; mmap-based, hard to test.
4. **Use a Zig LSM library** (e.g., `zig-lmdb` or `tigerbeetle-zig` components). None mature at the time of writing. TigerBeetle's storage layer is interesting but its VSR (Viewstamped Replication) is overkill for v0.1.0-alpha. We may revisit in v0.4.0 when distributed mode is in scope.

## Format Specification

WAL record format:
```
[len: u32 LE]
[record_type: u8]
[payload: N bytes (type-specific)]
[timestamp: i64 LE]
[checksum: u32 LE]    # xxHash3 of (type + payload + timestamp)
```

SSTable format (deferred detail to `src/storage/sstable.zig`):
```
[data block 1]
[data block 2]
...
[sparse index block]   # block → first key
[meta block]            # min_key, max_key, version, source_tag distribution
[footer: bloom filter + crc]
```

Snapshot format:
```
[snapshot marker in WAL]
[full state dump: memcells.bin + hyperedges.bin + kv.idx + hnsw.idx + goal_poset.bin]
[snapshot completed marker in WAL]
```

## References

- `dev.md` §2.4 (LSM Tree + hybrid index design)
- `dev.md` §3.1 (Zig 0.17 std.Io async writes)
- `.specify/memory/constitution.md` Principle IV (Zero-Dependency)
- `specs/001-trisource-everos-mvp/data-model.md` §WAL Record
- `specs/001-trisource-everos-mvp/data-model.md` §Recovery Semantics
