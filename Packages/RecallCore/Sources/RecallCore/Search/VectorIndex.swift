import Accelerate
import Foundation

public enum VectorMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Dot product; equals cosine similarity for normalized vectors.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}

public struct VectorHit: Sendable, Equatable {
    public var entityType: String
    public var entityID: Int64
    public var score: Float
}

/// Abstraction so a real ANN index (e.g. sqlite-vec, HNSW) can replace the scan later.
public protocol VectorIndex: Sendable {
    func search(query: [Float], model: String, entityTypes: [String], from: Date, to: Date, limit: Int) throws -> [VectorHit]
}

/// Exact search by streaming vectors out of SQLite page by page and keeping a bounded top-k.
/// Memory is O(page + k) regardless of history size; at ~1 ms per 10k 768-d vectors this
/// is adequate for a single user's history for a long time, especially when time-filtered.
public struct ScanVectorIndex: VectorIndex {
    let store: RecallStore
    public init(store: RecallStore) { self.store = store }

    public func search(query: [Float], model: String, entityTypes: [String], from: Date, to: Date, limit: Int) throws -> [VectorHit] {
        let q = VectorMath.normalized(query)
        var top: [VectorHit] = []
        top.reserveCapacity(limit + 1)
        try store.forEachEmbedding(model: model, entityTypes: entityTypes, from: from, to: to) { type, id, vector in
            let score = VectorMath.dot(q, vector)
            if top.count < limit || score > (top.last?.score ?? -.infinity) {
                let hit = VectorHit(entityType: type, entityID: id, score: score)
                let index = top.firstIndex { $0.score < score } ?? top.endIndex
                top.insert(hit, at: index)
                if top.count > limit { top.removeLast() }
            }
        }
        return top
    }
}
