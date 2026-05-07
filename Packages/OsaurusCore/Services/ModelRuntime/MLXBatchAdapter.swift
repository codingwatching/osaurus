//
//  MLXBatchAdapter.swift
//  osaurus
//
//  Single MLX entry point: routes each request through `BatchEngine.generate`,
//  which emits authoritative `.chunk(String)` / `.reasoning(String)` /
//  `.toolCall(ToolCall)` / `.info(GenerateCompletionInfo)` events. Reasoning,
//  tool-call extraction, and text-level stop matching are all owned by the
//  library — osaurus passes `stopSequences` as `GenerateParameters.extraStopStrings`
//  and forwards every event through `GenerationEventMapper`.
//
//  Osaurus no longer parses tool calls, reasoning, or stop sequences at the
//  app layer — see `GenerationEventMapper` for the trivial `Generation` →
//  `ModelRuntimeEvent` bridge that replaced the old token-level
//  `StreamAccumulator` and app-side `StopSequenceBuffer`.
//
//  Cache coordinator: captured automatically by `container.makeBatchEngine`.
//  Multi-turn KV reuse, mediaSalt for VLMs, sliding-window cache support —
//  all handled inside the engine. We do not need to plumb anything cache-
//  related through this layer.
//

import CoreImage
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import MLXRandom
import MLXVLM  // MediaProcessing for image downscaling
import os.log

private let batchAdapterLog = Logger(subsystem: "ai.osaurus", category: "BatchAdapter")

struct MLXBatchAdapter {

    /// Result handed back to `ModelRuntime`. The `Generation` stream is
    /// consumed by `GenerationEventMapper`, which translates the upstream
    /// events into `ModelRuntimeEvent`. The producer task exists so callers
    /// can cancel the underlying `BatchEngine` request via Swift's standard
    /// task-cancellation mechanism.
    struct PreparedStream {
        let stream: AsyncStream<Generation>
        let promptTokens: [Int]
        let genTask: Task<Void, Never>
    }

    // MARK: - Per-model engine cache

    /// Per-process cache of `BatchEngine` instances keyed by model name.
    ///
    /// Engines are heavyweight: they hold a captured `ModelContext` and run a
    /// background scheduling task. Creating one per request would defeat the
    /// continuous-batching point — the whole reason `BatchEngine` exists is
    /// to share a single forward pass across overlapping requests, which can
    /// only happen if those requests submit into the *same* engine instance.
    actor Registry {
        static let shared = Registry()

        /// Single-flight cache for the per-model `BatchEngine` instance.
        /// Coalesces concurrent first-fetch callers onto the same
        /// creation `Task` so the registry never returns two `BatchEngine`
        /// objects bound to the same MLX `ModelContainer`. Two engines
        /// on one container would put concurrent producers on the shared
        /// GPU command queue, which surfaces as a Metal completion-queue
        /// abort. See `TaskCoalescer` for the construction-order
        /// invariant the coalescer enforces.
        private let coalescer = TaskCoalescer<BatchEngine>()

        /// Returns the cached engine for `modelName`, creating it on first
        /// use from the supplied `ModelContainer`. The container's existing
        /// cache coordinator is captured automatically by `makeBatchEngine`.
        ///
        /// `BatchEngine.maxBatchSize` is mutable at runtime as of vmlx
        /// `b9da180` via `BatchEngine.updateMaxBatchSize(_:)`. When a later
        /// request asks for a different `maxBatchSize` than the cached
        /// engine's, we hot-resize the existing engine instead of rebuilding
        /// (which would have raced in-flight callers holding the cached
        /// handle). vmlx's `updateMaxBatchSize` is fail-closed: an
        /// `engineShutdown` throw means the engine has been torn down and
        /// the next caller will create a fresh one through the coalescer.
        ///
        /// Submitting to a shut-down engine returns a `.cancelled` info
        /// event from vmlx (`b9da180`), so even if a stale handle leaks
        /// past this gate the upstream stream finishes cleanly instead of
        /// restarting GPU work.
        func engine(
            for modelName: String,
            container: ModelContainer,
            maxBatchSize: Int
        ) async -> BatchEngine {
            let engine = await makeAndRegister(
                modelName: modelName,
                maxBatchSize: maxBatchSize
            ) {
                await container.makeBatchEngine(maxBatchSize: maxBatchSize)
            }
            // `BatchEngine.maxBatchSize` is actor-isolated; the await
            // suspends the registry actor while we read it. Subsequent
            // callers see the engine in `coalescer` already and won't
            // race the read.
            let cached = await engine.maxBatchSize
            if cached != maxBatchSize {
                do {
                    try await engine.updateMaxBatchSize(maxBatchSize)
                    batchAdapterLog.info(
                        "registry: hot-resized BatchEngine for \(modelName, privacy: .public) maxBatchSize=\(cached, privacy: .public) → \(maxBatchSize, privacy: .public)"
                    )
                } catch BatchEngineConfigurationError.engineShutdown {
                    // The cached engine was torn down between calls. Leaving
                    // it in `values` would loop here forever (every future
                    // call would resize-fail-and-return the same dead
                    // handle). Evict it so the coalescer's next first-fetch
                    // builds a fresh engine. The dispose step is a defensive
                    // shutdown — vmlx makes shutdown idempotent, and
                    // tombstoning across the dispose blocks racers from
                    // building a fresh BatchEngine on the same
                    // `ModelContainer` while teardown completes.
                    batchAdapterLog.notice(
                        "registry: cached BatchEngine for \(modelName, privacy: .public) is shut down; evicting and rebuilding at maxBatchSize=\(maxBatchSize, privacy: .public)"
                    )
                    await coalescer.remove(modelName) { engine in
                        await engine.shutdown()
                    }
                    // Rebuild via the same path. The new engine is
                    // constructed with `maxBatchSize` directly, so the
                    // resize check on the recursive call sees a match and
                    // skips `updateMaxBatchSize`.
                    return await self.engine(
                        for: modelName,
                        container: container,
                        maxBatchSize: maxBatchSize
                    )
                } catch {
                    // Other errors (e.g. `invalidMaxBatchSize` from a
                    // caller bug) leave the cached engine intact — it's
                    // still serving requests at its construction value, and
                    // the next valid resize call will succeed.
                    batchAdapterLog.notice(
                        "registry: BatchEngine for \(modelName, privacy: .public) rejected updateMaxBatchSize(\(maxBatchSize, privacy: .public)) — \(String(describing: error), privacy: .public). Engine continues at cached \(cached, privacy: .public)."
                    )
                }
            }
            return engine
        }

        /// Test seam. Coalesces a concurrent first-fetch using a custom
        /// `factory`, returning whatever the factory produces. Production
        /// callers go through `engine(for:container:maxBatchSize:)`. The
        /// `maxBatchSize` argument is only used in the log line.
        internal func makeAndRegister(
            modelName: String,
            maxBatchSize: Int,
            factory: @Sendable @escaping () async -> BatchEngine
        ) async -> BatchEngine {
            let engine = await coalescer.value(for: modelName, factory: factory)
            batchAdapterLog.info(
                "registry: ready BatchEngine for \(modelName, privacy: .public) maxBatchSize=\(maxBatchSize, privacy: .public)"
            )
            return engine
        }

        /// Diagnostic accessor. Test-only; production callers do not need
        /// to inspect the coalescer's internal state. `draining` reports
        /// engines whose in-flight creation has been claimed by a
        /// concurrent `shutdownEngine` / `shutdownAll` but whose factory
        /// has not yet completed.
        internal func registrySnapshot() async -> (resolved: Int, inFlight: Int, draining: Int) {
            await coalescer.snapshot()
        }

        /// Shut down and remove the engine for `modelName`. Safe to call
        /// when no engine exists. Pending requests on the engine receive a
        /// `.cancelled` info event before the actor exits.
        ///
        /// Uses the coalescer's `dispose:` variant so the
        /// `engine.shutdown()` call runs INSIDE the `draining[key]`
        /// tombstone window. A racing `value(for:)` for the same model
        /// waits for the shutdown to complete before its post-drain fresh
        /// factory builds a new `BatchEngine` — preventing two engines on
        /// one `ModelContainer` (the Metal-abort scenario the registry
        /// exists to prevent).
        func shutdownEngine(for modelName: String) async {
            await coalescer.remove(modelName) { engine in
                await engine.shutdown()
                batchAdapterLog.info(
                    "registry: shutdown BatchEngine for \(modelName, privacy: .public)"
                )
            }
        }

        /// Shut down every cached engine. Used by `ModelRuntime.clearAll()`.
        /// Drains in-flight creations and resolved entries through the
        /// coalescer's `dispose:` variant so per-key tombstones stay set
        /// across the per-engine `shutdown()` — same race protection as
        /// `shutdownEngine(for:)`, applied to every cached entry.
        func shutdownAll() async {
            await coalescer.removeAll { modelName, engine in
                await engine.shutdown()
                batchAdapterLog.info(
                    "registry: shutdown BatchEngine for \(modelName, privacy: .public)"
                )
            }
        }

    }

    // MARK: - Image preprocessing

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Downscale CIImage attachments to a sane upper bound before tokenization.
    /// Pre-existing `URL` / `array` cases pass through untouched.
    ///
    /// Preserves `toolCalls` and `toolCallId` through the rebuild — dropping
    /// them here would silently unwind the structured tool-call handoff set
    /// up by `ModelRuntime.mapOpenAIChatToMLX`, and MiniMax (plus every other
    /// template that reads `message.tool_calls[i]`) would fall back to the
    /// old "no previous assistant message with a tool call" hard fail.
    private static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
        chat.map { message in
            let processedImages = message.images.map { userInputImage -> UserInput.Image in
                switch userInputImage {
                case .ciImage(let ciImage):
                    return .ciImage(downscaleIfNeeded(ciImage))
                default:
                    return userInputImage
                }
            }
            return MLXLMCommon.Chat.Message(
                role: message.role,
                content: message.content,
                images: processedImages,
                videos: message.videos,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId
            )
        }
    }

    // MARK: - Thinking template context

    static func additionalContext(
        for generation: GenerationParameters,
        modelName: String
    ) -> [String: any Sendable] {
        if ModelFamilyNames.isLingFamily(modelName)
            || ModelFamilyNames.isZayaFamily(modelName)
        {
            return ["enable_thinking": false]
        }
        if let disableThinking = generation.modelOptions["disableThinking"]?.boolValue {
            return ["enable_thinking": !disableThinking]
        }
        return ["enable_thinking": true]
    }

    // MARK: - Submission

    /// Tokenize the chat + tools, fetch (or create) the per-model
    /// `BatchEngine`, and submit one request via `engine.generate`. Returns
    /// the resulting `Generation` stream wrapped with cancellation plumbing.
    static func generate(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        stopSequences: [String],
        runtime: RuntimeConfig,
        maxBatchSize: Int
    ) async throws -> PreparedStream {
        let trace = generation.ttftTrace
        trace?.mark("batch_prepare_start")

        let prepared = try await prepareInput(
            modelName: modelName,
            container: container,
            buildChat: buildChat,
            buildToolsSpec: buildToolsSpec,
            generation: generation,
            trace: trace
        )

        let engine = await Registry.shared.engine(
            for: modelName,
            container: container,
            maxBatchSize: maxBatchSize
        )

        // Honor the model's shipped sampling defaults (Hugging Face
        // `generation_config.json`) when the OpenAI-wire request omits a
        // field. Without this overlay osaurus served, e.g., Qwen 3.5 397B
        // at 0.7 temperature when its recipe specifies 0.6, and Gemma-4
        // 26B-A4B with top_k disabled when the recipe specifies top_k=64.
        // Explicit client values still win — the `?? modelDefaults`
        // ordering only applies when `generation.*` is nil.
        let modelDefaults = LocalGenerationDefaults.defaults(forModelId: modelName)
        let mlxParams = ModelRuntime.makeGenerateParameters(
            temperature: generation.temperature ?? modelDefaults.temperature ?? 0.7,
            maxTokens: generation.maxTokens,
            topP: generation.topPOverride ?? modelDefaults.topP ?? runtime.topP,
            topK: modelDefaults.topK ?? 0,
            repetitionPenalty: generation.repetitionPenalty ?? modelDefaults.repetitionPenalty,
            stopSequences: stopSequences
        )

        // Best-effort per-request determinism: seed the MLX global random
        // state immediately before submission. Note: vmlx's `Sampler`
        // constructs its own `RandomState()` from time-of-day inside the
        // engine, so concurrent seeded requests against the same model
        // are NOT guaranteed reproducible. Single-request seeding still
        // benefits any MLX code path that consults `MLXRandom.globalState`.
        if let seed = generation.seed {
            MLXRandom.seed(seed)
        }

        // `engine.generate` returns `AsyncStream<Generation>` directly with
        // reasoning + tool-call extraction handled inside vmlx. We re-wrap
        // it so we can attach a producer `Task` for cancellation.
        trace?.mark("batch_submit")
        let upstream = await engine.generate(
            input: prepared.input,
            parameters: mlxParams
        )

        let (outStream, continuation) = AsyncStream<Generation>.makeStream()
        let producerTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                for await event in upstream {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            } onCancel: {
                // The upstream stream is bound to a single request inside
                // the engine; cancelling the consumer task closes it
                // cooperatively (engine emits a final `.info(.cancelled)`
                // and finishes the stream).
                continuation.finish()
            }
        }

        batchAdapterLog.info(
            "submit: model=\(modelName, privacy: .public) promptTokens=\(prepared.promptTokens.count, privacy: .public)"
        )

        return PreparedStream(
            stream: outStream,
            promptTokens: prepared.promptTokens,
            genTask: producerTask
        )
    }

    // MARK: - Tokenization

    private struct PreparedInput: @unchecked Sendable {
        let input: LMInput
        let promptTokens: [Int]
    }

    private static func prepareInput(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        trace: TTFTTrace?
    ) async throws -> PreparedInput {
        // Heap-allocated outbox so the throwing closure can hand a value back
        // across the actor boundary.
        final class OutBox: @unchecked Sendable { var result: PreparedInput? }
        let box = OutBox()

        try await container.perform { (context: MLXLMCommon.ModelContext) in
            trace?.mark("batch_container_perform_entered")
            let chat = preprocessImages(in: buildChat())
            let toolsSpec = buildToolsSpec()

            // `enable_thinking` handling. Ling-2.6 Flash is served as a
            // non-reasoning model, so force it off even when a caller omits
            // model options or an older saved preference says otherwise.
            // Other families still honor explicit `disableThinking`; when
            // unspecified, default to `true` because thinking-capable Gemma,
            // Qwen, and auto-detected templates rely on a present truthy
            // kwarg to activate reasoning.
            let additionalContext = additionalContext(for: generation, modelName: modelName)
            let userInput = MLXLMCommon.UserInput(
                chat: chat,
                processing: .init(),
                tools: toolsSpec,
                additionalContext: additionalContext
            )

            trace?.mark("batch_tokenization_start")
            let lmInput: LMInput
            do {
                lmInput = try await context.processor.prepare(input: userInput)
            } catch {
                let detail =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                throw NSError(
                    domain: "MLXBatchAdapter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                )
            }
            trace?.mark("batch_tokenization_done")

            let tokens = lmInput.text.tokens.asArray(Int.self)
            guard !tokens.isEmpty else {
                throw NSError(
                    domain: "MLXBatchAdapter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }

            box.result = PreparedInput(input: lmInput, promptTokens: tokens)
        }

        guard let prepared = box.result else {
            throw NSError(
                domain: "MLXBatchAdapter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Prepared input missing after container.perform"]
            )
        }
        return prepared
    }
}
