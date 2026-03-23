//
//  ContextInterface.swift
//  osaurus
//
//  Unified context assembly layer across all four pillars:
//  Methods, Skills, Memory (existing), and Tools.
//

import Foundation
import os

private let contextLogger = Logger(subsystem: "ai.osaurus", category: "context.interface")

// MARK: - AssembledContext

public struct AssembledContext: Sendable {
    /// Methods with tier == .rule — always loaded (P1)
    public let rules: [Method]
    /// Methods matched by search above the model's threshold (P3)
    public let matchedMethods: [Method]
    /// Tool specs derived from matched methods' toolsUsed (P4)
    public let coLoadedToolIds: Set<String>
    /// Skills matched by search (P5)
    public let matchedSkills: [Skill]
    /// Compact method index text for the system prompt (P6)
    public let methodIndex: String?
    /// Compact tool index text for the system prompt (P6)
    public let toolIndex: String?
}

// MARK: - ContextInterface

public actor ContextInterface {
    public static let shared = ContextInterface()

    private init() {}

    /// Query all four pillars and assemble context for a single turn.
    public func assemble(
        query: String,
        agentId: String
    ) async throws -> AssembledContext {
        let profile = await ModelContextProfile.current()

        let rules = try MethodDatabase.shared.loadMethodsByTier(.rule)
        let ruleIds = Set(rules.map(\.id))

        async let searchResultsTask = MethodSearchService.shared.search(
            query: query,
            topK: profile.maxMethods,
            threshold: profile.methodThreshold
        )
        async let matchedSkillsTask = SkillSearchService.shared.search(query: query, topK: 5)

        let searchResults = await searchResultsTask
        let matchedSkills = await matchedSkillsTask

        let matchedMethods = searchResults.map(\.method).filter { !ruleIds.contains($0.id) }

        let allMethods = rules + matchedMethods
        let coLoadedToolIds = Set(allMethods.flatMap(\.toolsUsed))

        let methodIndex: String?
        if profile.loadMethodIndex {
            methodIndex = try buildCompactMethodIndex()
        } else {
            methodIndex = nil
        }

        let toolIndex: String?
        if profile.loadToolIndex {
            toolIndex = try await ToolIndexService.shared.buildCompactIndex()
        } else {
            toolIndex = nil
        }

        let ruleCount = rules.count
        let methodCount = matchedMethods.count
        let toolCount = coLoadedToolIds.count
        let skillCount = matchedSkills.count
        contextLogger.debug(
            "Assembled context: \(ruleCount) rules, \(methodCount) methods, \(toolCount) co-loaded tools, \(skillCount) skills"
        )

        return AssembledContext(
            rules: rules,
            matchedMethods: matchedMethods,
            coLoadedToolIds: coLoadedToolIds,
            matchedSkills: matchedSkills,
            methodIndex: methodIndex,
            toolIndex: toolIndex
        )
    }

    /// Overload accepting an explicit context mode (useful for tests).
    public func assemble(
        query: String,
        agentId: String,
        mode: ContextMode
    ) async throws -> AssembledContext {
        let profile = ModelContextProfile.profile(for: mode)

        let rules = try MethodDatabase.shared.loadMethodsByTier(.rule)
        let ruleIds = Set(rules.map(\.id))

        async let searchResultsTask = MethodSearchService.shared.search(
            query: query,
            topK: profile.maxMethods,
            threshold: profile.methodThreshold
        )
        async let matchedSkillsTask = SkillSearchService.shared.search(query: query, topK: 5)

        let searchResults = await searchResultsTask
        let matchedSkills = await matchedSkillsTask

        let matchedMethods = searchResults.map(\.method).filter { !ruleIds.contains($0.id) }

        let allMethods = rules + matchedMethods
        let coLoadedToolIds = Set(allMethods.flatMap(\.toolsUsed))

        let methodIndex: String?
        if profile.loadMethodIndex {
            methodIndex = try buildCompactMethodIndex()
        } else {
            methodIndex = nil
        }

        let toolIndex: String?
        if profile.loadToolIndex {
            toolIndex = try await ToolIndexService.shared.buildCompactIndex()
        } else {
            toolIndex = nil
        }

        let ruleCount = rules.count
        let methodCount = matchedMethods.count
        let toolCount = coLoadedToolIds.count
        let skillCount = matchedSkills.count
        contextLogger.debug(
            "Assembled context (\(mode.rawValue)): \(ruleCount) rules, \(methodCount) methods, \(toolCount) co-loaded tools, \(skillCount) skills"
        )

        return AssembledContext(
            rules: rules,
            matchedMethods: matchedMethods,
            coLoadedToolIds: coLoadedToolIds,
            matchedSkills: matchedSkills,
            methodIndex: methodIndex,
            toolIndex: toolIndex
        )
    }

    // MARK: - Compact Index Builders

    private func buildCompactMethodIndex() throws -> String {
        let methods = try MethodDatabase.shared.loadAllMethods()
        if methods.isEmpty { return "No methods available." }

        let scores = try MethodDatabase.shared.loadAllScores()
        let scoreMap = Dictionary(scores.map { ($0.methodId, $0.score) }, uniquingKeysWith: { first, _ in first })

        var lines: [String] = ["Available methods:"]
        for m in methods where m.tier != .dormant {
            let score = scoreMap[m.id] ?? 0.0
            lines.append("- \(m.name): \(m.description) [score: \(String(format: "%.1f", score))]")
        }
        return lines.joined(separator: "\n")
    }
}
