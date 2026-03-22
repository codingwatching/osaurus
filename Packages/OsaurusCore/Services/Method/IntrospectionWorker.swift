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

    static let refinementPrompt = """
        You are refining a reusable method based on how it was actually executed.

        The method's current steps define the expected tool-call sequence.
        The actual execution deviated from the expected steps.

        Your job: update the method YAML to reflect the actual successful execution,
        while preserving the method's intent and structure.

        Rules:
        - Keep the same YAML format (steps, failure_modes)
        - Preserve existing on_fail and expect entries unless contradicted
        - For minor deviations (order changes, extra steps): merge them in naturally
        - For structural deviations (missing/extra tools): rewrite affected steps
        - Use $VARIABLES for user-specific values

        Current method YAML:
        ---
        {method_body}
        ---

        Deviation detected: {deviation_summary}

        Actual tool calls executed (in order):
        {actual_calls}

        Output the refined YAML only, no explanation:
        """

    /// Compares loaded methods' steps vs actual tool calls from the session.
    /// Minor deviations are auto-applied; structural changes are surfaced to the user.
    func runRefinement(issueId: String, sessionStartTime: Date) async {
        do {
            let loadedEvents = try db.loadRecentLoadedEvents(since: sessionStartTime)

            let methodIssueEvents = loadedEvents.filter { $0.agentId == issueId }
            if methodIssueEvents.isEmpty { return }

            let coreModel = await MainActor.run {
                MemoryConfigurationStore.load().coreModelIdentifier
            }

            for event in methodIssueEvents {
                guard let method = try db.loadMethod(id: event.methodId) else { continue }

                let allEvents: [IssueEvent]
                do {
                    allEvents = try IssueStore.getEvents(
                        issueId: issueId,
                        ofType: .toolCallCompleted
                    )
                } catch {
                    introspectionLogger.error("Failed to load events for refinement: \(error)")
                    continue
                }

                let loadedAt = event.createdAt
                let actualEvents = allEvents.filter { $0.createdAt >= loadedAt }

                let deviation = detectDeviation(method: method, actualEvents: actualEvents)
                guard let deviation else { continue }

                let actualCalls = formatActualCalls(actualEvents)

                if deviation.isMinor {
                    await refineMinorDeviation(
                        method: method,
                        deviation: deviation,
                        actualCalls: actualCalls,
                        coreModel: coreModel
                    )
                } else {
                    await storeStructuralDeviation(
                        method: method,
                        deviation: deviation,
                        actualCalls: actualCalls,
                        coreModel: coreModel
                    )
                }
            }
        } catch {
            introspectionLogger.error("Method refinement failed: \(error)")
        }
    }

    private func refineMinorDeviation(
        method: Method,
        deviation: Deviation,
        actualCalls: String,
        coreModel: String
    ) async {
        introspectionLogger.info(
            "Auto-refining method '\(method.name)': \(deviation.summary)"
        )

        do {
            let prompt = Self.refinementPrompt
                .replacingOccurrences(of: "{method_body}", with: method.body)
                .replacingOccurrences(of: "{deviation_summary}", with: deviation.summary)
                .replacingOccurrences(of: "{actual_calls}", with: actualCalls)

            let refinedBody = try await MethodService.shared.callCoreModel(
                prompt: prompt,
                coreModelIdentifier: coreModel
            )

            var updated = method
            updated.body = refinedBody
            updated.toolsUsed = await MethodService.shared.extractToolIds(from: refinedBody)
            updated.tokenCount = max(1, refinedBody.count / 4)
            updated.version += 1
            try await MethodService.shared.update(updated)

            let event = MethodEvent(
                methodId: method.id,
                eventType: .refined,
                notes: "Auto-refined: \(deviation.summary)"
            )
            try db.insertEvent(event)

            introspectionLogger.info("Method '\(method.name)' refined to v\(updated.version)")
        } catch {
            introspectionLogger.error("Auto-refinement failed for '\(method.name)': \(error)")
            let fallbackEvent = MethodEvent(
                methodId: method.id,
                eventType: .refined,
                notes: "Refinement attempted but Core Model call failed: \(deviation.summary)"
            )
            try? db.insertEvent(fallbackEvent)
        }
    }

    private func storeStructuralDeviation(
        method: Method,
        deviation: Deviation,
        actualCalls: String,
        coreModel: String
    ) async {
        introspectionLogger.info(
            "Structural deviation for '\(method.name)': \(deviation.summary). Generating suggestion."
        )

        var suggestion = ""
        do {
            let prompt = Self.refinementPrompt
                .replacingOccurrences(of: "{method_body}", with: method.body)
                .replacingOccurrences(of: "{deviation_summary}", with: deviation.summary)
                .replacingOccurrences(of: "{actual_calls}", with: actualCalls)

            suggestion = try await MethodService.shared.callCoreModel(
                prompt: prompt,
                coreModelIdentifier: coreModel
            )
        } catch {
            introspectionLogger.error(
                "Core Model call failed for structural refinement of '\(method.name)': \(error)"
            )
            suggestion = "(Core Model unavailable — manual review needed)"
        }

        let notes =
            "[pending_review] deviation: \(deviation.summary) | suggestion: \(suggestion)"
        let event = MethodEvent(
            methodId: method.id,
            eventType: .refined,
            notes: notes
        )
        try? db.insertEvent(event)

        introspectionLogger.info(
            "Stored pending refinement for '\(method.name)' — user review needed"
        )
    }

    private func formatActualCalls(_ events: [IssueEvent]) -> String {
        events.compactMap { event -> String? in
            guard let payloadStr = event.payload,
                let data = payloadStr.data(using: .utf8),
                let payload = try? JSONDecoder().decode(EventPayload.ToolCallCompleted.self, from: data)
            else { return nil }
            let status = payload.success ? "success" : "failed"
            return "- \(payload.toolName) [\(status)]"
        }.joined(separator: "\n")
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

    static let toolPackagingPrompt = """
        You are packaging a successful sandbox script into a reusable tool manifest.

        Given the script arguments and result, generate a SandboxPlugin-compatible tool definition.

        The output must be valid JSON matching this structure:
        {
          "name": "<tool_name_snake_case>",
          "description": "<one-line description of what this tool does>",
          "parameters": {
            "<param_name>": { "type": "string", "description": "<what this parameter controls>" }
          },
          "script_template": "<the generalized script with {{param_name}} placeholders>"
        }

        Rules:
        - Extract a clear, reusable name from the script's purpose
        - Parameterize user-specific values (paths, names, URLs) as template variables
        - Keep the description concise (under 100 characters)
        - Only include parameters that would change between invocations

        Script arguments:
        ---
        {arguments}
        ---

        Script result summary:
        ---
        {result}
        ---

        Generate the tool manifest JSON:
        """

    /// Scans session for successful sandbox_run_script calls and suggests packaging as tools.
    func runToolPackaging(issueId: String) async {
        do {
            let events = try IssueStore.getEvents(issueId: issueId, ofType: .toolCallCompleted)

            let decoder = JSONDecoder()
            let scriptPayloads: [(event: IssueEvent, payload: EventPayload.ToolCallCompleted)] =
                events.compactMap { event in
                    guard let payloadStr = event.payload,
                        let data = payloadStr.data(using: .utf8),
                        let payload = try? decoder.decode(EventPayload.ToolCallCompleted.self, from: data),
                        payload.toolName == "sandbox_run_script" && payload.success
                    else { return nil }
                    return (event, payload)
                }

            guard !scriptPayloads.isEmpty else { return }

            let coreModel = await MainActor.run {
                MemoryConfigurationStore.load().coreModelIdentifier
            }

            for (event, payload) in scriptPayloads {
                let existingTools = await ToolSearchService.shared.search(
                    query: payload.arguments ?? "script",
                    topK: 3,
                    threshold: 0.8
                )

                guard existingTools.isEmpty else { continue }

                let prompt = Self.toolPackagingPrompt
                    .replacingOccurrences(
                        of: "{arguments}",
                        with: payload.arguments ?? "(no arguments)"
                    )
                    .replacingOccurrences(
                        of: "{result}",
                        with: String((payload.result ?? "(no result)").prefix(2000))
                    )

                do {
                    let manifest = try await MethodService.shared.callCoreModel(
                        prompt: prompt,
                        coreModelIdentifier: coreModel
                    )

                    introspectionLogger.info(
                        "Tool packaging suggestion generated for session \(issueId):\n\(manifest)"
                    )

                    let entry = ToolIndexEntry(
                        id: "suggestion_\(issueId)_\(event.id)",
                        name: "suggestion_\(issueId)_\(event.id)",
                        description: "[packaging_suggestion] \(manifest.prefix(200))",
                        runtime: .sandbox,
                        source: .introspection,
                        tokenCount: manifest.count / 4
                    )
                    try ToolDatabase.shared.upsertEntry(entry)
                    await ToolSearchService.shared.indexEntry(entry)
                } catch {
                    introspectionLogger.error(
                        "Tool packaging Core Model call failed for session \(issueId): \(error)"
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
        guard !expectedTools.isEmpty else { return nil }

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
