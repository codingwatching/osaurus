//
//  MLXGenerationEngine.swift
//  osaurus
//
//  Encapsulates MLX message preparation and generation stream construction.
//

import Foundation
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
        existingCache: [any KVCache]?
    ) async throws -> (AsyncStream<MLXLMCommon.Generation>, [any KVCache]) {
        let result: (AsyncStream<MLXLMCommon.Generation>, CacheBox) = try await container.perform {
            (context: MLXLMCommon.ModelContext) in
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

            // Pre-create the cache when none exists so we own it and can
            // persist it after generation.  When existingCache is provided,
            // generate() updates it in-place (the main perf win).
            let cache = existingCache ?? makePromptCache(model: context.model, parameters: parameters)

            let stream = try MLXLMCommon.generate(
                input: fullLMInput,
                cache: cache,
                parameters: parameters,
                context: contextWithEOS
            )

            return (stream, CacheBox(cache))
        }
        return (result.0, result.1.cache)
    }
}
