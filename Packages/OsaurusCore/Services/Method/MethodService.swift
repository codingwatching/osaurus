//
//  MethodService.swift
//  osaurus
//
//  Orchestrator for the methods subsystem: CRUD, scoring, distillation.
//  Routes LLM calls through ModelServiceRouter — never blocks chat.
//

import Foundation
import os

// MARK: - Errors

enum MethodServiceError: Error, LocalizedError, Equatable {
    case coreModelUnavailable(String)
    case circuitBreakerOpen
    case modelCallTimedOut
    case invalidYAML(String)
    case methodNotFound(String)

    var errorDescription: String? {
        switch self {
        case .coreModelUnavailable(let m): return "Core model unavailable: \(m)"
        case .circuitBreakerOpen: return "Method service circuit breaker is open"
        case .modelCallTimedOut: return "Core model call timed out"
        case .invalidYAML(let msg): return "Invalid method YAML: \(msg)"
        case .methodNotFound(let id): return "Method not found: \(id)"
        }
    }
}

// MARK: - MethodService

public actor MethodService {
    public static let shared = MethodService()

    private let db = MethodDatabase.shared

    private init() {}

    // MARK: - CRUD

    public func create(
        name: String,
        description: String,
        triggerText: String? = nil,
        body: String,
        source: MethodSource,
        sourceModel: String? = nil
    ) async throws -> Method {
        let toolsUsed = extractToolIds(from: body)
        let skillsUsed = extractSkillIds(from: body)
        let tokenCount = max(1, body.count / 4)

        let method = Method(
            name: name,
            description: description,
            triggerText: triggerText,
            body: body,
            source: source,
            sourceModel: sourceModel,
            toolsUsed: toolsUsed,
            skillsUsed: skillsUsed,
            tokenCount: tokenCount
        )

        try db.insertMethod(method)
        await MethodSearchService.shared.indexMethod(method)

        MethodLogger.service.info("Created method '\(name)' (id: \(method.id), tools: \(toolsUsed.count))")
        return method
    }

    public func update(_ method: Method) async throws {
        try db.updateMethod(method)
        await MethodSearchService.shared.indexMethod(method)
        MethodLogger.service.info("Updated method '\(method.name)' to v\(method.version)")
    }

    public func delete(id: String) async throws {
        try db.deleteMethod(id: id)
        await MethodSearchService.shared.removeMethod(id: id)
        MethodLogger.service.info("Deleted method \(id)")
    }

    public func load(id: String) throws -> Method? {
        try db.loadMethod(id: id)
    }

    public func loadRules() throws -> [Method] {
        try db.loadMethodsByTier(.rule)
    }

    // MARK: - Scoring

    public func reportOutcome(
        methodId: String,
        outcome: MethodEventType,
        modelUsed: String? = nil,
        agentId: String? = nil
    ) throws {
        let event = MethodEvent(
            methodId: methodId,
            eventType: outcome,
            modelUsed: modelUsed,
            agentId: agentId
        )
        try db.insertEvent(event)

        var score = try db.loadScore(methodId: methodId) ?? MethodScore(methodId: methodId)

        switch outcome {
        case .loaded:
            score.timesLoaded += 1
            score.lastUsedAt = Date()
        case .succeeded:
            score.timesSucceeded += 1
            score.lastUsedAt = Date()
        case .failed:
            score.timesFailed += 1
            score.lastUsedAt = Date()
        default:
            break
        }

        score.recalculate()
        try db.upsertScore(score)
    }

    public func recalculateAllScores() throws {
        let methods = try db.loadAllMethods()
        for method in methods {
            guard var score = try db.loadScore(methodId: method.id) else { continue }
            score.recalculate()
            try db.upsertScore(score)
        }
    }

    // MARK: - Distillation

    public static let distillationPrompt = """
        You are extracting a reusable tool-call sequence from a conversation trace.

        Extract ONLY the sequence of tool calls that led to the successful outcome.
        Remove: dead ends, failed attempts, verbose reasoning, conversational text.

        For each step, record:
        - tool: which tool was called (exact tool ID)
        - action: what command or request was made
        - params: what parameters were passed (use $VARIABLES for user-specific values)
        - expect: what a successful result looks like (if deterministic)
        - on_fail: what to do if this step fails

        Also record:
        - failure_modes: problems discovered during the task
        - Any steps that required user confirmation

        The output must be valid YAML matching this structure:

        steps:
          - tool: <tool_id>
            action: <exact command or request>
            params: (if applicable)
            expect: (if applicable)
            on_fail: <what to do>

        failure_modes:
          - "<condition> → <action>"

        Here is the conversation trace:
        ---
        {trace}
        ---

        Extract the tool-call sequence:
        """

    public func distill(
        trace: String,
        name: String,
        description: String,
        triggerText: String? = nil,
        sourceModel: String? = nil,
        coreModelIdentifier: String
    ) async throws -> Method {
        let prompt = Self.distillationPrompt.replacingOccurrences(of: "{trace}", with: trace)
        let body = try await callCoreModel(prompt: prompt, coreModelIdentifier: coreModelIdentifier)

        return try await create(
            name: name,
            description: description,
            triggerText: triggerText,
            body: body,
            source: .user,
            sourceModel: sourceModel
        )
    }

    // MARK: - YAML Extraction

    func extractToolIds(from yaml: String) -> [String] {
        var tools: [String] = []
        var seen = Set<String>()
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tool:") || trimmed.hasPrefix("- tool:") {
                let value =
                    trimmed
                    .replacingOccurrences(of: "- tool:", with: "")
                    .replacingOccurrences(of: "tool:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, !seen.contains(value) {
                    tools.append(value)
                    seen.insert(value)
                }
            }
        }
        return tools
    }

    func extractSkillIds(from yaml: String) -> [String] {
        var skills: [String] = []
        var seen = Set<String>()
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("skill_context:") {
                let value =
                    trimmed
                    .replacingOccurrences(of: "skill_context:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, !seen.contains(value) {
                    skills.append(value)
                    seen.insert(value)
                }
            }
        }
        return skills
    }

    // MARK: - Core Model Routing

    private let localServices: [ModelService] = [FoundationModelService(), MLXService.shared]

    private static let maxRetries = 3
    private static let baseRetryDelay: UInt64 = 1_000_000_000
    private static let modelCallTimeout: TimeInterval = 60

    private var consecutiveFailures = 0
    private var circuitOpenUntil: Date?
    private static let circuitBreakerThreshold = 5
    private static let circuitBreakerCooldown: TimeInterval = 60

    func callCoreModel(
        prompt: String,
        systemPrompt: String? = nil,
        coreModelIdentifier: String
    ) async throws -> String {
        if let openUntil = circuitOpenUntil, Date() < openUntil {
            throw MethodServiceError.circuitBreakerOpen
        }

        let messages: [ChatMessage] =
            if let systemPrompt {
                [ChatMessage(role: "system", content: systemPrompt), ChatMessage(role: "user", content: prompt)]
            } else {
                [ChatMessage(role: "user", content: prompt)]
            }
        let params = GenerationParameters(temperature: 0.3, maxTokens: 2048)

        var lastError: Error?
        for attempt in 0 ..< Self.maxRetries {
            do {
                let result = try await withModelTimeout {
                    try await self.executeModelCall(
                        model: coreModelIdentifier,
                        messages: messages,
                        params: params
                    )
                }
                consecutiveFailures = 0
                circuitOpenUntil = nil
                return result
            } catch {
                lastError = error
                let isRetryable =
                    !(error is MethodServiceError) || error as? MethodServiceError == .modelCallTimedOut
                if !isRetryable || attempt == Self.maxRetries - 1 { break }
                let delay = Self.baseRetryDelay * UInt64(1 << attempt)
                MethodLogger.service.warning(
                    "Core model call failed (attempt \(attempt + 1)/\(Self.maxRetries)), retrying in \(1 << attempt)s: \(error)"
                )
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        consecutiveFailures += 1
        if consecutiveFailures >= Self.circuitBreakerThreshold {
            circuitOpenUntil = Date().addingTimeInterval(Self.circuitBreakerCooldown)
            let cooldown = Int(Self.circuitBreakerCooldown)
            MethodLogger.service.error(
                "Circuit breaker opened after \(self.consecutiveFailures) consecutive failures — cooling down for \(cooldown)s"
            )
        }

        throw lastError ?? MethodServiceError.coreModelUnavailable(coreModelIdentifier)
    }

    private func executeModelCall(
        model: String,
        messages: [ChatMessage],
        params: GenerationParameters
    ) async throws -> String {
        let remoteServices: [ModelService] = await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }

        let route = ModelServiceRouter.resolve(
            requestedModel: model,
            services: localServices,
            remoteServices: remoteServices
        )

        switch route {
        case .service(let service, let effectiveModel):
            let promptLen = messages.last?.content?.count ?? 0
            MethodLogger.service.debug(
                "Routing to \(service.id) (model: \(effectiveModel), prompt: \(promptLen) chars)"
            )
            return try await service.generateOneShot(
                messages: messages,
                parameters: params,
                requestedModel: model
            )
        case .none:
            let localIds = self.localServices.map(\.id)
            let remoteIds = remoteServices.map(\.id)
            MethodLogger.service.info(
                "No service found for model '\(model)' — local: \(localIds), remote: \(remoteIds)"
            )
            throw MethodServiceError.coreModelUnavailable(model)
        }
    }

    private func withModelTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.modelCallTimeout))
                throw MethodServiceError.modelCallTimedOut
            }
            guard let result = try await group.next() else {
                throw MethodServiceError.modelCallTimedOut
            }
            group.cancelAll()
            return result
        }
    }
}
