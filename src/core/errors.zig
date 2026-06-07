//! mem3 error types.
//!
//! All public functions return `!T` with a tagged error union. No `null` for
//! fallible operations (Constitution: API Surface Standards).

const std = @import("std");

/// The set of errors mem3 can return. Tagged so the caller can `switch` on it.
pub const Error = error{
    // Encoding / classification
    /// A MemCell was constructed without a source_tag (constitution violation).
    /// In practice the type system prevents this — this error is only returned
    /// by manual reconstruction from bytes.
    MissingSourceTag,
    /// source_confidence was below the 0.5 acceptance threshold.
    SourceConfidenceTooLow,
    /// A MemCell lacks both foresight and goal_associations (spirit dim missing).
    SpiritDimMissing,
    /// Episode was empty.
    EmptyEpisode,

    // Storage / I/O
    OutOfMemory,
    /// WAL record checksum mismatch during replay.
    WALCorrupt,
    /// WAL record has an unknown type tag.
    WALUnknownRecord,
    /// Snapshot file is missing or has bad magic.
    SnapshotInvalid,
    /// Index out of bounds.
    IndexOutOfRange,
    /// Tried to read a MemCell that doesn't exist.
    NotFound,
    /// Tried to write a MemCell with a duplicate id.
    DuplicateId,

    // Hypergraph
    /// A hyperedge referenced a node that does not exist (or was deleted).
    DanglingEdge,
    /// Tried to add a hyperedge with fewer than 2 nodes.
    EdgeTooFewNodes,
    /// Hyperedge source_weights do not sum to 1.0 (within tolerance).
    InvalidSourceWeights,

    // Goals
    /// Attempted to create a goal cycle (a → b → a).
    GoalCycle,
    /// Goal id does not exist.
    GoalNotFound,

    // Embedding / retrieval
    /// Embedder model not loaded.
    EmbedderNotLoaded,
    /// Query is malformed.
    InvalidQuery,

    // Server / HTTP
    /// HTTP request was malformed.
    BadRequest,
    /// HTTP method not allowed on this route.
    MethodNotAllowed,
    /// Resource not found.
    HTTPNotFound,
    /// Server internal error.
    InternalServerError,

    // CLI
    /// Unknown subcommand.
    UnknownSubcommand,
    /// Missing required flag.
    MissingFlag,
    /// Invalid flag value.
    InvalidFlag,
    /// Tried to parse JSON and failed.
    InvalidJson,
    /// Tried to parse integer and failed.
    InvalidInteger,
    /// Tried to parse float and failed.
    InvalidFloat,
};

/// Convenience: pretty-print an error to a writer with the conventional "error: " prefix.
pub fn printError(err: anyerror, w: anytype) !void {
    try w.print("error: {s}\n", .{@errorName(err)});
}
