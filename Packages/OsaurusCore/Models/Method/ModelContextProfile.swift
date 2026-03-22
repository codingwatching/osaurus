//
//  ModelContextProfile.swift
//  osaurus
//
//  Defines context limits per model tier: how many methods and tools to load,
//  search thresholds, and whether to include compact fallback indices.
//

import Foundation

// MARK: - ModelTier

public enum ModelTier: String, Sendable {
    case frontier
    case capable
    case local
}

// MARK: - ModelContextProfile

public struct ModelContextProfile: Sendable {
    public let tier: ModelTier
    public let maxMethods: Int
    public let maxTools: Int?
    public let methodThreshold: Float
    public let loadMethodIndex: Bool
    public let loadToolIndex: Bool

    public static let frontier = ModelContextProfile(
        tier: .frontier,
        maxMethods: 10,
        maxTools: nil,
        methodThreshold: 0.3,
        loadMethodIndex: true,
        loadToolIndex: false
    )

    public static let capable = ModelContextProfile(
        tier: .capable,
        maxMethods: 5,
        maxTools: 15,
        methodThreshold: 0.5,
        loadMethodIndex: true,
        loadToolIndex: true
    )

    public static let local = ModelContextProfile(
        tier: .local,
        maxMethods: 2,
        maxTools: 5,
        methodThreshold: 0.7,
        loadMethodIndex: false,
        loadToolIndex: true
    )

    private static let frontierIdentifiers: Set<String> = [
        "opus", "gpt-4o", "gpt-4-turbo", "gpt-4.1", "o3", "o4-mini",
        "gemini-2.5-pro", "deepseek-r1",
    ]

    public static func profile(for modelId: String) -> ModelContextProfile {
        if SystemPromptBuilder.isLocalModel(modelId) {
            return .local
        }

        let lowered = modelId.lowercased()
        for id in frontierIdentifiers {
            if lowered.contains(id) { return .frontier }
        }

        return .capable
    }
}
