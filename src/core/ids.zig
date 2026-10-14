//! Monotonic ID allocator.
//!
//! Each id space (MemCell, HyperEdge, Goal, Harness) has its own counter.
//! Id 0 is reserved (synthetic "root" / null). Ids start at 1.
//!
//! Counters are in-memory only — on restart, they are reconciled with
//! `max(persisted_id) + 1` by the storage layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.mem3_ids);

/// Generic monotonic id source. Thread-safe via `std.Io.Mutex`.
pub fn IdSource(comptime label: []const u8) type {
    return struct {
        next: std.atomic.Value(u64),

        pub fn init() @This() {
            return .{ .next = std.atomic.Value(u64).init(1) };
        }

        /// Allocate the next id.
        pub fn alloc(self: *@This()) u64 {
            const id = self.next.fetchAdd(1, .monotonic);
            log.debug("{s} id allocated: {d}", .{ label, id });
            return id;
        }

        /// Peek the next id (does not consume).
        pub fn peek(self: *const @This()) u64 {
            return self.next.load(.monotonic);
        }

        /// Seed the counter past `seed`. Used at startup to reconcile with
        /// the persisted maximum id.
        pub fn seedPast(self: *@This(), seed: u64) void {
            const want = seed + 1;
            while (true) {
                const cur = self.next.load(.monotonic);
                if (cur >= want) return;
                if (self.next.cmpxchgWeak(cur, want, .monotonic, .monotonic)) |_| {
                    return;
                } else {}
            }
        }
    };
}

/// Composite of all id sources used by the runtime.
pub const IdSources = struct {
    memcell: IdSource("memcell") = .init(),
    hyperedge: IdSource("hyperedge") = .init(),
    goal: IdSource("goal") = .init(),
    harness: IdSource("harness") = .init(),
    scene: IdSource("scene") = .init(),

    pub fn init() IdSources {
        return .{};
    }
};

test "IdSource: monotonic, starts at 1" {
    var src: IdSource("test") = .init();
    try std.testing.expectEqual(@as(u64, 1), src.alloc());
    try std.testing.expectEqual(@as(u64, 2), src.alloc());
    try std.testing.expectEqual(@as(u64, 3), src.alloc());
    try std.testing.expectEqual(@as(u64, 4), src.peek());
}

test "IdSource: seedPast moves counter forward only" {
    var src: IdSource("test") = .init();
    _ = src.alloc();
    _ = src.alloc();
    // Already past 2, so seeding at 2 is a no-op.
    src.seedPast(2);
    try std.testing.expectEqual(@as(u64, 3), src.peek());
    // Seed past the current value — should move to 100.
    src.seedPast(99);
    try std.testing.expectEqual(@as(u64, 100), src.peek());
}
