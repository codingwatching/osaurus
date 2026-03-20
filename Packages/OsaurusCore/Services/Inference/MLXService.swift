//
//  MLXService.swift
//  osaurus
//
//  Migrated to Swift 6 actors; delegates runtime state to ModelManager/ModelRuntime.
//

import Combine
import Foundation

/// Lightweight reference to a local MLX model (name + repo id)
private struct LocalModelRef {
    let name: String
    let modelId: String
}

actor MLXService: ToolCapableService {

    /// Shared instance for convenience (actor is stateless, delegates to ModelRuntime.shared)
    static let shared = MLXService()

    nonisolated var id: String { "mlx" }

    // MARK: - Availability / Routing

    nonisolated func isAvailable() -> Bool {
        return !Self.getAvailableModels().isEmpty
    }

    nonisolated func handles(requestedModel: String?) -> Bool {
        let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Self.findModel(named: trimmed) != nil
    }

    // MARK: - Static discovery wrappers (delegate to ModelManager)

    nonisolated static func getAvailableModels() -> [String] {
        return ModelManager.installedModelNames()
    }

    fileprivate nonisolated static func findModel(named name: String) -> LocalModelRef? {
        if let found = ModelManager.findInstalledModel(named: name) {
            return LocalModelRef(name: found.name, modelId: found.id)
        }
        return nil
    }

    // MARK: - Warm-up

    func warmUp(modelName: String? = nil, agentId: UUID? = nil, prefillChars: Int = 0, maxTokens: Int = 1) async {
        let chosen: LocalModelRef? = {
            if let name = modelName {
                return Self.findModel(named: name)
            }
            if let first = Self.getAvailableModels().first, let m = Self.findModel(named: first) {
                return m
            }
            return nil
        }()
        guard let model = chosen else { return }

        // Model warm-up is tool-agnostic -- always run immediately.
        await ModelRuntime.shared.warmUp(
            modelId: model.modelId,
            modelName: model.name,
            prefillChars: prefillChars,
            maxTokens: maxTokens
        )
        guard !Task.isCancelled else { return }

        // Prefix cache depends on the correct tool set. If sandbox is
        // mid-launch, wait for it so the hash includes sandbox tools.
        let effectiveAgentId = agentId ?? Agent.defaultId
        let sandboxEnabled = await MainActor.run {
            AgentManager.shared.effectiveAutonomousExec(for: effectiveAgentId)?.enabled == true
        }
        if sandboxEnabled {
            let status = await MainActor.run { SandboxManager.State.shared.status }
            if status == .starting {
                await Self.awaitSandboxReady(timeout: 60)
            }
        }
        guard !Task.isCancelled else { return }

        await ModelRuntime.shared.precomputeUIPrefix(
            modelId: model.modelId,
            modelName: model.name,
            agentId: effectiveAgentId
        )
    }

    /// Waits until sandbox leaves the `.starting` state or the timeout elapses.
    private static func awaitSandboxReady(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                var resumed = false
                var cancellable: AnyCancellable?
                var timeoutItem: DispatchWorkItem?

                let finish: @MainActor () -> Void = {
                    guard !resumed else { return }
                    resumed = true
                    cancellable?.cancel()
                    timeoutItem?.cancel()
                    continuation.resume()
                }

                cancellable = SandboxManager.State.shared.$status
                    .dropFirst()
                    .filter { $0 != .starting }
                    .first()
                    .sink { _ in finish() }

                let item = DispatchWorkItem { finish() }
                timeoutItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)

                if SandboxManager.State.shared.status != .starting {
                    finish()
                }
            }
        }
    }

    // MARK: - ModelService

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = try selectModel(requestedName: requestedModel)
        return try await ModelRuntime.shared.streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: [],
            toolChoice: nil,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: []
        )
        var out = ""
        for try await s in stream { out += s }
        return out
    }

    // MARK: - Message-based Tool-capable bridge

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        let model = try selectModel(requestedName: requestedModel)
        return try await ModelRuntime.shared.respondWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = try selectModel(requestedName: requestedModel)
        return try await ModelRuntime.shared.streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    // MARK: - Runtime cache management

    func cachedRuntimeSummaries() async -> [ModelRuntime.ModelCacheSummary] {
        await ModelRuntime.shared.cachedModelSummaries()
    }

    func unloadRuntimeModel(named name: String) async {
        await ModelRuntime.shared.unload(name: name)
    }

    func clearRuntimeCache() async {
        await ModelRuntime.shared.clearAll()
    }

    // MARK: - Helpers

    private func selectModel(requestedName: String?) throws -> LocalModelRef {
        let trimmed = (requestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "MLXService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Requested model is required"]
            )
        }
        if let m = Self.findModel(named: trimmed) { return m }
        throw NSError(
            domain: "MLXService",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Requested model not found: \(trimmed)"]
        )
    }
}
