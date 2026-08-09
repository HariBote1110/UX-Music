import Foundation

// TODO: capacity/eviction not implemented yet — see ArtworkMemoryCacheTests.swift (TDD red step).
final class ArtworkMemoryCache<Value> {
    init(capacity: Int) {}
    func value(forKey key: String) -> Value? { nil }
    func setValue(_ value: Value, forKey key: String) {}
    func removeValue(forKey key: String) {}
    var count: Int { 0 }
}
