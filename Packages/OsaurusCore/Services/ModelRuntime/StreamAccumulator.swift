//
//  StreamAccumulator.swift
//  osaurus
//
//  Consumes MLX generation events and emits typed ModelRuntimeEvent with
//  token slicing, stop-sequence handling, and tool-call signaling.
//

import Foundation
import MLXLMCommon

struct StreamAccumulator {
    static func accumulate(
        events: AsyncStream<MLXLMCommon.Generation>,
        stopSequences: [String],
        tools: [Tool]?,
        generationTask: Task<Void, Never>? = nil
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let producerTask = Task {
            var rollingBuffer = ""
            var bufferStartOffset = 0
            var emittedCount = 0

            let maxStopLen = stopSequences.map { $0.count }.max() ?? 0
            let shouldCheckStop = !stopSequences.isEmpty
            let maxBufferSize = 10_000
            let pruneToSize = 5_000

            // Brace-depth tracking avoids expensive regex scans on every token.
            // Only trigger tool detection when depth returns to zero after being positive.
            let hasTools = tools != nil && !(tools?.isEmpty ?? true)
            var braceDepth = 0
            var seenOpenBrace = false

            for await event in events {
                if Task.isCancelled {
                    generationTask?.cancel()
                    continuation.finish()
                    return
                }
                if let toolCall = event.toolCall {
                    generationTask?.cancel()
                    let argsData = try? JSONSerialization.data(
                        withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue }
                    )
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    continuation.yield(.toolInvocation(name: toolCall.function.name, argsJSON: argsString))
                    continuation.finish()
                    return
                }
                if let info = event.info {
                    print(
                        String(
                            format: "[MLX] prompt: %d tokens %.1f tok/s (%.2fs) | gen: %d tokens %.1f tok/s (%.2fs)",
                            info.promptTokenCount,
                            info.promptTokensPerSecond,
                            info.promptTime,
                            info.generationTokenCount,
                            info.tokensPerSecond,
                            info.generateTime
                        )
                    )
                    continue
                }
                guard let token = event.chunk, !token.isEmpty else { continue }

                rollingBuffer += token

                if rollingBuffer.count > maxBufferSize {
                    let removeCount = rollingBuffer.count - pruneToSize
                    rollingBuffer.removeFirst(removeCount)
                    bufferStartOffset += removeCount
                }

                // Optimized tool detection: track brace depth to avoid scanning on every '}' token.
                // Only run the expensive regex detection when we see a complete JSON object.
                if hasTools {
                    for ch in token {
                        if ch == "{" {
                            braceDepth += 1; seenOpenBrace = true
                        } else if ch == "}" {
                            braceDepth = max(0, braceDepth - 1)
                        }
                    }

                    if seenOpenBrace && braceDepth == 0 {
                        if let tools,
                            let (name, argsJSON) = ToolDetection.detectInlineToolCall(in: rollingBuffer, tools: tools)
                        {
                            generationTask?.cancel()
                            continuation.yield(.toolInvocation(name: name, argsJSON: argsJSON))
                            continuation.finish()
                            return
                        }
                        seenOpenBrace = false
                    }
                }

                if shouldCheckStop {
                    let checkLen = maxStopLen + token.count + 1

                    let searchStart =
                        rollingBuffer.index(
                            rollingBuffer.endIndex,
                            offsetBy: -checkLen,
                            limitedBy: rollingBuffer.startIndex
                        ) ?? rollingBuffer.startIndex
                    let searchRange = searchStart ..< rollingBuffer.endIndex

                    if let match = stopSequences.compactMap({ s -> (String, Range<String.Index>)? in
                        guard let range = rollingBuffer.range(of: s, range: searchRange) else { return nil }
                        return (s, range)
                    }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                        let stopRange = match.1

                        let stopLocalIndex = rollingBuffer.distance(
                            from: rollingBuffer.startIndex,
                            to: stopRange.lowerBound
                        )
                        let stopGlobalIndex = bufferStartOffset + stopLocalIndex

                        if stopGlobalIndex > emittedCount {
                            let yieldGlobalStart = max(emittedCount, bufferStartOffset)
                            let yieldGlobalEnd = stopGlobalIndex

                            if yieldGlobalStart < yieldGlobalEnd {
                                let localStart = yieldGlobalStart - bufferStartOffset
                                let localEnd = yieldGlobalEnd - bufferStartOffset

                                if localStart >= 0 && localEnd <= rollingBuffer.count {
                                    let startIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localStart)
                                    let endIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localEnd)
                                    let content = String(rollingBuffer[startIdx ..< endIdx])
                                    if !content.isEmpty { continuation.yield(.tokens(content)) }
                                }
                            }
                        }

                        generationTask?.cancel()
                        continuation.finish()
                        return
                    }
                }

                continuation.yield(.tokens(token))
                emittedCount += token.count
            }
            if let generationTask {
                await generationTask.value
            }
            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
            generationTask?.cancel()
        }

        return stream
    }
}
