//! Which predicates may supersede an older cell (ADR 0005 §"Single-valued
//! predicates").
//!
//! The first cut treated every (subject, predicate) as single-valued, so
//! `user|likes|tea` followed by `user|likes|coffee` hid the tea cell from
//! default recall — silent memory loss for any naturally multi-valued fact.
//! The default is now conservative: only a predicate on a small, explicit
//! functional list can supersede. These tests pin that, in the order the
//! three categories matter:
//!
//!   (a) functional predicate, contradicting object  -> superseded
//!   (b) multi-valued predicate                      -> NEVER superseded
//!   (c) unknown predicate                           -> NEVER superseded
//!
//! plus the knobs (`off` / `functional` / `all`, a custom list) and the
//! rules that keep a cell with a still-true fact from being hidden.
//!
//! Nothing here touches the filesystem.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");
const MemCell = mem3.MemCell;
const Fact = mem3.Fact;
const conflict = mem3.memory.conflict;
const ConflictIndex = mem3.memory.ConflictIndex;
const Policy = conflict.Policy;

fn fact(s: []const u8, p: []const u8, o: []const u8) Fact {
    return .{ .subject = s, .predicate = p, .object = o, .confidence = 1.0, .source = "test" };
}

fn cellWith(id: u64, facts: []const Fact) MemCell {
    return .{
        .id = id,
        .source = .matter,
        .episode = "x",
        .atomic_facts = facts,
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };
}

/// Index `old`, then ask what `newer` supersedes under `policy`.
fn hitsFor(policy: Policy, old: *MemCell, newer: *MemCell, out: *std.ArrayList(conflict.Hit)) !void {
    var idx = ConflictIndex.initWithPolicy(testing.allocator, policy);
    defer idx.deinit();
    try idx.index(old);
    try idx.index(newer);
    try idx.detectHits(testing.allocator, newer, out);
}

// -----------------------------------------------------------------------------
// The default list
// -----------------------------------------------------------------------------

test "policy: the default is `functional`, with no custom list" {
    const p = Policy{};
    try testing.expectEqual(mem3.core.config.SupersedeMode.functional, p.mode);
    try testing.expect(p.predicates == null);
    try testing.expectEqual(mem3.core.config.SupersedeMode.functional, (mem3.core.Config{}).supersede_mode);
    try testing.expect((mem3.core.Config{}).functional_predicates == null);
}

test "policy: the default list names single-valued predicates, and nothing multi-valued" {
    const p = Policy{};
    const single = [_][]const u8{
        "lives_in", "resides_in",   "located_in", "works_at", "employed_by",
        "has_status", "status",     "version",    "name",     "email",
        "owner",      "born_in",    "birthday",   "current_city", "current_employer",
    };
    for (single) |s| try testing.expect(p.isFunctional(s));

    // Naturally multi-valued, or merely common. `is` is on the list the
    // request suggested and is deliberately not here: "alice is a doctor"
    // and "alice is tall" are both true.
    const multi = [_][]const u8{
        "likes", "prefers", "knows", "uses", "is", "has", "owns",
        "visited", "speaks", "role", "hobby", "friend_of", "works_with",
    };
    for (multi) |s| try testing.expect(!p.isFunctional(s));
}

test "policy: predicate matching ignores case, surrounding space and space/hyphen/underscore" {
    const p = Policy{};
    try testing.expect(p.isFunctional("Lives_In"));
    try testing.expect(p.isFunctional("  lives in "));
    try testing.expect(p.isFunctional("LIVES-IN"));
    try testing.expect(p.isFunctional("Current Location")); // current_*
    try testing.expect(!p.isFunctional("")); // an empty predicate is no predicate
    try testing.expect(!p.isFunctional("current")); // `current_*` needs the underscore
    try testing.expect(!p.isFunctional("lives_in_a_house_with")); // exact, not prefix
}

test "policy: a custom list replaces the default, `+` extends it" {
    const only = Policy{ .predicates = "likes, Pet_Name" };
    try testing.expect(only.isFunctional("likes"));
    try testing.expect(only.isFunctional("pet name"));
    try testing.expect(!only.isFunctional("lives_in")); // replaced, not extended

    const more = Policy{ .predicates = "+is,role" };
    try testing.expect(more.isFunctional("is"));
    try testing.expect(more.isFunctional("role"));
    try testing.expect(more.isFunctional("lives_in")); // still there

    // A trailing `*` is a prefix match in a custom list too.
    const pre = Policy{ .predicates = "pref_*" };
    try testing.expect(pre.isFunctional("pref_color"));
    try testing.expect(!pre.isFunctional("color"));
}

test "policy: `all` treats every predicate as functional, `off` none" {
    try testing.expect((Policy{ .mode = .all }).isFunctional("likes"));
    try testing.expect(!(Policy{ .mode = .off }).isFunctional("lives_in"));
}

// -----------------------------------------------------------------------------
// (a) functional predicates supersede
// -----------------------------------------------------------------------------

test "(a) functional: a contradicting value supersedes, and the hit names the predicate" {
    var old = cellWith(1, &.{fact("user", "lives_in", "Paris")});
    var newer = cellWith(2, &.{fact("user", "lives_in", "Berlin")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{}, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 1), out.items[0].old.id);
    try testing.expectEqualStrings("lives_in", out.items[0].via.predicate);
    try testing.expectEqualStrings("user", out.items[0].via.subject);
}

test "(a) functional: restating the same value is not a contradiction" {
    var old = cellWith(1, &.{fact("user", "lives_in", "Paris")});
    var newer = cellWith(2, &.{fact("USER", "Lives_In", " paris ")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{}, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// -----------------------------------------------------------------------------
// (b) multi-valued predicates never supersede
// -----------------------------------------------------------------------------

test "(b) multi-valued: 'likes tea' then 'likes coffee' supersedes nothing" {
    var old = cellWith(1, &.{fact("user", "likes", "tea")});
    var newer = cellWith(2, &.{fact("user", "likes", "coffee")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{}, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "(b) multi-valued: `is`, `knows`, `prefers`, `uses` never supersede by default" {
    inline for (.{ "is", "knows", "prefers", "uses", "has", "owns" }) |pred| {
        var old = cellWith(1, &.{fact("alice", pred, "a")});
        var newer = cellWith(2, &.{fact("alice", pred, "b")});
        var out: std.ArrayList(conflict.Hit) = .empty;
        defer out.deinit(testing.allocator);
        try hitsFor(.{}, &old, &newer, &out);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

// -----------------------------------------------------------------------------
// (c) unknown predicates are treated as multi-valued
// -----------------------------------------------------------------------------

test "(c) unknown predicate: a real contradiction is NOT auto-superseded (deliberate)" {
    // `shoe_size` is genuinely single-valued, but it is not on the list, and
    // the system cannot tell. Showing a stale fact beside its correction is
    // the cheap mistake; hiding a true one is the costly one.
    var old = cellWith(1, &.{fact("user", "shoe_size", "42")});
    var newer = cellWith(2, &.{fact("user", "shoe_size", "43")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{}, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// -----------------------------------------------------------------------------
// The knobs
// -----------------------------------------------------------------------------

test "mode `all` keeps the old heuristic: every predicate is single-valued" {
    var old = cellWith(1, &.{fact("user", "likes", "tea")});
    var newer = cellWith(2, &.{fact("user", "likes", "coffee")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{ .mode = .all }, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("likes", out.items[0].via.predicate);
}

test "mode `off` supersedes nothing, even a functional predicate" {
    var old = cellWith(1, &.{fact("user", "lives_in", "Paris")});
    var newer = cellWith(2, &.{fact("user", "lives_in", "Berlin")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{ .mode = .off }, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a custom list makes `likes` functional and `lives_in` not" {
    var old = cellWith(1, &.{ fact("user", "likes", "tea") });
    var newer = cellWith(2, &.{fact("user", "likes", "coffee")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{ .predicates = "likes" }, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    var o2 = cellWith(3, &.{fact("user", "lives_in", "Paris")});
    var n2 = cellWith(4, &.{fact("user", "lives_in", "Berlin")});
    out.clearRetainingCapacity();
    try hitsFor(.{ .predicates = "likes" }, &o2, &n2, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the policy can change at runtime without re-indexing" {
    // The index holds every asserted fact; the policy only decides which
    // contradictions count. So `Store` can switch it after a snapshot load.
    var idx = ConflictIndex.init(testing.allocator);
    defer idx.deinit();
    var old = cellWith(1, &.{fact("user", "likes", "tea")});
    var newer = cellWith(2, &.{fact("user", "likes", "coffee")});
    try idx.index(&old);
    try idx.index(&newer);
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try idx.detectHits(testing.allocator, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    idx.policy = .{ .mode = .all };
    try idx.detectHits(testing.allocator, &newer, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

// -----------------------------------------------------------------------------
// A cell with anything still true is never hidden
// -----------------------------------------------------------------------------

test "a functional contradiction does not hide a cell that also asserts a multi-valued fact" {
    // "lives in Paris" is contradicted; "likes tea" is not (and cannot be).
    // Hiding the cell would drop the tea fact from default recall.
    var old = cellWith(1, &.{ fact("user", "lives_in", "Paris"), fact("user", "likes", "tea") });
    var newer = cellWith(2, &.{fact("user", "lives_in", "Berlin")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{}, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // `all` still hides it only when EVERY fact is contradicted.
    try hitsFor(.{ .mode = .all }, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a cell whose facts are all functional is superseded once all are contradicted" {
    var idx = ConflictIndex.init(testing.allocator);
    defer idx.deinit();
    var old = cellWith(1, &.{ fact("user", "lives_in", "Paris"), fact("user", "works_at", "Acme") });
    var a = cellWith(2, &.{fact("user", "lives_in", "Berlin")});
    var b = cellWith(3, &.{fact("user", "works_at", "Initech")});
    try idx.index(&old);
    try idx.index(&a);
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try idx.detectHits(testing.allocator, &a, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try idx.index(&b);
    try idx.detectHits(testing.allocator, &b, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 1), out.items[0].old.id);
}

test "a restored (unsuperseded) cell is pinned: it is not detected again" {
    var old = cellWith(1, &.{fact("user", "lives_in", "Paris")});
    old.metadata.supersede_pinned = true;
    var newer = cellWith(2, &.{fact("user", "lives_in", "Berlin")});
    var out: std.ArrayList(conflict.Hit) = .empty;
    defer out.deinit(testing.allocator);
    try hitsFor(.{}, &old, &newer, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
