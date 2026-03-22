//
//  MethodTools.swift
//  osaurus
//
//  Agent-facing tools for the methods subsystem: search, load, save, report.
//

import Foundation

// MARK: - methods_search

final class MethodsSearchTool: OsaurusTool, @unchecked Sendable {
    let name = "methods_search"
    let description =
        "Search for reusable methods (recorded tool-call sequences). "
        + "Returns ranked results with names, descriptions, scores, and tiers."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query describing the task"),
            ])
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let query = args["query"] as? String,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: 'query' parameter is required."
        }

        let results = await MethodSearchService.shared.search(query: query, topK: 10)
        if results.isEmpty {
            return "No methods found matching '\(query)'."
        }

        var output = "Found \(results.count) method(s):\n\n"
        for result in results {
            let m = result.method
            output += "- **\(m.name)** (id: \(m.id))\n"
            output += "  Description: \(m.description)\n"
            output += "  Tier: \(m.tier.rawValue) | Score: \(String(format: "%.2f", result.score))\n"
            output += "  Tools: \(m.toolsUsed.joined(separator: ", "))\n\n"
        }
        output += "Use `methods_load` with the id to load full method steps."
        return output
    }
}

// MARK: - methods_load

final class MethodsLoadTool: OsaurusTool, @unchecked Sendable {
    let name = "methods_load"
    let description =
        "Load a method's full step-by-step instructions into context. "
        + "Use after methods_search to get the complete replay sequence."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object([
                "type": .string("string"),
                "description": .string("Method ID to load"),
            ])
        ]),
        "required": .array([.string("id")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let id = args["id"] as? String,
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: 'id' parameter is required."
        }

        guard let method = try await MethodService.shared.load(id: id) else {
            return "Error: Method '\(id)' not found."
        }

        let issueId = WorkExecutionContext.currentIssueId
        try await MethodService.shared.reportOutcome(
            methodId: id,
            outcome: .loaded,
            agentId: issueId
        )

        var output = "# Method: \(method.name)\n\n"
        output += "Description: \(method.description)\n"
        output += "Version: \(method.version) | Source: \(method.source.rawValue)\n"
        if !method.toolsUsed.isEmpty {
            output += "Tools: \(method.toolsUsed.joined(separator: ", "))\n"
        }
        output += "\n---\n\n"
        output += method.body
        return output
    }
}

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
