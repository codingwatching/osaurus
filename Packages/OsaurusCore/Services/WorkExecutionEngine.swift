//
//  WorkExecutionEngine.swift
//  osaurus
//
//  Execution engine for Osaurus Agents - reasoning loop based.
//  Handles iterative task execution where model decides actions.
//

import Foundation

/// Execution engine for running work tasks via reasoning loop
public actor WorkExecutionEngine {
    /// The chat engine for LLM calls
    private let chatEngine: ChatEngineProtocol

    init(chatEngine: ChatEngineProtocol? = nil) {
        self.chatEngine = chatEngine ?? ChatEngine(source: .chatUI)
    }

    // MARK: - Tool Execution

    /// Maximum time (in seconds) to wait for a single tool execution before timing out.
    private static let toolExecutionTimeout: UInt64 = 120

    /// Executes a tool call with a timeout to prevent indefinite hangs.
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        overrides: [String: Bool]?,
        issueId: String
    ) async throws -> ToolCallResult {
        let callId =
            invocation.toolCallId
            ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        let timeout = Self.toolExecutionTimeout
        let toolName = invocation.toolName

        let result: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await self.executeToolInBackground(
                    name: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments,
                    overrides: overrides,
                    issueId: issueId
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                return nil
            }

            let first = await group.next()!
            group.cancelAll()

            if let result = first {
                return result
            }

            print("[WorkExecutionEngine] Tool '\(toolName)' timed out after \(timeout)s")
            return "[TIMEOUT] Tool '\(toolName)' did not complete within \(timeout) seconds."
        }

        let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(
                name: invocation.toolName,
                arguments: invocation.jsonArguments
            ),
            geminiThoughtSignature: invocation.geminiThoughtSignature
        )

        return ToolCallResult(toolCall: toolCall, result: result)
    }

    /// Helper to execute tool in background with issue context
    private func executeToolInBackground(
        name: String,
        argumentsJSON: String,
        overrides: [String: Bool]?,
        issueId: String
    ) async -> String {
        do {
            // Wrap with execution context so folder tools can log operations
            return try await WorkExecutionContext.$currentIssueId.withValue(issueId) {
                try await ToolRegistry.shared.execute(
                    name: name,
                    argumentsJSON: argumentsJSON,
                    overrides: overrides
                )
            }
        } catch {
            print("[WorkExecutionEngine] Tool execution failed: \(error)")
            return "[REJECTED] \(error.localizedDescription)"
        }
    }

    // MARK: - Tool Result Truncation

    /// Maximum characters for a single tool result in the conversation.
    static let maxToolResultLength = 8000

    /// Truncates a tool result, keeping head and tail with an omission marker.
    /// Internal visibility for testability via `@testable import`.
    func truncateToolResult(_ result: String) -> String {
        guard result.count > Self.maxToolResultLength else { return result }
        if let structured = truncateStructuredToolResult(result) {
            return structured
        }
        return truncatePlainTextToolResult(result)
    }

    private func truncateStructuredToolResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
            var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let preferredKeys = ["stdout", "stderr", "output", "content", "entries", "matches", "processes"]
        let presentKeys = preferredKeys.filter { (payload[$0] as? String)?.isEmpty == false }
        guard !presentKeys.isEmpty else { return nil }

        let perFieldLimit = max(600, (Self.maxToolResultLength - 1200) / max(presentKeys.count, 1))
        var truncatedAny = false
        for key in presentKeys {
            guard let value = payload[key] as? String, value.count > perFieldLimit else { continue }
            payload[key] = truncatePlainTextToolResult(value, limit: perFieldLimit)
            payload["\(key)_truncated"] = true
            payload["\(key)_original_length"] = value.count
            truncatedAny = true
        }

        guard truncatedAny,
            let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: encoded, encoding: .utf8),
            text.count <= Self.maxToolResultLength
        else { return nil }

        return text
    }

    private func truncatePlainTextToolResult(_ result: String, limit: Int = maxToolResultLength) -> String {
        guard result.count > limit else { return result }
        let headSize = limit * 3 / 4
        let tailSize = limit / 4
        let head = String(result.prefix(headSize))
        let tail = String(result.suffix(tailSize))
        let omitted = result.count - headSize - tailSize
        return
            "\(head)\n\n[... \(omitted) characters omitted — use sandbox_read_file (with start_line, line_count, or tail_lines) or file_read to inspect the full output ...]\n\n\(tail)"
    }

    // MARK: - Folder Context

    /// Builds the folder context section for prompts when a folder is selected
    private static func buildFolderContextSection(from folderContext: WorkFolderContext?) -> String {
        guard let folder = folderContext else {
            return ""
        }

        var section = "\n## Working Directory\n"
        section += "**Path:** \(folder.rootPath.path)\n"
        section += "**Project Type:** \(folder.projectType.displayName)\n"

        section += "\n**File Structure:**\n```\n\(folder.tree)```\n"

        if let manifest = folder.manifest {
            // Truncate manifest if too long for prompt
            let truncatedManifest =
                manifest.count > 2000 ? String(manifest.prefix(2000)) + "\n... (truncated)" : manifest
            section += "\n**Manifest:**\n```\n\(truncatedManifest)\n```\n"
        }

        if let gitStatus = folder.gitStatus, !gitStatus.isEmpty {
            section += "\n**Git Status:**\n```\n\(gitStatus)\n```\n"
        }

        section +=
            "\n**File Tools Available:** Use file_read, file_write, file_edit, file_search, etc. to work with files.\n"
        section += "Always read files before editing. Use relative paths from the working directory.\n"
        section +=
            "To share files or content with the user, call `share_artifact` with a relative path or pass content directly.\n"

        return section
    }

    private static let sandboxEnvironmentBlock = """
        You have access to an isolated Linux sandbox (Alpine Linux, ARM64).
        Your workspace is your home directory inside the sandbox.
        The user cannot see files you create unless you call `share_artifact` with a relative path or inline content.

        Pre-installed: bash, python3, pip, node, npm, git, curl, wget, jq, ripgrep (rg),
        sqlite3, build-base (gcc/make), cmake, vim, tree, and standard POSIX utilities.
        The default shell is bash. Internet access is available.

        **Prefer scripts over sequential tool calls.** Use `sandbox_run_script` for
        multi-line scripts (python, bash, node). For single shell commands use
        `sandbox_exec`. For background processes use `sandbox_exec_background`.
        Set `timeout` for long operations (default 60s scripts, 30s exec, max 300s).
        """

    private static let sandboxRuntimeHints = """
        Runtime hints:
        - Python deps: `sandbox_pip_install` installs into the agent's `.venv`; execution tools automatically prefer it.
        - Node deps: `sandbox_npm_install` installs packages and execution tools include local `node_modules/.bin` on PATH for the current working directory.
        - Additional toolchains like Go or Rust can be installed with `sandbox_install`.
        - Use `sandbox_read_file` with `start_line`, `line_count`, or `tail_lines` to inspect large logs.

        The sandbox is disposable — experiment freely.
        """

    /// Chat-mode sandbox guidance (no `complete_task` workflow).
    static func chatSandboxPromptSection() -> String {
        """

        ## Linux Sandbox Environment

        \(sandboxEnvironmentBlock)
        Files persist across messages.

        \(sandboxRuntimeHints)

        """
    }

    /// Work-mode sandbox guidance with the full build/verify/share/complete pattern.
    static func sandboxPromptSection() -> String {
        """

        ## Linux Sandbox Environment

        \(sandboxEnvironmentBlock)
        Files persist across tasks.

        For build/test tasks, follow this pattern:
        1. Inspect the workspace and choose a stack.
        2. Prefer one `sandbox_run_script` to scaffold or bulk-edit multiple files.
        3. Install project-specific dependencies with `sandbox_pip_install` or `sandbox_npm_install`.
        4. Run tests or verification commands with `sandbox_exec`.
        5. If verification fails, read the error carefully, fix the cause, and rerun.
        6. **IMPORTANT:** Call `share_artifact` for every file or directory the user should see (images, charts, websites, reports, code output, etc.). Do this BEFORE calling `complete_task`.
        7. When everything passes, call `complete_task` with a concise summary.

        \(sandboxRuntimeHints)

        """
    }

    // MARK: - Reasoning Loop

    /// Callback type for iteration-based streaming updates
    public typealias IterationStreamingCallback = @MainActor @Sendable (String, Int) async -> Void

    /// Callback type for tool call completion
    public typealias ToolCallCallback = @MainActor @Sendable (String, String, String) async -> Void

    /// Callback type for status updates
    public typealias StatusCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for artifact generation
    public typealias ArtifactCallback = @MainActor @Sendable (SharedArtifact) async -> Void

    /// Callback type for iteration start (iteration number)
    public typealias IterationStartCallback = @MainActor @Sendable (Int) async -> Void

    /// Callback type for tool hint (pending tool name detected during streaming)
    public typealias ToolHintCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for token consumption (inputTokens, outputTokens)
    public typealias TokenConsumptionCallback = @MainActor @Sendable (Int, Int) async -> Void
    public typealias InterruptCheckCallback = @Sendable () async -> Bool

    /// Default maximum iterations for the reasoning loop
    public static let defaultMaxIterations = 50

    /// Maximum consecutive text-only responses (no tool call) before aborting.
    /// Models that don't support tool calling will describe actions in plain text
    /// instead of invoking tools, causing an infinite loop of "Continue" prompts.
    private static let maxConsecutiveTextOnlyResponses = 3

    /// The main reasoning loop. Model decides what to do on each iteration.
    /// - Parameters:
    ///   - issue: The issue being executed
    ///   - messages: Conversation messages (mutated with new messages)
    ///   - systemPrompt: The full system prompt including work instructions
    ///   - model: Model to use
    ///   - tools: All available tools (model picks which to use)
    ///   - toolOverrides: Tool permission overrides
    ///   - contextLength: Model context window size in tokens (used for budget management)
    ///   - toolTokenEstimate: Estimated tokens consumed by tool definitions
    ///   - maxIterations: Maximum loop iterations (not tool calls - iterations)
    ///   - onIterationStart: Callback at the start of each iteration
    ///   - onDelta: Callback for streaming text deltas
    ///   - onToolCall: Callback when a tool is called (toolName, args, result)
    ///   - onStatusUpdate: Callback for status messages
    ///   - onArtifact: Callback when an artifact is shared (via share_artifact tool)
    ///   - onTokensConsumed: Callback with estimated token consumption per iteration
    /// - Returns: The result of the loop execution
    func executeLoop(
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        toolOverrides: [String: Bool]?,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        topPOverride: Float? = nil,
        contextLength: Int? = nil,
        toolTokenEstimate: Int = 0,
        maxIterations: Int = defaultMaxIterations,
        executionMode: WorkExecutionMode = .none,
        sandboxAgentName: String? = nil,
        shouldInterrupt: @escaping InterruptCheckCallback = { false },
        onIterationStart: @escaping IterationStartCallback,
        onDelta: @escaping IterationStreamingCallback,
        onToolHint: @escaping ToolHintCallback,
        onToolCall: @escaping ToolCallCallback,
        onStatusUpdate: @escaping StatusCallback,
        onArtifact: @escaping ArtifactCallback,
        onTokensConsumed: @escaping TokenConsumptionCallback
    ) async throws -> LoopResult {
        var iteration = 0
        var totalToolCalls = 0
        var toolsUsed: [String] = []
        var consecutiveTextOnly = 0
        var lastResponseContent = ""

        // Set up context budget manager if context length is known
        var budgetManager: ContextBudgetManager? = nil
        if let ctxLen = contextLength {
            var manager = ContextBudgetManager(contextLength: ctxLen)
            manager.reserveByCharCount(.systemPrompt, characters: systemPrompt.count)
            manager.reserve(.tools, tokens: toolTokenEstimate)
            manager.reserve(.memory, tokens: 0)
            manager.reserve(.response, tokens: maxTokens ?? 4096)
            budgetManager = manager
        }

        while iteration < maxIterations {
            iteration += 1
            if Task.isCancelled {
                return .interrupted(
                    messages: messages,
                    iteration: iteration - 1,
                    totalToolCalls: totalToolCalls
                )
            }
            if await shouldInterrupt() {
                return .interrupted(
                    messages: messages,
                    iteration: iteration - 1,
                    totalToolCalls: totalToolCalls
                )
            }

            await onIterationStart(iteration)
            await onStatusUpdate("Iteration \(iteration)")

            // Budget awareness — inject every 10 iterations and at the 5-remaining mark
            if iteration > 1 && iteration % 10 == 0 {
                let remaining = maxIterations - iteration
                await onStatusUpdate("Budget: \(remaining) of \(maxIterations) iterations remaining")
                messages.append(
                    ChatMessage(
                        role: "system",
                        content:
                            "[Budget: \(remaining)/\(maxIterations) iterations remaining. Prioritize completing the core task. Use create_issue for non-essential follow-up work.]"
                    )
                )
            }

            if iteration == maxIterations - 5 {
                await onStatusUpdate("Warning: 5 iterations remaining")
                messages.append(
                    ChatMessage(
                        role: "system",
                        content:
                            "[WARNING: 5 iterations remaining. Finish current work and call complete_task with a summary. Create issues for anything unfinished.]"
                    )
                )
            }

            // Trim messages to fit context budget (no-op if within budget or no limit known)
            let effectiveMessages: [ChatMessage]
            if let manager = budgetManager {
                effectiveMessages = manager.trimMessages(messages)
            } else {
                effectiveMessages = messages
            }

            // Build full messages with system prompt
            let fullMessages = [ChatMessage(role: "system", content: systemPrompt)] + effectiveMessages

            // Create request with all available tools - model picks which to use
            let request = ChatCompletionRequest(
                model: model ?? "default",
                messages: fullMessages,
                temperature: temperature ?? 0.3,
                max_tokens: maxTokens ?? 4096,
                stream: nil,
                top_p: topPOverride,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: tools.isEmpty ? nil : tools,
                tool_choice: nil,
                session_id: nil
            )

            // Stream response
            var responseContent = ""
            var toolInvoked: ServiceToolInvocation?

            do {
                let stream = try await chatEngine.streamChat(request: request)
                for try await delta in stream {
                    if let toolName = StreamingToolHint.decode(delta) {
                        await onToolHint(toolName)
                        continue
                    }
                    responseContent += delta
                    await onDelta(delta, iteration)
                }
            } catch let invocation as ServiceToolInvocation {
                toolInvoked = invocation
            } catch is CancellationError {
                return .interrupted(
                    messages: messages,
                    iteration: iteration,
                    totalToolCalls: totalToolCalls
                )
            }

            lastResponseContent = responseContent

            // Estimate token consumption for this iteration
            // Rough estimate: ~4 characters per token (varies by model/tokenizer)
            let inputChars = fullMessages.reduce(0) { $0 + ($1.content?.count ?? 0) } + systemPrompt.count
            let outputChars = responseContent.count + (toolInvoked?.jsonArguments.count ?? 0)
            let estimatedInputTokens = max(1, inputChars / 4)
            let estimatedOutputTokens = max(1, outputChars / 4)
            await onTokensConsumed(estimatedInputTokens, estimatedOutputTokens)

            // If pure text response (no tool call), keep nudging tool-capable progress.
            if toolInvoked == nil {
                messages.append(ChatMessage(role: "assistant", content: responseContent))

                // Track consecutive text-only responses to detect models that can't use tools
                consecutiveTextOnly += 1
                if consecutiveTextOnly >= Self.maxConsecutiveTextOnlyResponses {
                    print(
                        "[WorkExecutionEngine] \(consecutiveTextOnly) consecutive text-only responses"
                            + " — aborting to prevent infinite loop"
                    )
                    let summary = extractCompletionSummary(from: responseContent)
                    let fallback =
                        summary.isEmpty
                        ? String(responseContent.prefix(500))
                        : summary
                    return .completed(summary: fallback, artifact: nil)
                }

                // Model is reasoning but hasn't called a tool yet - prompt to continue
                // This helps models that reason out loud before acting
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "Continue with the next action. Use the available tools to do the work, verify the result, and call complete_task only after verification."
                    )
                )
                continue
            }

            // Model successfully called a tool - reset consecutive text-only counter
            consecutiveTextOnly = 0

            // Tool call - execute it
            let invocation = toolInvoked!
            totalToolCalls += 1
            if !toolsUsed.contains(invocation.toolName) {
                toolsUsed.append(invocation.toolName)
            }

            // Check for meta-tool signals before execution
            switch invocation.toolName {
            case "complete_task":
                // Parse the complete_task arguments to get summary and artifact
                let (summary, artifact) = parseCompleteTaskArgs(invocation.jsonArguments, taskId: issue.taskId)
                return .completed(summary: summary, artifact: artifact)

            case "request_clarification":
                // Parse clarification request
                let clarification = parseClarificationArgs(invocation.jsonArguments)
                return .needsClarification(
                    clarification,
                    messages: messages,
                    iteration: iteration,
                    totalToolCalls: totalToolCalls
                )

            default:
                break
            }

            // Execute the tool
            let result = try await executeToolCall(invocation, overrides: toolOverrides, issueId: issue.id)

            // Process share_artifact before storing the result so the enriched
            // metadata (host_path, file_size, etc.) flows into the transcript.
            var toolResultForDisplay = result.result
            var sharedArtifact: SharedArtifact?
            if invocation.toolName == "share_artifact" {
                if let processed = SharedArtifact.processToolResult(
                    result.result,
                    contextId: issue.taskId,
                    contextType: .work,
                    executionMode: executionMode,
                    sandboxAgentName: sandboxAgentName
                ) {
                    toolResultForDisplay = processed.enrichedToolResult
                    sharedArtifact = processed.artifact
                }
            }

            let truncatedResult = truncateToolResult(toolResultForDisplay)
            await onToolCall(invocation.toolName, invocation.jsonArguments, toolResultForDisplay)

            // Clean response content - strip any leaked function-call JSON patterns
            let cleanedContent = StringCleaning.stripFunctionCallLeakage(responseContent, toolName: invocation.toolName)

            // Append tool call + result to conversation
            if cleanedContent.isEmpty {
                messages.append(
                    ChatMessage(role: "assistant", content: nil, tool_calls: [result.toolCall], tool_call_id: nil)
                )
            } else {
                messages.append(
                    ChatMessage(
                        role: "assistant",
                        content: cleanedContent,
                        tool_calls: [result.toolCall],
                        tool_call_id: nil
                    )
                )
            }
            messages.append(
                ChatMessage(
                    role: "tool",
                    content: truncatedResult,
                    tool_calls: nil,
                    tool_call_id: result.toolCall.id
                )
            )

            // Log the tool call event
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .toolCallCompleted,
                    payload: EventPayload.ToolCallCompleted(
                        toolName: invocation.toolName,
                        iteration: iteration,
                        arguments: invocation.jsonArguments,
                        result: result.result,
                        success: !result.result.hasPrefix("[REJECTED]")
                    )
                )
            )

            // Handle semi-meta-tools (execute but also process results)
            switch invocation.toolName {
            case "create_issue":
                await onStatusUpdate("Created follow-up issue")

            case "share_artifact":
                if let artifact = sharedArtifact {
                    await onArtifact(artifact)
                    await onStatusUpdate("Shared artifact: \(artifact.filename)")
                }

            default:
                break
            }
        }

        // Hit iteration limit
        return .iterationLimitReached(
            messages: messages,
            totalIterations: iteration,
            totalToolCalls: totalToolCalls,
            lastResponseContent: lastResponseContent
        )
    }

    /// Builds the work system prompt for reasoning loop execution
    /// - Parameters:
    ///   - base: Base system prompt (agent instructions, etc.)
    ///   - issue: The issue being executed
    ///   - executionMode: Resolved work execution mode
    ///   - skillInstructions: Optional skill-specific instructions
    /// - Returns: Complete system prompt for work mode
    static func buildAgentSystemPrompt(
        base: String,
        issue: Issue,
        executionMode: WorkExecutionMode,
        skillInstructions: String? = nil
    ) -> String {
        var prompt = base

        prompt += """


            # Work Mode

            You are executing a task for the user. Your goal:

            **\(issue.title)**
            \(issue.description ?? "")

            ## How to Work

            - You have tools available. Use them to accomplish the goal.
            - Work step by step. After each tool call, assess what you learned and decide the next action.
            - You do NOT need to plan everything upfront. Explore, read, understand, then act.
            - If you discover additional work needed, use `create_issue` to track it.
            - Use `complete_task` as the normal way to finish work once the task is actually verified.
            - If the task is ambiguous and you cannot make a reasonable assumption, use `request_clarification`.

            ## Important Guidelines

            - Always read/explore before modifying. Don't guess at file contents or project structure.
            - For coding tasks: install missing dependencies, write code efficiently, then verify it works.
            - Prefer bulk file generation or editing approaches over many tiny write calls when the tools support it.
            - After failed tests/builds, inspect the error output, fix the cause, and rerun verification.
            - If something fails, analyze the error and try a different approach. Don't repeat the same action.
            - Keep the user's original request in mind at all times. Every action should serve the goal.
            - When creating follow-up issues, write detailed descriptions with full context about what you learned.

            ## Communication Style

            - Before calling tools, briefly explain what you are about to do and why.
            - After receiving tool results, summarize what you learned before proceeding.
            - Use concise natural language (not code or JSON) when explaining your actions.
            - The user sees your text responses in real time, so keep them informed of progress.

            ## Sharing Output

            **Always call `share_artifact` for every output file or directory the user should see** — images, charts, generated code, websites, reports, audio, etc. The user cannot see files you create unless you explicitly share them. Call `share_artifact` with the file's relative path before calling `complete_task`.

            ## Completion

            When the goal is fully achieved:
            1. First, call `share_artifact` for any generated files or content the user needs.
            2. Then call `complete_task` with a summary and `success: true`.

            Do NOT call complete_task until you have actually done the work, verified it, and shared any output files.

            """

        switch executionMode {
        case .hostFolder(let folderContext):
            prompt += buildFolderContextSection(from: folderContext)
        case .sandbox:
            prompt += sandboxPromptSection()
        case .none:
            break
        }

        // Add skill instructions if available
        if let skills = skillInstructions, !skills.isEmpty {
            prompt += "\n## Active Skills\n\(skills)\n"
        }

        return prompt
    }

    /// Extracts a completion summary from a text response
    private func extractCompletionSummary(from content: String) -> String {
        // Try to find a summary section
        let lines = content.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        var inSummary = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().contains("SUMMARY") || trimmed.uppercased().contains("COMPLETED") {
                inSummary = true
            }
            if inSummary && !trimmed.isEmpty {
                summaryLines.append(trimmed)
            }
        }

        if summaryLines.isEmpty {
            // Just use the whole content, truncated
            return String(content.prefix(500))
        }
        return summaryLines.joined(separator: "\n")
    }

    /// Parses complete_task tool arguments
    private func parseCompleteTaskArgs(_ jsonArgs: String, taskId: String) -> (String, SharedArtifact?) {
        struct CompleteTaskArgs: Decodable {
            let summary: String
            let success: Bool?
            let artifact: String?
            let remaining_work: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(CompleteTaskArgs.self, from: data)
        else {
            return ("Task completed", nil)
        }

        var artifact: SharedArtifact? = nil
        if let rawContent = args.artifact, !rawContent.isEmpty {
            let content =
                rawContent
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")

            let contextDir = OsaurusPaths.contextArtifactsDir(contextId: taskId)
            OsaurusPaths.ensureExistsSilent(contextDir)
            let destPath = contextDir.appendingPathComponent("result.md")
            try? content.write(to: destPath, atomically: true, encoding: .utf8)

            artifact = SharedArtifact(
                contextId: taskId,
                contextType: .work,
                filename: "result.md",
                mimeType: "text/markdown",
                fileSize: content.utf8.count,
                hostPath: destPath.path,
                content: content,
                isFinalResult: true
            )
            if let artifact { _ = try? IssueStore.createSharedArtifact(artifact) }
        }

        var summary = args.summary
        if args.success == false, let remaining = args.remaining_work, !remaining.isEmpty {
            summary += "\nRemaining work: \(remaining)"
        }

        return (summary, artifact)
    }

    /// Parses request_clarification tool arguments
    private func parseClarificationArgs(_ jsonArgs: String) -> ClarificationRequest {
        struct ClarificationArgs: Decodable {
            let question: String
            let options: [String]?
            let context: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(ClarificationArgs.self, from: data)
        else {
            return ClarificationRequest(question: "Could you please clarify your request?")
        }

        return ClarificationRequest(
            question: args.question,
            options: args.options,
            context: args.context
        )
    }

}

// MARK: - Supporting Types

/// Result of a tool call
public struct ToolCallResult: Sendable {
    public let toolCall: ToolCall
    public let result: String
}

// MARK: - Errors

/// Errors that can occur during work execution
public enum WorkExecutionError: Error, LocalizedError {
    case executionCancelled
    case iterationLimitReached(Int)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case toolExecutionFailed(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .executionCancelled:
            return "Execution was cancelled"
        case .iterationLimitReached(let count):
            return "Iteration limit reached after \(count) iterations"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .toolExecutionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .unknown(let reason):
            return "Unknown error: \(reason)"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .networkError, .rateLimited:
            return true
        case .toolExecutionFailed:
            return true
        case .executionCancelled, .iterationLimitReached:
            return false
        case .unknown:
            return true
        }
    }
}
