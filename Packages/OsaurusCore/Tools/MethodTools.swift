//
//  MethodTools.swift
//  osaurus
//
//  Agent-facing tools for saving and reporting on methods.
//  Search and load are handled by capabilities_search / capabilities_load.
//

import Foundation

// MARK: - methods_save

final class MethodsSaveTool: OsaurusTool, @unchecked Sendable {
    let name = "methods_save"
    let description =
        "Save a reusable method from the current session. "
        + "Provide steps_yaml directly, or omit it to auto-distill from this session's tool calls."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Short name for the method"),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("What this method does"),
            ]),
            "trigger_text": .object([
                "type": .string("string"),
                "description": .string("Phrases that should trigger this method"),
            ]),
            "steps_yaml": .object([
                "type": .string("string"),
                "description": .string(
                    "YAML steps directly. If omitted, distills from current session's tool calls."
                ),
            ]),
        ]),
        "required": .array([.string("name"), .string("description")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let rawName = args["name"] as? String,
            let rawDesc = args["description"] as? String
        else {
            return "Error: 'name' and 'description' parameters are required."
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty else {
            return "Error: 'name' and 'description' must not be blank."
        }

        let triggerText = args["trigger_text"] as? String
        let stepsYaml = args["steps_yaml"] as? String

        if let yaml = stepsYaml, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let method = try await MethodService.shared.create(
                name: name,
                description: description,
                triggerText: triggerText,
                body: yaml,
                source: .user
            )
            return
                "Method '\(method.name)' saved (id: \(method.id), tools: \(method.toolsUsed.joined(separator: ", ")))."
        }

        let trace = try buildTraceFromCurrentSession()
        if trace.isEmpty {
            return "Error: No successful tool calls found in the current session to distill."
        }

        let coreModel = await MainActor.run {
            MemoryConfigurationStore.load().coreModelIdentifier
        }

        let method = try await MethodService.shared.distill(
            trace: trace,
            name: name,
            description: description,
            triggerText: triggerText,
            coreModelIdentifier: coreModel
        )

        return
            "Method '\(method.name)' distilled and saved (id: \(method.id), tools: \(method.toolsUsed.joined(separator: ", ")))."
    }

    private func buildTraceFromCurrentSession() throws -> String {
        guard let issueId = WorkExecutionContext.currentIssueId else {
            return ""
        }

        let events = try IssueStore.getEvents(issueId: issueId, ofType: .toolCallCompleted)
        if events.isEmpty { return "" }

        var trace = ""
        var stepNumber = 0
        for event in events {
            guard let payloadStr = event.payload,
                let data = payloadStr.data(using: .utf8),
                let payload = try? JSONDecoder().decode(EventPayload.ToolCallCompleted.self, from: data)
            else { continue }

            guard payload.success else { continue }

            stepNumber += 1

            let truncatedResult =
                payload.result.map { result in
                    result.count > 500 ? String(result.prefix(500)) + "..." : result
                } ?? "(no output)"

            let truncatedArgs =
                payload.arguments.map { args in
                    args.count > 300 ? String(args.prefix(300)) + "..." : args
                } ?? ""

            trace += "Step \(stepNumber): \(payload.toolName)(\(truncatedArgs)) -> \(truncatedResult)\n"
        }
        return trace
    }
}

// MARK: - methods_report

final class MethodsReportTool: OsaurusTool, @unchecked Sendable {
    let name = "methods_report"
    let description =
        "Report the outcome of following a method. "
        + "Call after completing (or failing) a method's steps to update its score."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object([
                "type": .string("string"),
                "description": .string("Method ID to report on"),
            ]),
            "outcome": .object([
                "type": .string("string"),
                "description": .string("Result: 'succeeded' or 'failed'"),
                "enum": .array([.string("succeeded"), .string("failed")]),
            ]),
            "notes": .object([
                "type": .string("string"),
                "description": .string("Optional notes about what happened"),
            ]),
        ]),
        "required": .array([.string("id"), .string("outcome")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let id = args["id"] as? String,
            let outcomeStr = args["outcome"] as? String,
            let outcome = MethodEventType(rawValue: outcomeStr),
            (outcome == .succeeded || outcome == .failed)
        else {
            return "Error: 'id' and 'outcome' (succeeded/failed) are required."
        }

        guard let method = try await MethodService.shared.load(id: id) else {
            return "Error: Method '\(id)' not found."
        }

        try await MethodService.shared.reportOutcome(
            methodId: id,
            outcome: outcome,
            agentId: WorkExecutionContext.currentIssueId
        )

        let score = try await MethodService.shared.loadScore(methodId: id)
        let scoreStr = score.map { String(format: "%.2f", $0.score) } ?? "N/A"
        return "Reported '\(outcomeStr)' for method '\(method.name)'. Current score: \(scoreStr)."
    }
}
