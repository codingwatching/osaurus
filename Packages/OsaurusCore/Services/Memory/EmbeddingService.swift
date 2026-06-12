//
//  EmbeddingService.swift
//  osaurus
//
//  Provides text embedding generation via vmlx-swift's Model2Vec embedder.
//  Used by the /v1/embeddings (OpenAI) and /api/embed (Ollama) endpoints.
//

import Foundation
import MLXEmbedders
import VecturaKit
import os

public actor EmbeddingService {
    public static let shared = EmbeddingService()
    public static let modelName = "potion-base-4M"
    /// Known dimension for potion-base-4M so VecturaKit can init without loading the model.
    public static let embeddingDimension = 128

    /// Single shared embedder used by all VecturaKit indexes and the embedding API.
    /// Wrapped in MetalSafeEmbedder to coordinate embedding and generation work.
    public static let sharedEmbedder: MetalSafeEmbedder = MetalSafeEmbedder(
        inner: VMLXModel2VecEmbedder(
            modelName: modelName,
            dimension: embeddingDimension,
            tokenizerLoader: SwiftTransformersTokenizerLoader()
        )
    )

    private static let logger = Logger(subsystem: "ai.osaurus", category: "EmbeddingService")

    private var isInitialized = false

    private init() {}

    /// Generate embeddings for one or more texts.
    public func embed(texts: [String]) async throws -> [[Float]] {
        if !isInitialized {
            _ = try await Self.sharedEmbedder.dimension
            isInitialized = true
            Self.logger.info("EmbeddingService initialized")
        }
        return try await Self.sharedEmbedder.embed(texts: texts)
    }
}
