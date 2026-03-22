//
//  MethodSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search (BM25 + vector) over methods.
//  Falls back gracefully when VecturaKit is unavailable.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public actor MethodSearchService {
    public static let shared = MethodSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        do {
            let storageDir = OsaurusPaths.methods().appendingPathComponent("vectura", isDirectory: true)
            OsaurusPaths.ensureExistsSilent(storageDir)

            let config = try VecturaConfig(
                name: "osaurus-methods",
                directoryURL: storageDir,
                searchOptions: VecturaConfig.SearchOptions(
                    defaultNumResults: 10,
                    minThreshold: 0.3,
                    hybridWeight: 0.5,
                    k1: 1.2,
                    b: 0.75
                ),
                memoryStrategy: .automatic()
            )

            let embedder = SwiftEmbedder(modelSource: .default)
            vectorDB = try await VecturaKit(config: config, embedder: embedder)
            isInitialized = true
            MethodLogger.search.info("VecturaKit initialized successfully for methods")
        } catch {
            MethodLogger.search.error("VecturaKit init failed for methods (search unavailable): \(error)")
            vectorDB = nil
        }
    }

    // MARK: - Indexing

    public func indexMethod(_ method: Method) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(for: method.id)
            let text = buildIndexText(for: method)
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            MethodLogger.search.error("Failed to index method \(method.id): \(error)")
        }
    }

    public func removeMethod(id: String) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            MethodLogger.search.error("Failed to remove method \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [MethodSearchResult] {
        guard let db = vectorDB else { return [] }
        do {
            let results = try await db.search(
                query: .text(query),
                numResults: topK,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let idStrings = results.map { $0.id.uuidString }
            let scoreMap = Dictionary(
                results.map { ($0.id.uuidString, Float($0.score)) },
                uniquingKeysWith: { first, _ in first }
            )

            let methodIds = idStrings.compactMap { uuidString -> String? in
                reverseIdMap[uuidString]
            }

            let methods = try MethodDatabase.shared.loadMethodsByIds(methodIds)
            let scores = try methodIds.compactMap { try MethodDatabase.shared.loadScore(methodId: $0) }
            let scoreByMethod = Dictionary(scores.map { ($0.methodId, $0) }, uniquingKeysWith: { first, _ in first })

            return methods.compactMap { method -> MethodSearchResult? in
                let uuid = deterministicUUID(for: method.id)
                guard let searchScore = scoreMap[uuid.uuidString] else { return nil }
                let methodScore = scoreByMethod[method.id]?.score ?? 0.0
                return MethodSearchResult(method: method, searchScore: searchScore, score: methodScore)
            }
            .sorted { $0.searchScore > $1.searchScore }
        } catch {
            MethodLogger.search.error("Method search failed: \(error)")
            return []
        }
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()
            let methods = try MethodDatabase.shared.loadAllMethods()
            for method in methods {
                let id = deterministicUUID(for: method.id)
                let text = buildIndexText(for: method)
                _ = try await db.addDocument(text: text, id: id)
                reverseIdMap[id.uuidString] = method.id
            }
            MethodLogger.search.info("Method index rebuilt with \(methods.count) methods")
        } catch {
            MethodLogger.search.error("Failed to rebuild method index: \(error)")
        }
    }

    // MARK: - Helpers

    private var reverseIdMap: [String: String] = [:]

    private func buildIndexText(for method: Method) -> String {
        var text = method.description
        if let trigger = method.triggerText, !trigger.isEmpty {
            text += " " + trigger
        }
        return text
    }

    private func deterministicUUID(for methodId: String) -> UUID {
        let hash = SHA256.hash(data: Data("method:\(methodId)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = methodId
        return uuid
    }
}
