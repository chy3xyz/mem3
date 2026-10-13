//! Public re-exports for the retrieval layer.

pub const hnsw = @import("hnsw.zig");
pub const embedder = @import("embedder.zig");
pub const hybrid_retriever = @import("hybrid_retriever.zig");
pub const reranker = @import("reranker.zig");

pub const HNSW = hnsw.HNSW;
pub const StubEmbedder = embedder.StubEmbedder;
pub const LexicalEmbedder = embedder.LexicalEmbedder;
/// The dispatch union callers should actually hold. Either variant can
/// be selected at build time; `Embedder.init` picks one.
pub const Embedder = embedder.Embedder;
pub const HybridRetriever = hybrid_retriever.HybridRetriever;
pub const Candidate = hybrid_retriever.Candidate;
pub const RerankContext = reranker.RerankContext;
pub const ScoredCell = reranker.ScoredCell;
