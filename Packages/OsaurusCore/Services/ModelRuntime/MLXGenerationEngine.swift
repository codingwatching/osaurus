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
import Tokenizers
import os.log

private let engineLog = Logger(subsystem: "com.dinoki.osaurus", category: "Generation")

/// Returns the offset of the first KV cache layer that actually tracks position (i.e., not a
/// MambaCache / ArraysCache layer whose `offset` is always 0). Hybrid models like Qwen3.5-27B
/// interleave linear-attention (MambaCache) and full-attention (KVCacheSimple) layers; reading
/// `cache.first?.offset` on those models always returns 0 even after a full prefill.
func effectiveCacheOffset(_ cache: [any KVCache]) -> Int {
    for layer in cache {
        // MambaCache (and its parent ArraysCache) never updates offset — skip them.
        if layer is ArraysCache { continue }
        return layer.offset
    }
    // All layers are Mamba-style; fall back to first layer (offset will be 0 but that's correct).
    return cache.first?.offset ?? 0
}

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
    ) async throws -> (AsyncStream<MLXLMCommon.TokenGeneration>, any Tokenizer, [any KVCache], [Int], Task<Void, Never>, ToolCallFormat)
    {
        let result: (AsyncStream<MLXLMCommon.TokenGeneration>, any Tokenizer, CacheBox, [Int], Task<Void, Never>, ToolCallFormat) =
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
                engineLog.info(
                    "prepareAndGenerate: promptTokens=\(newPromptTokens.count, privacy: .public) hasImage=\(fullLMInput.image != nil, privacy: .public)"
                )
                print(
                    "[MLXGenerationEngine] promptTokens=\(newPromptTokens.count) hasImage=\(fullLMInput.image != nil)"
                )
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

                    // Trim cache if needed.
                    // Use effectiveCacheOffset() to skip MambaCache/ArraysCache layers (offset always 0).
                    let cacheOffset = effectiveCacheOffset(existingCache)
                    // Log tokens around the divergence point to diagnose chat-template differences
                    let divergeIdx = commonPrefixLength
                    let loStart = max(0, divergeIdx - 2)
                    let loEnd = min(min(newPromptTokens.count, cachedTokens.count), divergeIdx + 4)
                    if loEnd > loStart {
                        let newSlice = Array(newPromptTokens[loStart ..< loEnd])
                        let cachedSlice = Array(cachedTokens[loStart ..< loEnd])
                        debugLog(
                            "[MLXGenerationEngine] diverge@\(divergeIdx): new[\(loStart)..<\(loEnd)]=\(newSlice) cached[\(loStart)..<\(loEnd)]=\(cachedSlice)"
                        )
                    }
                    debugLog(
                        "[MLXGenerationEngine] cache reuse: newTokens=\(newPromptTokens.count) cachedTokens=\(cachedTokens.count) commonPrefix=\(commonPrefixLength) cacheOffset=\(cacheOffset) canTrim=\(canTrimPromptCache(existingCache))"
                    )
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
                            debugLog("[MLXGenerationEngine] trimmed cache by \(toTrim) tokens, reusing")
                        } else {
                            // If cache cannot be trimmed, we must discard it
                            cache = makePromptCache(model: context.model, parameters: parameters)
                            commonPrefixLength = 0
                            debugLog("[MLXGenerationEngine] cache not trimmable, full prefill")
                        }
                    } else {
                        cache = existingCache
                        debugLog("[MLXGenerationEngine] cache offset matches, reusing directly")
                    }

                    // Slice input to only evaluate new tokens.
                    // Use effectiveCacheOffset to account for hybrid models where cache[0] may be
                    // a MambaCache (offset always 0) and the true offset lives in a later layer.
                    if commonPrefixLength > 0 && commonPrefixLength < newPromptTokens.count && !cache.isEmpty
                        && effectiveCacheOffset(cache) > 0
                    {
                        let newTokens = MLXArray(Array(newPromptTokens[commonPrefixLength...]))
                        effectiveInput = LMInput(
                            text: .init(tokens: newTokens),
                            image: fullLMInput.image,
                            video: fullLMInput.video
                        )
                        debugLog("[MLXGenerationEngine] sliced input to \(newTokens.shape) new tokens")
                    }
                } else {
                    // Cannot reuse cache (e.g. VLM with images, or no cached tokens)
                    cache = makePromptCache(model: context.model, parameters: parameters)
                    debugLog(
                        "[MLXGenerationEngine] no existing cache, full prefill. existingCache=\(existingCache != nil) cachedTokens=\(cachedTokens?.count ?? -1)"
                    )
                }

                // withError converts MLX C++ errors (e.g. shape mismatches from stale caches) to catchable Swift errors
                engineLog.info(
                    "prepareAndGenerate: constructing TokenIterator effectiveTokens=\(effectiveInput.text.tokens.dim(0), privacy: .public)"
                )
                print(
                    "[MLXGenerationEngine] constructing TokenIterator effectiveTokens=\(effectiveInput.text.tokens.dim(0))"
                )
                let iterator = try withError {
                    try TokenIterator(
                        input: effectiveInput,
                        model: contextWithEOS.model,
                        cache: cache,
                        parameters: parameters
                    )
                }
                let postPrefillOffset = effectiveCacheOffset(cache)
                debugLog(
                    "[MLXGenerationEngine] post-prefill effectiveCacheOffset=\(postPrefillOffset) cacheCount=\(cache.count) cacheTypes=\(cache.prefix(4).map { type(of: $0) })"
                )
                print("[MLXGenerationEngine] post-prefill effectiveCacheOffset=\(postPrefillOffset)")
                let (stream, genTask) = MLXLMCommon.generateTokenTask(
                    promptTokenCount: newPromptTokens.count,
                    modelConfiguration: contextWithEOS.configuration,
                    tokenizer: contextWithEOS.tokenizer,
                    iterator: iterator
                )
                engineLog.info("prepareAndGenerate: generateTokenTask created, returning stream")
                print("[MLXGenerationEngine] generateTokenTask created, returning stream")

                let toolCallFormat = contextWithEOS.configuration.toolCallFormat ?? .json
                return (stream, contextWithEOS.tokenizer, CacheBox(cache), newPromptTokens, genTask, toolCallFormat)
            }
        return (result.0, result.1, result.2.cache, result.3, result.4, result.5)
    }
}
