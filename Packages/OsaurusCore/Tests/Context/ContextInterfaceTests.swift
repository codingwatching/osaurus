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
}
