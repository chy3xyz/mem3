//! Public re-exports for the storage layer.

pub const wal = @import("wal.zig");

pub const WAL = wal.WAL;
pub const WALRecord = wal.WALRecord;
pub const WALRecordType = wal.WALRecordType;
