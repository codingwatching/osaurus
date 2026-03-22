//
//  IntrospectionWorkerTests.swift
//  osaurus
//
//  Unit tests for IntrospectionWorker decision logic:
//  tier promotion/demotion rules and deviation detection.
//

import Foundation
import Testing

@testable import OsaurusCore

private typealias Method = OsaurusCore.Method

struct TierTransitionTests {

    // MARK: - Promotion: active -> rule

    @Test func promotesActiveToRuleWhenQualified() async {
        let method = OsaurusCore.Method(
            id: "m1",
            name: "deploy",
            description: "deploy to staging",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.active
        )
        let score = MethodScore(
            methodId: "m1",
            timesLoaded: 6,
            timesSucceeded: 6,
            timesFailed: 0,
            successRate: 1.0,
            lastUsedAt: Date().addingTimeInterval(-5 * 86400),
            score: 0.85
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition != nil)
        #expect(transition?.newTier == .rule)
        #expect(transition?.eventType == .promoted)
    }

    @Test func doesNotPromoteWithTooFewUses() async {
        let method = OsaurusCore.Method(
            id: "m2",
            name: "test",
            description: "run tests",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.active
        )
        let score = MethodScore(
            methodId: "m2",
            timesLoaded: 4,
            timesSucceeded: 4,
            timesFailed: 0,
            successRate: 1.0,
            lastUsedAt: Date().addingTimeInterval(-2 * 86400),
            score: 0.9
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition == nil)
    }

    @Test func doesNotPromoteWithLowSuccessRate() async {
        let method = OsaurusCore.Method(
            id: "m3",
            name: "fragile",
            description: "fragile method",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.active
        )
        let score = MethodScore(
            methodId: "m3",
            timesLoaded: 10,
            timesSucceeded: 6,
            timesFailed: 4,
            successRate: 0.6,
            lastUsedAt: Date().addingTimeInterval(-1 * 86400),
            score: 0.5
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition == nil)
    }

    // MARK: - Demotion: rule -> active

    @Test func demotesRuleToActiveOnLowSuccess() async {
        let method = OsaurusCore.Method(
            id: "m4",
            name: "bad-rule",
            description: "failing rule",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.rule
        )
        let score = MethodScore(
            methodId: "m4",
            timesLoaded: 4,
            timesSucceeded: 1,
            timesFailed: 3,
            successRate: 0.25,
            lastUsedAt: Date(),
            score: 0.2
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition != nil)
        #expect(transition?.newTier == .active)
        #expect(transition?.eventType == .demoted)
    }

    @Test func ruleStaysRuleWithGoodSuccess() async {
        let method = OsaurusCore.Method(
            id: "m5",
            name: "good-rule",
            description: "solid rule",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.rule
        )
        let score = MethodScore(
            methodId: "m5",
            timesLoaded: 10,
            timesSucceeded: 9,
            timesFailed: 1,
            successRate: 0.9,
            lastUsedAt: Date(),
            score: 0.85
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition == nil)
    }

    // MARK: - Dormancy: active -> dormant

    @Test func dormancyAfter91Days() async {
        let method = OsaurusCore.Method(
            id: "m6",
            name: "old-method",
            description: "unused method",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.active
        )
        let score = MethodScore(
            methodId: "m6",
            timesLoaded: 3,
            timesSucceeded: 2,
            timesFailed: 1,
            successRate: 0.67,
            lastUsedAt: Date().addingTimeInterval(-91 * 86400),
            score: 0.1
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition != nil)
        #expect(transition?.newTier == .dormant)
        #expect(transition?.eventType == .demoted)
    }

    @Test func noTransitionForRecentlyUsedActive() async {
        let method = OsaurusCore.Method(
            id: "m7",
            name: "recent",
            description: "recently used",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            tier: MethodTier.active
        )
        let score = MethodScore(
            methodId: "m7",
            timesLoaded: 3,
            timesSucceeded: 2,
            timesFailed: 1,
            successRate: 0.67,
            lastUsedAt: Date().addingTimeInterval(-10 * 86400),
            score: 0.5
        )

        let transition = await IntrospectionWorker.shared.evaluateTransition(method: method, score: score)
        #expect(transition == nil)
    }
}

struct DeviationDetectionTests {

    private func makeToolCallEvent(toolName: String, success: Bool = true) -> IssueEvent {
        let payload = EventPayload.ToolCallCompleted(
            toolName: toolName,
            iteration: 1,
            arguments: nil,
            result: nil,
            success: success
        )
        return IssueEvent.withPayload(
            issueId: "test-issue",
            eventType: .toolCallCompleted,
            payload: payload
        )
    }

    @Test func noDeviationWhenToolsMatch() async {
        let method = OsaurusCore.Method(
            id: "m1",
            name: "test",
            description: "test",
            body: "steps:\n  - tool: terminal\n  - tool: web_fetch",
            source: MethodSource.user,
            toolsUsed: ["terminal", "web_fetch"]
        )

        let events = [
            makeToolCallEvent(toolName: "terminal"),
            makeToolCallEvent(toolName: "web_fetch"),
        ]

        let deviation = await IntrospectionWorker.shared.detectDeviation(
            method: method,
            actualEvents: events
        )
        #expect(deviation == nil)
    }

    @Test func minorDeviationWhenExtraToolsAppended() async {
        let method = OsaurusCore.Method(
            id: "m2",
            name: "test",
            description: "test",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            toolsUsed: ["terminal"]
        )

        let events = [
            makeToolCallEvent(toolName: "terminal"),
            makeToolCallEvent(toolName: "web_fetch"),
            makeToolCallEvent(toolName: "sandbox_run_script"),
        ]

        let deviation = await IntrospectionWorker.shared.detectDeviation(
            method: method,
            actualEvents: events
        )
        #expect(deviation != nil)
        #expect(deviation?.isMinor == true)
        #expect(deviation?.summary.contains("additional") == true)
    }

    @Test func minorDeviationWhenToolOrderChanged() async {
        let method = OsaurusCore.Method(
            id: "m3",
            name: "test",
            description: "test",
            body: "steps:\n  - tool: terminal\n  - tool: web_fetch",
            source: MethodSource.user,
            toolsUsed: ["terminal", "web_fetch"]
        )

        let events = [
            makeToolCallEvent(toolName: "web_fetch"),
            makeToolCallEvent(toolName: "terminal"),
        ]

        let deviation = await IntrospectionWorker.shared.detectDeviation(
            method: method,
            actualEvents: events
        )
        #expect(deviation != nil)
        #expect(deviation?.isMinor == true)
        #expect(deviation?.summary.contains("order") == true)
    }

    @Test func structuralDeviationWhenToolsMissing() async {
        let method = OsaurusCore.Method(
            id: "m4",
            name: "test",
            description: "test",
            body: "steps:\n  - tool: terminal\n  - tool: web_fetch\n  - tool: sandbox_run_script",
            source: MethodSource.user,
            toolsUsed: ["terminal", "web_fetch", "sandbox_run_script"]
        )

        let events = [
            makeToolCallEvent(toolName: "terminal"),
            makeToolCallEvent(toolName: "new_tool"),
        ]

        let deviation = await IntrospectionWorker.shared.detectDeviation(
            method: method,
            actualEvents: events
        )
        #expect(deviation != nil)
        #expect(deviation?.isMinor == false)
        #expect(deviation?.summary.contains("missing") == true)
    }

    @Test func noDeviationWithNoActualEvents() async {
        let method = OsaurusCore.Method(
            id: "m5",
            name: "test",
            description: "test",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user,
            toolsUsed: ["terminal"]
        )

        let deviation = await IntrospectionWorker.shared.detectDeviation(
            method: method,
            actualEvents: []
        )
        #expect(deviation == nil)
    }
}
