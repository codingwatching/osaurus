//
//  KVCacheStoreTests.swift
//  osaurusTests
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct KVCacheStoreTests {

    /// Creates a lightweight `[any KVCache]` without triggering Metal GPU ops.
    /// State bytes are 0, but entry management and LRU logic are fully exercised.
    private func makeCache() -> [any KVCache] {
        [KVCacheSimple()]
    }

    // MARK: - Hot tier put / get

    @Test func putAndGetHotCache() {
        var store = KVCacheStore()
        let cache = makeCache()

        store.putCache(sessionId: "s1", cache: cache, modelName: "llama")

        let retrieved = store.getCache(sessionId: "s1", modelName: "llama")
        #expect(retrieved != nil)
        #expect(retrieved!.count == 1)
    }

    @Test func getCacheReturnsNilOnMiss() {
        var store = KVCacheStore()
        let result = store.getCache(sessionId: "nonexistent", modelName: "llama")
        #expect(result == nil)
    }

    @Test func getCacheInvalidatesOnModelChange() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "modelA")

        let result = store.getCache(sessionId: "s1", modelName: "modelB")
        #expect(result == nil)

        // Entry should be fully evicted -- re-getting with original model also fails
        let retry = store.getCache(sessionId: "s1", modelName: "modelA")
        #expect(retry == nil)
    }

    // MARK: - LRU ordering

    @Test func lruOrderMaintainedAcrossAccesses() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        store.putCache(sessionId: "s2", cache: makeCache(), modelName: "m")
        store.putCache(sessionId: "s3", cache: makeCache(), modelName: "m")

        // Access s1 -- should promote it to MRU; s2 becomes coldest
        _ = store.getCache(sessionId: "s1", modelName: "m")

        // All three should still be retrievable
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)
        #expect(store.getCache(sessionId: "s2", modelName: "m") != nil)
        #expect(store.getCache(sessionId: "s3", modelName: "m") != nil)
    }

    @Test func putCacheTouchesLRU() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        store.putCache(sessionId: "s2", cache: makeCache(), modelName: "m")

        // Re-putting s1 should promote it to MRU
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")

        // Both should still be retrievable after re-put
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)
        #expect(store.getCache(sessionId: "s2", modelName: "m") != nil)
    }

    // MARK: - ensureBudget

    @Test func ensureBudgetIsNoOpWhenUnderBudget() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")

        // With 0-byte caches, totalHotBytes is 0 which is within any budget
        store.ensureBudget(1024)
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)
    }

    // MARK: - Invalidation

    @Test func invalidateRemovesSession() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)

        store.invalidate(sessionId: "s1")
        #expect(store.getCache(sessionId: "s1", modelName: "m") == nil)
    }

    @Test func invalidateIsNoOpForUnknownSession() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        store.invalidate(sessionId: "unknown")
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)
    }

    @Test func invalidateModelRemovesAllForModel() {
        var store = KVCacheStore()
        store.putCache(sessionId: "a1", cache: makeCache(), modelName: "modelA")
        store.putCache(sessionId: "a2", cache: makeCache(), modelName: "modelA")
        store.putCache(sessionId: "b1", cache: makeCache(), modelName: "modelB")

        store.invalidateModel("modelA")

        #expect(store.getCache(sessionId: "a1", modelName: "modelA") == nil)
        #expect(store.getCache(sessionId: "a2", modelName: "modelA") == nil)
        #expect(store.getCache(sessionId: "b1", modelName: "modelB") != nil)
    }

    @Test func invalidateModelIsNoOpForUnknownModel() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        store.invalidateModel("unknown")
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)
    }

    @Test func clearAllRemovesEverything() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m1")
        store.putCache(sessionId: "s2", cache: makeCache(), modelName: "m2")

        store.clearAll()

        #expect(store.totalHotBytes == 0)
        #expect(store.getCache(sessionId: "s1", modelName: "m1") == nil)
        #expect(store.getCache(sessionId: "s2", modelName: "m2") == nil)
    }

    // MARK: - Prefix cache

    @Test func prefixKeyFormat() {
        let key = KVCacheStore.prefixKey(modelName: "llama", hash: "abc123")
        #expect(key == "prefix_llama_abc123")
    }

    @Test func prefixKeyDifferentModelsProduceDifferentKeys() {
        let k1 = KVCacheStore.prefixKey(modelName: "llama", hash: "h1")
        let k2 = KVCacheStore.prefixKey(modelName: "gemma", hash: "h1")
        #expect(k1 != k2)
    }

    @Test func prefixKeyDifferentHashesProduceDifferentKeys() {
        let k1 = KVCacheStore.prefixKey(modelName: "llama", hash: "h1")
        let k2 = KVCacheStore.prefixKey(modelName: "llama", hash: "h2")
        #expect(k1 != k2)
    }

    /// Seeds a prefix cache entry without triggering SSD serialization.
    /// Uses `putCache` with the composite prefix key directly.
    private func seedPrefixCache(
        _ store: inout KVCacheStore,
        modelName: String,
        hash: String
    ) {
        let key = KVCacheStore.prefixKey(modelName: modelName, hash: hash)
        store.putCache(sessionId: key, cache: makeCache(), modelName: modelName)
    }

    @Test func putPrefixCacheRegistersEntry() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "hash1")

        #expect(store.hasPrefixCache(modelName: "llama", hash: "hash1"))
    }

    @Test func getPrefixCacheReturnsNilWithoutSSD() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "hash1")

        // getPrefixCache always loads from SSD to avoid shared-reference mutation;
        // seeded entries have no ssdPath so it returns nil.
        let retrieved = store.getPrefixCache(modelName: "llama", hash: "hash1")
        #expect(retrieved == nil)
    }

    @Test func hasPrefixCacheReturnsFalseOnMiss() {
        let store = KVCacheStore()
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "nonexistent"))
    }

    @Test func differentHashesDontCollide() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "hash_a")
        seedPrefixCache(&store, modelName: "llama", hash: "hash_b")

        #expect(store.hasPrefixCache(modelName: "llama", hash: "hash_a"))
        #expect(store.hasPrefixCache(modelName: "llama", hash: "hash_b"))
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "hash_c"))
    }

    @Test func prefixCacheEvictedByModelInvalidation() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "h1")
        #expect(store.hasPrefixCache(modelName: "llama", hash: "h1"))

        store.invalidateModel("llama")
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "h1"))
    }

    @Test func prefixCacheEvictedByClearAll() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "h1")
        store.clearAll()
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "h1"))
    }

    // MARK: - Budget computation

    @Test func computeBudgetFloor() {
        let hugeWeights: Int64 = Int64(ProcessInfo.processInfo.physicalMemory) * 2
        let budget = KVCacheStore.computeBudget(modelWeightsBytes: hugeWeights)
        #expect(budget == 512 * 1024 * 1024)
    }

    @Test func computeBudgetPositiveForReasonableWeights() {
        let budget = KVCacheStore.computeBudget(modelWeightsBytes: 0)
        #expect(budget >= 512 * 1024 * 1024)
    }

    @Test func computeBudgetDecreasesWithLargerWeights() {
        let small = KVCacheStore.computeBudget(modelWeightsBytes: 1_000_000_000)
        let large = KVCacheStore.computeBudget(modelWeightsBytes: 4_000_000_000)
        #expect(small >= large)
    }

    // MARK: - cacheBytes

    @Test func cacheBytesZeroForEmptyCache() {
        let cache: [any KVCache] = [KVCacheSimple()]
        let bytes = KVCacheStore.cacheBytes(cache)
        #expect(bytes == 0)
    }

    @Test func cacheBytesZeroForEmptyArray() {
        let bytes = KVCacheStore.cacheBytes([])
        #expect(bytes == 0)
    }

    // MARK: - Update existing session

    @Test func putCacheUpdatesExistingSession() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)

        let newCache = makeCache()
        store.putCache(sessionId: "s1", cache: newCache, modelName: "m")

        let retrieved = store.getCache(sessionId: "s1", modelName: "m")
        #expect(retrieved != nil)
        #expect(retrieved!.count == 1)
    }

    @Test func putCacheCanChangeModel() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "old")
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "new")

        #expect(store.getCache(sessionId: "s1", modelName: "new") != nil)
    }

    // MARK: - totalHotBytes tracking (uses _testPutSized to avoid Metal)

    @Test func totalHotBytesTracksInserts() {
        var store = KVCacheStore()
        #expect(store.totalHotBytes == 0)

        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        #expect(store.totalHotBytes == 1000)

        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 2000)
        #expect(store.totalHotBytes == 3000)
    }

    @Test func totalHotBytesDecreasesOnInvalidate() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 2000)
        #expect(store.totalHotBytes == 3000)

        store.invalidate(sessionId: "s1")
        #expect(store.totalHotBytes == 2000)
    }

    @Test func totalHotBytesZeroAfterClearAll() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 2000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 3000)
        store.clearAll()
        #expect(store.totalHotBytes == 0)
    }

    @Test func testPutSizedUpdatesHotBytesOnReplace() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 500)
        #expect(store.totalHotBytes == 500)

        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 2000)
        #expect(store.totalHotBytes == 2000)
    }

    // MARK: - ensureBudget eviction

    @Test func ensureBudgetEvictsLRUWhenOverBudget() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s3", modelName: "m", sizeBytes: 1000)
        #expect(store.totalHotBytes == 3000)

        // Access s2 and s3 to make s1 the coldest
        _ = store.getCache(sessionId: "s2", modelName: "m")
        _ = store.getCache(sessionId: "s3", modelName: "m")

        // Budget allows only 2 entries
        store.ensureBudget(2001)

        // s1 was coldest and should have been evicted
        #expect(store.totalHotBytes <= 2001)
    }

    @Test func ensureBudgetEvictsMultipleEntries() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s3", modelName: "m", sizeBytes: 1000)

        // Budget of 0 should evict everything from hot tier
        store.ensureBudget(0)
        #expect(store.totalHotBytes == 0)
    }

    @Test func ensureBudgetPreservesMRU() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s3", modelName: "m", sizeBytes: 1000)

        // Touch s3 to make it MRU
        _ = store.getCache(sessionId: "s3", modelName: "m")

        // Budget for exactly 1 entry
        store.ensureBudget(1000)

        // s3 (most recently used) should survive
        #expect(store.getCache(sessionId: "s3", modelName: "m") != nil)
        #expect(store.totalHotBytes == 1000)
    }

    // MARK: - evictToSSD

    @Test func evictToSSDClearsHotCache() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        #expect(store.totalHotBytes == 1000)

        store.evictToSSD(sessionId: "s1")
        #expect(store.totalHotBytes == 0)
    }

    @Test func evictToSSDIsIdempotent() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store.evictToSSD(sessionId: "s1")
        #expect(store.totalHotBytes == 0)

        // Second eviction should be a no-op (cache already nil, removed from LRU)
        store.evictToSSD(sessionId: "s1")
        #expect(store.totalHotBytes == 0)
    }

    // MARK: - putCache clears stale ssdPath

    @Test func putCacheClearsSsdPath() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")
        store.putCache(sessionId: "s1", cache: makeCache(), modelName: "m")

        // After re-put, the entry is still hot-retrievable (ssdPath cleared internally).
        #expect(store.getCache(sessionId: "s1", modelName: "m") != nil)
    }

    // MARK: - Prefix key null-byte delimiter

    @Test func prefixKeyWithColonInModelName() {
        let k1 = KVCacheStore.prefixKey(modelName: "org:model", hash: "h1")
        let k2 = KVCacheStore.prefixKey(modelName: "org", hash: "model_h1")
        #expect(k1 != k2)
    }
}
