//
//  EvalRunnerToolResultGrounding.swift
//  OsaurusEvalsKit
//
//  Pure-data scoring for frozen tool-call/result transcripts. This lane
//  gives runtime-proof artifacts a deterministic way to show that the final
//  answer used the tool result payload, not stale prompt text or call args.
//

import Foundation

extension EvalRunner {
    static func runToolResultGroundingCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.toolResultGrounding else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["missing `expect.toolResultGrounding`"],
                modelId: modelId
            )
        }

        let parsed = parseToolResultGroundingEvents(exp.events)
        if !parsed.errors.isEmpty {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: parsed.errors,
                modelId: modelId
            )
        }

        var notes: [String] = []
        let requireMatchedResults = exp.requireMatchedResults ?? true
        if requireMatchedResults {
            for result in parsed.results.values.sorted(by: { $0.index < $1.index }) {
                guard let call = parsed.calls[result.callId] else {
                    notes.append("tool result \(result.callId) has no prior matching tool call")
                    continue
                }
                if result.index < call.index {
                    notes.append("tool result \(result.callId) appears before its matching tool call")
                }
                if let resultTool = result.tool, resultTool != call.tool {
                    notes.append(
                        "tool result \(result.callId) tool mismatch: call \(call.tool), result \(resultTool)"
                    )
                }
            }
        }

        guard let final = parsed.finalAssistant else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .failed,
                notes: notes + ["no final assistant message to score"],
                modelId: modelId
            )
        }

        if exp.requireFinalAfterToolResults ?? true {
            let anyPriorResult = parsed.results.values.contains { $0.index < final.index }
            if !anyPriorResult {
                notes.append("final answer appeared before any tool result")
            }
        }

        for assertion in exp.assertions {
            guard let result = parsed.results[assertion.callId] else {
                notes.append("assertion references missing tool result \(assertion.callId)")
                continue
            }
            let call = parsed.calls[assertion.callId]
            if result.index > final.index {
                notes.append("asserted tool result \(assertion.callId) appears after the final answer")
            }

            for fragment in assertion.resultMustContain ?? [] {
                if !result.content.contains(fragment) {
                    notes.append("result \(assertion.callId) missing required fragment `\(fragment)`")
                }
            }
            for fragment in assertion.answerMustContain ?? [] {
                if !final.content.contains(fragment) {
                    notes.append("final answer missing required fragment `\(fragment)`")
                }
                if !result.content.contains(fragment) {
                    notes.append(
                        "required answer fragment `\(fragment)` is not present in result \(assertion.callId)"
                    )
                }
                if call?.arguments?.contains(fragment) == true {
                    notes.append(
                        "required answer fragment `\(fragment)` was already present in tool call \(assertion.callId) arguments"
                    )
                }
            }
            for fragment in assertion.answerMustNotContain ?? [] {
                if final.content.contains(fragment) {
                    notes.append("final answer contains forbidden fragment `\(fragment)`")
                }
            }
            for fragment in assertion.argumentsMustNotContain ?? [] {
                if call?.arguments?.contains(fragment) == true {
                    notes.append("tool call \(assertion.callId) arguments contain forbidden fragment `\(fragment)`")
                }
            }
        }

        let passed = notes.isEmpty
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: passed
                ? ["grounded \(exp.assertions.count) assertion(s) across \(parsed.results.count) tool result(s)"]
                : notes,
            modelId: modelId
        )
    }

    private static func parseToolResultGroundingEvents(
        _ events: [EvalCase.ToolResultGroundingExpectations.Event]
    ) -> GroundingParse {
        var calls: [String: GroundingCall] = [:]
        var results: [String: GroundingResult] = [:]
        var finalAssistant: GroundingAssistant?
        var errors: [String] = []

        for (index, event) in events.enumerated() {
            switch normalizedGroundingKind(event.kind) {
            case "toolcall":
                guard let callId = nonEmpty(event.callId), let tool = nonEmpty(event.tool) else {
                    errors.append("event \(index) toolCall needs non-empty callId and tool")
                    continue
                }
                if calls[callId] != nil {
                    errors.append("event \(index) duplicates toolCall id \(callId)")
                    continue
                }
                calls[callId] = GroundingCall(
                    callId: callId,
                    tool: tool,
                    arguments: event.arguments,
                    index: index
                )
            case "toolresult":
                guard let callId = nonEmpty(event.callId), let content = event.content else {
                    errors.append("event \(index) toolResult needs non-empty callId and content")
                    continue
                }
                if results[callId] != nil {
                    errors.append("event \(index) duplicates toolResult id \(callId)")
                    continue
                }
                results[callId] = GroundingResult(
                    callId: callId,
                    tool: event.tool,
                    content: content,
                    index: index
                )
            case "assistant":
                guard let content = event.content else {
                    errors.append("event \(index) assistant needs content")
                    continue
                }
                finalAssistant = GroundingAssistant(content: content, index: index)
            default:
                errors.append("event \(index) has unknown kind `\(event.kind)`")
            }
        }

        return GroundingParse(
            calls: calls,
            results: results,
            finalAssistant: finalAssistant,
            errors: errors
        )
    }

    private static func normalizedGroundingKind(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private struct GroundingParse {
        var calls: [String: GroundingCall]
        var results: [String: GroundingResult]
        var finalAssistant: GroundingAssistant?
        var errors: [String]
    }

    private struct GroundingCall {
        var callId: String
        var tool: String
        var arguments: String?
        var index: Int
    }

    private struct GroundingResult {
        var callId: String
        var tool: String?
        var content: String
        var index: Int
    }

    private struct GroundingAssistant {
        var content: String
        var index: Int
    }
}
