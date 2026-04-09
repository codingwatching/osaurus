//
//  SlashCommand.swift
//  osaurus
//
//  A named shortcut that expands to a prompt template or triggers a built-in
//  action from the chat input. Users invoke commands by typing /name.
//

import Foundation

/// How the command behaves when selected from the popup.
public enum SlashCommandKind: String, Codable, Sendable {
    /// Executes a side-effect built into the app (e.g. clear history, open model picker).
    case action
    /// Replaces the /command token with a prompt template the user continues typing.
    case template
    /// Activates a Skill for the next sent message (injects skill instructions into system context).
    case skill
}

/// A slash command available in the chat input.
public struct SlashCommand: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var description: String
    /// SF Symbol name shown in the popup row.
    public var icon: String
    public var kind: SlashCommandKind
    /// Text inserted into the input field when kind == .template.
    public var template: String?
    public let isBuiltIn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        icon: String = "text.bubble",
        kind: SlashCommandKind = .template,
        template: String? = nil,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.kind = kind
        self.template = template
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Built-in Commands

extension SlashCommand {
    /// Fixed built-in commands. IDs are stable so they can be matched by name.
    public static let builtIns: [SlashCommand] = [
        SlashCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            name: "clear",
            description: "Clear the current conversation",
            icon: "trash",
            kind: .action,
            isBuiltIn: true
        ),
        SlashCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            name: "model",
            description: "Switch the AI model",
            icon: "cpu",
            kind: .action,
            isBuiltIn: true
        ),
        SlashCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            name: "help",
            description: "Show available commands and shortcuts",
            icon: "questionmark.circle",
            kind: .action,
            isBuiltIn: true
        ),
    ]
}
