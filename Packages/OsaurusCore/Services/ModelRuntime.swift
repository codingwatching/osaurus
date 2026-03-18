//
//  ModelRuntime.swift
//  osaurus
//
//  Holds MLX runtime state (containers, gates, caches) behind an actor.
//

import CoreImage
import CryptoKit
import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM

// Force MLXVLM to be linked by referencing VLMModelFactory
// This ensures VLM models can be loaded via the ModelFactoryRegistry
private let _vlmFactory = MLXVLM.VLMModelFactory.shared

actor ModelRuntime {
    // MARK: - Types

    struct ModelCacheSummary: Sendable {
        let name: String
        let bytes: Int64
        let isCurrent: Bool
    }

    private final class SessionHolder: NSObject, @unchecked Sendable {
        let name: String
        let container: ModelContainer
        let weightsSizeBytes: Int64
        init(name: String, container: ModelContainer, weightsSizeBytes: Int64) {
            self.name = name
            self.container = container
            self.weightsSizeBytes = weightsSizeBytes
        }
    }

    // MARK: - Singleton

    static let shared = ModelRuntime()

    // MARK: - State

    private var modelCache: [String: SessionHolder] = [:]
    private var loadingTasks: [String: Task<SessionHolder, Error>] = [:]
    private var currentModelName: String?
    private var kvCacheStore = KVCacheStore()
    private var cachedConfig: RuntimeConfig?

    private init() {}

    // MARK: - Public API

    func cachedModelSummaries() -> [ModelCacheSummary] {
        return modelCache.values.map { holder in
            ModelCacheSummary(
                name: holder.name,
                bytes: holder.weightsSizeBytes,
                isCurrent: holder.name == currentModelName
            )
        }.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name < rhs.name
        }
    }

    // MARK: - Model lifecycle

    func unload(name: String) {
        kvCacheStore.invalidateModel(name)

        autoreleasepool {
            _ = modelCache.removeValue(forKey: name)
        }
        loadingTasks[name]?.cancel()
        loadingTasks.removeValue(forKey: name)
        if currentModelName == name { currentModelName = nil }

        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    /// Unloads any loaded model not referenced by an active window.
    func unloadModelsNotIn(_ activeNames: Set<String>) {
        for name in modelCache.keys where !activeNames.contains(name) {
            print("[ModelRuntime] GC: Unloading unused model \(name)")
            unload(name: name)
        }
    }

    func clearAll() {
        kvCacheStore.clearAll()

        autoreleasepool {
            modelCache.removeAll()
        }
        for task in loadingTasks.values { task.cancel() }
        loadingTasks.removeAll()
        currentModelName = nil
        cachedConfig = nil

        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    /// Invalidates the cached RuntimeConfig so the next request reads fresh values.
    func invalidateConfig() {
        cachedConfig = nil
    }

    /// Pre-warms a session's KV cache by loading it from SSD into RAM.
    func prewarmSession(sessionId: String, modelName: String) {
        let budget = currentKVBudget()
        kvCacheStore.prewarm(sessionId: sessionId, modelName: modelName, budgetBytes: budget)
    }

    /// Invalidates the KV cache for a specific session (e.g., on session delete).
    func invalidateSession(_ sessionId: String) {
        kvCacheStore.invalidate(sessionId: sessionId)
    }

    // MARK: - Warm-up

    func warmUp(modelId: String, modelName: String, prefillChars: Int = 0, maxTokens: Int = 1) async {
        guard !Task.isCancelled else { return }
        let content = String(repeating: "A", count: prefillChars > 0 ? max(1, prefillChars) : 1024)
        do {
            let stream = try await deltasStream(
                messages: [Message(role: .user, content: content)],
                modelId: modelId,
                modelName: modelName,
                temperature: 0.0,
                maxTokens: maxTokens,
                stopSequences: [],
                tools: nil,
                toolChoice: nil
            )
            for await _ in stream where !Task.isCancelled {}
        } catch {}
    }

    /// Precomputes the prefix KV cache using current UI context (memory, agent
    /// prompt, tools) so that new conversations start with a warm cache.
    func precomputeUIPrefix(modelId: String, modelName: String, agentId: UUID) async {
        guard !Task.isCancelled else { return }
        guard let holder = try? await loadContainer(id: modelId, name: modelName) else { return }
        await precomputePrefixCache(holder: holder, agentId: agentId)
    }

    func deltasStream(
        messages: [Message],
        modelId: String,
        modelName: String,
        temperature: Float,
        maxTokens: Int,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) async throws -> AsyncStream<String> {
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: nil,
            repetitionPenalty: nil
        )
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let producerTask = Task {
            do {
                let events = try await generateEventStream(
                    chatBuilder: { ModelRuntime.mapMessagesToMLX(messages) },
                    parameters: params,
                    stopSequences: stopSequences,
                    tools: tools,
                    toolChoice: toolChoice,
                    modelId: modelId,
                    modelName: modelName
                )
                for try await ev in events {
                    if Task.isCancelled {
                        break
                    }
                    if case .tokens(let s) = ev, !s.isEmpty {
                        continuation.yield(s)
                    } else {
                        break
                    }
                }
            } catch {
                // ignore errors; best-effort warm-up / streaming
            }
            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - Internals

    private func getConfig() async -> RuntimeConfig {
        if let cached = cachedConfig { return cached }
        let cfg = await RuntimeConfig.snapshot()
        cachedConfig = cfg
        return cfg
    }

    private func currentKVBudget() -> Int {
        let modelBytes = modelCache.values.reduce(Int64(0)) { $0 + $1.weightsSizeBytes }
        return KVCacheStore.computeBudget(modelWeightsBytes: modelBytes)
    }

    private func loadContainer(id: String, name: String) async throws -> SessionHolder {
        if let existing = modelCache[name] { return existing }

        let policy = await ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel

        if policy == .strictSingleModel {
            let otherModels = modelCache.keys.filter { $0 != name }
            for other in otherModels {
                print("[ModelRuntime] Enforcing strict policy: Unloading \(other)")
                unload(name: other)
            }

            let otherTasks = loadingTasks.keys.filter { $0 != name }
            for other in otherTasks {
                print("[ModelRuntime] Cancelling pending load for \(other)")
                loadingTasks[other]?.cancel()
                loadingTasks.removeValue(forKey: other)
            }
        } else {
            if !modelCache.isEmpty {
                print("[ModelRuntime] Loading \(name) alongside existing models (Flexible Policy)")
            }
        }

        if let existingTask = loadingTasks[name] {
            return try await existingTask.value
        }

        guard let localURL = Self.findLocalDirectory(forModelId: id) else {
            throw NSError(
                domain: "ModelRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not downloaded: \(name)"]
            )
        }

        let task = Task<SessionHolder, Error> {
            let isVLM = ModelManager.isVisionModel(at: localURL)
            let container: ModelContainer

            if isVLM {
                let configuration = ModelConfiguration(directory: localURL)
                container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
            } else {
                container = try await loadModelContainer(directory: localURL)
            }

            let weightsBytes = Self.computeWeightsSizeBytes(at: localURL)
            return SessionHolder(name: name, container: container, weightsSizeBytes: weightsBytes)
        }

        loadingTasks[name] = task

        do {
            let holder = try await task.value
            modelCache[name] = holder
            loadingTasks[name] = nil
            currentModelName = name

            // Set memory limits based on model size
            let budget = KVCacheStore.computeBudget(modelWeightsBytes: holder.weightsSizeBytes)
            Memory.cacheLimit = budget

            return holder
        } catch {
            loadingTasks[name] = nil
            throw error
        }
    }

    /// Builds a prefix KV cache from the full context (memory + system prompt +
    /// tools) and stores it keyed by a content hash so that UI and API requests
    /// with the same context get a warm start on new conversations.
    private func precomputePrefixCache(holder: SessionHolder, agentId: UUID) async {
        let modelName = holder.name

        do {
            let (systemBase, memCfg, toolSpecs) = await MainActor.run {
                let sys = SystemPromptBuilder.effectiveBasePrompt(
                    AgentManager.shared.effectiveSystemPrompt(for: agentId)
                )
                let cfg = MemoryConfigurationStore.load()
                let specs = ToolRegistry.shared.chatSpecs(withOverrides: nil, mode: .none)
                return (sys, cfg, specs)
            }

            let memCtx = await MemoryContextAssembler.assembleContext(
                agentId: agentId.uuidString,
                config: memCfg
            )

            let systemContent = SystemPromptBuilder.prependMemoryContext(memCtx, to: systemBase)
            let toolNames = toolSpecs.map { $0.function.name }
            let tokenizerTools = Self.makeTokenizerTools(tools: toolSpecs, toolChoice: .auto)

            let hash = Self.computePrefixHash(systemContent: systemContent, toolNames: toolNames)
            guard !kvCacheStore.hasPrefixCache(modelName: modelName, hash: hash) else { return }

            let runtimeCfg = await getConfig()
            let messages: [MLXLMCommon.Chat.Message] = [
                .init(role: .system, content: systemContent, images: [], videos: []),
                .init(role: .user, content: "Hi", images: [], videos: []),
            ]

            let params = GenerationParameters(temperature: 0.0, maxTokens: 1)

            let (_, cache) = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: { messages },
                buildToolsSpec: { tokenizerTools },
                generation: params,
                runtime: runtimeCfg,
                existingCache: nil
            )

            kvCacheStore.putPrefixCache(cache, modelName: modelName, hash: hash)
            print("[ModelRuntime] Prefix cached for \(modelName) (hash: \(hash.prefix(8)))")
        } catch {
            print("[ModelRuntime] Failed to pre-compute prefix cache: \(error)")
        }
    }

    // MARK: - Driver helpers (actor-isolated)

    private func generateEventStream(
        chatBuilder: @Sendable () -> [MLXLMCommon.Chat.Message],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let cfg = await getConfig()
        let holder = try await loadContainer(id: modelId, name: modelName)

        // Compute a content hash from the generation inputs for prefix cache lookup.
        // An explicit cache_hint from the API overrides the computed hash.
        let sessionId = parameters.sessionId
        let chatMessages = chatBuilder()
        let toolNames = (tools ?? []).map { $0.function.name }
        let prefixHash =
            parameters.cacheHint
            ?? Self.computePrefixHash(
                systemContent: chatMessages.first(where: { $0.role == .system })?.content ?? "",
                toolNames: toolNames
            )

        // Look up existing KV cache for this session, or fall back to a
        // hash-keyed prefix cache for a warm start on new conversations.
        // nonisolated(unsafe) suppresses the Sendable check for [any KVCache] which
        // doesn't conform to Sendable but is safe here because access is serialized
        // through the ModelRuntime actor and ModelContainer.perform.
        nonisolated(unsafe) let existingCache: [any KVCache]? = {
            if let sid = sessionId {
                if let sessionCache = kvCacheStore.getCache(sessionId: sid, modelName: modelName) {
                    return sessionCache
                }
            }
            return kvCacheStore.getPrefixCache(modelName: modelName, hash: prefixHash)
        }()

        let capturedMessages = chatMessages
        let (rawStream, cache) = try await MLXGenerationEngine.prepareAndGenerate(
            container: holder.container,
            buildChat: { capturedMessages },
            buildToolsSpec: { ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice) },
            generation: parameters,
            runtime: cfg,
            existingCache: existingCache
        )

        // Always store the cache so subsequent turns get a hot hit.
        // Note: we don't saveToDisk here because the stream hasn't been consumed yet
        // (tokens are generated lazily). The SSD copy would only contain the prefill.
        // The cache will be persisted to SSD when evictToSSD runs during ensureBudget.
        if let sid = sessionId {
            kvCacheStore.putCache(sessionId: sid, cache: cache, modelName: modelName)
            let budget = currentKVBudget()
            kvCacheStore.ensureBudget(budget)
        }

        return StreamAccumulator.accumulate(events: rawStream, stopSequences: stopSequences, tools: tools)
    }

    // MARK: - New message-based (OpenAI ChatMessage) APIs

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> String {
        var accumulated = ""
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(messages) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        for try await ev in events {
            switch ev {
            case .tokens(let s):
                accumulated += s
            case .toolInvocation(let name, let argsJSON):
                throw ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
            }
        }
        return accumulated
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(messages) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producerTask = Task {
            do {
                for try await ev in events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch ev {
                    case .tokens(let s):
                        if !s.isEmpty { continuation.yield(s) }
                    case .toolInvocation(let name, let argsJSON):
                        continuation.yield(StreamingToolHint.encode(name))
                        continuation.finish(
                            throwing: ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
                        )
                        return
                    }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - Static helpers (nonisolated)

    nonisolated static func computePrefixHash(
        systemContent: String,
        toolNames: [String]
    ) -> String {
        let tools = toolNames.sorted().joined(separator: "\0")
        let combined = systemContent + "\0" + tools
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func makeGenerateParameters(
        temperature: Float,
        maxTokens: Int,
        topP: Float,
        repetitionPenalty: Float?,
        kvBits: Int?,
        kvGroup: Int,
        quantStart: Int,
        maxKV: Int?,
        prefillStep: Int
    ) -> MLXLMCommon.GenerateParameters {
        var p = MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: maxKV,
            kvBits: kvBits,
            kvGroupSize: kvGroup,
            quantizedKVStart: quantStart,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 20
        )
        p.prefillStepSize = prefillStep
        return p
    }

    nonisolated static func mapMessagesToMLX(_ messages: [Message]) -> [MLXLMCommon.Chat.Message] {
        return messages.map { m in
            let role: MLXLMCommon.Chat.Message.Role = {
                switch m.role {
                case .system: return .system
                case .user: return .user
                case .assistant: return .assistant
                case .tool: return .tool
                }
            }()
            return MLXLMCommon.Chat.Message(role: role, content: m.content, images: [], videos: [])
        }
    }

    nonisolated static func makeTokenizerTools(
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) -> [[String: any Sendable]]? {
        guard let tools, !tools.isEmpty else { return nil }
        if let toolChoice {
            switch toolChoice {
            case .none:
                return nil
            case .auto:
                return tools.map { $0.toTokenizerToolSpec() }
            case .function(let target):
                let name = target.function.name
                let filtered = tools.filter { $0.function.name == name }
                return filtered.isEmpty ? nil : filtered.map { $0.toTokenizerToolSpec() }
            }
        } else {
            return tools.map { $0.toTokenizerToolSpec() }
        }
    }

    nonisolated static func mapOpenAIChatToMLX(
        _ msgs: [ChatMessage]
    ) -> [MLXLMCommon.Chat.Message] {
        var toolIdToName: [String: String] = [:]
        for m in msgs where m.role == "assistant" {
            if let calls = m.tool_calls {
                for call in calls { toolIdToName[call.id] = call.function.name }
            }
        }

        var out: [MLXLMCommon.Chat.Message] = []
        out.reserveCapacity(max(6, msgs.count))
        for m in msgs {
            let images = extractImageSources(from: m)

            switch m.role {
            case "system":
                out.append(
                    MLXLMCommon.Chat.Message(role: .system, content: m.content ?? "", images: images, videos: [])
                )
            case "user":
                out.append(
                    MLXLMCommon.Chat.Message(role: .user, content: m.content ?? "", images: images, videos: [])
                )
            case "assistant":
                if let calls = m.tool_calls, !calls.isEmpty, m.content == nil || m.content?.isEmpty == true {
                    break
                } else {
                    out.append(
                        MLXLMCommon.Chat.Message(
                            role: .assistant,
                            content: m.content ?? "",
                            images: images,
                            videos: []
                        )
                    )
                }
            case "tool":
                out.append(
                    MLXLMCommon.Chat.Message(role: .tool, content: m.content ?? "", images: images, videos: [])
                )
            default:
                out.append(
                    MLXLMCommon.Chat.Message(role: .user, content: m.content ?? "", images: images, videos: [])
                )
            }
        }
        return out
    }

    nonisolated private static func extractImageSources(
        from message: ChatMessage
    ) -> [MLXLMCommon.UserInput.Image] {
        let imageUrls = message.imageUrls
        guard !imageUrls.isEmpty else { return [] }

        var sources: [MLXLMCommon.UserInput.Image] = []
        for urlString in imageUrls {
            if urlString.hasPrefix("data:image/") {
                if let commaIndex = urlString.firstIndex(of: ",") {
                    let base64String = String(urlString[urlString.index(after: commaIndex)...])
                    if let imageData = Data(base64Encoded: base64String),
                        let ciImage = CIImage(data: imageData)
                    {
                        sources.append(.ciImage(ciImage))
                    }
                }
            } else if let url = URL(string: urlString) {
                sources.append(.url(url))
            }
        }
        return sources
    }

    private static func computeWeightsSizeBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "safetensors" {
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                    let size = attrs[.size] as? NSNumber
                {
                    total += size.int64Value
                }
            }
        }
        return total
    }

    private static func findLocalDirectory(forModelId id: String) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
        if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
            hasConfig && items.contains(where: { $0.pathExtension == "safetensors" })
        {
            return url
        }
        return nil
    }
}
