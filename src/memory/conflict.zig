//! PCR conflict detection: find the older cells a newer cell supersedes.
//!
//! **GHW Layer**: Memory (三源合恰). Spec FR-015 / user story 1.4: a new fact
//! that contradicts an old one is stored, and the old one is marked
//! `superseded_at` — **never deleted**. This file only *finds* the cells to
//! mark; marking, journaling and querying live with the callers.
//!
//! ## Definitions (ADR 0005 is the authority)
//!
//! * A **keyed fact** is an atomic fact whose subject, predicate and object
//!   are all non-empty after trimming ASCII whitespace. Anything else makes
//!   no assertion and conflicts with nothing.
//! * Two keyed facts **conflict** when subject and predicate are equal and
//!   the objects differ. Equality is ASCII case-insensitive on trimmed text.
//!   `user|prefers|Zig` restates `user|prefers|zig`; it does not contradict it.
//! * "**Newer**" is **arrival order = id order**, not `created_at`. Ids come
//!   from one monotonic counter, so they order writes even when a wall clock
//!   steps backwards or an importer back-dates a cell, and the write path and
//!   the sweep therefore agree about who superseded whom.
//! * A cell is **superseded** when *every one* of its keyed facts is
//!   contradicted by some newer indexed cell. A cell with a contradicted fact
//!   and an uncontradicted one still says something that is true, so it
//!   stays current. This is the conservative reading of the spec's "two
//!   MemCells with conflicting atomic_facts": hiding a cell from recall is
//!   the costly mistake, showing a stale fact beside its correction is not.
//!   A cell with no keyed facts is never superseded.
//! * **Only single-valued predicates can supersede.** `Policy` decides which.
//!   By default (`functional`) that is a small explicit list (`lives_in`,
//!   `works_at`, `status`, `current_*`, ...; `default_functional`); every other
//!   predicate is multi-valued, never supersedes, and never counts toward a
//!   conflict. `user|likes|tea` then `user|likes|coffee` therefore leaves
//!   both cells current. `all` restores the first heuristic (every
//!   subject+predicate is single-valued) as an explicit opt-in; `off`
//!   disables supersession. A cell is only hidden when *every* fact it
//!   asserts is functional and contradicted, so a cell that also says
//!   something multi-valued is never hidden by a functional change.
//! * A cell an operator restored with `mem3 unsupersede`
//!   (`metadata.supersede_pinned`) is never superseded again.
//!
//! ## The index
//!
//! subject+predicate hash → groups by object hash → the cells asserting it.
//! Looking up a new fact therefore costs the number of *distinct objects*
//! already asserted for its key plus the cells in the conflicting groups
//! (which are about to be superseded, so that work is amortised), and never
//! the number of cells that merely restate the same fact. Hashes are only
//! used to find candidates; every hit is re-verified on the strings, so a
//! 64-bit collision cannot supersede anything.
//!
//! The index is derived state: rebuilt from the cells at restore, never
//! persisted. It stores `*MemCell`, not copies, so a caller that frees a cell
//! must `remove` it first. Superseded cells are not indexed (they are
//! resolved) and `index` skips them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const Fact = core.Fact;

pub const Mode = core.SupersedeMode;

/// Predicates treated as single-valued when no list is configured. Small on
/// purpose: a predicate belongs here only if a person has (at any one time)
/// one value for it, so that a newer, different value really does replace the
/// older one. Anything uncertain is left off, because the cost of a missing
/// entry is a stale fact shown next to its correction, and the cost of a wrong
/// one is a true fact silently hidden. Matching is on the normalised
/// predicate (trimmed, lower-case, space/hyphen -> `_`); a trailing `*` is a
/// prefix match. Deliberately NOT here: `is`, `has`, `owns`, `likes`,
/// `prefers`, `uses`, `knows`, `role` (all multi-valued). ADR 0005 gives the
/// reasoning entry by entry.
pub const default_functional = [_][]const u8{
    "lives_in",
    "resides_in",
    "located_in",
    "works_at",
    "employed_by",
    "has_status",
    "status",
    "version",
    "name",
    "email",
    "owner",
    "born_in",
    "birthday",
    "current_*",
};

/// Normalise a predicate for list matching into `buf`; null when it is empty
/// or too long to be any list entry.
fn normPredicate(buf: []u8, s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0 or t.len > buf.len) return null;
    for (t, buf[0..t.len]) |c, *o| o.* = switch (c) {
        ' ', '-' => '_',
        else => std.ascii.toLower(c),
    };
    return buf[0..t.len];
}

fn entryMatches(entry: []const u8, pred: []const u8) bool {
    if (entry.len > 1 and entry[entry.len - 1] == '*') {
        const prefix = entry[0 .. entry.len - 1];
        return pred.len > prefix.len and std.mem.startsWith(u8, pred, prefix);
    }
    return std.mem.eql(u8, entry, pred);
}

/// Which predicates may supersede. Cheap to copy; the `predicates` text is
/// borrowed.
pub const Policy = struct {
    mode: Mode = .functional,
    /// Comma-separated list. `null` = `default_functional`. A plain list
    /// replaces the default; a leading `+` extends it.
    predicates: ?[]const u8 = null,

    pub fn fromConfig(cfg: core.Config) Policy {
        return .{ .mode = cfg.supersede_mode, .predicates = cfg.functional_predicates };
    }

    /// May a fact with this predicate supersede / be superseded?
    pub fn isFunctional(self: Policy, predicate: []const u8) bool {
        switch (self.mode) {
            .off => return false,
            .all => return std.mem.trim(u8, predicate, " \t\r\n").len > 0,
            .functional => {},
        }
        var pbuf: [96]u8 = undefined;
        const pred = normPredicate(&pbuf, predicate) orelse return false;
        var use_default = true;
        if (self.predicates) |list| {
            var rest = std.mem.trim(u8, list, " \t\r\n");
            if (rest.len > 0 and rest[0] == '+') {
                rest = rest[1..];
            } else {
                use_default = false;
            }
            var it = std.mem.splitScalar(u8, rest, ',');
            while (it.next()) |raw| {
                var ebuf: [96]u8 = undefined;
                const entry = normPredicate(&ebuf, raw) orelse continue;
                if (entryMatches(entry, pred)) return true;
            }
        }
        if (use_default) {
            for (default_functional) |entry| {
                if (entryMatches(entry, pred)) return true;
            }
        }
        return false;
    }
};

/// A cell superseded by a newer one, and the fact of the newer cell that
/// contradicted it (its strings are borrowed from the newer cell).
pub const Hit = struct {
    old: *MemCell,
    via: Fact,
};

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// ASCII case-insensitive equality of trimmed text.
pub fn normEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(trimmed(a), trimmed(b));
}

/// Hash of trimmed, ASCII-lowercased text. `normEql(a, b)` implies equal hashes.
pub fn normHash(s: []const u8) u64 {
    var h = std.hash.XxHash3.init(0);
    var buf: [128]u8 = undefined;
    var rest = trimmed(s);
    while (rest.len > 0) {
        const n = @min(rest.len, buf.len);
        for (rest[0..n], buf[0..n]) |c, *o| o.* = std.ascii.toLower(c);
        h.update(buf[0..n]);
        rest = rest[n..];
    }
    // Length-terminate so "ab" + "c" cannot collide with "a" + "bc" when
    // two hashes are combined below.
    const len: u64 = trimmed(s).len;
    h.update(std.mem.asBytes(&len));
    return h.final();
}

pub const Key = struct {
    /// Hash of (subject, predicate).
    kh: u64,
    /// Hash of object.
    oh: u64,
};

/// The conflict key of a fact, or null when it makes no assertion.
pub fn keyOf(f: Fact) ?Key {
    if (trimmed(f.subject).len == 0 or trimmed(f.predicate).len == 0 or trimmed(f.object).len == 0) return null;
    const hp = normHash(f.predicate);
    return .{
        .kh = std.hash.XxHash3.hash(normHash(f.subject), std.mem.asBytes(&hp)),
        .oh = normHash(f.object),
    };
}

/// Same subject and predicate, different object. Verified on the text.
pub fn conflicts(a: Fact, b: Fact) bool {
    if (keyOf(a) == null or keyOf(b) == null) return false;
    return normEql(a.subject, b.subject) and normEql(a.predicate, b.predicate) and !normEql(a.object, b.object);
}

/// Same subject, predicate and object.
pub fn factsEqual(a: Fact, b: Fact) bool {
    return normEql(a.subject, b.subject) and normEql(a.predicate, b.predicate) and normEql(a.object, b.object);
}

/// Number of facts that assert something.
pub fn keyedFactCount(cell: *const MemCell) usize {
    var n: usize = 0;
    for (cell.atomic_facts) |f| {
        if (keyOf(f) != null) n += 1;
    }
    return n;
}

const Group = struct {
    oh: u64,
    /// id → cell. A map, not a list, so removing one of ten thousand cells
    /// that all restate a fact is O(1).
    cells: std.AutoHashMapUnmanaged(u64, *MemCell) = .empty,
};

const KeyEntry = struct {
    groups: std.ArrayList(Group) = .empty,
};

pub const ConflictIndex = struct {
    alloc: Allocator,
    keys: std.AutoHashMapUnmanaged(u64, KeyEntry) = .empty,
    /// Which contradictions count. The index itself holds every asserted fact
    /// whatever the policy, so this can change at any time (the CLI sets it
    /// after a snapshot load) without re-indexing.
    policy: Policy = .{},

    pub fn init(alloc: Allocator) ConflictIndex {
        return .{ .alloc = alloc };
    }

    pub fn initWithPolicy(alloc: Allocator, policy: Policy) ConflictIndex {
        return .{ .alloc = alloc, .policy = policy };
    }

    pub fn deinit(self: *ConflictIndex) void {
        var it = self.keys.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.groups.items) |*g| g.cells.deinit(self.alloc);
            e.value_ptr.groups.deinit(self.alloc);
        }
        self.keys.deinit(self.alloc);
    }

    /// Number of distinct (subject, predicate) keys held. For tests.
    pub fn keyCount(self: *const ConflictIndex) usize {
        return self.keys.count();
    }

    /// Add the cell's keyed facts. A superseded cell is resolved history and
    /// is not indexed.
    pub fn index(self: *ConflictIndex, cell: *MemCell) !void {
        if (cell.metadata.superseded_at != null) return;
        for (cell.atomic_facts, 0..) |f, i| {
            const k = keyOf(f) orelse continue;
            if (seenEarlier(cell, i, k)) continue;
            const e = try self.keys.getOrPut(self.alloc, k.kh);
            if (!e.found_existing) e.value_ptr.* = .{};
            var group: ?*Group = null;
            for (e.value_ptr.groups.items) |*g| {
                if (g.oh == k.oh) {
                    group = g;
                    break;
                }
            }
            if (group == null) {
                try e.value_ptr.groups.append(self.alloc, .{ .oh = k.oh });
                group = &e.value_ptr.groups.items[e.value_ptr.groups.items.len - 1];
            }
            try group.?.cells.put(self.alloc, cell.id, cell);
        }
    }

    /// Drop the cell from every group it is in. Missing is not an error: a
    /// superseded or fact-less cell was never indexed.
    pub fn remove(self: *ConflictIndex, cell: *const MemCell) void {
        for (cell.atomic_facts, 0..) |f, i| {
            const k = keyOf(f) orelse continue;
            if (seenEarlier(cell, i, k)) continue;
            const e = self.keys.getPtr(k.kh) orelse continue;
            var gi: usize = 0;
            while (gi < e.groups.items.len) : (gi += 1) {
                const g = &e.groups.items[gi];
                if (g.oh != k.oh) continue;
                // Only remove our own entry: a cell that was re-added under
                // the same id is somebody else's.
                if (g.cells.get(cell.id)) |p| {
                    if (p == @as(*const MemCell, cell)) _ = g.cells.remove(cell.id);
                }
                if (g.cells.count() == 0) {
                    g.cells.deinit(self.alloc);
                    _ = e.groups.swapRemove(gi);
                }
                break;
            }
            if (e.groups.items.len == 0) {
                e.groups.deinit(self.alloc);
                _ = self.keys.remove(k.kh);
            }
        }
    }

    /// The indexed cells that `newer` supersedes: older (smaller id), not
    /// already superseded, not pinned, with every fact functional and
    /// contradicted. Appended to `out` in ascending id order. `newer` may or
    /// may not be indexed itself. Nothing is mutated.
    pub fn detect(self: *ConflictIndex, alloc: Allocator, newer: *const MemCell, out: *std.ArrayList(*MemCell)) !void {
        var hits: std.ArrayList(Hit) = .empty;
        defer hits.deinit(alloc);
        try self.detectHits(alloc, newer, &hits);
        for (hits.items) |h| try out.append(alloc, h.old);
    }

    /// `detect`, naming for each superseded cell the contradicting fact of
    /// `newer` (the audit trail `memory_add` reports).
    pub fn detectHits(self: *ConflictIndex, alloc: Allocator, newer: *const MemCell, out: *std.ArrayList(Hit)) !void {
        if (self.policy.mode == .off) return;
        const Touched = struct { cell: *MemCell, via: usize };
        var touched: std.AutoHashMapUnmanaged(u64, Touched) = .empty;
        defer touched.deinit(alloc);

        for (newer.atomic_facts, 0..) |nf, fi| {
            const k = keyOf(nf) orelse continue;
            // Multi-valued: a second value is an addition, not a correction.
            if (!self.policy.isFunctional(nf.predicate)) continue;
            const e = self.keys.getPtr(k.kh) orelse continue;
            for (e.groups.items) |*g| {
                if (g.oh == k.oh) continue;
                var it = g.cells.iterator();
                while (it.next()) |c| {
                    const old = c.value_ptr.*;
                    if (old.id >= newer.id or old.metadata.superseded_at != null) continue;
                    // An operator already said this one is still true.
                    if (old.metadata.supersede_pinned) continue;
                    if (!hasConflictingFact(old, nf)) continue;
                    const slot = try touched.getOrPut(alloc, old.id);
                    if (!slot.found_existing) slot.value_ptr.* = .{ .cell = old, .via = fi };
                }
            }
        }

        const start = out.items.len;
        var it = touched.iterator();
        while (it.next()) |t| {
            if (self.fullyContradicted(t.value_ptr.cell, newer)) {
                try out.append(alloc, .{ .old = t.value_ptr.cell, .via = newer.atomic_facts[t.value_ptr.via] });
            }
        }
        std.mem.sort(Hit, out.items[start..], {}, hitLess);
    }

    /// Every fact `old` asserts is functional and contradicted by `newer` or
    /// by another indexed cell that arrived after `old`. One multi-valued
    /// fact is enough to keep the cell: it still says something true.
    fn fullyContradicted(self: *ConflictIndex, old: *const MemCell, newer: *const MemCell) bool {
        var keyed: usize = 0;
        for (old.atomic_facts) |of| {
            const k = keyOf(of) orelse continue;
            keyed += 1;
            if (!self.policy.isFunctional(of.predicate)) return false;
            if (hasConflictingFact(newer, of)) continue;
            const e = self.keys.getPtr(k.kh) orelse return false;
            var found = false;
            groups: for (e.groups.items) |*g| {
                if (g.oh == k.oh) continue;
                var it = g.cells.iterator();
                while (it.next()) |c| {
                    const p = c.value_ptr.*;
                    if (p.id <= old.id or p.id == newer.id) continue;
                    if (hasConflictingFact(p, of)) {
                        found = true;
                        break :groups;
                    }
                }
            }
            if (!found) return false;
        }
        return keyed > 0;
    }
};

fn hitLess(_: void, a: Hit, b: Hit) bool {
    return a.old.id < b.old.id;
}

/// Is fact `i` of `cell` a repeat of an earlier fact of the same cell (same
/// key and object)? Such a repeat must not be indexed or removed twice.
fn seenEarlier(cell: *const MemCell, i: usize, k: Key) bool {
    for (cell.atomic_facts[0..i]) |g| {
        const gk = keyOf(g) orelse continue;
        if (gk.kh == k.kh and gk.oh == k.oh) return true;
    }
    return false;
}

fn hasConflictingFact(cell: *const MemCell, f: Fact) bool {
    for (cell.atomic_facts) |g| {
        if (conflicts(g, f)) return true;
    }
    return false;
}
