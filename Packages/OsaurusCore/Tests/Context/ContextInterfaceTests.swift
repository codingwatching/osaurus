//
//  ContextInterfaceTests.swift
//  osaurus
//
//  Tests for ModelContextProfile selection and the context interface's
//  structural guarantees.
//

import Foundation
import Testing

@testable import OsaurusCore

private typealias Method = OsaurusCore.Method

// MARK: - ModelContextProfile Tests

struct ModelContextProfileTests {

    @Test func frontierModelsDetected() {
        let opusProfile = ModelContextProfile.profile(for: "claude-4-opus")
        #expect(opusProfile.tier == .frontier)

        let gpt4Profile = ModelContextProfile.profile(for: "gpt-4o-2025-01")
        #expect(gpt4Profile.tier == .frontier)

        let geminiProfile = ModelContextProfile.profile(for: "gemini-2.5-pro-latest")
        #expect(geminiProfile.tier == .frontier)
    }

    @Test func unknownModelDefaultsToCapable() {
        let profile = ModelContextProfile.profile(for: "unknown-model-xyz")
        #expect(profile.tier == .capable)
    }

    @Test func frontierProfileLimits() {
        let p = ModelContextProfile.frontier
        #expect(p.maxMethods == 10)
        #expect(p.maxTools == nil)
        #expect(p.methodThreshold == 0.3)
        #expect(p.loadMethodIndex == true)
        #expect(p.loadToolIndex == false)
    }

    @Test func capableProfileLimits() {
        let p = ModelContextProfile.capable
        #expect(p.maxMethods == 5)
        #expect(p.maxTools == 15)
        #expect(p.methodThreshold == 0.5)
        #expect(p.loadMethodIndex == true)
        #expect(p.loadToolIndex == true)
    }

    @Test func localProfileLimits() {
        let p = ModelContextProfile.local
        #expect(p.maxMethods == 2)
        #expect(p.maxTools == 5)
        #expect(p.methodThreshold == 0.7)
        #expect(p.loadMethodIndex == false)
        #expect(p.loadToolIndex == true)
    }
}

// MARK: - AssembledContext Structural Tests

struct AssembledContextTests {

    @Test func emptyContextIsValid() {
        let ctx = AssembledContext(
            rules: [],
            matchedMethods: [],
            coLoadedToolIds: [],
            matchedSkills: [],
            methodIndex: nil,
            toolIndex: nil
        )
        #expect(ctx.rules.isEmpty)
        #expect(ctx.matchedMethods.isEmpty)
        #expect(ctx.coLoadedToolIds.isEmpty)
        #expect(ctx.matchedSkills.isEmpty)
        #expect(ctx.methodIndex == nil)
        #expect(ctx.toolIndex == nil)
    }

    @Test func coLoadedToolIdsAggregatesFromAllMethods() {
        let rule = OsaurusCore.Method(
            id: "r1",
            name: "rule",
            description: "a rule",
            body: "",
            source: MethodSource.user,
            tier: MethodTier.rule,
            toolsUsed: ["terminal", "web_fetch"]
        )
        let matched = OsaurusCore.Method(
            id: "m1",
            name: "matched",
            description: "a match",
            body: "",
            source: MethodSource.user,
            tier: MethodTier.active,
            toolsUsed: ["web_fetch", "sandbox_run_script"]
        )

        let allMethods = [rule, matched]
        let coLoaded = Set(allMethods.flatMap(\.toolsUsed))

        #expect(coLoaded.count == 3)
        #expect(coLoaded.contains("terminal"))
        #expect(coLoaded.contains("web_fetch"))
        #expect(coLoaded.contains("sandbox_run_script"))
    }

    @Test func matchedSkillsPreservedInContext() {
        let skill = Skill(name: "gemini-api", description: "Gemini API skill", instructions: "Use Gemini")
        let ctx = AssembledContext(
            rules: [],
            matchedMethods: [],
            coLoadedToolIds: [],
            matchedSkills: [skill],
            methodIndex: nil,
            toolIndex: nil
        )
        #expect(ctx.matchedSkills.count == 1)
        #expect(ctx.matchedSkills[0].name == "gemini-api")
    }

    @Test func contextWithAllFieldsPopulated() {
        let rule = OsaurusCore.Method(
            id: "r1",
            name: "rule",
            description: "a rule",
            body: "",
            source: MethodSource.user,
            tier: MethodTier.rule,
            toolsUsed: ["terminal"]
        )
        let matched = OsaurusCore.Method(
            id: "m1",
            name: "match",
            description: "a match",
            body: "",
            source: MethodSource.user,
            tier: MethodTier.active,
            toolsUsed: ["web_fetch"]
        )
        let skill = Skill(name: "test-skill", description: "test", instructions: "test")

        let ctx = AssembledContext(
            rules: [rule],
            matchedMethods: [matched],
            coLoadedToolIds: ["terminal", "web_fetch"],
            matchedSkills: [skill],
            methodIndex: "Available methods:\n- rule: a rule",
            toolIndex: "Available tools:\n- terminal"
        )

        #expect(ctx.rules.count == 1)
        #expect(ctx.matchedMethods.count == 1)
        #expect(ctx.coLoadedToolIds.count == 2)
        #expect(ctx.matchedSkills.count == 1)
        #expect(ctx.methodIndex != nil)
        #expect(ctx.toolIndex != nil)
    }
}

// MARK: - Skill Merging Logic Tests (Gap 2)

struct SkillMergingTests {

    @Test func additionalSkillsFiltersDuplicates() {
        let catalogSkillNames: Set<String> = ["gemini-api", "swift-best-practices"]
        let matchedSkills = [
            Skill(name: "gemini-api", description: "Gemini", instructions: "Use Gemini"),
            Skill(name: "docker-deploy", description: "Docker", instructions: "Deploy with Docker"),
            Skill(name: "swift-best-practices", description: "Swift", instructions: "Swift tips"),
        ]

        let additional = matchedSkills.filter { !catalogSkillNames.contains($0.name) }
        #expect(additional.count == 1)
        #expect(additional[0].name == "docker-deploy")
    }

    @Test func noAdditionalSkillsWhenAllInCatalog() {
        let catalogSkillNames: Set<String> = ["gemini-api", "swift-best-practices"]
        let matchedSkills = [
            Skill(name: "gemini-api", description: "Gemini", instructions: "Use Gemini"),
            Skill(name: "swift-best-practices", description: "Swift", instructions: "Swift tips"),
        ]

        let additional = matchedSkills.filter { !catalogSkillNames.contains($0.name) }
        #expect(additional.isEmpty)
    }

    @Test func allSkillsAreAdditionalWhenCatalogEmpty() {
        let catalogSkillNames: Set<String> = []
        let matchedSkills = [
            Skill(name: "docker-deploy", description: "Docker", instructions: "Deploy"),
            Skill(name: "k8s-ops", description: "Kubernetes", instructions: "K8s ops"),
        ]

        let additional = matchedSkills.filter { !catalogSkillNames.contains($0.name) }
        #expect(additional.count == 2)
    }

    @Test func additionalSkillsFormattedCorrectly() {
        let additionalSkills = [
            Skill(name: "docker-deploy", description: "Docker deployment workflow", instructions: "Deploy")
        ]

        let formatted = additionalSkills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        #expect(formatted == "- docker-deploy: Docker deployment workflow")
    }
}

// MARK: - ContextBudgetCategory Tests (Gap 7)

struct ContextBudgetCategoryTests {

    @Test func methodsCategoryNotPresent() {
        let allCases = ContextBudgetCategory.allCases.map(\.rawValue)
        #expect(!allCases.contains("methods"))
    }

    @Test func expectedCategoriesPresent() {
        let allCases = Set(ContextBudgetCategory.allCases.map(\.rawValue))
        #expect(allCases.contains("systemPrompt"))
        #expect(allCases.contains("tools"))
        #expect(allCases.contains("memory"))
        #expect(allCases.contains("response"))
        #expect(allCases.contains("history"))
    }

    @Test func budgetManagerInitializesAllCategories() {
        let manager = ContextBudgetManager(contextLength: 128_000)
        #expect(manager.totalReserved == 0)
        #expect(manager.effectiveBudget > 0)
    }

    @Test func budgetManagerReservesCorrectly() {
        var manager = ContextBudgetManager(contextLength: 128_000)
        manager.reserve(.systemPrompt, tokens: 1000)
        manager.reserve(.tools, tokens: 2000)
        #expect(manager.totalReserved == 3000)
    }
}

// MARK: - Context Assembly Integration Tests

@Suite(.serialized)
struct ContextAssemblyTests {

    private func seedTestData() async throws {
        MethodDatabase.shared.close()
        try MethodDatabase.shared.openInMemory()

        ToolDatabase.shared.close()
        try ToolDatabase.shared.openInMemory()

        try MethodDatabase.shared.insertMethod(
            OsaurusCore.Method(
                id: "rule-1",
                name: "always-confirm-deploys",
                description: "Always confirm before deploying to any environment",
                body: "steps:\n  - tool: terminal\n    action: confirm deployment",
                source: MethodSource.user,
                tier: MethodTier.rule,
                toolsUsed: ["terminal"]
            )
        )

        try MethodDatabase.shared.insertMethod(
            OsaurusCore.Method(
                id: "active-high",
                name: "deploy-staging",
                description: "Deploy to Fly.io staging environment",
                body: "steps:\n  - tool: terminal\n  - tool: web_fetch",
                source: MethodSource.user,
                tier: MethodTier.active,
                toolsUsed: ["terminal", "web_fetch"]
            )
        )
        try MethodDatabase.shared.upsertScore(
            MethodScore(
                methodId: "active-high",
                timesLoaded: 10,
                timesSucceeded: 9,
                timesFailed: 1,
                successRate: 0.9,
                lastUsedAt: Date(),
                score: 0.9
            )
        )

        try MethodDatabase.shared.insertMethod(
            OsaurusCore.Method(
                id: "active-low",
                name: "deploy-alt",
                description: "Alternative deploy workflow",
                body: "steps:\n  - tool: sandbox_run_script",
                source: MethodSource.user,
                tier: MethodTier.active,
                toolsUsed: ["sandbox_run_script"]
            )
        )
        try MethodDatabase.shared.upsertScore(
            MethodScore(
                methodId: "active-low",
                timesLoaded: 3,
                timesSucceeded: 1,
                timesFailed: 2,
                successRate: 0.33,
                lastUsedAt: Date(),
                score: 0.2
            )
        )

        await MethodSearchService.shared.initialize()
        await MethodSearchService.shared.rebuildIndex()
    }

    @Test func frontierLoadsGenerously() async throws {
        try await seedTestData()
        let ctx = try await ContextInterface.shared.assemble(
            query: "deploy to staging",
            modelId: "claude-opus-4-6",
            agentId: "test"
        )
        #expect(!ctx.rules.isEmpty)
        #expect(ctx.rules.allSatisfy { $0.tier == .rule })
        #expect(ctx.toolIndex == nil)
        #expect(ctx.methodIndex != nil)
    }

    @Test func localLoadsStrictly() async throws {
        try await seedTestData()
        let ctx = try await ContextInterface.shared.assemble(
            query: "deploy to staging",
            modelId: "foundation",
            agentId: "test"
        )
        #expect(!ctx.rules.isEmpty)
        #expect(ctx.matchedMethods.count <= 2)
        #expect(!ctx.coLoadedToolIds.isEmpty)
        #expect(ctx.toolIndex != nil)
        #expect(ctx.methodIndex == nil)
    }

    @Test func noMatchStillLoadsRules() async throws {
        try await seedTestData()
        let ctx = try await ContextInterface.shared.assemble(
            query: "completely unrelated query about cooking recipes",
            modelId: "claude-opus-4-6",
            agentId: "test"
        )
        #expect(!ctx.rules.isEmpty)
        #expect(ctx.rules[0].tier == .rule)
        #expect(ctx.coLoadedToolIds.contains("terminal"))
    }

    @Test func zeroToolsInvariant() async throws {
        try await seedTestData()
        for modelId in ["claude-opus-4-6", "claude-sonnet-4-6", "foundation"] {
            for query in ["deploy to staging", "unrelated query xyz"] {
                let ctx = try await ContextInterface.shared.assemble(
                    query: query,
                    modelId: modelId,
                    agentId: "test"
                )
                let hasToolAccess = !ctx.coLoadedToolIds.isEmpty || ctx.toolIndex != nil
                #expect(hasToolAccess, "No tool access for \(modelId) with query '\(query)'")
            }
        }
    }

    @Test func localExcludesLowScoringMethods() async throws {
        try await seedTestData()
        let ctx = try await ContextInterface.shared.assemble(
            query: "deploy to staging",
            modelId: "foundation",
            agentId: "test"
        )
        let matchedIds = ctx.matchedMethods.map(\.id)
        #expect(!matchedIds.contains("active-low"))
    }

    @Test func rulesAlwaysIncludedInCoLoadedTools() async throws {
        try await seedTestData()
        let ctx = try await ContextInterface.shared.assemble(
            query: "something completely unrelated",
            modelId: "claude-opus-4-6",
            agentId: "test"
        )
        #expect(ctx.coLoadedToolIds.contains("terminal"))
    }

    @Test func loadScoreDelegatesToDatabase() async throws {
        try await seedTestData()
        let score = try await MethodService.shared.loadScore(methodId: "active-high")
        #expect(score != nil)
        #expect(score?.timesLoaded == 10)
        #expect(score?.timesSucceeded == 9)
        #expect(abs((score?.score ?? 0) - 0.9) < 0.001)
    }

    @Test func loadScoreReturnsNilForMissing() async throws {
        try await seedTestData()
        let score = try await MethodService.shared.loadScore(methodId: "nonexistent")
        #expect(score == nil)
    }

    @Test func compactMethodIndexExcludesDormant() async throws {
        try await seedTestData()
        try MethodDatabase.shared.insertMethod(
            OsaurusCore.Method(
                id: "dormant-1",
                name: "old-deploy",
                description: "Obsolete deploy method",
                body: "steps:\n  - tool: terminal",
                source: MethodSource.user,
                tier: MethodTier.dormant,
                toolsUsed: ["terminal"]
            )
        )

        let ctx = try await ContextInterface.shared.assemble(
            query: "deploy",
            modelId: "claude-opus-4-6",
            agentId: "test"
        )

        #expect(ctx.methodIndex != nil)
        #expect(ctx.methodIndex?.contains("old-deploy") == false)
        #expect(ctx.methodIndex?.contains("deploy-staging") == true)
    }
}
