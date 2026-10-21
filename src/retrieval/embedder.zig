//! Embedders. Two implementations behind one shape:
//!
//!   * `StubEmbedder`    — legacy xxHash3 pseudo-random vectors (v0.1.0).
//!                        Deterministic but semantically blind: cosine
//!                        similarity between two related strings is noise.
//!   * `LexicalEmbedder` — a real lexical embedder. Hashed bag-of-features
//!                        over word unigrams, word bigrams and character
//!                        3-grams, with sublinear tf weighting, signed
//!                        hashing, and L2 normalisation. Dot product ==
//!                        cosine similarity of lexical feature overlap,
//!                        so HNSW retrieval ranks by actual relevance.
//!
//! `LexicalEmbedder` is pure Zig (Constitution IV: no external deps), uses no
//! heap allocation beyond the returned vector, and is deterministic.
//!
//!   * `ExternalEmbedder` — opt-in. Spawns one long-lived child process (a
//!                        `llama.cpp`, `fastembed`, or Python runtime the
//!                        *user* installs) and speaks a one-line protocol to
//!                        it over two pipes. The binary still links nothing
//!                        but libSystem; the dependency is the user's, and
//!                        only if they ask for it. See "ExternalEmbedder"
//!                        below for the protocol.
//!
//! All three are reachable through the `Embedder` union, selected by
//! `Config.EmbedderKind` for the two built-ins and by `initExternal` for the
//! opt-in backend. That union is the seam: a call site holds an `Embedder`
//! and does not care which variant backs it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hashing = @import("../utils/hashing.zig");
const config = @import("../core/config.zig");
const clock = @import("../platform/clock.zig");

/// How long to wait for a backend that just broke the request pipe to become
/// reapable. It is a ceiling, not a typical cost: the loop returns as soon as
/// the child can be collected, and it only runs on a failure path.
const exit_grace_ms: u32 = 250;

// =============================================================================
// StubEmbedder (legacy — kept working; other modules and tests depend on it)
// =============================================================================

pub const StubEmbedder = struct {
    dim: u16,

    pub fn init(dim: u16) StubEmbedder {
        return .{ .dim = dim };
    }

    /// Embed a single string. Returns an owned slice.
    pub fn embed(self: *const StubEmbedder, alloc: Allocator, s: []const u8) ![]f32 {
        const out = try alloc.alloc(f32, self.dim);
        // Fill with pseudo-random values derived from a chained hash of the input.
        var seed = hashing.stableHash(s);
        for (out) |*v| {
            // xorshift64 → f32 in [-1, 1]
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            const normalized: f32 = @as(f32, @floatFromInt(seed % 10000)) / 10000.0;
            v.* = normalized * 2.0 - 1.0;
        }
        // L2 normalize so cosine sim = dot product.
        var norm: f32 = 0.0;
        for (out) |v| norm += v * v;
        const n = @sqrt(norm);
        if (n > 0.0) {
            for (out) |*v| v.* /= n;
        }
        return out;
    }

    /// Batch embedding for corpus construction.
    pub fn embedBatch(
        self: *const StubEmbedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ![][]f32 {
        const out = try alloc.alloc([]f32, inputs.len);
        for (inputs, 0..) |s, i| {
            out[i] = try self.embed(alloc, s);
        }
        return out;
    }
};

// =============================================================================
// LexicalEmbedder
// =============================================================================

/// Byte separating the two halves of a bigram feature. Not a word byte, so a
/// bigram can never collide with the concatenation of a shorter token pair.
const bigram_sep: u8 = 0x1f;

/// Feature kinds. Mixed into the hash so "zig" as a unigram, as a bigram
/// half and as a char 3-gram land in independent buckets.
const kind_unigram: u64 = 1;
const kind_bigram: u64 = 2;
const kind_char3: u64 = 3;

/// Base weights per feature kind. Word-level evidence is weighted above
/// character-level evidence: char n-grams exist to soften typos and
/// morphology, not to dominate.
const w_unigram: f32 = 1.0;
const w_bigram: f32 = 0.7;
const w_char3: f32 = 1.0;

/// Open-addressed term table. Lives on the stack, so `embed` allocates
/// nothing but the output vector. 512 distinct features covers the memory
/// cells this system stores; past that, new terms are dropped deterministically
/// (same input → same drops → same vector).
const max_terms = 512;

const TermEntry = struct {
    key: u64 = 0,
    tf: u32 = 0,
    base_w: f32 = 0.0,
};

const TermTable = struct {
    slots: [max_terms]TermEntry = @splat(TermEntry{}),
    used: usize = 0,

    /// Record one occurrence of `key`. Hash collisions inside the table are
    /// resolved by linear probing; two different terms sharing a slot still
    /// get distinct hashes downstream, so this only affects tf bookkeeping.
    fn add(self: *TermTable, key: u64, base_w: f32) void {
        if (self.used >= max_terms) {
            std.log.debug("LexicalEmbedder: term table full, dropping terms", .{});
            return;
        }
        var idx: usize = @intCast(key % max_terms);
        var probes: usize = 0;
        while (probes < max_terms) : (probes += 1) {
            const e = &self.slots[idx];
            if (e.tf == 0) {
                e.* = .{ .key = key, .tf = 1, .base_w = base_w };
                self.used += 1;
                return;
            }
            if (e.key == key) {
                e.tf += 1;
                return;
            }
            idx = (idx + 1) % max_terms;
        }
    }
};

/// Streaming ASCII-lowercasing hasher. Lets us hash a feature without
/// materialising a normalised copy of it, so arbitrarily long tokens are
/// handled without a scratch buffer.
const LowerHasher = struct {
    h: std.hash.XxHash3,

    fn init(kind: u64) LowerHasher {
        return .{ .h = std.hash.XxHash3.init(hashing.stableHash(&std.mem.toBytes(kind))) };
    }

    fn feed(self: *LowerHasher, s: []const u8) void {
        var chunk: [64]u8 = undefined;
        var i: usize = 0;
        while (i < s.len) {
            const n = @min(chunk.len, s.len - i);
            for (0..n) |k| chunk[k] = std.ascii.toLower(s[i + k]);
            self.h.update(chunk[0..n]);
            i += n;
        }
    }

    fn final(self: *LowerHasher) u64 {
        return self.h.final();
    }
};

const Token = struct { start: usize, end: usize };

/// Word bytes are ASCII alphanumerics plus any byte >= 0x80, so UTF-8
/// sequences stay inside a token instead of shattering into noise.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Next whitespace/punctuation-delimited token at or after `from`.
fn nextToken(s: []const u8, from: usize) ?Token {
    var i = from;
    while (i < s.len and !isWordByte(s[i])) i += 1;
    if (i >= s.len) return null;
    const start = i;
    while (i < s.len and isWordByte(s[i])) i += 1;
    return .{ .start = start, .end = i };
}

pub const LexicalEmbedder = struct {
    dim: u16,

    pub fn init(dim: u16) LexicalEmbedder {
        std.debug.assert(dim > 0);
        return .{ .dim = dim };
    }

    /// Embed a single string. Returns an owned, L2-normalised slice of length
    /// `dim`. Empty or punctuation-only input yields the all-zero vector
    /// rather than a NaN or a crash.
    pub fn embed(self: *const LexicalEmbedder, alloc: Allocator, s: []const u8) ![]f32 {
        const out = try alloc.alloc(f32, self.dim);
        errdefer alloc.free(out);
        @memset(out, 0.0);

        var table = TermTable{};

        // Pass 1 — extract features and count their frequencies.
        var prev: ?Token = null;
        var cur = nextToken(s, 0);
        while (cur) |t| {
            const tok = s[t.start..t.end];

            var unigram = LowerHasher.init(kind_unigram);
            unigram.feed(tok);
            table.add(unigram.final(), w_unigram);

            if (prev) |p| {
                var bigram = LowerHasher.init(kind_bigram);
                bigram.feed(s[p.start..p.end]);
                bigram.feed(&[_]u8{bigram_sep});
                bigram.feed(tok);
                table.add(bigram.final(), w_bigram);
            }

            // Character 3-grams, normalised by sqrt(token length) so a long
            // token cannot contribute more total mass than a short one.
            const len = t.end - t.start;
            const gram_w = w_char3 / @sqrt(@as(f32, @floatFromInt(len)));
            if (len < 3) {
                var short = LowerHasher.init(kind_char3);
                short.feed(tok);
                table.add(short.final(), gram_w);
            } else {
                var k: usize = 0;
                while (k + 3 <= len) : (k += 1) {
                    var gram = LowerHasher.init(kind_char3);
                    gram.feed(tok[k .. k + 3]);
                    table.add(gram.final(), gram_w);
                }
            }

            prev = t;
            cur = nextToken(s, t.end);
        }

        // Pass 2 — signed-hashed, sublinearly weighted accumulation.
        // Signed hashing is what keeps inner products unbiased: every feature
        // lands in a random bucket with a random ±1 sign, so unrelated texts
        // cancel toward 0 instead of piling up positive bias from shared
        // buckets alone.
        for (table.slots) |e| {
            if (e.tf == 0) continue;
            const tf: f32 = @floatFromInt(e.tf);
            const weight = e.base_w * (1.0 + @log(tf));
            const sign: f32 = if ((e.key & 1) == 1) -1.0 else 1.0;
            const bucket: usize = @as(usize, @truncate(e.key >> 1)) % @as(usize, self.dim);
            out[bucket] += sign * weight;
        }

        // L2 normalise: dot product == cosine similarity, which is the
        // invariant HNSW.cosineSim and the existing tests rely on.
        var norm: f32 = 0.0;
        for (out) |v| norm += v * v;
        if (norm > 0.0) {
            const inv = 1.0 / @sqrt(norm);
            for (out) |*v| v.* *= inv;
        }
        return out;
    }

    pub fn embedBatch(
        self: *const LexicalEmbedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ![][]f32 {
        const out = try alloc.alloc([]f32, inputs.len);
        for (inputs, 0..) |s, i| {
            out[i] = self.embed(alloc, s) catch |err| {
                var j = i;
                while (j > 0) : (j -= 1) alloc.free(out[j - 1]);
                alloc.free(out);
                return err;
            };
        }
        return out;
    }
};

// =============================================================================
// ExternalEmbedder — opt-in real embeddings, still zero linked dependencies
// =============================================================================
//
// ## Why a subprocess
//
// The alternative to a subprocess was a linked embedding runtime, which is a
// Constitution IV violation (no external deps) and cannot be amended without
// giving up the product's defining property. So the runtime is the user's,
// chosen at configuration time, and mem3 only ever speaks to it over a pipe.
// Nobody who does not opt in pays anything: no new symbol is linked, no
// library is loaded, and the default path is untouched (see the fingerprint
// test at the bottom of this file).
//
// ## Wire protocol
//
// One request per line, one response per line, both on pipes, forever.
//
//   request : `<hex of the input's UTF-8 bytes>` `\n`
//   response: `<dim whitespace-separated decimal floats>` `\n`
//
// Hex because the input may contain newlines, quotes or NUL-adjacent bytes
// and escaping them would put a second parser in the contract. Plain
// whitespace-separated floats because that is the one line format every
// language can print without a JSON library.
//
//   ```python
//   # embed_server.py — run with: python3 embed_server.py
//   import sys
//   for line in sys.stdin:                      # one hex-encoded input
//       text = bytes.fromhex(line.strip()).decode("utf-8")
//       v = my_model.encode(text)               # 384 floats
//       print(" ".join(f"{x:.9g}" for x in v), flush=True)
//   ```
//
// ## Determinism
//
// The built-in embedders are deterministic, and invariants across the
// product depend on it. A subprocess backend is deterministic only to the
// extent that the *user's tool* is: mem3 adds no randomness, does not batch
// across inputs (batching is one of the two usual ways a runtime becomes
// non-reproducible), and does not reorder. If the tool is stochastic, so is
// the index — that is the operator's call, and it is why this stays opt-in
// rather than becoming the default.
//
// ## Failure policy
//
// Every way the wire can go wrong is a typed error. There is no path that
// returns a vector this module has not fully validated: wrong width,
// non-finite component, unparseable token, truncated response, oversized
// response, dead child. A silently-wrong vector would poison the HNSW index
// invisibly, which is strictly worse than no vector at all.

const fd_t = std.c.fd_t;
const pid_t = std.c.pid_t;

/// Request bytes tolerated before the input is rejected as absurd. Protects
/// against a caller embedding a whole WAL.
const max_request_bytes = 1 << 20;

/// Fixed probe text. Its content does not matter; only the *width* of the
/// reply does, and that is what construction-time validation checks.
const probe_input = "mem3 embedder probe";

/// Bytes reserved per float in the response buffer. `%.9g` is 12 characters;
/// the widest legal f32 text (`-1.4012984643e-45`) is 18.
const response_bytes_per_dim = 24;

/// Hard ceiling on the response buffer, so a backend that never emits a
/// newline cannot make the process allocate without bound. The buffer is
/// also capped at one maximal-width line (`dim * 24 + 64`), which is the
/// smaller of the two for every realistic dimension.
const max_response_bytes = 1 << 20;

pub const ExternalError = error{
    /// The program is not on PATH, or the path does not exist.
    BackendNotFound,
    /// The program exists but cannot be run (EACCES/ENOEXEC).
    BackendNotExecutable,
    /// Spawn failed for any other reason (EMFILE, ENOMEM, ...).
    BackendSpawnFailed,
    /// The child closed its stdout or exited: crash, OOM-kill, or a tool
    /// that decided to stop.
    BackendExited,
    /// A second embed arrived while the first was still in flight. One pipe
    /// carries one request at a time; interleaving would corrupt framing.
    BackendBusy,
    /// `close` already ran.
    BackendClosed,
    /// Writing the request failed (the child died between the liveness check
    /// and the write).
    WriteFailed,
    /// Reading the response failed.
    ReadFailed,
    /// The input is larger than `max_request_bytes`.
    RequestTooLarge,
    /// The child emitted more than the response buffer without a newline.
    ResponseTooLarge,
    /// The response line was empty, truncated mid-line, or carried a token
    /// that is not a float (or carried more tokens than `dim`).
    MalformedResponse,
    /// The reply had a different number of floats than `dim`. Checked on
    /// every call, and at construction via the probe.
    EmbeddingDimensionMismatch,
    /// A component was NaN or ±Inf.
    NonFiniteValue,
    /// All components were zero, or the L2 norm overflowed. An all-zero
    /// vector is not a valid embedding: it makes every distance identical
    /// and would silently flatten ranking.
    DegenerateVector,
    /// Allocation failed. Listed explicitly because the error set is
    /// hand-written rather than inferred.
    OutOfMemory,
};

/// How to reach the external runtime. `cmd` is resolved through `PATH`
/// (a PATH walk), so `"python3"` works as well as an absolute path.
/// There is no shell: `args` is passed through verbatim, so quoting and
/// globbing are the caller's problem and injection is not possible.
pub const ExternalSpec = struct {
    cmd: []const u8,
    args: []const []const u8 = &.{},
    /// Must equal the width the tool actually emits; a mismatch is rejected
    /// here, at construction, not discovered mid-write.
    dim: u16,
};

// --- libc / spawn glue -------------------------------------------------------
// 0.17 exposes `std.process.Child` only through `std.Io`, and the library
// deliberately carries no `Io` (Store.init and every Embedder call site are
// `Io`-free; adding one would change files this change does not own). So the
// few POSIX calls we need are declared here against libc directly. Symbols
// only -- `otool -L` still lists libSystem and nothing else.
//
// fork + execve, not posix_spawn: `posix_spawn_file_actions_t` is an opaque
// library-allocated block whose size differs per libc (glibc 16 bytes, musl
// 136), which would be a portability guess in a project with two supported
// platforms. fork+execve has no such struct, works identically on both, and
// the child touches nothing but dup2/close/execve before exec -- the
// async-signal-safe discipline that makes fork safe in the daemon's
// multi-threaded process.

const c_signal = struct {
    extern "c" fn signal(sig: c_int, handler: usize) usize;
};

const c_close = struct {
    // `close` is not exported by std.c on 0.17. libc is, and linking libc is
    // what the binary already does.
    extern "c" fn close(fd: fd_t) c_int;
};

const c_fork = struct {
    extern "c" fn fork() c_int;
};

fn closeFdRaw(fd: fd_t) void {
    if (fd < 0) return;
    _ = c_close.close(fd);
}

/// Ignore SIGPIPE, once. Without this, a backend that dies between our
/// liveness check and our `write` delivers SIGPIPE and kills the *host*
/// process instead of returning an error. mem3 has no correct use for a
/// fatal SIGPIPE (its server writes to sockets), but changing a
/// process-global disposition is called out here because it is the one
/// global side effect in this file.
fn ignoreSigpipe() void {
    // SIG_IGN is 1 in the C ABI (`std.c.SIG.IGN` is the same value, typed as
    // a function pointer there, which is why it is spelled as an integer
    // here and not passed through).
    _ = c_signal.signal(@backingInt(std.posix.SIG.PIPE), 1);
}

/// Longest program path we will resolve. PATH entries longer than this are
/// pathological; failing them is better than a VLA-sized stack buffer.
const max_path_len = 4096;

fn accessPath(path: []const u8, mode: c_uint) ExternalError!void {
    if (path.len + 1 > max_path_len) return error.BackendNotFound;
    var buf: [max_path_len]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.c.access(@ptrCast(&buf), mode);
    if (rc == 0) return;
    // `std.c.errno` only reads errno when rc == -1, and access() reports
    // failure that way, so the switch is on the real code.
    return switch (std.c.errno(rc)) {
        .NOENT => error.BackendNotFound,
        .ACCES, .PERM, .NOEXEC => error.BackendNotExecutable,
        else => error.BackendNotFound,
    };
}

/// Validate one candidate path: it has to exist (else `NotFound`) *and* be
/// executable (else `NotExecutable`). Those are different operator mistakes
/// and get different messages.
fn checkExecutable(path: []const u8) ExternalError!void {
    try accessPath(path, std.c.F_OK);
    try accessPath(path, std.c.X_OK);
}

/// Resolve `cmd` to an executable absolute-or-relative path, searching PATH
/// when the caller gave a bare name. Resolution happens in the *parent*, so
/// "no such program" is a precise error at construction instead of a child
/// dying silently on the first request.
fn resolveProgram(alloc: Allocator, cmd: []const u8) ExternalError![:0]u8 {
    if (cmd.len == 0) return error.BackendNotFound;
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        try checkExecutable(cmd);
        return alloc.dupeSentinel(u8, cmd, 0);
    }
    const env: [*:null]const ?[*:0]const u8 = @ptrCast(@constCast(std.c.environ));
    var i: usize = 0;
    while (env[i]) |raw| : (i += 1) {
        const entry = std.mem.span(raw);
        if (!std.mem.startsWith(u8, entry, "PATH=")) continue;
        var dirs = std.mem.splitScalar(u8, entry["PATH=".len..], ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue; // POSIX: empty PATH element is "."
            const joined = std.mem.concat(alloc, u8, &.{ dir, "/", cmd }) catch return error.BackendNotFound;
            defer alloc.free(joined);
            if (checkExecutable(joined)) |_| {
                return alloc.dupeSentinel(u8, joined, 0) catch return error.BackendSpawnFailed;
            } else |_| {
                continue;
            }
        }
    }
    return error.BackendNotFound;
}

/// Spawn, wire the three standard descriptors, execve. Returns the child pid.
/// Between `fork` and `execve` the child calls only dup2, close, write and
/// execve, which is what keeps this safe inside the daemon's threaded
/// process.
///
/// `exec_err_fd` is the write end of an FD_CLOEXEC pipe. If execve fails the
/// child writes its errno there before exiting; if it succeeds the kernel
/// closes the descriptor and the parent's read sees EOF. That is the only
/// race-free way to tell "the program is not there" from "the program ran and
/// died", and it is what keeps the construction-time error precise instead of
/// a coin flip between `BackendNotFound` and `BackendExited`.
fn spawnChild(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    in_fd: fd_t,
    out_fd: fd_t,
    err_fd: fd_t,
    exec_err_fd: fd_t,
) ExternalError!pid_t {
    const pid = c_fork.fork();
    if (pid < 0) return error.BackendSpawnFailed;
    if (pid == 0) {
        if (std.c.dup2(in_fd, 0) < 0) execFailure(exec_err_fd, @backingInt(std.c.E.BADF));
        if (std.c.dup2(out_fd, 1) < 0) execFailure(exec_err_fd, @backingInt(std.c.E.BADF));
        if (std.c.dup2(err_fd, 2) < 0) execFailure(exec_err_fd, @backingInt(std.c.E.BADF));
        if (in_fd > 2) _ = c_close.close(in_fd);
        if (out_fd > 2) _ = c_close.close(out_fd);
        if (err_fd > 2) _ = c_close.close(err_fd);
        // Inherit the environment: a venv-based runtime needs VIRTUAL_ENV
        // and HOME, and PATH has already done its job in the parent.
        //
        // `std.c.environ`'s *value*, not `&std.c.environ`: taking the
        // address of the extern var and casting that yields a pointer execve
        // rejects with EFAULT. Verified both ways before settling on this
        // spelling.
        const rc = std.c.execve(path, argv, @ptrCast(@constCast(std.c.environ)));
        execFailure(exec_err_fd, @backingInt(std.c.errno(rc)));
    }
    return pid;
}

/// Async-signal-safe: four bytes and `_exit`. The parent closes the read end
/// only after it has seen this, so the write never blocks.
fn execFailure(exec_err_fd: fd_t, err: c_int) noreturn {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @as(u32, @bitCast(err)), .little);
    _ = std.c.write(exec_err_fd, &buf, buf.len);
    std.c._exit(127);
}

/// Set FD_CLOEXEC so the descriptor disappears at a *successful* exec.
fn setCloexec(fd: fd_t) void {
    // F_SETFD / FD_CLOEXEC are the same on every POSIX platform we support;
    // `pipe2(O_CLOEXEC)` would be tidier but does not exist on macOS.
    const F_SETFD: c_int = 2;
    const FD_CLOEXEC: c_int = 1;
    _ = std.c.fcntl(fd, F_SETFD, FD_CLOEXEC);
}

/// Read the exec-error pipe. Returns the child's errno when exec failed, or
/// null when exec succeeded (EOF, because the descriptor was CLOEXEC).
fn readExecError(rd: fd_t) ?c_int {
    var buf: [4]u8 = undefined;
    const n = std.c.read(rd, &buf, buf.len);
    closeFdRaw(rd);
    if (n != @as(isize, buf.len)) return null;
    return @bitCast(std.mem.readInt(u32, &buf, .little));
}

fn mapExecError(err: c_int) ExternalError {
    const code = @as(u16, @intCast(err & 0xff));
    return switch (@as(std.c.E, @fromBackingInt(@intCast(code)))) {
        .NOENT => error.BackendNotFound,
        .ACCES, .PERM, .NOEXEC, .ISDIR => error.BackendNotExecutable,
        else => error.BackendSpawnFailed,
    };
}

/// One live child process plus the two pipe buffers it is spoken to through.
/// Heap-allocated and shared by pointer so that the copies of the `Embedder`
/// union living in `Store` and `Store.hybrid` share one pipe (and cannot
/// double-close it).
const Backend = struct {
    alloc: Allocator,
    dim: u16,
    pid: pid_t,
    to_child: fd_t,
    from_child: fd_t,
    req: []u8,
    resp: []u8,
    in_use: bool = false,
    closed: bool = false,

    fn init(alloc: Allocator, spec: ExternalSpec) ExternalError!*Backend {
        std.debug.assert(spec.dim > 0);
        ignoreSigpipe();

        const in_fds = try pipePair();
        errdefer closeFdRaw(in_fds[0]);
        errdefer closeFdRaw(in_fds[1]);
        const out_fds = try pipePair();
        errdefer closeFdRaw(out_fds[0]);
        errdefer closeFdRaw(out_fds[1]);

        // The child's stderr goes to /dev/null. Not "inherited": a library
        // must never let a child's diagnostics reach the host's stderr,
        // which would desynchronise `zig build test --listen=-`. It is also
        // not a pipe we drain: a third pipe with no reader draining it is a
        // deadlock waiting to happen, and interleaved stderr bytes on stdout
        // would corrupt the framing anyway.
        const devnull_z = "/dev/null";
        const devnull = std.c.open(devnull_z, std.c.O{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (devnull < 0) return error.BackendSpawnFailed;
        defer closeFdRaw(devnull);

        // Resolved before the fork so "no such program" is reported as
        // itself, not as a child that died before writing a byte.
        const program = try resolveProgram(alloc, spec.cmd);
        defer alloc.free(program);

        // The exec-error pipe. Set up before the fork so the child inherits
        // it already CLOEXEC.
        const exec_err = try pipePair();
        errdefer closeFdRaw(exec_err[0]);
        errdefer closeFdRaw(exec_err[1]);
        setCloexec(exec_err[1]);

        var owned: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned.items) |o| alloc.free(o);
            owned.deinit(alloc);
        }
        var argv: std.ArrayList([*:0]const u8) = .empty;
        defer argv.deinit(alloc);
        try appendArg(alloc, &owned, &argv, spec.cmd);
        for (spec.args) |a| try appendArg(alloc, &owned, &argv, a);
        // exec's argv is NULL-terminated; an ArrayList of a non-optional
        // pointer cannot carry that terminator, so build the C array once.
        const argv_z = try alloc.alloc(?[*:0]const u8, argv.items.len + 1);
        defer alloc.free(argv_z);
        for (argv.items, 0..) |a, i| argv_z[i] = a;
        argv_z[argv.items.len] = null;
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);

        // The child gets the *read* end of the request pipe as stdin and
        // the *write* end of the response pipe as stdout.
        const pid = try spawnChild(program.ptr, argv_ptr, in_fds[0], out_fds[1], devnull, exec_err[1]);

        // Parent side: drop the children's ends, and keep its own — the
        // write end of the request pipe and the read end of the response
        // pipe. Leaving the child's ends open here would mean its stdout
        // never sees EOF when it exits.
        closeFdRaw(in_fds[0]);
        closeFdRaw(out_fds[1]);
        closeFdRaw(exec_err[1]);

        // Blocks until the child either execs (EOF: descriptor was CLOEXEC)
        // or reports why it could not. Both are quick: the child does
        // nothing between fork and execve except this.
        if (readExecError(exec_err[0])) |err| {
            // exec never happened, so reap the child we just made before
            // reporting; nothing else owns it.
            _ = std.c.kill(pid, .KILL);
            var dead: c_int = 0;
            _ = std.c.waitpid(pid, &dead, 0);
            closeFdRaw(in_fds[1]);
            closeFdRaw(out_fds[0]);
            return mapExecError(err);
        }

        const be = try alloc.create(Backend);
        be.* = .{
            .alloc = alloc,
            .dim = spec.dim,
            .pid = pid,
            .to_child = in_fds[1],
            .from_child = out_fds[0],
            .req = &.{},
            .resp = &.{},
        };
        errdefer {
            be.close();
            alloc.destroy(be);
        }
        be.req = try alloc.alloc(u8, 1024);
        // One maximal-width line, and no more: a backend that never emits
        // '\n' fills this buffer and is reported rather than allowed to
        // grow the heap without bound.
        be.resp = try alloc.alloc(
            u8,
            @min(@as(usize, spec.dim) * response_bytes_per_dim + 64, max_response_bytes),
        );

        // Construction-time dimension check. Everything else about the tool
        // is the operator's business; the width is ours, because the store
        // has already sized its index by now.
        //
        // The `errdefer` above is the only teardown path here: adding a
        // second one in this catch is exactly the double free that the
        // tests caught.
        const probe = ExternalEmbedder{ .dim = be.dim, .backend = be };
        const v = probe.embed(alloc, probe_input) catch |err| {
            // Exit 127 out of the child is our own "execve failed", i.e. a
            // program that passed the parent's checks and then vanished (or
            // never was runnable, e.g. a directory). Reporting that as a
            // generic exit would send the operator looking at their model
            // instead of at their command.
            return if (err == error.BackendExited) classifyDeadChild(be) else err;
        };
        alloc.free(v);
        return be;
    }

    /// Reap the child and release the pipes and buffers. Idempotent: the
    /// union is copied into `Store.hybrid`, so `close` can legitimately be
    /// reached more than once and must not close an fd twice.
    ///
    /// Deliberately does *not* free the `Backend` struct: a later `embed`
    /// has to be able to read `closed` and answer `BackendClosed` rather
    /// than touch freed memory. `destroy` frees the handle and is called
    /// once, by whoever created it.
    fn close(be: *Backend) void {
        if (be.closed) return;
        be.closed = true;
        if (be.pid > 0) {
            _ = std.c.kill(be.pid, .KILL);
            var status: c_int = 0;
            _ = std.c.waitpid(be.pid, &status, 0);
            be.pid = -1;
        }
        closeFdRaw(be.to_child);
        closeFdRaw(be.from_child);
        be.to_child = -1;
        be.from_child = -1;
        if (be.req.len != 0) {
            be.alloc.free(be.req);
            be.req = &.{};
        }
        if (be.resp.len != 0) {
            be.alloc.free(be.resp);
            be.resp = &.{};
        }
    }

    /// Free the handle itself. Call once, by whoever called `init`.
    fn destroy(be: *Backend) void {
        be.close();
        be.alloc.destroy(be);
    }

    fn writeAll(be: *Backend, bytes: []const u8) ExternalError!void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = std.c.write(be.to_child, bytes[sent..].ptr, bytes.len - sent);
            if (n < 0) {
                switch (std.c.errno(n)) {
                    .INTR => continue,
                    // EPIPE lands here, and is the reason SIGPIPE is ignored.
                    .PIPE => return error.WriteFailed,
                    else => return error.WriteFailed,
                }
            }
            if (n == 0) return error.WriteFailed;
            sent += @intCast(n);
        }
    }

    /// Read until '\n'. Returns a slice of `resp` owned by the backend,
    /// valid until the next call.
    fn readLine(be: *Backend) ExternalError![]const u8 {
        var filled: usize = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, be.resp[0..filled], '\n')) |nl| {
                return be.resp[0..nl];
            }
            if (filled == be.resp.len) return error.ResponseTooLarge;
            const n = std.c.read(be.from_child, be.resp.ptr + filled, be.resp.len - filled);
            if (n == 0) {
                // EOF. A child that exits cleanly between requests shows up
                // here too, which is the same actionable condition.
                if (filled == 0) return error.BackendExited;
                // A line that stops mid-float is corruption, not a short
                // vector: reporting "wrong dimension" would send the
                // operator hunting the wrong bug.
                return error.MalformedResponse;
            }
            if (n < 0) {
                switch (std.c.errno(n)) {
                    .INTR => continue,
                    else => return error.ReadFailed,
                }
            }
            filled += @intCast(n);
        }
    }

    fn childAlive(be: *Backend) bool {
        if (be.pid <= 0) return false;
        var status: c_int = 0;
        const r = std.c.waitpid(be.pid, &status, 1); // WNOHANG
        if (r == be.pid) {
            be.pid = -1;
            return false;
        }
        return true;
    }

    /// Like `childAlive`, but gives a child that is already exiting time to
    /// become reapable. EPIPE on the request pipe means every read end is
    /// closed, and a dying process closes its descriptors before it turns into
    /// a zombie that `waitpid` can collect. A single non-blocking check in
    /// that window answers "alive" for a process that is gone, and the caller
    /// then reports `WriteFailed` instead of `BackendExited`.
    ///
    /// The wait is bounded: a backend that closed its stdin on purpose but is
    /// still running must not hang the caller, so after `budget_ms` it is
    /// treated as alive and the original error stands.
    fn childGoneWithin(be: *Backend, budget_ms: u32) bool {
        var waited: u32 = 0;
        while (true) {
            if (!be.childAlive()) return true;
            if (waited >= budget_ms) return false;
            clock.sleepMs(1);
            waited += 1;
        }
    }
};

fn pipePair() ExternalError![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.BackendSpawnFailed;
    return fds;
}

/// Turn "the child is already gone" into the most specific error we can
/// justify. POSIX wait status, decoded here rather than through `std.posix.W`
/// because only the two facts we need are wanted: exited normally, and with
/// what code.
fn classifyDeadChild(be: *Backend) ExternalError {
    if (be.pid <= 0) return error.BackendExited;
    var status: c_int = 0;
    const r = std.c.waitpid(be.pid, &status, 1); // WNOHANG
    if (r != be.pid) return error.BackendExited;
    be.pid = -1;
    const exited_normally = (status & 0x7f) == 0;
    const code: u32 = @intCast((status >> 8) & 0xff);
    if (exited_normally and code == 127) return error.BackendNotFound;
    return error.BackendExited;
}

fn appendArg(
    alloc: Allocator,
    owned: *std.ArrayList([:0]u8),
    argv: *std.ArrayList([*:0]const u8),
    s: []const u8,
) !void {
    const copy = try alloc.dupeSentinel(u8, s, 0);
    try owned.append(alloc, copy);
    try argv.append(alloc, copy);
}

const hex_digits = "0123456789abcdef";

/// Encode `s` as hex + '\n' into the backend's request buffer.
fn buildRequest(be: *Backend, s: []const u8) ExternalError![]const u8 {
    if (s.len > max_request_bytes) return error.RequestTooLarge;
    const need = s.len * 2 + 1;
    if (be.req.len < need) {
        const grown = try be.alloc.alloc(u8, need * 2);
        be.alloc.free(be.req);
        be.req = grown;
    }
    const buf = be.req[0..need];
    for (s, 0..) |b, i| {
        buf[i * 2] = hex_digits[b >> 4];
        buf[i * 2 + 1] = hex_digits[b & 0x0f];
    }
    buf[need - 1] = '\n';
    return buf;
}

/// Parse exactly `dim` floats. Order of the checks is the contract: an extra
/// token is a protocol violation, a short line is a dimension problem, and a
/// non-finite component is never allowed through even in the right place.
fn parseVector(line: []const u8, out: []f32) ExternalError!void {
    var count: usize = 0;
    // '\n' cannot survive `readLine`, but tolerating it costs nothing and
    // keeps this function correct if it is ever called on a raw line.
    var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
    while (it.next()) |tok| {
        if (count >= out.len) return error.MalformedResponse;
        const v = std.fmt.parseFloat(f32, tok) catch return error.MalformedResponse;
        if (!std.math.isFinite(v)) return error.NonFiniteValue;
        out[count] = v;
        count += 1;
    }
    if (count != out.len) {
        // Nothing at all on the line is a protocol violation, not a short
        // vector: it is what a backend prints when it has nothing to say.
        if (count == 0) return error.MalformedResponse;
        return error.EmbeddingDimensionMismatch;
    }
}

/// L2 normalise, so dot product == cosine just like the built-ins. Rejects
/// the degenerate cases instead of returning a vector that would rank
/// nothing.
fn normalise(out: []f32) ExternalError!void {
    var norm: f32 = 0.0;
    for (out) |v| norm += v * v;
    if (!std.math.isFinite(norm) or !(norm > 0.0)) return error.DegenerateVector;
    const inv = 1.0 / @sqrt(norm);
    for (out) |*v| v.* *= inv;
}

pub const ExternalEmbedder = struct {
    /// Kept as a real field, not just a `Backend` member, because both
    /// built-in variants expose `dim` as a plain field and existing call
    /// sites (including the MCP tools) read `embedder.dim` through the
    /// union. Losing that would be a source break in a file this change
    /// does not own.
    dim: u16,
    backend: *Backend,

    pub fn embed(self: *const ExternalEmbedder, alloc: Allocator, s: []const u8) ExternalError![]f32 {
        const be = self.backend;
        if (be.closed) return error.BackendClosed;
        if (be.in_use) return error.BackendBusy;
        be.in_use = true;
        defer be.in_use = false;

        // Reap a dead child before writing rather than after: it turns the
        // common "the tool exited" case into a clean error instead of a
        // pipe error, and the waitpid is non-blocking.
        if (!be.childAlive()) return error.BackendExited;

        const out = try alloc.alloc(f32, be.dim);
        errdefer alloc.free(out);

        be.writeAll(try buildRequest(be, s)) catch |err| switch (err) {
            // EPIPE means nobody is reading the request pipe, i.e. the
            // backend died between the liveness check above and this
            // write. It is the same condition `BackendExited` already
            // names, and an operator should not have to learn two error
            // names for one failure.
            error.WriteFailed => {
                if (be.childGoneWithin(exit_grace_ms)) return error.BackendExited;
                return err;
            },
            else => return err,
        };
        const line = try be.readLine();
        try parseVector(line, out);
        try normalise(out);
        return out;
    }

    pub fn embedBatch(
        self: *const ExternalEmbedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ExternalError![][]f32 {
        const out = try alloc.alloc([]f32, inputs.len);
        for (inputs, 0..) |s, i| {
            out[i] = self.embed(alloc, s) catch |err| {
                var j = i;
                while (j > 0) : (j -= 1) alloc.free(out[j - 1]);
                alloc.free(out);
                return err;
            };
        }
        return out;
    }

    pub fn close(self: *const ExternalEmbedder) void {
        self.backend.close();
    }

    /// Release the shared handle. Exactly once, by the creator.
    pub fn destroy(self: *const ExternalEmbedder) void {
        self.backend.destroy();
    }
};

// =============================================================================
// Embedder — the common seam
// =============================================================================

/// One embedder shape. Call sites hold an `Embedder` and do not care which
/// variant backs it, so a real embedding model can replace `lexical_hash`
/// later without touching them.
pub const Embedder = union(enum) {
    stub_xxhash: StubEmbedder,
    lexical_hash: LexicalEmbedder,
    /// Opt-in external runtime. Reached through `initExternal`, never
    /// through `init(kind, dim)`: selecting it needs a program path, and
    /// `Config.EmbedderKind` has no field to carry one.
    external_pipe: ExternalEmbedder,

    /// `EmbedderKind.onnx_external` is reserved for a v0.2.0 model load
    /// and has no implementation. It used to `@panic` from `init`, which
    /// is a crash: the variant is reachable from a deserialised config
    /// (`Config.embedder_kind`), so any future config loader would take
    /// the whole daemon down on a value that is documented as legal.
    /// The constitution's API Surface Standards say no panics in
    /// libraries, so this is a typed error the caller decides what to
    /// do with.
    ///
    /// Wiring this enum value to `ExternalEmbedder` needs a command field
    /// on `Config`, which lives in a file this change does not own; until
    /// that exists, `ExternalSpec` is the only way in and the honest
    /// mapping from this enum value stays "unsupported".
    pub const InitError = error{UnsupportedEmbedder};

    pub fn init(kind: config.Config.EmbedderKind, dim: u16) InitError!Embedder {
        return switch (kind) {
            .stub_xxhash => .{ .stub_xxhash = StubEmbedder.init(dim) },
            .lexical_hash => .{ .lexical_hash = LexicalEmbedder.init(dim) },
            .onnx_external => error.UnsupportedEmbedder,
        };
    }

    /// Build the opt-in external backend. Fails — loudly, at construction —
    /// when the tool is missing, cannot be executed, dies during the probe,
    /// or answers with a width other than `spec.dim`.
    pub fn initExternal(alloc: Allocator, spec: ExternalSpec) ExternalError!Embedder {
        const be = try Backend.init(alloc, spec);
        return .{ .external_pipe = .{ .dim = be.dim, .backend = be } };
    }

    pub fn fromConfig(cfg: config.Config) InitError!Embedder {
        return init(cfg.embedder_kind, cfg.embedder_dim);
    }

    pub fn embed(self: *const Embedder, alloc: Allocator, s: []const u8) ![]f32 {
        return switch (self.*) {
            inline else => |e| e.embed(alloc, s),
        };
    }

    pub fn embedBatch(
        self: *const Embedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ![][]f32 {
        return switch (self.*) {
            inline else => |e| e.embedBatch(alloc, inputs),
        };
    }

    /// Release backend-owned resources. A no-op for the two built-ins, so
    /// every existing call site can call it unconditionally. Idempotent,
    /// and leaves the handle readable so a later `embed` answers
    /// `BackendClosed` instead of touching freed memory.
    pub fn close(self: *const Embedder) void {
        switch (self.*) {
            .stub_xxhash, .lexical_hash => {},
            .external_pipe => |e| e.close(),
        }
    }

    /// `close` plus freeing the shared backend handle. Once, from the owner.
    pub fn destroy(self: *const Embedder) void {
        switch (self.*) {
            .stub_xxhash, .lexical_hash => {},
            .external_pipe => |e| e.destroy(),
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StubEmbedder: deterministic" {
    const alloc = std.testing.allocator;
    const emb = StubEmbedder.init(8);

    const v1 = try emb.embed(alloc, "hello");
    defer alloc.free(v1);
    const v2 = try emb.embed(alloc, "hello");
    defer alloc.free(v2);
    try std.testing.expectEqualSlices(f32, v1, v2);

    const v3 = try emb.embed(alloc, "world");
    defer alloc.free(v3);
    try std.testing.expect(!std.mem.eql(f32, v1, v3));
}

test "StubEmbedder: unit norm" {
    const alloc = std.testing.allocator;
    const emb = StubEmbedder.init(64);
    const v = try emb.embed(alloc, "test");
    defer alloc.free(v);
    var norm: f32 = 0.0;
    for (v) |x| norm += x * x;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);
}

fn cosOf(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0.0;
    for (a, 0..) |x, i| dot += x * b[i];
    return dot; // both sides are already unit norm
}

fn cosOfText(alloc: Allocator, e: *const LexicalEmbedder, a: []const u8, b: []const u8) !f32 {
    const va = try e.embed(alloc, a);
    defer alloc.free(va);
    const vb = try e.embed(alloc, b);
    defer alloc.free(vb);
    return cosOf(va, vb);
}

// The headline property: retrieval now means something. This is the test the
// old hash-based stub cannot pass — it fails on the `> 0.5` expectation.
test "LexicalEmbedder: overlapping vocabulary ranks far above unrelated" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const related = try cosOfText(alloc, &e, "the user prefers zig", "the user really prefers zig");
    const unrelated = try cosOfText(
        alloc,
        &e,
        "the user prefers zig",
        "quarterly revenue forecast for the logistics division",
    );

    std.log.info("lexical: related={d:.4} unrelated={d:.4}", .{ related, unrelated });

    try std.testing.expect(related > 0.7);
    try std.testing.expect(unrelated < 0.2);
    try std.testing.expect(related > unrelated * 4.0);
}

test "LexicalEmbedder: deterministic" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const v1 = try e.embed(alloc, "the user prefers zig over rust");
    defer alloc.free(v1);
    const v2 = try e.embed(alloc, "the user prefers zig over rust");
    defer alloc.free(v2);
    try std.testing.expectEqualSlices(f32, v1, v2);

    // Case and separator differences must not change the vector.
    const v3 = try e.embed(alloc, "The  User, PREFERS zig over rust!");
    defer alloc.free(v3);
    try std.testing.expectEqualSlices(f32, v1, v3);
}

test "LexicalEmbedder: char n-grams give partial credit for morphology and typos" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const morph = try cosOfText(alloc, &e, "preference", "preferences");
    const typo = try cosOfText(alloc, &e, "embed", "embedded");
    const unrelated = try cosOfText(alloc, &e, "embed", "kubernetes ingress controller rollout");

    std.log.info("lexical: preference/preferences={d:.4} embed/embedded={d:.4} unrelated={d:.4}", .{
        morph, typo, unrelated,
    });

    // Morphological variants stay strongly related.
    try std.testing.expect(morph > 0.35);
    // Single words differ entirely — only the char 3-grams overlap, so this
    // is genuine partial credit, not exact-token matching.
    try std.testing.expect(typo > 0.2);
    try std.testing.expect(unrelated < 0.05);
    try std.testing.expect(typo > unrelated);
}

test "LexicalEmbedder: a typo still retrieves its source" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const clean = try cosOfText(alloc, &e, "configure the vector index", "configure teh vektor index");
    std.log.info("lexical: typo-tolerant cosine={d:.4}", .{clean});
    try std.testing.expect(clean > 0.4);
}

test "LexicalEmbedder: unit norm" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    // A pathologically repetitive input must still normalise cleanly.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(alloc);
    for (0..40) |_| try long.appendSlice(alloc, "the user prefers zig ");

    const inputs = [_][]const u8{ "hello", "the user prefers zig", long.items };
    for (inputs) |s| {
        const v = try e.embed(alloc, s);
        defer alloc.free(v);
        var norm: f32 = 0.0;
        for (v) |x| norm += x * x;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);
    }
}

test "LexicalEmbedder: empty and punctuation-only input is defined" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    for ([_][]const u8{ "", "   ", "--- ... !!! ???", "\n\t" }) |s| {
        const v = try e.embed(alloc, s);
        defer alloc.free(v);
        try std.testing.expectEqual(@as(usize, 384), v.len);
        for (v) |x| try std.testing.expectEqual(@as(f32, 0.0), x);
    }

    // Two empty inputs must still compare equal (0.0, not NaN).
    const a = try e.embed(alloc, "");
    defer alloc.free(a);
    const b = try e.embed(alloc, "...");
    defer alloc.free(b);
    try std.testing.expectEqual(@as(f32, 0.0), cosOf(a, b));
}

// Guards the sign trick: without random ±1 signs, shared buckets would add
// positive bias to every pair and unrelated text would look similar.
test "LexicalEmbedder: signed hashing keeps unrelated pairs centred on zero" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const corpus = [_][]const u8{
        "the user prefers zig over rust",
        "quarterly revenue forecast for logistics",
        "kubernetes ingress controller rollout failed",
        "she prefers tea in the afternoon",
        "vector index recall benchmark results",
        "the deployment was rolled back",
        "postgres vacuum blocked a long query",
        "notes on the alignment problem",
    };

    var sum: f64 = 0.0;
    var n: usize = 0;
    for (corpus, 0..) |a, i| {
        const va = try e.embed(alloc, a);
        defer alloc.free(va);
        for (corpus, 0..) |b, j| {
            if (i >= j) continue;
            const vb = try e.embed(alloc, b);
            defer alloc.free(vb);
            sum += @floatCast(cosOf(va, vb));
            n += 1;
        }
    }

    const mean: f32 = @floatCast(sum / @as(f64, @floatFromInt(n)));
    std.log.info("lexical: mean pairwise cosine over {d} pairs = {d:.4}", .{ n, mean });

    // A couple of corpus members genuinely overlap ("prefers", "rolled back"),
    // so the mean is allowed a little slack — but it must not be positive-biased.
    try std.testing.expect(mean < 0.15);
    try std.testing.expect(mean > -0.15);
}

test "LexicalEmbedder: repeated words do not dominate" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    // Sublinear tf keeps a repeated stop word from swamping the content
    // words. With linear tf, four copies of "the" would drag this vector
    // away from its own base text and toward a generic "the" direction.
    const a = try e.embed(alloc, "the the the the retrieval index is fast");
    defer alloc.free(a);
    const b = try e.embed(alloc, "the retrieval index is fast");
    defer alloc.free(b);
    const vs_unrelated = try cosOfText(
        alloc,
        &e,
        "the the the the retrieval index is fast",
        "quartz calcite feldspar mica",
    );
    const vs_base = cosOf(a, b);
    std.log.info("lexical: tf-damped vs base={d:.4} vs unrelated={d:.4}", .{ vs_base, vs_unrelated });

    // Still recognisably the same statement...
    try std.testing.expect(vs_base > 0.7);
    // ...and not dragged toward some unrelated stop-word-heavy text.
    try std.testing.expect(vs_unrelated < 0.2);
}

// End-to-end through the real index: this is the property the whole system
// exists for.
test "LexicalEmbedder + HNSW: relevant cell is retrieved first" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const docs = [_]struct { id: u64, text: []const u8 }{
        .{ .id = 1, .text = "the user prefers zig for systems programming" },
        .{ .id = 2, .text = "quarterly revenue forecast for the logistics division" },
        .{ .id = 3, .text = "kubernetes ingress controller rollout failed overnight" },
        .{ .id = 4, .text = "postgres vacuum blocked a long running query" },
        .{ .id = 5, .text = "notes on the vecchio alignment problem" },
    };

    var hnsw = @import("hnsw.zig").HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();

    for (docs) |d| {
        const v = try e.embed(alloc, d.text);
        defer alloc.free(v);
        try hnsw.insert(d.id, v);
    }

    const q = try e.embed(alloc, "the user really prefers zig");
    defer alloc.free(q);

    const results = try hnsw.search(alloc, q, 3);
    defer alloc.free(results);

    try std.testing.expect(results.len >= 3);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expect(results[0].score > results[2].score);
}

test "Embedder: union selects the configured kind" {
    const alloc = std.testing.allocator;

    var cfg = config.Config{};
    cfg.embedder_dim = 384;

    cfg.embedder_kind = .stub_xxhash;
    const stub = try Embedder.fromConfig(cfg);
    try std.testing.expect(stub == .stub_xxhash);

    cfg.embedder_kind = .lexical_hash;
    const lex = try Embedder.fromConfig(cfg);
    try std.testing.expect(lex == .lexical_hash);

    const via_stub = try stub.embed(alloc, "the user prefers zig");
    defer alloc.free(via_stub);
    const via_lex = try lex.embed(alloc, "the user prefers zig");
    defer alloc.free(via_lex);
    try std.testing.expectEqual(@as(usize, 384), via_stub.len);
    try std.testing.expectEqual(@as(usize, 384), via_lex.len);
    try std.testing.expect(!std.mem.eql(f32, via_stub, via_lex));

    const batch = try lex.embedBatch(alloc, &.{ "alpha beta", "beta gamma" });
    defer {
        for (batch) |v| alloc.free(v);
        alloc.free(batch);
    }
    try std.testing.expectEqual(@as(usize, 2), batch.len);
}

test "Embedder: the reserved variant is a typed error, never a panic" {
    // The constitution's API Surface Standards forbid panics in
    // libraries, and `.onnx_external` is reachable from a config file.
    // This test fails loudly if anyone reintroduces `@panic` here: the
    // process dies instead of returning, and the runner reports it.
    try std.testing.expectError(
        error.UnsupportedEmbedder,
        Embedder.init(.onnx_external, 384),
    );
    try std.testing.expectError(
        error.UnsupportedEmbedder,
        Embedder.fromConfig(.{ .embedder_kind = .onnx_external }),
    );
}

test "Config: lexical_hash is a selectable EmbedderKind" {
    const c: config.Config = .{};
    try std.testing.expectEqual(@as(u16, 384), c.embedder_dim);

    const lex: config.Config = .{ .embedder_kind = .lexical_hash };
    try std.testing.expect(lex.embedder_kind == .lexical_hash);
    // Default stays on the stub so no existing behaviour changes implicitly.
    try std.testing.expect(c.embedder_kind == .stub_xxhash);
}

// =============================================================================
// ExternalEmbedder tests
// =============================================================================

/// Every process-level test needs a shell to be the "model". If there is
/// none, the case is skipped rather than silently passed (AGENTS.md rule 2).
fn requireShell() !void {
    const fd = std.c.open("/bin/sh", std.c.O{}, @as(std.c.mode_t, 0));
    if (fd < 0) return error.SkipZigTest;
    closeFdRaw(fd);
}

fn expectConstructFails(expected: ExternalError, spec: ExternalSpec) !void {
    const alloc = std.testing.allocator;
    if (Embedder.initExternal(alloc, spec)) |emb| {
        var live = emb;
        live.destroy();
        std.log.err("expected construction to fail with {s}", .{@errorName(expected)});
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

// --- the pure layer: parsing and normalising, no child involved -----------

test "ExternalEmbedder: the parser accepts exactly dim finite floats" {
    var out = [_]f32{ 9, 9, 9, 9 };
    try parseVector("1 2 3 4", &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &out);

    // Tabs and \r\n are tolerated: a tool printing on Windows-style lines
    // is a formatting quirk, not corruption.
    try parseVector("1\t2\r\n3  4", &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &out);

    // Exponent notation is what most runtimes print for small components.
    try parseVector("1e-3 -2.5E+2 0.5 .25", &out);
    try std.testing.expectEqualSlices(f32, &.{ 1e-3, -250, 0.5, 0.25 }, &out);
}

test "ExternalEmbedder: every malformed response shape is a typed error" {
    var out = [_]f32{ 9, 9, 9, 9 };

    // Too few / too many components are different bugs and get different
    // errors, because they send the operator to different places.
    try std.testing.expectError(
        error.EmbeddingDimensionMismatch,
        parseVector("1 2 3", &out),
    );
    // A non-numeric token anywhere in the line.
    try std.testing.expectError(
        error.MalformedResponse,
        parseVector("1 2 three 4", &out),
    );
    // Trailing garbage after a complete vector.
    try std.testing.expectError(
        error.MalformedResponse,
        parseVector("1 2 3 4 5", &out),
    );
    // Nothing at all.
    try std.testing.expectError(error.MalformedResponse, parseVector("", &out));
    try std.testing.expectError(error.MalformedResponse, parseVector("   ", &out));
    // NaN and both infinities never survive, in any position.
    try std.testing.expectError(error.NonFiniteValue, parseVector("nan 2 3 4", &out));
    try std.testing.expectError(error.NonFiniteValue, parseVector("1 2 3 inf", &out));
    try std.testing.expectError(error.NonFiniteValue, parseVector("1 2 3 -inf", &out));
    // Note the parser writes components as it goes, so a line that fails
    // halfway leaves the caller's buffer partly filled. That is not a leak
    // of trust: `embed` allocates a fresh vector and frees it on the error
    // path, so a failed parse never yields a vector at all.
}

test "ExternalEmbedder: a zero or overflowing vector is refused, not normalised" {
    var zeros = [_]f32{ 0, 0, 0, 0 };
    try std.testing.expectError(error.DegenerateVector, normalise(&zeros));

    var huge = [_]f32{ 1e30, 1e30, 1e30, 1e30 };
    try std.testing.expectError(error.DegenerateVector, normalise(&huge));

    var ok = [_]f32{ 3, 4, 0, 0 };
    try normalise(&ok);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), ok[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), ok[1], 1e-6);
}

// --- the process layer ------------------------------------------------------

test "ExternalEmbedder: a working backend is framed, validated and normalised" {
    try requireShell();
    const alloc = std.testing.allocator;

    // Echoes the request length back as the first component, so the test can
    // prove the exact bytes that crossed the pipe: hex doubles every byte,
    // and `read -r` strips the newline we appended.
    const args = [_][]const u8{
        "-c",
        "while IFS= read -r l; do printf '%s 1 0 0\\n' \"${#l}\"; done",
    };
    var emb = try Embedder.initExternal(alloc, .{ .cmd = "/bin/sh", .args = &args, .dim = 4 });
    defer emb.destroy();

    const text = "the user prefers zig";
    const v = try emb.embed(alloc, text);
    defer alloc.free(v);

    try std.testing.expectEqual(@as(usize, 4), v.len);
    // v == [2*len(text), 1, 0, 0] before normalisation, so the ratio
    // survives it: this is the request framing, asserted end to end.
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(text.len * 2)),
        v[0] / v[1],
        0.01,
    );
    var norm: f32 = 0;
    for (v) |x| norm += x * x;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);

    // Determinism, insofar as it is ours to be: the same input through the
    // same process must be byte-identical.
    const again = try emb.embed(alloc, text);
    defer alloc.free(again);
    try std.testing.expectEqualSlices(f32, v, again);

    // Batch is the same pipe, one frame at a time. This double answers with
    // the request's *length*, so two different lengths must give two
    // different vectors — that is what proves the frames are not being
    // mixed up between items.
    const batch = try emb.embedBatch(alloc, &.{ "aaaa", "bbbbbbbb" });
    defer {
        for (batch) |b| alloc.free(b);
        alloc.free(batch);
    }
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expect(!std.mem.eql(f32, batch[0], batch[1]));

    // An absurd input is refused before anything is written to the pipe,
    // rather than being hex-encoded into a multi-megabyte frame.
    var huge: std.ArrayList(u8) = .empty;
    defer huge.deinit(alloc);
    try huge.appendNTimes(alloc, 'x', max_request_bytes + 1);
    try std.testing.expectError(error.RequestTooLarge, emb.embed(alloc, huge.items));
}

test "ExternalEmbedder: a missing program fails at construction" {
    try expectConstructFails(error.BackendNotFound, .{
        .cmd = "mem3-no-such-embedder-9f3a",
        .dim = 4,
    });
}

test "ExternalEmbedder: a program that cannot be executed fails at construction" {
    // A directory exists on both supported platforms and can never be
    // exec'd. POSIX leaves the exact errno open (`access(X_OK)` accepts a
    // directory because it is searchable, so the refusal only surfaces when
    // exec fails), and every way it surfaces is still a clear error — which
    // is the property under test.
    const alloc = std.testing.allocator;
    const spec = ExternalSpec{ .cmd = "/tmp", .dim = 4 };
    if (Embedder.initExternal(alloc, spec)) |emb| {
        var live = emb;
        live.destroy();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(
            err == error.BackendNotFound or
                err == error.BackendNotExecutable or
                err == error.BackendSpawnFailed,
        );
    }
}

test "ExternalEmbedder: a backend that dies mid-request is BackendExited" {
    try requireShell();
    const alloc = std.testing.allocator;

    // Reads one line, then exits without answering: a crash, an OOM kill and
    // a tool that gives up all look like this from here.
    const mid = [_][]const u8{ "-c", "IFS= read -r l; exit 3" };
    try expectConstructFails(error.BackendExited, .{
        .cmd = "/bin/sh",
        .args = &mid,
        .dim = 4,
    });

    // And the same thing *between* requests: the probe succeeds, the next
    // embed finds the child gone.
    const args = [_][]const u8{
        "-c",
        "IFS= read -r l; printf '1 1 1 1\\n'; exit 0",
    };
    var emb = try Embedder.initExternal(alloc, .{ .cmd = "/bin/sh", .args = &args, .dim = 4 });
    defer emb.destroy();
    try std.testing.expectError(error.BackendExited, emb.embed(alloc, "second"));
}

test "ExternalEmbedder: a wrong width is refused at construction, not mid-write" {
    try requireShell();
    const args = [_][]const u8{ "-c", "while IFS= read -r l; do printf '1 2\\n'; done" };
    try expectConstructFails(error.EmbeddingDimensionMismatch, .{
        .cmd = "/bin/sh",
        .args = &args,
        .dim = 4,
    });
}

test "ExternalEmbedder: a non-finite component never becomes a vector" {
    try requireShell();
    const args = [_][]const u8{ "-c", "while IFS= read -r l; do printf 'nan 1 1 1\\n'; done" };
    try expectConstructFails(error.NonFiniteValue, .{
        .cmd = "/bin/sh",
        .args = &args,
        .dim = 4,
    });
}

test "ExternalEmbedder: garbage, extra tokens and truncation are all refused" {
    try requireShell();

    const garbage = [_][]const u8{ "-c", "while IFS= read -r l; do printf '1 2 x 4\\n'; done" };
    try expectConstructFails(error.MalformedResponse, .{
        .cmd = "/bin/sh",
        .args = &garbage,
        .dim = 4,
    });

    const extra = [_][]const u8{ "-c", "while IFS= read -r l; do printf '1 2 3 4 5\\n'; done" };
    try expectConstructFails(error.MalformedResponse, .{
        .cmd = "/bin/sh",
        .args = &extra,
        .dim = 4,
    });

    // A vector cut off mid-line is corruption, not a short vector.
    const truncated = [_][]const u8{ "-c", "while IFS= read -r l; do printf '1 2 3'; break; done" };
    try expectConstructFails(error.MalformedResponse, .{
        .cmd = "/bin/sh",
        .args = &truncated,
        .dim = 4,
    });
}

test "ExternalEmbedder: an endless response is refused instead of buffered" {
    try requireShell();
    // Never emits a newline. The read buffer is bounded, so this terminates
    // with a typed error instead of growing the heap or hanging forever.
    const flood = [_][]const u8{
        "-c",
        "while IFS= read -r l; do i=0; while [ $i -lt 400 ]; do printf 'x'; i=$((i+1)); done; done",
    };
    try expectConstructFails(error.ResponseTooLarge, .{
        .cmd = "/bin/sh",
        .args = &flood,
        .dim = 4,
    });
}

test "ExternalEmbedder: an all-zero vector is refused" {
    try requireShell();
    const args = [_][]const u8{ "-c", "while IFS= read -r l; do printf '0 0 0 0\\n'; done" };
    try expectConstructFails(error.DegenerateVector, .{
        .cmd = "/bin/sh",
        .args = &args,
        .dim = 4,
    });
}

test "ExternalEmbedder: a second embed in flight is refused, never interleaved" {
    try requireShell();
    const alloc = std.testing.allocator;
    const args = [_][]const u8{
        "-c",
        "while IFS= read -r l; do printf '%s 1 0 0\\n' \"${#l}\"; done",
    };
    var emb = try Embedder.initExternal(alloc, .{ .cmd = "/bin/sh", .args = &args, .dim = 4 });
    defer emb.destroy();

    // `Store` and `Store.hybrid` hold two copies of this union over one
    // pipe. Serial use is fine — the frame is written and read to
    // completion inside one call — but a genuinely concurrent call would
    // splice two responses into one line. That has to be an error, never a
    // plausible-looking vector.
    emb.external_pipe.backend.in_use = true;
    try std.testing.expectError(error.BackendBusy, emb.embed(alloc, "clash"));
    emb.external_pipe.backend.in_use = false;

    const v = try emb.embed(alloc, "clash");
    defer alloc.free(v);
    try std.testing.expectEqual(@as(usize, 4), v.len);
}

test "ExternalEmbedder: close is idempotent, and a closed handle answers rather than crashes" {
    try requireShell();
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "-c", "while IFS= read -r l; do printf '1 1 1 1\\n'; done" };
    var emb = try Embedder.initExternal(alloc, .{ .cmd = "/bin/sh", .args = &args, .dim = 4 });

    const v = try emb.embed(alloc, "before");
    alloc.free(v);

    emb.close();
    emb.close(); // twice: the union is copied, so this must not double-close

    // The handle outlives close on purpose — this must be a typed error,
    // not a read of freed memory.
    try std.testing.expectError(error.BackendClosed, emb.embed(alloc, "after"));
    emb.destroy();
}

// --- the default path, pinned ----------------------------------------------

fn fingerprintFnv(bytes: []const u8, seed: u64) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// The `LexicalEmbedder` output, bit for bit, across the input spread this
// project actually sees: empty, whitespace, ASCII, punctuation soup, CJK,
// emoji, stop-words only, duplicates, and a text far longer than one
// feature-table window. Captured from the unmodified tree before the
// external backend existed; if this test ever fails, the default embedder
// moved and every persisted vector space moved with it.
//
// The fingerprint is over raw bytes, so it holds on the little-endian
// targets this project supports (x86_64 and aarch64, macOS and Linux).
test "LexicalEmbedder: the default path is bit-identical to its pre-change fingerprint" {
    const alloc = std.testing.allocator;

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(alloc);
    for (0..40) |_| try long.appendSlice(alloc, "the user prefers zig over rust and sqlite ");

    const cases = [_][]const u8{
        "",
        "   ",
        "\n\t",
        "hello",
        "The  User, PREFERS zig over rust!",
        "the user prefers zig",
        "the user really prefers zig",
        "\xe8\xae\xb0\xe5\xbf\x86\xe7\xb3\xbb\xe7\xbb\x9f\xe4\xb8\x89\xe6\xba\x90\xe5\x90\x88\xe6\x81\xb9",
        "\xf0\x9f\x9a\x80 launch the index \xf0\x9f\x9a\x80",
        "the of and a to in is it that for",
        "dup dup dup dup",
        long.items,
    };
    // dim=384 fingerprints, in order.
    const expected_384 = [_]u64{
        0x6ab05ef9aa8b9b25, 0x6ab05ef9aa8b9b25, 0x6ab05ef9aa8b9b25, 0x0e9906be5c7a59d0,
        0x1d76644232e3c572, 0xbd06ff131df10461, 0x2e797b99377d9e2b, 0xa4a4505d228dbf3d,
        0x047b1e51a3498ae7, 0x51ae26d5fee7cbd4, 0x26968ab302805f46, 0xa5057ad8f84dfb2e,
    };

    const e = LexicalEmbedder.init(384);
    for (cases, expected_384, 0..) |s, want, i| {
        const v = try e.embed(alloc, s);
        defer alloc.free(v);
        const got = fingerprintFnv(std.mem.sliceAsBytes(v), 0xcbf29ce484222325);
        if (got != want) {
            std.log.err("case {d}: fingerprint 0x{x:0>16}, expected 0x{x:0>16}", .{ i, got, want });
            return error.TestExpectedEqual;
        }
    }
}

test "Embedder: the external variant is opt-in and never the default" {
    const alloc = std.testing.allocator;
    var cfg = config.Config{};
    cfg.embedder_dim = 384;
    cfg.embedder_kind = .lexical_hash;

    const emb = try Embedder.fromConfig(cfg);
    try std.testing.expect(emb == .lexical_hash);
    // `close`/`destroy` are safe on the built-ins, which is what lets every
    // call site call them unconditionally.
    emb.close();
    emb.destroy();

    // The reserved enum value still refuses rather than panicking.
    try std.testing.expectError(
        error.UnsupportedEmbedder,
        Embedder.init(.onnx_external, 384),
    );
    const missing = Embedder.initExternal(alloc, .{ .cmd = "mem3-no-such-embedder-9f3a", .dim = 4 });
    try std.testing.expectError(error.BackendNotFound, missing);
}
