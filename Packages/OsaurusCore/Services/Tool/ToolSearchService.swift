//
//  ToolSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search over the unified tool index.
//  Falls back gracefully when VecturaKit is unavailable.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public enum ToolIndexLogger {
    static let search = Logger(subsystem: "ai.osaurus", category: "toolindex.search")
    static let service = Logger(subsystem: "ai.osaurus", category: "toolindex.service")
}

public actor ToolSearchService {
    public static let shared = ToolSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false
    private var reverseIdMap: [String: String] = [:]

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        do {
            let storageDir = OsaurusPaths.toolIndex().appendingPathComponent("vectura", isDirectory: true)
            OsaurusPaths.ensureExistsSilent(storageDir)

            let config = try VecturaConfig(
                name: "osaurus-tools",
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
            ToolIndexLogger.search.info("VecturaKit initialized successfully for tools")
        } catch {
            ToolIndexLogger.search.error("VecturaKit init failed for tools (search unavailable): \(error)")
            vectorDB = nil
        }
    }

    // MARK: - Indexing

    public func indexEntry(_ entry: ToolIndexEntry) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(for: entry.id)
            let text = "\(entry.name) \(entry.description)"
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            ToolIndexLogger.search.error("Failed to index tool \(entry.id): \(error)")
        }
    }

    public func removeEntry(id: String) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            ToolIndexLogger.search.error("Failed to remove tool \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [ToolIndexEntry] {
        guard let db = vectorDB else { return [] }
        do {
            let fetchCount = topK * 3
            let results = try await db.search(
                query: .text(query),
                numResults: fetchCount,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let toolIds = results.compactMap { reverseIdMap[$0.id.uuidString] }
            guard !toolIds.isEmpty else { return [] }

            let enabledNames = await MainActor.run {
                Set(ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name })
            }

            return Array(
                try ToolDatabase.shared.loadAllEntries()
                    .filter { toolIds.contains($0.id) && enabledNames.contains($0.name) }
                    .prefix(topK)
            )
        } catch {
            ToolIndexLogger.search.error("Tool search failed: \(error)")
            return []
        }
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()
            let entries = try ToolDatabase.shared.loadAllEntries()
            for entry in entries {
                let id = deterministicUUID(for: entry.id)
                let text = "\(entry.name) \(entry.description)"
                _ = try await db.addDocument(text: text, id: id)
            }
            ToolIndexLogger.search.info("Tool index rebuilt with \(entries.count) entries")
        } catch {
            ToolIndexLogger.search.error("Failed to rebuild tool index: \(error)")
        }
    }

    // MARK: - Helpers

    private func deterministicUUID(for toolId: String) -> UUID {
        let hash = SHA256.hash(data: Data("tool:\(toolId)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = toolId
        return uuid
    }
}
