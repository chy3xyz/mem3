//! Incremental single-linkage cluster index for consolidation.
//!
//! **GHW Layer**: Memory (三源合恰). Holds the state `Consolidator` keeps
//! between passes so that a pass compares only what changed.
//!
//! ## What it maintains
//!
//! For every live cell: a 512-bit token signature, a 64-bit content hash,
//! and a union-find parent. The invariant, true between `sync` calls, is
//!
//!     the union-find partition == the connected components of the graph
//!     whose vertices are the live cells and whose edges are the pairs with
//!     Jaccard(signature_a, signature_b) >= threshold
//!
//! which is exactly what the previous all-pairs pass computed from scratch
//! on every call. `sync` restores the invariant after the cell set changed:
//!
//!   1. **Cells that left** (forgotten, fuzzied, replaced): see "Removal".
//!   2. **Cells that arrived**: each is compared against every cell already
//!      present, and against the new cells inserted before it, once each.
//!      That is `new x present + new x (new-1) / 2` pair comparisons, where
//!      the full pass paid `(present + new) x (present + new - 1) / 2`.
//!
//! ## Removal — the rule
//!
//! Union-find can merge but cannot split, and single linkage can split: in
//! a chain a~b~c where a and c are dissimilar, deleting b leaves two
//! components. The rule:
//!
//!   * Find the component of every removed cell. Each affected component is
//!     "dirty".
//!   * Reset every surviving member of a dirty component to its own
//!     singleton, then re-run all-pairs **within that component's
//!     survivors only**, and union the pairs that pass.
//!   * Components that lost nothing are not touched.
//!
//! This is exact, not a heuristic. The invariant says there is no edge
//! between two different components, so the components of `G - v` are the
//! components of `C - v` for `v`'s component `C` and are unchanged
//! everywhere else; re-deriving `C - v` needs only pairs inside it. When
//! several cells leave the same component in one pass it is rebuilt once.
//!
//! Cost: the rebuild is `k x (k - 1) / 2` for a dirty component with `k`
//! survivors, so it is bounded above by the full pass and is zero when the
//! removed cell was a singleton or the last of its cluster. The bad case is
//! a *large* cluster that loses a member on every pass: each pass then pays
//! that cluster's quadratic cost again. That is a limit, not a hidden one;
//! a cheaper rebuild would need the edge list, O(edges) memory.
//!
//! ## Invalidation
//!
//! The threshold decides which pairs are edges, so a different threshold
//! invalidates every edge: `sync` clears the whole index and reports
//! `full_recompute`. `invalidate` does the same on demand. Nothing else in
//! `Config` reaches the partition.
//!
//! ## Detecting that a cell changed
//!
//! The manager has no change notification, so `sync` diffs the live set
//! against the index by id. An id that is present in both but whose
//! content hash differs is treated as removed-then-added: that is what a
//! restore under a reused id looks like, and trusting the id alone would
//! keep the stale signature and the stale edges. The hash covers the
//! episode and the three strings of every atomic fact (the only inputs to
//! the signature); a 64-bit collision would miss a change.
//!
//! ## Ownership
//!
//! `ClusterIndex` owns its arrays and takes the allocator at `init`. It
//! holds no pointer into any cell: a cell can be freed between passes and
//! the index never dereferences it afterwards. `deinit` frees everything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const coherence_mod = @import("coherence.zig");

/// `MAX_TRACKED_TOKENS` buckets packed into u64 words. 512 bits = 8 words.
pub const TOKEN_WORDS: usize = coherence_mod.MAX_TRACKED_TOKENS / 64;

/// One cell's token set, hashed into 512 buckets and packed.
pub const Signature = [TOKEN_WORDS]u64;

/// Call `sink` with the hash bucket of every alphanumeric token in `text`.
///
/// The single definition of bucket assignment. The signature and the
/// abstract's text filter both go through it, so they cannot drift: if
/// they disagreed on a bucket the clustering and the abstract would
/// silently describe different token sets.
pub fn forEachToken(text: []const u8, context: anytype, comptime sink: fn (@TypeOf(context), u32) void) void {
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        var buf: [64]u8 = undefined;
        var bl: usize = 0;
        for (tok) |c| {
            const lc: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
            if (lc >= 'a' and lc <= 'z' or lc >= '0' and lc <= '9') {
                if (bl < buf.len) {
                    buf[bl] = lc;
                    bl += 1;
                }
            }
        }
        if (bl == 0) continue;
        const h = std.hash.XxHash3.hash(0, buf[0..bl]);
        sink(context, @intCast(h % coherence_mod.MAX_TRACKED_TOKENS));
    }
}

/// Token signature of a cell's matter + form fields: the episode and the
/// subject / predicate / object of every atomic fact.
pub fn signatureOf(cell: *const MemCell) Signature {
    var sig: Signature = @splat(0);
    const visit = struct {
        fn v(ws: *Signature, text: []const u8) void {
            forEachToken(text, ws, struct {
                fn f(s: *Signature, bucket: u32) void {
                    s[bucket / 64] |= @as(u64, 1) << @intCast(bucket % 64);
                }
            }.f);
        }
    }.v;
    visit(&sig, cell.episode);
    for (cell.atomic_facts) |f| {
        visit(&sig, f.subject);
        visit(&sig, f.predicate);
        visit(&sig, f.object);
    }
    return sig;
}

/// Hash of exactly the fields `signatureOf` reads, length-prefixed so that
/// moving a byte across a field boundary changes the hash.
pub fn contentHash(cell: *const MemCell) u64 {
    var h = std.hash.XxHash3.init(0);
    const feed = struct {
        fn f(hh: *std.hash.XxHash3, s: []const u8) void {
            const len: u64 = s.len;
            hh.update(std.mem.asBytes(&len));
            hh.update(s);
        }
    }.f;
    feed(&h, cell.episode);
    for (cell.atomic_facts) |f| {
        feed(&h, f.subject);
        feed(&h, f.predicate);
        feed(&h, f.object);
    }
    return h.final();
}

/// The edge predicate. Arithmetic is byte-for-byte what the all-pairs loop
/// used, so the edge set — and therefore the partition — cannot differ.
inline fn similar(a: *const Signature, b: *const Signature, threshold: f32) bool {
    var inter: usize = 0;
    var union_size: usize = 0;
    for (0..TOKEN_WORDS) |w| {
        inter += @popCount(a[w] & b[w]);
        union_size += @popCount(a[w] | b[w]);
    }
    if (union_size == 0) return false;
    const jaccard = @as(f32, @floatFromInt(inter)) / @as(f32, @floatFromInt(union_size));
    return jaccard >= threshold;
}

pub const SyncStats = struct {
    /// The index was empty or the threshold changed, so every pair was
    /// compared. The first pass of a process is always one of these.
    full_recompute: bool = false,
    /// Cells inserted this sync (including cells re-added under an id whose
    /// content changed).
    cells_new: usize = 0,
    /// Cells dropped this sync (including the stale half of a changed id).
    cells_removed: usize = 0,
    /// Dirty components that had at least two survivors and so needed their
    /// pairs re-evaluated. A removal that left 0 or 1 survivors costs
    /// nothing and is not counted.
    clusters_rebuilt: usize = 0,
    /// Jaccard evaluations performed: new-vs-present, new-vs-new, and the
    /// rebuilds. This is the quantity the O(n^2) pass paid `n(n-1)/2` of.
    pair_comparisons: u64 = 0,
};

pub const PartitionEntry = struct {
    id: u64,
    /// Smallest id in this cell's component. A canonical name for the
    /// component that does not depend on which slot happens to be root.
    label: u64,
};

/// Components laid out contiguously. Cluster `k` is
/// `slots[starts[k]..starts[k + 1]]`; members are in ascending id order and
/// clusters are in ascending order of their lowest id. Both orders are what
/// make a pass a pure function of the cell set.
pub const Groups = struct {
    slots: []u32,
    starts: []u32,

    pub fn clusterCount(self: Groups) usize {
        return self.starts.len - 1;
    }

    pub fn members(self: Groups, k: usize) []const u32 {
        return self.slots[self.starts[k]..self.starts[k + 1]];
    }

    pub fn deinit(self: *Groups, alloc: Allocator) void {
        alloc.free(self.slots);
        alloc.free(self.starts);
        self.* = undefined;
    }
};

const LIVE: u8 = 1;
const SEEN: u8 = 2; // seen in the current sync's scan of the manager
const DEAD: u8 = 4; // being removed by the current sync
const DIRTY: u8 = 8; // a root whose component lost a member this sync

pub const ClusterIndex = struct {
    alloc: Allocator,

    // Struct-of-arrays, indexed by slot. A slot is a stable index for a
    // live cell; removed slots go on `free` and are reused.
    sigs: std.ArrayList(Signature) = .empty,
    ids: std.ArrayList(u64) = .empty,
    hashes: std.ArrayList(u64) = .empty,
    parent: std.ArrayList(u32) = .empty,
    flags: std.ArrayList(u8) = .empty,
    free: std.ArrayList(u32) = .empty,
    by_id: std.AutoHashMap(u64, u32),

    live_count: usize = 0,
    /// Bit pattern of the threshold the edges were evaluated with. Compared
    /// as bits so a NaN or a -0.0 cannot make "unchanged" compare unequal.
    threshold_bits: u32 = 0,
    /// False until the first sync, and after `clear`.
    primed: bool = false,

    pub fn init(alloc: Allocator) ClusterIndex {
        return .{ .alloc = alloc, .by_id = std.AutoHashMap(u64, u32).init(alloc) };
    }

    pub fn deinit(self: *ClusterIndex) void {
        self.sigs.deinit(self.alloc);
        self.ids.deinit(self.alloc);
        self.hashes.deinit(self.alloc);
        self.parent.deinit(self.alloc);
        self.flags.deinit(self.alloc);
        self.free.deinit(self.alloc);
        self.by_id.deinit();
        self.* = undefined;
    }

    /// Drop every cell and edge. Keeps the arrays' capacity, so
    /// invalidation does not hand memory back only to ask for it again.
    pub fn clear(self: *ClusterIndex) void {
        self.sigs.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        self.hashes.clearRetainingCapacity();
        self.parent.clearRetainingCapacity();
        self.flags.clearRetainingCapacity();
        self.free.clearRetainingCapacity();
        self.by_id.clearRetainingCapacity();
        self.live_count = 0;
        self.primed = false;
    }

    /// Bring the index in line with `cells`, which must be every live cell
    /// exactly once, in any order. On error the index is cleared, so the
    /// next call recomputes from scratch rather than trusting a half-applied
    /// update.
    pub fn sync(self: *ClusterIndex, cells: []const *MemCell, threshold: f32) !SyncStats {
        return self.syncInner(cells, threshold) catch |e| {
            self.clear();
            return e;
        };
    }

    fn syncInner(self: *ClusterIndex, cells: []const *MemCell, threshold: f32) !SyncStats {
        const alloc = self.alloc;
        var stats: SyncStats = .{};

        const bits: u32 = @bitCast(threshold);
        if (!self.primed or self.threshold_bits != bits) {
            self.clear();
            self.threshold_bits = bits;
            self.primed = true;
            stats.full_recompute = true;
        }

        // ---- 1. diff the manager against the index ----------------------
        var arrivals: std.ArrayList(*MemCell) = .empty;
        defer arrivals.deinit(alloc);
        for (cells) |cell| {
            const h = contentHash(cell);
            if (self.by_id.get(cell.id)) |slot| {
                if (self.hashes.items[slot] == h) {
                    self.flags.items[slot] |= SEEN;
                    continue;
                }
                // Same id, other content: left unseen, so step 2 removes
                // the old slot, and the cell is inserted afresh below.
            }
            try arrivals.append(alloc, cell);
        }

        var removed: std.ArrayList(u32) = .empty;
        defer removed.deinit(alloc);
        for (self.flags.items, 0..) |*f, slot| {
            if (f.* & LIVE == 0) continue;
            if (f.* & SEEN != 0) {
                f.* &= ~SEEN;
            } else {
                f.* |= DEAD;
                try removed.append(alloc, @intCast(slot));
            }
        }
        stats.cells_removed = removed.items.len;
        stats.cells_new = arrivals.items.len;

        // ---- 2. removals: rebuild only the components that lost a member
        if (removed.items.len > 0) try self.applyRemovals(removed.items, threshold, &stats);

        // ---- 3. arrivals: each against everything already present -------
        // Ascending id, so slot assignment for a fresh index is a function
        // of the cell set and not of hash-map iteration order.
        std.mem.sort(*MemCell, arrivals.items, {}, struct {
            fn lt(_: void, a: *MemCell, b: *MemCell) bool {
                return a.id < b.id;
            }
        }.lt);
        for (arrivals.items) |cell| try self.insert(cell, threshold, &stats);

        return stats;
    }

    fn applyRemovals(self: *ClusterIndex, removed: []const u32, threshold: f32, stats: *SyncStats) !void {
        const alloc = self.alloc;

        // The components these cells belonged to. Marking happens before any
        // slot is freed or any parent reset, while every chain still leads
        // to its root.
        var dirty_roots: std.ArrayList(u32) = .empty;
        defer dirty_roots.deinit(alloc);
        for (removed) |slot| {
            const r = self.find(slot);
            if (self.flags.items[r] & DIRTY == 0) {
                self.flags.items[r] |= DIRTY;
                try dirty_roots.append(alloc, r);
            }
        }

        // Survivors of dirty components, tagged with their old root.
        const Survivor = struct { root: u32, slot: u32 };
        var survivors: std.ArrayList(Survivor) = .empty;
        defer survivors.deinit(alloc);
        for (self.flags.items, 0..) |f, i| {
            if (f & LIVE == 0 or f & DEAD != 0) continue;
            const slot: u32 = @intCast(i);
            const r = self.find(slot);
            if (self.flags.items[r] & DIRTY != 0) try survivors.append(alloc, .{ .root = r, .slot = slot });
        }
        for (dirty_roots.items) |r| self.flags.items[r] &= ~DIRTY;

        // Free the removed slots. Their parent entries are no longer read:
        // every survivor that could have pointed at one is in `survivors`
        // and is reset just below.
        for (removed) |slot| {
            _ = self.by_id.remove(self.ids.items[slot]);
            self.flags.items[slot] = 0;
            try self.free.append(alloc, slot);
            self.live_count -= 1;
        }
        for (survivors.items) |s| self.parent.items[s.slot] = s.slot;

        std.mem.sort(Survivor, survivors.items, {}, struct {
            fn lt(_: void, a: Survivor, b: Survivor) bool {
                if (a.root != b.root) return a.root < b.root;
                return a.slot < b.slot;
            }
        }.lt);

        var start: usize = 0;
        while (start < survivors.items.len) {
            var end = start + 1;
            while (end < survivors.items.len and survivors.items[end].root == survivors.items[start].root) end += 1;
            if (end - start >= 2) {
                stats.clusters_rebuilt += 1;
                for (start..end) |a| {
                    const sa = survivors.items[a].slot;
                    for (a + 1..end) |b| {
                        const sb = survivors.items[b].slot;
                        stats.pair_comparisons += 1;
                        if (similar(&self.sigs.items[sa], &self.sigs.items[sb], threshold)) self.unite(sa, sb);
                    }
                }
            }
            start = end;
        }
    }

    fn insert(self: *ClusterIndex, cell: *const MemCell, threshold: f32, stats: *SyncStats) !void {
        const alloc = self.alloc;
        const slot: u32 = if (self.free.pop()) |s| s else blk: {
            const s: u32 = @intCast(self.sigs.items.len);
            try self.sigs.append(alloc, undefined);
            try self.ids.append(alloc, 0);
            try self.hashes.append(alloc, 0);
            try self.parent.append(alloc, s);
            try self.flags.append(alloc, 0);
            break :blk s;
        };
        self.sigs.items[slot] = signatureOf(cell);
        self.ids.items[slot] = cell.id;
        self.hashes.items[slot] = contentHash(cell);
        self.parent.items[slot] = slot;
        // Not LIVE yet, so the loop below skips it.
        self.flags.items[slot] = 0;

        const mine = &self.sigs.items[slot];
        const flags = self.flags.items;
        var pairs: u64 = 0;
        for (self.sigs.items, 0..) |*other, s| {
            if (flags[s] & LIVE == 0) continue;
            pairs += 1;
            if (similar(mine, other, threshold)) self.unite(slot, @intCast(s));
        }
        stats.pair_comparisons += pairs;

        try self.by_id.put(cell.id, slot);
        self.flags.items[slot] = LIVE;
        self.live_count += 1;
    }

    /// Union-find root with path halving.
    fn find(self: *ClusterIndex, slot: u32) u32 {
        const p = self.parent.items;
        var x = slot;
        while (p[x] != x) {
            p[x] = p[p[x]];
            x = p[x];
        }
        return x;
    }

    fn unite(self: *ClusterIndex, a: u32, b: u32) void {
        const ra = self.find(a);
        const rb = self.find(b);
        if (ra != rb) self.parent.items[ra] = rb;
    }

    /// Lay the components out in canonical order. O(n log n) for the sort by
    /// id; no pair work. Caller owns the result.
    pub fn groups(self: *ClusterIndex, alloc: Allocator) !Groups {
        const n = self.live_count;
        const order = try alloc.alloc(u32, n);
        defer alloc.free(order);
        var k: usize = 0;
        for (self.flags.items, 0..) |f, slot| {
            if (f & LIVE == 0) continue;
            order[k] = @intCast(slot);
            k += 1;
        }
        std.debug.assert(k == n);
        std.mem.sort(u32, order, self.ids.items, struct {
            fn lt(ids: []const u64, a: u32, b: u32) bool {
                return ids[a] < ids[b];
            }
        }.lt);

        // Cluster number = rank of its lowest id, because `order` is by id
        // and a root is numbered at the first member that reaches it.
        const none = std.math.maxInt(u32);
        const number = try alloc.alloc(u32, self.sigs.items.len);
        defer alloc.free(number);
        @memset(number, none);
        const of_pos = try alloc.alloc(u32, n);
        defer alloc.free(of_pos);
        var clusters: u32 = 0;
        for (order, 0..) |slot, pos| {
            const r = self.find(slot);
            if (number[r] == none) {
                number[r] = clusters;
                clusters += 1;
            }
            of_pos[pos] = number[r];
        }

        const starts = try alloc.alloc(u32, clusters + 1);
        errdefer alloc.free(starts);
        @memset(starts, 0);
        for (of_pos) |c| starts[c + 1] += 1;
        for (0..clusters) |c| starts[c + 1] += starts[c];

        const slots = try alloc.alloc(u32, n);
        errdefer alloc.free(slots);
        const cursor = try alloc.alloc(u32, clusters);
        defer alloc.free(cursor);
        @memcpy(cursor, starts[0..clusters]);
        for (order, 0..) |slot, pos| {
            const c = of_pos[pos];
            slots[cursor[c]] = slot;
            cursor[c] += 1;
        }
        return .{ .slots = slots, .starts = starts };
    }

    /// `{id, label}` for every live cell, ascending by id. For tests and
    /// diagnostics; the consolidation pass uses `groups` directly.
    pub fn partition(self: *ClusterIndex, alloc: Allocator) ![]PartitionEntry {
        var g = try self.groups(alloc);
        defer g.deinit(alloc);
        const out = try alloc.alloc(PartitionEntry, self.live_count);
        errdefer alloc.free(out);
        var w: usize = 0;
        for (0..g.clusterCount()) |c| {
            const m = g.members(c);
            const label = self.ids.items[m[0]];
            for (m) |slot| {
                out[w] = .{ .id = self.ids.items[slot], .label = label };
                w += 1;
            }
        }
        std.mem.sort(PartitionEntry, out, {}, struct {
            fn lt(_: void, a: PartitionEntry, b: PartitionEntry) bool {
                return a.id < b.id;
            }
        }.lt);
        return out;
    }

    pub fn idOf(self: *const ClusterIndex, slot: u32) u64 {
        return self.ids.items[slot];
    }

    pub fn signatureAt(self: *const ClusterIndex, slot: u32) *const Signature {
        return &self.sigs.items[slot];
    }

    /// Heap bytes held, by capacity. The hash map's share is estimated from
    /// its entry count (key + value + one metadata byte per bucket), since
    /// the std map does not expose its allocation size.
    pub fn bytesHeld(self: *const ClusterIndex) usize {
        const arrays = self.sigs.capacity * @sizeOf(Signature) +
            self.ids.capacity * @sizeOf(u64) +
            self.hashes.capacity * @sizeOf(u64) +
            self.parent.capacity * @sizeOf(u32) +
            self.flags.capacity * @sizeOf(u8) +
            self.free.capacity * @sizeOf(u32);
        const map = @as(usize, self.by_id.capacity()) * (@sizeOf(u64) + @sizeOf(u32) + 1);
        return arrays + map;
    }
};
