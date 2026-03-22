//
//  IntrospectionWorker.swift
//  osaurus
//
//  Background actor for method lifecycle management:
//  - Job 1: Method refinement (session end)
//  - Job 2: Tier promotion/demotion (daily)
//  - Job 4: Tool packaging from sandbox_run_script traces (session end)
//  - Job 3 (pattern detection) is deferred to a second iteration.
//

import Foundation
import os

private let introspectionLogger = Logger(subsystem: "ai.osaurus", category: "introspection")

public actor IntrospectionWorker {
    public static let shared = IntrospectionWorker()

    private let db = MethodDatabase.shared
    private var lastDailyRun: Date?
    private static let dailyInterval: TimeInterval = 86400
    private static let dormancyThresholdDays = 90
    private static let pruneThresholdDays = 180

    private init() {}

    // MARK: - Session End Hook

    /// Called when a work session ends. Runs refinement (Job 1) and tool packaging (Job 4).
    public func onSessionEnd(issueId: String, sessionStartTime: Date) async {
        await runRefinement(issueId: issueId, sessionStartTime: sessionStartTime)
        await runToolPackaging(issueId: issueId)

        if shouldRunDaily() {
            await runTierManagement()
            lastDailyRun = Date()
        }
    }

    // MARK: - Job 1: Method Refinement

    /// Compares loaded methods' steps vs actual tool calls from the session.
    /// Minor deviations are auto-applied; structural changes are surfaced to the user.
    func runRefinement(issueId: String, sessionStartTime: Date) async {
        do {
            let loadedEvents = try db.loadRecentLoadedEvents(since: sessionStartTime)

            let methodIssueEvents = loadedEvents.filter { $0.agentId == issueId }
            if methodIssueEvents.isEmpty { return }

            for event in methodIssueEvents {
                guard let method = try db.loadMethod(id: event.methodId) else { continue }

                let actualEvents: [IssueEvent]
                do {
                    actualEvents = try IssueStore.getEvents(
                        issueId: issueId,
                        ofType: .toolCallCompleted
                    )
                } catch {
                    introspectionLogger.error("Failed to load events for refinement: \(error)")
                    continue
                }

                let deviation = detectDeviation(method: method, actualEvents: actualEvents)
                guard let deviation else { continue }

                if deviation.isMinor {
                    introspectionLogger.info(
                        "Auto-refining method '\(method.name)': \(deviation.summary)"
                    )
                    let event = MethodEvent(
                        methodId: method.id,
                        eventType: .refined,
                        notes: "Auto-refined: \(deviation.summary)"
                    )
                    try db.insertEvent(event)
                } else {
                    introspectionLogger.info(
                        "Structural deviation detected for method '\(method.name)': \(deviation.summary). Surfacing to user."
                    )
                }
            }
        } catch {
            introspectionLogger.error("Method refinement failed: \(error)")
        }
    }

    // MARK: - Job 2: Tier Promotion/Demotion

    /// Checks all methods against transition rules and promotes/demotes as needed.
    public func runTierManagement() async {
        do {
            let methods = try db.loadAllMethods()
            let scores = try db.loadAllScores()
            let scoreByMethod = Dictionary(scores.map { ($0.methodId, $0) }, uniquingKeysWith: { first, _ in first })

            for method in methods {
                guard let score = scoreByMethod[method.id] else { continue }

                let transition = evaluateTransition(method: method, score: score)
                guard let transition else { continue }

                var updated = method
                updated.tier = transition.newTier

                try db.updateMethod(updated)

                let event = MethodEvent(
                    methodId: method.id,
                    eventType: transition.eventType,
                    notes: transition.reason
                )
                try db.insertEvent(event)
                await MethodSearchService.shared.indexMethod(updated)

                introspectionLogger.info(
                    "Method '\(method.name)' \(transition.eventType.rawValue): \(transition.reason)"
                )
            }
        } catch {
            introspectionLogger.error("Tier management failed: \(error)")
        }
    }

    // MARK: - Job 4: Tool Packaging

    /// Scans session for successful sandbox_run_script calls and suggests packaging as tools.
    func runToolPackaging(issueId: String) async {
        do {
            let events = try IssueStore.getEvents(issueId: issueId, ofType: .toolCallCompleted)

            let sandboxScriptEvents = events.filter { event in
                guard let payloadStr = event.payload,
                    let data = payloadStr.data(using: .utf8),
                    let payload = try? JSONDecoder().decode(EventPayload.ToolCallCompleted.self, from: data)
                else { return false }
                return payload.toolName == "sandbox_run_script" && payload.success
            }

            guard !sandboxScriptEvents.isEmpty else { return }

            for event in sandboxScriptEvents {
                guard let payloadStr = event.payload,
                    let data = payloadStr.data(using: .utf8),
                    let payload = try? JSONDecoder().decode(EventPayload.ToolCallCompleted.self, from: data)
                else { continue }

                let existingTools = await ToolSearchService.shared.search(
                    query: payload.arguments ?? "script",
                    topK: 3,
                    threshold: 0.8
                )

                if existingTools.isEmpty {
                    introspectionLogger.info(
                        "Candidate tool detected from sandbox_run_script in session \(issueId). Could be packaged as a reusable tool."
                    )
                }
            }
        } catch {
            introspectionLogger.error("Tool packaging scan failed: \(error)")
        }
    }

    // MARK: - Deviation Detection

    struct Deviation {
        let isMinor: Bool
        let summary: String
    }

    func detectDeviation(method: Method, actualEvents: [IssueEvent]) -> Deviation? {
        let expectedTools = method.toolsUsed

        let actualTools: [String] = actualEvents.compactMap { event in
            guard let payloadStr = event.payload,
                let data = payloadStr.data(using: .utf8),
                let payload = try? JSONDecoder().decode(EventPayload.ToolCallCompleted.self, from: data)
            else { return nil }
            return payload.toolName
        }

        guard !actualTools.isEmpty else { return nil }

        let expectedSet = Set(expectedTools)
        let actualSet = Set(actualTools)

        if expectedTools == Array(actualTools.prefix(expectedTools.count)) {
            if actualTools.count > expectedTools.count {
                let extra = actualTools.count - expectedTools.count
                return Deviation(isMinor: true, summary: "\(extra) additional tool call(s) appended")
            }
            return nil
        }

        let missingTools = expectedSet.subtracting(actualSet)
        let extraTools = actualSet.subtracting(expectedSet)

        if missingTools.isEmpty && extraTools.isEmpty {
            return Deviation(isMinor: true, summary: "Tool order changed")
        }

        var parts: [String] = []
        if !missingTools.isEmpty {
            parts.append("missing: \(missingTools.sorted().joined(separator: ", "))")
        }
        if !extraTools.isEmpty {
            parts.append("extra: \(extraTools.sorted().joined(separator: ", "))")
        }
        return Deviation(isMinor: false, summary: parts.joined(separator: "; "))
    }

    // MARK: - Tier Transition Logic

    struct TierTransition {
        let newTier: MethodTier
        let eventType: MethodEventType
        let reason: String
    }

    func evaluateTransition(method: Method, score: MethodScore) -> TierTransition? {
        let daysSinceUsed: Int
        if let last = score.lastUsedAt {
            daysSinceUsed = Int(Date().timeIntervalSince(last) / 86400.0)
        } else {
            daysSinceUsed = 999
        }

        switch method.tier {
        case .active:
            // active -> rule: used >= 5x, success >= 80%, used within last 30 days
            if score.timesLoaded >= 5 && score.successRate >= 0.8 && daysSinceUsed <= 30 {
                return TierTransition(
                    newTier: .rule,
                    eventType: .promoted,
                    reason: "Promoted to rule: \(score.timesLoaded) uses, \(Int(score.successRate * 100))% success"
                )
            }
            // active -> dormant: not used in 90 days
            if daysSinceUsed >= Self.dormancyThresholdDays {
                return TierTransition(
                    newTier: .dormant,
                    eventType: .demoted,
                    reason: "Demoted to dormant: unused for \(daysSinceUsed) days"
                )
            }

        case .rule:
            // rule -> active: success < 50% over last 3+ uses
            let recentTotal = score.timesSucceeded + score.timesFailed
            if recentTotal >= 3 && score.successRate < 0.5 {
                return TierTransition(
                    newTier: .active,
                    eventType: .demoted,
                    reason: "Demoted to active: \(Int(score.successRate * 100))% success over \(recentTotal) uses"
                )
            }

        case .dormant:
            // dormant -> pruned: not used in 180 days (notify, don't auto-delete)
            if daysSinceUsed >= Self.pruneThresholdDays {
                introspectionLogger.info(
                    "Method '\(method.name)' is a pruning candidate (unused for \(daysSinceUsed) days)"
                )
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func shouldRunDaily() -> Bool {
        guard let last = lastDailyRun else { return true }
        return Date().timeIntervalSince(last) >= Self.dailyInterval
    }
}
