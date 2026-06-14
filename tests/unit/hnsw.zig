//! Unit tests for `HNSW` (Hierarchical Navigable Small World) index.
//!
//! These cover the core API surface: insert, search (TopK cosine
//! similarity), deinit cleanup. They do NOT exercise the layered
//! graph navigation — that's a v0.2 follow-up. For v0.1.0 the index
//! does a brute-force TopK over the stored vectors and uses cosine
//! similarity, which is exactly what these tests pin down.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");
const Config = mem3.core.Config;
const HNSW = mem3.retrieval.HNSW;

test "HNSW: empty index returns no results" {
    var hnsw = HNSW.init(testing.allocator, .{}, 4);
    defer hnsw.deinit();

    const results = try hnsw.search(testing.allocator, &[_]f32{ 1.0, 0.0, 0.0, 0.0 }, 5);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "HNSW: insert + search returns the inserted id" {
    var hnsw = HNSW.init(testing.allocator, .{}, 4);
    defer hnsw.deinit();

    const v1 = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v2 = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const v3 = [_]f32{ 0.0, 0.0, 1.0, 0.0 };

    try hnsw.insert(101, &v1);
    try hnsw.insert(102, &v2);
    try hnsw.insert(103, &v3);
    try testing.expectEqual(@as(usize, 3), hnsw.count);

    // Search with v1: top hit should be id 101 (cosine sim 1.0).
    const results = try hnsw.search(testing.allocator, &v1, 3);
    defer testing.allocator.free(results);
    try testing.expect(results.len >= 1);
    try testing.expectEqual(@as(u64, 101), results[0].id);
    try testing.expectApproxEqAbs(@as(f32, 1.0), results[0].score, 1e-5);
}

test "HNSW: cosine similarity is symmetric and bounded" {
    var hnsw = HNSW.init(testing.allocator, .{}, 3);
    defer hnsw.deinit();

    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    try testing.expectApproxEqAbs(@as(f32, 0.0), hnsw.cosineSim(&a, &b), 1e-6);

    const c = [_]f32{ 0.7071, 0.7071, 0.0 };
    try testing.expectApproxEqAbs(@as(f32, 0.7071), hnsw.cosineSim(&a, &c), 1e-3);
}

test "HNSW: dimension mismatch returns InvalidQuery" {
    var hnsw = HNSW.init(testing.allocator, .{}, 4);
    defer hnsw.deinit();

    const wrong_dim = [_]f32{ 1.0, 0.0 };
    try testing.expectError(error.InvalidQuery, hnsw.insert(1, &wrong_dim));
}

test "HNSW: many inserts + search ranks correctly" {
    // Build 100 vectors along the identity axis (one-hot). Query for
    // a target dimension; the corresponding id should be the top hit.
    var hnsw = HNSW.init(testing.allocator, .{}, 8);
    defer hnsw.deinit();

    var i: u64 = 0;
    while (i < 8) : (i += 1) {
        var v = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
        v[i] = 1.0;
        try hnsw.insert(1000 + i, &v);
    }
    try testing.expectEqual(@as(usize, 8), hnsw.count);

    var query = [_]f32{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0 };
    const results = try hnsw.search(testing.allocator, &query, 3);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u64, 1003), results[0].id);
}