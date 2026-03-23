//
//  ModelContextProfile.swift
//  osaurus
//
//  Defines context limits per user-selected context mode: how many methods
//  and tools to load, search thresholds, and whether to include compact
//  fallback indices. The user picks Full / Balanced / Focused in the UI.
//

import Foundation

// MARK: - ContextMode

public enum ContextMode: String, Codable, Sendable, CaseIterable {
    case full
    case balanced
    case focused
}

// MARK: - ModelContextProfile

public struct ModelContextProfile: Sendable {
    public let mode: ContextMode
    public let maxMethods: Int
    public let maxTools: Int?
    public let methodThreshold: Float
    public let loadMethodIndex: Bool
    public let loadToolIndex: Bool

    public static let full = ModelContextProfile(
        mode: .full,
        maxMethods: 10,
        maxTools: nil,
        methodThreshold: 0.3,
        loadMethodIndex: true,
        loadToolIndex: false
    )

    public static let balanced = ModelContextProfile(
        mode: .balanced,
        maxMethods: 5,
        maxTools: 15,
        methodThreshold: 0.5,
        loadMethodIndex: true,
        loadToolIndex: true
    )

    public static let focused = ModelContextProfile(
        mode: .focused,
        maxMethods: 2,
        maxTools: 5,
        methodThreshold: 0.7,
        loadMethodIndex: false,
        loadToolIndex: true
    )

    @MainActor
    public static func current() -> ModelContextProfile {
        let mode = ChatConfigurationStore.load().contextMode
        return profile(for: mode)
    }

    public static func profile(for mode: ContextMode) -> ModelContextProfile {
        switch mode {
        case .full: return .full
        case .balanced: return .balanced
        case .focused: return .focused
        }
    }

    // MARK: - Suggestion for Default

    private static let fullIdentifiers: Set<String> = [
        "opus", "gpt-4o", "gpt-4-turbo", "gpt-4.1", "o3", "o4-mini",
        "gemini-2.5-pro", "deepseek-r1",
    ]

    public static func suggestedMode(for modelId: String) -> ContextMode {
        if SystemPromptBuilder.isLocalModel(modelId) {
            return .focused
        }

        let lowered = modelId.lowercased()
        for id in fullIdentifiers {
            if lowered.contains(id) { return .full }
        }

        return .balanced
    }
}
