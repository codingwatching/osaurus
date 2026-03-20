//
//  MLXGenerationEngine.swift
//  osaurus
//
//  Encapsulates MLX message preparation and generation stream construction.
//

import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import CoreImage
import MLXVLM

struct MLXGenerationEngine {

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
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
                videos: message.videos
            )
        }
    }

    /// Holds the generation stream plus the caller-owned KV cache that was
    /// passed into (or created for) `generate()`.  Because `[any KVCache]` is
    /// not `Sendable`, we wrap it in an `@unchecked Sendable` box so it can
    /// cross the `container.perform` boundary safely -- access is serialised
    /// through the `ModelRuntime` actor.
    final class CacheBox: @unchecked Sendable {
        let cache: [any KVCache]
        init(_ cache: [any KVCache]) { self.cache = cache }
    }

    static func prepareAndGenerate(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        runtime: RuntimeConfig,
        existingCache: [any KVCache]?,
        cachedTokens: [Int]?
    ) async throws -> (AsyncStream<MLXLMCommon.Generation>, [any KVCache], [Int], Task<Void, Never>) {
        let result: (AsyncStream<MLXLMCommon.Generation>, CacheBox, [Int], Task<Void, Never>) =
            try await container.perform { (context: MLXLMCommon.ModelContext) in
                let chat = preprocessImages(in: buildChat())
                let toolsSpec = buildToolsSpec()
                let parameters = ModelRuntime.makeGenerateParameters(
                    temperature: generation.temperature ?? 0.7,
                    maxTokens: generation.maxTokens,
                    topP: generation.topPOverride ?? runtime.topP,
                    repetitionPenalty: generation.repetitionPenalty,
                    kvBits: runtime.kvBits,
                    kvGroup: runtime.kvGroup,
                    quantStart: runtime.quantStart,
                    maxKV: runtime.maxKV,
                    prefillStep: runtime.prefillStep
                )
                let additionalContext: [String: any Sendable]? =
                    generation.modelOptions["disableThinking"]?.boolValue == true
                    ? ["enable_thinking": false] : nil
                let fullInput = MLXLMCommon.UserInput(
                    chat: chat,
                    processing: .init(),
                    tools: toolsSpec,
                    additionalContext: additionalContext
                )
                let fullLMInput: LMInput
                do {
                    fullLMInput = try await context.processor.prepare(input: fullInput)
                } catch {
                    let detail =
                        (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                    throw NSError(
                        domain: "MLXGenerationEngine",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                    )
                }

                var contextWithEOS = context
                let existing = context.configuration.extraEOSTokens
                let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
                contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

                let newPromptTokens = fullLMInput.text.tokens.asArray(Int.self)
                guard !newPromptTokens.isEmpty else {
                    throw NSError(
                        domain: "MLXGenerationEngine",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                    )
                }
                var cache: [any KVCache]
                var effectiveInput = fullLMInput

                if let existingCache = existingCache, let cachedTokens = cachedTokens, fullLMInput.image == nil,
                    fullLMInput.video == nil
                {
                    // Find common prefix length
                    var commonPrefixLength = zip(newPromptTokens, cachedTokens).prefix(while: { $0 == $1 }).count

                    // We must pass at least 1 token to the model to start generation
                    if commonPrefixLength == newPromptTokens.count && commonPrefixLength > 0 {
                        commonPrefixLength -= 1
                    }

                    // Trim cache if needed
                    let cacheOffset = existingCache.first?.offset ?? 0
                    if commonPrefixLength > cacheOffset {
                        commonPrefixLength = cacheOffset
                    }

                    if commonPrefixLength < cacheOffset {
                        let toTrim = cacheOffset - commonPrefixLength
                        if canTrimPromptCache(existingCache) {
                            for layerCache in existingCache {
                                _ = layerCache.trim(toTrim)
                            }
                            cache = existingCache
                        } else {
                            // If cache cannot be trimmed, we must discard it
                            cache = makePromptCache(model: context.model, parameters: parameters)
                            commonPrefixLength = 0
                        }
                    } else {
                        cache = existingCache
                    }

                    // Slice input to only evaluate new tokens
                    if commonPrefixLength > 0 && commonPrefixLength < newPromptTokens.count && !cache.isEmpty
                        && cache[0].offset > 0
                    {
                        let newTokens = MLXArray(Array(newPromptTokens[commonPrefixLength...]))
                        effectiveInput = LMInput(
                            text: .init(tokens: newTokens),
                            image: fullLMInput.image,
                            video: fullLMInput.video
                        )
                    }
                } else {
                    // Cannot reuse cache (e.g. VLM with images, or no cached tokens)
                    cache = makePromptCache(model: context.model, parameters: parameters)
                }

                // withError converts MLX C++ errors (e.g. shape mismatches from stale caches) to catchable Swift errors
                let iterator = try withError {
                    try TokenIterator(
                        input: effectiveInput,
                        model: contextWithEOS.model,
                        cache: cache,
                        parameters: parameters
                    )
                }
                let (stream, genTask) = MLXLMCommon.generateTask(
                    promptTokenCount: newPromptTokens.count,
                    modelConfiguration: contextWithEOS.configuration,
                    tokenizer: contextWithEOS.tokenizer,
                    iterator: iterator
                )

                return (stream, CacheBox(cache), newPromptTokens, genTask)
            }
        return (result.0, result.1.cache, result.2, result.3)
    }
}
