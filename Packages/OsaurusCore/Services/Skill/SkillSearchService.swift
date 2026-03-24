//
//  SkillSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search over SKILL.md files.
//  Derived index — files on disk are the source of truth.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public enum SkillSearchLogger {
    static let search = Logger(subsystem: "ai.osaurus", category: "skill.search")
}

public actor SkillSearchService {
    public static let shared = SkillSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false
    private var reverseIdMap: [String: UUID] = [:]

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        do {
            let storageDir = OsaurusPaths.skills().appendingPathComponent("vectura", isDirectory: true)
            OsaurusPaths.ensureExistsSilent(storageDir)

            let config = try VecturaConfig(
                name: "osaurus-skills",
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
            SkillSearchLogger.search.info("VecturaKit initialized successfully for skills")
        } catch {
            SkillSearchLogger.search.error("VecturaKit init failed for skills (search unavailable): \(error)")
            vectorDB = nil
        }
    }

    // MARK: - Indexing

    public func indexSkill(_ skill: Skill) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(for: skill.id)
            let text = "\(skill.name) \(skill.description)"
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            SkillSearchLogger.search.error("Failed to index skill \(skill.name): \(error)")
        }
    }

    public func removeSkill(id: UUID) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            SkillSearchLogger.search.error("Failed to remove skill \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [Skill] {
        guard let db = vectorDB else { return [] }
        do {
            let fetchCount = topK * 3
            let results = try await db.search(
                query: .text(query),
                numResults: fetchCount,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let matchedSkillIds = results.compactMap { reverseIdMap[$0.id.uuidString] }
            guard !matchedSkillIds.isEmpty else { return [] }

            let allSkills = await MainActor.run { SkillManager.shared.skills }
            let idSet = Set(matchedSkillIds)
            return Array(allSkills.filter { idSet.contains($0.id) && $0.enabled }.prefix(topK))
        } catch {
            SkillSearchLogger.search.error("Skill search failed: \(error)")
            return []
        }
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()

            let allSkills = await MainActor.run { SkillManager.shared.skills }
            for skill in allSkills {
                let id = deterministicUUID(for: skill.id)
                let text = "\(skill.name) \(skill.description)"
                _ = try await db.addDocument(text: text, id: id)
            }
            SkillSearchLogger.search.info("Skill index rebuilt with \(allSkills.count) skills")
        } catch {
            SkillSearchLogger.search.error("Failed to rebuild skill index: \(error)")
        }
    }

    // MARK: - Helpers

    private func deterministicUUID(for skillId: UUID) -> UUID {
        let hash = SHA256.hash(data: Data("skill:\(skillId.uuidString)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = skillId
        return uuid
    }
}
